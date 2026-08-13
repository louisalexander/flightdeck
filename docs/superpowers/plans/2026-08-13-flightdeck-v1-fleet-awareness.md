# Flightdeck v1 — Fleet Awareness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Row 1 of a Stream Deck XL into a live, ambient annunciator panel for every running Claude Code agent — colour is state, label is repo and task, press focuses that session, long-press tears it down under guard.

**Architecture:** Claude Code hooks write one JSON file per agent into `~/.fleet/sessions/`. `fleet-reconcile` turns those files into a sticky slot→agent map at `~/.fleet/slots.json`. A deliberately dumb Stream Deck plugin watches that one file, paints eight keys, and shells out to `bin/fleet-press` on input. All decision logic lives in Python scripts editable without a rebuild.

**Tech Stack:** Python 3.9-compatible (stdlib only), osascript (iTerm2 AppleScript), launchd, Node 23 + TypeScript + `@elgato/streamdeck` SDK v2. Tested with bats-core 1.14; `install.sh` linted with shellcheck 0.11.

**Spec:** `docs/superpowers/specs/2026-08-13-streamdeck-fleet-design.md`

## Global Constraints

- **Python 3.9 syntax, standard library only.** No third-party packages, no venv, no `jq`. 3.9 is the floor because CommandLineTools ships 3.9.6 and that is what launchd resolves to. Avoid `match`, and `X | Y` in annotations. `dict1 | dict2` merging is fine (3.9+).
- **Interpreter pinning is mandatory.** This machine has four `python3` on `PATH`: an interactive shell gets Homebrew 3.13.5, launchd gets CommandLineTools 3.9.6. Scripts keep `#!/usr/bin/env python3` in the repo so the tree stays clean, and **every automated caller is pinned to an absolute path**: hooks in `settings.json`, the launchd plist, and the plugin (which reads the path from `~/.fleet/interpreter`, written by `install.sh`).
- **Hooks always exit 0.** No hook may fail, hang, or write to stdout. A bug here must never break a real agent. Errors go to `~/.fleet/fleet.log` only.
- **All writes atomic.** Write to a temp file in the same directory, then `os.replace()`. The plugin must never read a partial file.
- **Exactly five hooks:** `SessionStart`, `UserPromptSubmit`, `Notification`, `Stop`, `SessionEnd`. **Never** `PreToolUse`/`PostToolUse` — they fire per tool call and would tax every agent action.
- **`subprocess` is always called with a list, never `shell=True`.** This is what structurally eliminates the word-splitting risk in `fleet-kill`; a repo path containing a space must never become two arguments.
- **All state under `~/.fleet/`.** Identical path on every machine.
- **Node ≥ 20** for the plugin (machine has v23.11.0). **Claude Code ≥ 2.1.91** for deep links (machine has 2.1.231).
- **Never build a `claude-cli://` link from untrusted input.** Literals in `fleet.local.json` only. A patched RCE smuggled `--settings` through the `q` parameter.
- **`config/fleet.local.json` is gitignored** and holds only pins and the vault path.

### Visual constraints (from the UX design)

- **Background colour is exclusively lifecycle state.** No repo colours, no emoji, no gradients, no nested chrome, no ornamental borders.
- **Red is exclusively observed failure.** Never for pending confirmation. The armed state is near-black with an amber warning triangle.
- **Glyphs are SVG geometry, never `<text>`.** Helvetica lacks U+25B2/U+25B6, so text glyphs would fall back to an arbitrary font with different metrics, or fail to render.
- **Empty is fully black with no content.** Absence should look absent.
- **Labels shorten token-aware, never blind truncation.**
- **No animation in v1.**

---

### Task 1: Hook contract spike

Everything downstream assumes five hook names and their payload shapes. The `claude` binary is compiled and could not be inspected. **This task is a gate: do not start Task 3 until `docs/hook-contract.md` exists.**

The probe is scoped to this repo only, so it cannot disturb the agents already running on this machine.

**Files:**
- Create: `.claude/settings.json` (project-scoped, temporary probe config)
- Create: `tools/probe-hook.sh`
- Create: `docs/hook-contract.md`

**Interfaces:**
- Consumes: nothing
- Produces: `docs/hook-contract.md`, documenting for each of the five hooks: exact event name, whether it fires, and the full stdin JSON payload with field names. Task 3 reads field names from this file.

- [ ] **Step 1: Write the probe script**

Shell is fine here — this is a throwaway dumper that never ships.

Create `tools/probe-hook.sh`:

```bash
#!/usr/bin/env bash
# Dumps a hook's stdin payload for contract discovery. Never fails. Throwaway.
set -u
OUT="${HOME}/.fleet-probe"
mkdir -p "$OUT" 2>/dev/null
EVENT="${1:-unknown}"
{
  printf '=== %s @ %s ===\n' "$EVENT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'ITERM_SESSION_ID=%s\n' "${ITERM_SESSION_ID:-<unset>}"
  printf 'CLAUDE_CODE_SESSION_ID=%s\n' "${CLAUDE_CODE_SESSION_ID:-<unset>}"
  printf 'PWD=%s PPID=%s\n' "$PWD" "$PPID"
  printf -- '--- stdin ---\n'
  cat
  printf '\n'
} >> "$OUT/probe.log" 2>/dev/null
exit 0
```

```bash
chmod +x tools/probe-hook.sh
```

- [ ] **Step 2: Register all five hooks, scoped to this repo only**

Create `.claude/settings.json`. Being project-scoped it applies only to sessions started inside `~/code/flightdeck`, leaving your other running agents untouched.

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "$CLAUDE_PROJECT_DIR/tools/probe-hook.sh SessionStart" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "$CLAUDE_PROJECT_DIR/tools/probe-hook.sh UserPromptSubmit" }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "$CLAUDE_PROJECT_DIR/tools/probe-hook.sh Notification" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "$CLAUDE_PROJECT_DIR/tools/probe-hook.sh Stop" }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "$CLAUDE_PROJECT_DIR/tools/probe-hook.sh SessionEnd" }] }]
  }
}
```

If Claude Code rejects any event name on startup, that name is wrong — record the rejection and find the correct name via `/hooks` in an interactive session.

- [ ] **Step 3: Exercise every transition**

```bash
rm -rf ~/.fleet-probe
```

In a **new** terminal window:

```bash
cd ~/code/flightdeck && claude
```

Drive each transition deliberately:
1. Launch → expect `SessionStart`.
2. Submit any prompt, e.g. `list the files here` → expect `UserPromptSubmit`.
3. Let it finish → expect `Stop`.
4. Ask for something needing approval, e.g. `run: rm -i /tmp/nonexistent-flightdeck-probe` → **expect `Notification` when the permission prompt appears.** This is the critical one.
5. `/exit` → expect `SessionEnd`.

- [ ] **Step 4: Record the contract**

```bash
cat ~/.fleet-probe/probe.log
```

Write `docs/hook-contract.md` containing, for each event: whether it fired, at what moment, and the verbatim stdin JSON. Explicitly record the field names for session id, cwd, and (for `SessionEnd`) any reason/exit field.

**Record the answer to the decisive question:** did `Notification` fire when the permission prompt appeared, and does its payload distinguish a permission request from an idle nudge?

If `Notification` did **not** fire on the permission prompt, stop and flag it. Per the spec, iTerm2 title-glyph polling is the designed fallback and the plan needs revising before Task 3.

- [ ] **Step 5: Remove the probe and commit**

```bash
rm -f .claude/settings.json
rm -rf ~/.fleet-probe
git add tools/probe-hook.sh docs/hook-contract.md
git commit -m "docs: record verified Claude Code hook contract"
```

---

### Task 2: Scaffold, shared library, and test harness

**Files:**
- Create: `.gitignore`, `config/fleet.json`, `config/fleet.local.example.json`
- Create: `bin/fleetlib.py`, `bin/fleet-config`
- Create: `tests/run.sh`, `tests/config.bats`, `tests/labels.bats`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `bin/fleetlib.py` — the shared module every script imports. Public surface:
    - `fleet_home() -> Path`, `sessions_dir()`, `slots_path()`, `armed_path()`, `events_path()`, `log_path()`
    - `load_config() -> dict` (layered, `FLEET_CONFIG_DIR` honoured)
    - `read_json(path, default=None)`, `write_json_atomic(path, obj)`, `append_jsonl(path, obj)`
    - `log(msg)`
    - `shorten(text, max_chars, strip_prefixes) -> str`
    - `git(args, cwd) -> (returncode, stdout)`
  - `bin/fleet-config` — prints merged config JSON; `--shorten TEXT [MAX]` exposes the label rule for testing and hand inspection.
  - `tests/run.sh` — single entry point: lints `install.sh` with shellcheck, then runs the bats suite.
  - `FLEET_HOME` env var, defaulting to `~/.fleet`, honoured by **every** script.

**Test conventions used by every task from here on.** bats gives each `@test` a fresh `$BATS_TEST_TMPDIR`, so tests are isolated by construction. `run <cmd>` captures `$status` and `$output`. A test asserting an *ordered sequence* (slot stickiness, arm-then-confirm) keeps the whole sequence inside one `@test`.

- [ ] **Step 1: Write the failing tests**

Create `tests/config.bats`:

```bash
#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  mkdir -p "$FLEET_CONFIG_DIR"
  cat >"$FLEET_CONFIG_DIR/fleet.json" <<'EOF'
{"slots":{"count":8},"timings":{"armMs":3000},"states":{"idle":{"color":"#25282D"}}}
EOF
}

@test "base config is returned when no local file exists" {
  run "$BIN/fleet-config"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | python3 -c 'import json,sys;print(json.load(sys.stdin)["slots"]["count"])')" = "8" ]
}

@test "local config deep-merges without clobbering siblings" {
  cat >"$FLEET_CONFIG_DIR/fleet.local.json" <<'EOF'
{"timings":{"armMs":5000},"pins":{"7":{"host":"pinned-app","app":"ChatGPT"}}}
EOF
  run "$BIN/fleet-config"
  [ "$status" -eq 0 ]
  py() { echo "$output" | python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }
  [ "$(py 'd["timings"]["armMs"]')"      = "5000" ]
  [ "$(py 'd["pins"]["7"]["app"]')"      = "ChatGPT" ]
  [ "$(py 'd["slots"]["count"]')"        = "8" ]
  [ "$(py 'd["states"]["idle"]["color"]')" = "#25282D" ]
}

@test "malformed local config falls back to base instead of emitting garbage" {
  printf '{ this is not json' >"$FLEET_CONFIG_DIR/fleet.local.json"
  run "$BIN/fleet-config"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | python3 -c 'import json,sys;print(json.load(sys.stdin)["slots"]["count"])')" = "8" ]
}

@test "missing base config emits valid empty JSON rather than nothing" {
  rm -f "$FLEET_CONFIG_DIR/fleet.json"
  run "$BIN/fleet-config"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | python3 -c 'import json,sys;print(type(json.load(sys.stdin)).__name__)')" = "dict" ]
}
```

Create `tests/labels.bats`. These assert the exact worked examples in the spec:

```bash
#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_CONFIG_DIR="$ROOT/config"
}

short() { "$BIN/fleet-config" --shorten "$1" "${2:-11}"; }

@test "an already-short label is unchanged" {
  [ "$(short flightdeck)" = "flightdeck" ]
}

@test "a single long token is truncated" {
  [ "$(short averyverylongsingletoken)" = "averyverylo" ]
}

@test "keeps first and last token, trimming the longer one" {
  [ "$(short break-state-exit-handling)" = "break-handl" ]
}

@test "protects the last token when the first already fits" {
  [ "$(short agent-hook-notification)" = "agent-notif" ]
}

@test "strips known branch prefixes before shortening" {
  [ "$(short feat/stream-deck-renderer)" = "strea-rende" ]
}

@test "splits on underscores and slashes as well as hyphens" {
  [ "$(short my_module/deep_nested_thing)" = "my-thing" ]
}

@test "empty input yields empty output" {
  [ -z "$(short '')" ]
}

@test "output never exceeds the maximum" {
  result="$(short some-extremely-long-branch-name-here 11)"
  [ "${#result}" -le 11 ]
}
```

- [ ] **Step 2: Write the test entry point**

Create `tests/run.sh`:

```bash
#!/usr/bin/env bash
# Single entry point: lint shell bootstrap, compile-check Python, run bats.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rc=0

printf '== shellcheck (bootstrap shell only) ==\n'
targets=""
for f in "$ROOT"/install.sh "$ROOT"/tools/*.sh; do
  [ -f "$f" ] && targets="$targets $f"
done
if [ -z "$targets" ]; then
  printf 'nothing to lint yet\n'
# shellcheck disable=SC2086  # $targets is intentionally a word list of paths
elif shellcheck -s bash -S warning $targets; then
  printf 'clean\n'
else
  rc=1
fi

printf '\n== python syntax ==\n'
if python3 -m compileall -q "$ROOT/bin" >/dev/null 2>&1; then
  printf 'clean\n'
else
  python3 -m compileall -q "$ROOT/bin"
  rc=1
fi

printf '\n== bats ==\n'
bats "$ROOT/tests" || rc=1

exit "$rc"
```

```bash
chmod +x tests/run.sh
```

`compileall` is a cheap syntax gate that catches typos before bats runs a script and reports a confusing runtime failure. It is not a linter — correctness lives in the tests.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `./tests/run.sh`
Expected: FAIL — all 12 tests fail because `bin/fleet-config` does not exist.

- [ ] **Step 4: Write `bin/fleetlib.py`**

```python
"""Shared helpers for flightdeck. Standard library only, Python 3.9 compatible."""

import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# --- paths -----------------------------------------------------------------

def fleet_home():
    return Path(os.environ.get("FLEET_HOME") or (Path.home() / ".fleet"))

def sessions_dir():
    return fleet_home() / "sessions"

def slots_path():
    return fleet_home() / "slots.json"

def armed_path():
    return fleet_home() / "armed.json"

def events_path():
    return fleet_home() / "events.jsonl"

def log_path():
    return fleet_home() / "fleet.log"

def repo_root():
    return Path(__file__).resolve().parent.parent

def config_dir():
    env = os.environ.get("FLEET_CONFIG_DIR")
    return Path(env) if env else repo_root() / "config"

# --- logging ---------------------------------------------------------------

def log(message):
    """Best-effort logging. Never raises — callers may be inside a hook."""
    try:
        fleet_home().mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with open(log_path(), "a", encoding="utf-8") as handle:
            handle.write("{} {}\n".format(stamp, message))
    except Exception:
        pass

# --- json io ---------------------------------------------------------------

def read_json(path, default=None):
    """Returns default on any failure, including a partially written file."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return default

def write_json_atomic(path, obj):
    """Writes via a temp file in the same directory, then os.replace()."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".{}.".format(path.name))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(obj, handle, separators=(",", ":"))
        os.replace(tmp, str(path))
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise

def append_jsonl(path, obj):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(obj, separators=(",", ":")) + "\n")

# --- config ----------------------------------------------------------------

def deep_merge(base, over):
    out = dict(base)
    for key, value in over.items():
        if key in out and isinstance(out[key], dict) and isinstance(value, dict):
            out[key] = deep_merge(out[key], value)
        else:
            out[key] = value
    return out

def load_config():
    base = read_json(config_dir() / "fleet.json", {}) or {}
    local = read_json(config_dir() / "fleet.local.json", {}) or {}
    if not isinstance(base, dict):
        base = {}
    if not isinstance(local, dict):
        local = {}
    return deep_merge(base, local)

# --- labels ----------------------------------------------------------------

DEFAULT_PREFIXES = ("feat/", "fix/", "chore/", "feature/")

def shorten(text, max_chars=11, strip_prefixes=DEFAULT_PREFIXES):
    """Token-aware shortening.

    Blind truncation destroys the distinguishing part of a name:
    break-state-exit-handling and break-state-entry-handling both truncate
    to 'break-state'. So keep the first and last tokens and trim whichever
    is currently longer, tie-breaking toward trimming the first -- the last
    token is usually what distinguishes sibling branches.
    """
    text = (text or "").strip()
    for prefix in strip_prefixes or ():
        if text.startswith(prefix):
            text = text[len(prefix):]
            break

    tokens = [t for t in re.split(r"[-_/]+", text) if t]
    if not tokens:
        return ""
    if len(tokens) == 1:
        return tokens[0][:max_chars]

    joined = "-".join(tokens)
    if len(joined) <= max_chars:
        return joined

    first, last = tokens[0], tokens[-1]
    while len(first) + len(last) + 1 > max_chars:
        if len(first) >= len(last):
            if len(first) <= 1:
                break
            first = first[:-1]
        else:
            if len(last) <= 1:
                break
            last = last[:-1]
    return (first + "-" + last)[:max_chars]

# --- process ---------------------------------------------------------------

def git(args, cwd):
    """Runs git with an argument LIST -- never a shell string.

    This is what makes a repo path containing a space safe.
    """
    try:
        proc = subprocess.run(
            ["git", "-C", str(cwd)] + list(args),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        return proc.returncode, proc.stdout.decode("utf-8", "replace").strip()
    except Exception:
        return 1, ""

def add_bin_to_path():
    """Lets sibling scripts `import fleetlib` regardless of cwd."""
    here = str(Path(__file__).resolve().parent)
    if here not in sys.path:
        sys.path.insert(0, here)
```

- [ ] **Step 5: Write `bin/fleet-config`**

```python
#!/usr/bin/env python3
"""Prints merged configuration, or exercises the label rule.

  fleet-config                      -> merged config JSON
  fleet-config --shorten TEXT [MAX] -> the deck label for TEXT
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fleetlib  # noqa: E402


def main(argv):
    if len(argv) >= 2 and argv[1] == "--shorten":
        text = argv[2] if len(argv) > 2 else ""
        max_chars = int(argv[3]) if len(argv) > 3 else 11
        cfg = fleetlib.load_config()
        prefixes = cfg.get("labels", {}).get("stripPrefixes", fleetlib.DEFAULT_PREFIXES)
        print(fleetlib.shorten(text, max_chars, prefixes))
        return 0

    print(json.dumps(fleetlib.load_config(), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

```bash
chmod +x bin/fleet-config
```

- [ ] **Step 6: Write the config files**

Create `config/fleet.json`. Colours and glyph names come from the UX design; `glyphColor` and `textColor` exist because white text on `#F5A623` amber has poor contrast.

```json
{
  "slots": { "count": 8 },
  "timings": { "armMs": 3000, "longPressMs": 800, "reaperSeconds": 15 },
  "labels": { "maxChars": 11, "stripPrefixes": ["feat/", "fix/", "chore/", "feature/"] },
  "states": {
    "blocked": { "color": "#F5A623", "glyph": "blocked", "glyphColor": "#1A1200", "textColor": "#1A1200" },
    "working": { "color": "#1256A3", "glyph": "working", "glyphColor": "#FFFFFFCC", "textColor": "#FFFFFF" },
    "done":    { "color": "#238636", "glyph": "done",    "glyphColor": "#FFFFFFEE", "textColor": "#FFFFFF" },
    "idle":    { "color": "#25282D", "glyph": "idle",    "glyphColor": "#FFFFFF55", "textColor": "#FFFFFF99" },
    "failed":  { "color": "#B42318", "glyph": "failed",  "glyphColor": "#FFFFFFEE", "textColor": "#FFFFFF" },
    "empty":   { "color": "#000000", "glyph": "none",    "glyphColor": "#000000",   "textColor": "#000000" },
    "armed":   { "color": "#0A0A0A", "glyph": "armed",   "glyphColor": "#F5A623",   "textColor": "#F5A623" }
  }
}
```

Create `config/fleet.local.example.json`:

```json
{
  "pins": {
    "7": { "host": "pinned-app", "app": "ChatGPT", "label_top": "ask", "label_bottom": "ChatGPT" }
  },
  "journal": { "vault": "/Users/pk/Documents/Obsidian Vaults/Vault 101" }
}
```

Create `.gitignore`:

```
config/fleet.local.json
plugin/node_modules/
plugin/*.sdPlugin/bin/
bin/__pycache__/
.DS_Store
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `./tests/run.sh`
Expected: shellcheck `nothing to lint yet`, python `clean`, then `12 tests, 0 failures`.

- [ ] **Step 8: Commit**

```bash
git add .gitignore config bin tests
git commit -m "feat: scaffold, shared library, token-aware label shortening"
```

---

### Task 3: `fleet-emit` — the hook entrypoint

**Files:**
- Create: `bin/fleet-emit`
- Create: `tests/emit.bats`

**Interfaces:**
- Consumes: `docs/hook-contract.md` (field names), `fleetlib`
- Produces:
  - `bin/fleet-emit <EventName>` — reads hook JSON on stdin, writes `$FLEET_HOME/sessions/<session_id>.json`, appends to `events.jsonl`. **Always exits 0.**
  - **Session file schema**, relied on by Tasks 4, 5, 8, 9:
    ```json
    { "session_id": "...", "state": "working", "repo": "flightdeck",
      "branch": "main", "title": "", "cwd": "/abs/path", "host": "iterm2",
      "iterm_session": "UUID", "pid": 1234, "ts": 1755100000 }
    ```
  - Env `FLEET_SKIP_RECONCILE=1` suppresses the reconcile call (tests use it).

> **Adjust the payload field names below to match `docs/hook-contract.md` from Task 1.** The plan assumes `session_id` and `cwd`; if the contract differs, change the two `payload.get(...)` lines and nothing else.

- [ ] **Step 1: Write the failing test**

Create `tests/emit.bats`:

```bash
#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  export FLEET_SKIP_RECONCILE=1
  mkdir -p "$FLEET_HOME/sessions"
  PAYLOAD='{"session_id":"S1","cwd":"/tmp"}'
}

emit() { printf '%s' "${2:-$PAYLOAD}" | "$BIN/fleet-emit" "$1"; }
field() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" \
            "$FLEET_HOME/sessions/S1.json" "$1"; }

@test "SessionStart maps to idle" { emit SessionStart; [ "$(field state)" = "idle" ]; }
@test "UserPromptSubmit maps to working" { emit UserPromptSubmit; [ "$(field state)" = "working" ]; }
@test "Notification maps to blocked" { emit Notification; [ "$(field state)" = "blocked" ]; }
@test "Stop maps to done" { emit Stop; [ "$(field state)" = "done" ]; }

@test "SessionEnd removes the session file" {
  emit SessionStart
  [ -f "$FLEET_HOME/sessions/S1.json" ]
  emit SessionEnd
  [ ! -f "$FLEET_HOME/sessions/S1.json" ]
}

@test "every event appends one line to the journal spine, removals included" {
  emit SessionStart; emit UserPromptSubmit; emit Stop; emit SessionEnd
  [ "$(wc -l <"$FLEET_HOME/events.jsonl" | tr -d ' ')" = "4" ]
  [ "$(tail -1 "$FLEET_HOME/events.jsonl" | python3 -c 'import json,sys;print(json.load(sys.stdin)["event"])')" = "SessionEnd" ]
}

@test "iTerm session uuid is captured with its w/t/p prefix stripped" {
  ITERM_SESSION_ID="w1t2p0:ABC-123" emit SessionStart
  [ "$(field iterm_session)" = "ABC-123" ]
  [ "$(field host)" = "iterm2" ]
}

@test "host is unknown when not running under iTerm" {
  ITERM_SESSION_ID="" emit SessionStart
  [ "$(field host)" = "unknown" ]
}

@test "repo and branch are derived from the session cwd" {
  R="$BATS_TEST_TMPDIR/somerepo"
  mkdir -p "$R" && git init -q "$R" && git -C "$R" checkout -q -b my-branch 2>/dev/null || true
  emit SessionStart "{\"session_id\":\"S1\",\"cwd\":\"$R\"}"
  [ "$(field repo)" = "somerepo" ]
}

@test "garbage stdin exits 0 and creates no session file" {
  run bash -c "printf 'not json at all' | '$BIN/fleet-emit' Stop"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$FLEET_HOME/sessions")" ]
}

@test "unknown event name is ignored safely" {
  run bash -c "printf '%s' '$PAYLOAD' | '$BIN/fleet-emit' TotallyUnknownEvent"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$FLEET_HOME/sessions")" ]
}

@test "an unwritable state directory still exits 0" {
  run env FLEET_HOME=/nonexistent/unwritable bash -c "printf '{}' | '$BIN/fleet-emit' Stop"
  [ "$status" -eq 0 ]
}

@test "a missing session id exits 0 without writing" {
  run bash -c "printf '{\"cwd\":\"/tmp\"}' | env CLAUDE_CODE_SESSION_ID= '$BIN/fleet-emit' Stop"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$FLEET_HOME/sessions")" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./tests/run.sh`
Expected: FAIL — `bin/fleet-emit` does not exist.

- [ ] **Step 3: Write `bin/fleet-emit`**

```python
#!/usr/bin/env python3
"""Claude Code hook entrypoint. Records agent state.

MUST ALWAYS EXIT 0. A bug in this file must never break a real agent.
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fleetlib  # noqa: E402

EVENT_STATES = {
    "SessionStart": "idle",
    "UserPromptSubmit": "working",
    "Notification": "blocked",
    "Stop": "done",
    "SessionEnd": "__end__",
}


def find_agent_pid():
    """Walk up the process tree to the agent this hook was spawned from."""
    pid = os.getppid()
    for _ in range(6):
        if pid <= 1:
            break
        try:
            proc = subprocess.run(
                ["ps", "-o", "comm=", "-o", "ppid=", "-p", str(pid)],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            )
            parts = proc.stdout.decode("utf-8", "replace").split()
            if not parts:
                break
            comm, parent = parts[0].rsplit("/", 1)[-1], parts[-1]
            if comm in ("claude", "node"):
                return pid
            pid = int(parent)
        except Exception:
            break
    return 0


def run(event):
    state = EVENT_STATES.get(event)
    if state is None:
        fleetlib.log("emit: ignoring unknown event {!r}".format(event))
        return

    try:
        payload = json.loads(sys.stdin.read())
        if not isinstance(payload, dict):
            raise ValueError("payload is not an object")
    except Exception:
        fleetlib.log("emit: unparseable payload for {}".format(event))
        return

    session_id = payload.get("session_id") or os.environ.get("CLAUDE_CODE_SESSION_ID") or ""
    if not session_id:
        fleetlib.log("emit: no session id for {}".format(event))
        return

    cwd = payload.get("cwd") or os.getcwd()

    # iTerm exports w<win>t<tab>p<pane>:<uuid>; only the uuid is addressable.
    iterm = os.environ.get("ITERM_SESSION_ID", "")
    iterm_uuid = iterm.split(":", 1)[1] if ":" in iterm else ""
    host = "iterm2" if iterm_uuid else "unknown"

    repo = branch = ""
    code, top = fleetlib.git(["rev-parse", "--show-toplevel"], cwd)
    if code == 0 and top:
        repo = Path(top).name
        _, branch = fleetlib.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd)

    now = int(time.time())

    # Journal spine first, so removals are recorded too.
    try:
        fleetlib.append_jsonl(fleetlib.events_path(), {
            "event": event, "session_id": session_id, "repo": repo,
            "branch": branch, "cwd": cwd, "ts": now,
        })
    except Exception as err:
        fleetlib.log("emit: could not append event: {}".format(err))

    target = fleetlib.sessions_dir() / "{}.json".format(session_id)
    if state == "__end__":
        try:
            target.unlink()
        except Exception:
            pass
    else:
        fleetlib.write_json_atomic(target, {
            "session_id": session_id, "state": state, "repo": repo,
            "branch": branch, "title": "", "cwd": cwd, "host": host,
            "iterm_session": iterm_uuid, "pid": find_agent_pid(), "ts": now,
        })

    if os.environ.get("FLEET_SKIP_RECONCILE") != "1":
        try:
            subprocess.run([sys.executable, str(Path(__file__).resolve().parent / "fleet-reconcile")],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass


if __name__ == "__main__":
    try:
        run(sys.argv[1] if len(sys.argv) > 1 else "")
    except Exception as err:            # noqa: BLE001 -- the exit-0 guarantee
        fleetlib.log("emit: unhandled {!r}".format(err))
    sys.exit(0)
```

```bash
chmod +x bin/fleet-emit
```

The bare `except Exception` at the bottom is deliberate and is the exit-0 guarantee made structural: no failure path in this file can propagate into the agent.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run.sh`
Expected: `25 tests, 0 failures` (12 + 13 emit).

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-emit tests/emit.bats
git commit -m "feat: fleet-emit hook entrypoint with atomic writes and exit-0 guarantee"
```

---

### Task 4: `fleet-reconcile` — sticky slot assignment

The heart of the system, and the file the design promises you can edit freely. Keep it obvious.

**Files:**
- Create: `bin/fleet-reconcile`
- Create: `tests/reconcile.bats`

**Interfaces:**
- Consumes: session files (Task 3), `fleetlib`
- Produces:
  - `bin/fleet-reconcile` — reads `sessions/*.json`, writes `slots.json` atomically.
  - **`slots.json` schema**, consumed by Tasks 7, 10 and 11:
    ```json
    { "ts": 1755100000, "overflow": 0,
      "slots": [ { "index": 0, "state": "working", "label_top": "flightdeck",
                   "label_bottom": "main", "session_id": "S1", "host": "iterm2",
                   "iterm_session": "UUID", "cwd": "/abs/path", "app": "" } ] }
    ```
    Empty slots use `state: "empty"` with empty strings elsewhere. The array always has exactly `slots.count` entries, ordered by index.

- [ ] **Step 1: Write the failing test**

Create `tests/reconcile.bats`:

```bash
#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  export FLEET_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  mkdir -p "$FLEET_HOME/sessions" "$FLEET_CONFIG_DIR"
  cp "$ROOT/config/fleet.json" "$FLEET_CONFIG_DIR/fleet.json"
}

# id state repo branch [title]
mksession() {
  python3 - "$FLEET_HOME/sessions/$1.json" "$1" "$2" "$3" "$4" "${5:-}" <<'PY'
import json,sys
p,sid,st,repo,br,title = sys.argv[1:7]
json.dump({"session_id":sid,"state":st,"repo":repo,"branch":br,"title":title,
           "cwd":"/tmp","host":"iterm2","iterm_session":"U-"+sid,"pid":1,"ts":1},
          open(p,"w"))
PY
}

sf() {
  python3 -c "import json,sys;d=json.load(open('$FLEET_HOME/slots.json'));\
print([s for s in d['slots'] if s['index']==$1][0]['$2'])"
}
top() { python3 -c "import json;d=json.load(open('$FLEET_HOME/slots.json'));print(d['$1'])"; }

@test "sessions claim the lowest free slot and the file always has 8 entries" {
  mksession A working flightdeck main
  mksession B blocked sisko feat/login
  run "$BIN/fleet-reconcile"
  [ "$status" -eq 0 ]
  [ "$(sf 0 session_id)" = "A" ]
  [ "$(sf 1 session_id)" = "B" ]
  [ "$(python3 -c "import json;print(len(json.load(open('$FLEET_HOME/slots.json'))['slots']))")" = "8" ]
  [ "$(sf 7 state)" = "empty" ]
}

@test "STICKINESS: a freed slot does not shift its neighbours, and is reused" {
  mksession A working flightdeck main
  mksession B blocked sisko feat/login
  "$BIN/fleet-reconcile"

  rm -f "$FLEET_HOME/sessions/A.json"
  "$BIN/fleet-reconcile"
  [ "$(sf 0 state)" = "empty" ]
  [ "$(sf 1 session_id)" = "B" ]

  mksession C idle homeassistant main
  "$BIN/fleet-reconcile"
  [ "$(sf 0 session_id)" = "C" ]
  [ "$(sf 1 session_id)" = "B" ]
}

@test "labels put repo on top and shorten the branch" {
  mksession B blocked sisko feat/login
  "$BIN/fleet-reconcile"
  [ "$(sf 0 label_top)" = "sisko" ]
  [ "$(sf 0 label_bottom)" = "login" ]
}

@test "task title beats branch for the bottom label" {
  mksession B blocked sisko feat/login break-state
  "$BIN/fleet-reconcile"
  [ "$(sf 0 label_bottom)" = "break-state" ]
}

@test "labels never exceed maxChars" {
  mksession D working averyverylongreponame some/very-long-branch-name
  "$BIN/fleet-reconcile"
  t="$(sf 0 label_top)"; b="$(sf 0 label_bottom)"
  [ "${#t}" -le 11 ]
  [ "${#b}" -le 11 ]
}

@test "OVERFLOW: only 8 are slotted and the remainder is counted, not shuffled in" {
  i=1; while [ $i -le 9 ]; do mksession "S$i" working "repo$i" main; i=$((i+1)); done
  "$BIN/fleet-reconcile"
  [ "$(python3 -c "import json;d=json.load(open('$FLEET_HOME/slots.json'));\
print(len([s for s in d['slots'] if s['state']!='empty']))")" = "8" ]
  [ "$(top overflow)" = "1" ]
}

@test "a pinned slot is never auto-assigned and reduces capacity" {
  cat >"$FLEET_CONFIG_DIR/fleet.local.json" <<'EOF'
{"pins":{"7":{"host":"pinned-app","app":"ChatGPT","label_top":"ask","label_bottom":"ChatGPT"}}}
EOF
  i=1; while [ $i -le 8 ]; do mksession "P$i" working "repo$i" main; i=$((i+1)); done
  "$BIN/fleet-reconcile"
  [ "$(sf 7 host)"  = "pinned-app" ]
  [ "$(sf 7 app)"   = "ChatGPT" ]
  [ "$(sf 7 state)" = "idle" ]
  [ "$(top overflow)" = "1" ]
}

@test "a corrupt session file is skipped rather than failing the whole reconcile" {
  mksession OK working flightdeck main
  printf 'garbage{' >"$FLEET_HOME/sessions/BAD.json"
  run "$BIN/fleet-reconcile"
  [ "$status" -eq 0 ]
  [ "$(sf 0 session_id)" = "OK" ]
}

@test "no sessions at all still produces a valid 8-slot file" {
  run "$BIN/fleet-reconcile"
  [ "$status" -eq 0 ]
  [ "$(top overflow)" = "0" ]
  [ "$(sf 3 state)" = "empty" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./tests/run.sh`
Expected: FAIL — `bin/fleet-reconcile` does not exist.

- [ ] **Step 3: Write `bin/fleet-reconcile`**

```python
#!/usr/bin/env python3
"""Turns session files into a sticky slot map at $FLEET_HOME/slots.json.

Stickiness is the point: a session claims the lowest free slot on first
sight and holds it until it dies. When it dies the slot goes empty and
NOTHING ELSE MOVES. Keys that shift under your thumb destroy the whole
value of the row.
"""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fleetlib  # noqa: E402


def load_live_sessions():
    """Every parseable session file, oldest first for stable assignment."""
    sessions = []
    directory = fleetlib.sessions_dir()
    if not directory.is_dir():
        return sessions
    for path in sorted(directory.glob("*.json")):
        data = fleetlib.read_json(path)
        if isinstance(data, dict) and data.get("session_id"):
            sessions.append(data)
    sessions.sort(key=lambda s: (s.get("ts", 0), s.get("session_id", "")))
    return sessions


def previous_assignment():
    """slot index (as int) -> session_id, from the last written slots.json."""
    previous = fleetlib.read_json(fleetlib.slots_path(), {}) or {}
    result = {}
    for slot in previous.get("slots", []):
        if slot.get("session_id"):
            result[slot["index"]] = slot["session_id"]
    return result


def empty_slot(index):
    return {"index": index, "state": "empty", "label_top": "", "label_bottom": "",
            "session_id": "", "host": "", "iterm_session": "", "cwd": "", "app": ""}


def pinned_slot(index, pin):
    return {"index": index, "state": "idle",
            "label_top": pin.get("label_top", ""),
            "label_bottom": pin.get("label_bottom", ""),
            "session_id": "", "host": pin.get("host", "pinned-app"),
            "iterm_session": "", "cwd": "", "app": pin.get("app", "")}


def session_slot(index, session, max_chars, prefixes):
    title = (session.get("title") or "").strip()
    bottom = title if title else (session.get("branch") or "")
    return {"index": index,
            "state": session.get("state", "idle"),
            "label_top": fleetlib.shorten(session.get("repo", ""), max_chars, prefixes),
            "label_bottom": fleetlib.shorten(bottom, max_chars, prefixes),
            "session_id": session["session_id"],
            "host": session.get("host", "unknown"),
            "iterm_session": session.get("iterm_session", ""),
            "cwd": session.get("cwd", ""),
            "app": ""}


def main():
    config = fleetlib.load_config()
    count = config.get("slots", {}).get("count", 8)
    pins = config.get("pins", {}) or {}
    labels = config.get("labels", {})
    max_chars = labels.get("maxChars", 11)
    prefixes = labels.get("stripPrefixes", fleetlib.DEFAULT_PREFIXES)

    live = load_live_sessions()
    by_id = {s["session_id"]: s for s in live}
    previous = previous_assignment()

    # Pass 1: every index is a pin, a retained session, or free.
    held = {}
    free = []
    for index in range(count):
        pin = pins.get(str(index))
        if pin:
            continue
        keeper = previous.get(index)
        if keeper and keeper in by_id:
            held[index] = keeper
        else:
            free.append(index)

    # Pass 2: sessions with no slot fill the free indices, lowest first.
    assigned = set(held.values())
    pending = [s["session_id"] for s in live if s["session_id"] not in assigned]
    for index in free:
        if not pending:
            break
        held[index] = pending.pop(0)

    # Pass 3: render.
    slots = []
    for index in range(count):
        pin = pins.get(str(index))
        if pin:
            slots.append(pinned_slot(index, pin))
        elif index in held:
            slots.append(session_slot(index, by_id[held[index]], max_chars, prefixes))
        else:
            slots.append(empty_slot(index))

    fleetlib.write_json_atomic(fleetlib.slots_path(), {
        "ts": int(time.time()), "overflow": len(pending), "slots": slots,
    })
    if pending:
        fleetlib.log("reconcile: {} session(s) unslotted (overflow)".format(len(pending)))


if __name__ == "__main__":
    try:
        main()
    except Exception as err:            # noqa: BLE001
        fleetlib.log("reconcile: unhandled {!r}".format(err))
    sys.exit(0)
```

```bash
chmod +x bin/fleet-reconcile
```

Compare this to the bash version it replaces: three passes of ordinary Python you can edit six months from now, rather than a `jq` reduce over a pending queue.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run.sh`
Expected: `34 tests, 0 failures`. Watch `STICKINESS` — it is the behaviour the whole row depends on.

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-reconcile tests/reconcile.bats
git commit -m "feat: sticky slot assignment with pins, overflow, and label shortening"
```

---

### Task 5: Reaping crashed sessions

A crashed agent never runs `SessionEnd`, so its file lingers and its slot never frees.

**Files:**
- Create: `bin/fleet-reap`, `tests/reap.bats`
- Create: `launchd/com.louisalexander.flightdeck.reaper.plist`

**Interfaces:**
- Consumes: session files (Task 3)
- Produces: `bin/fleet-reap` — removes session files whose `pid` is dead, then runs `fleet-reconcile`. Always exits 0. Honours `FLEET_SKIP_RECONCILE`.

- [ ] **Step 1: Write the failing test**

Create `tests/reap.bats`:

```bash
#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  export FLEET_SKIP_RECONCILE=1
  mkdir -p "$FLEET_HOME/sessions"
}

mk() {
  python3 - "$FLEET_HOME/sessions/$1.json" "$1" "$2" <<'PY'
import json,sys
p,sid,pid = sys.argv[1:4]
try: pid = int(pid)
except ValueError: pass
json.dump({"session_id":sid,"state":"working","repo":"r","branch":"b","title":"",
           "cwd":"/tmp","host":"iterm2","iterm_session":"U","pid":pid,"ts":1},
          open(p,"w"))
PY
}

@test "a session whose process is alive is kept" {
  mk ALIVE "$$"; "$BIN/fleet-reap"; [ -f "$FLEET_HOME/sessions/ALIVE.json" ]
}

@test "a session whose process is gone is reaped" {
  mk DEAD 999999; "$BIN/fleet-reap"; [ ! -f "$FLEET_HOME/sessions/DEAD.json" ]
}

@test "an unknown pid is never guessed at — the session is kept" {
  mk NOPID 0; "$BIN/fleet-reap"; [ -f "$FLEET_HOME/sessions/NOPID.json" ]
}

@test "a non-numeric pid is treated as unknown, not as dead" {
  mk WEIRD "not-a-number"; "$BIN/fleet-reap"; [ -f "$FLEET_HOME/sessions/WEIRD.json" ]
}

@test "reaping an empty directory is safe and idempotent" {
  run "$BIN/fleet-reap"; [ "$status" -eq 0 ]
  run "$BIN/fleet-reap"; [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./tests/run.sh`
Expected: FAIL — `bin/fleet-reap` does not exist.

- [ ] **Step 3: Write `bin/fleet-reap`**

```python
#!/usr/bin/env python3
"""Removes session files whose agent process is gone.

Conservative by design: pid 0 or a non-numeric pid means 'unknown', and
unknown is never reaped. A stale key is a small annoyance; a key that
vanishes while its agent is alive is a correctness failure.
"""

import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fleetlib  # noqa: E402


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True          # exists, owned by someone else
    except Exception:
        return True          # never reap on an unexpected error


def main():
    directory = fleetlib.sessions_dir()
    if not directory.is_dir():
        return

    for path in sorted(directory.glob("*.json")):
        data = fleetlib.read_json(path)
        if not isinstance(data, dict):
            continue
        pid = data.get("pid", 0)
        if not isinstance(pid, int) or pid <= 0:
            continue
        if not alive(pid):
            try:
                path.unlink()
                fleetlib.log("reap: removed {} (pid {} gone)".format(path.name, pid))
            except Exception:
                pass

    if os.environ.get("FLEET_SKIP_RECONCILE") != "1":
        try:
            subprocess.run([sys.executable, str(Path(__file__).resolve().parent / "fleet-reconcile")],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass


if __name__ == "__main__":
    try:
        main()
    except Exception as err:            # noqa: BLE001
        fleetlib.log("reap: unhandled {!r}".format(err))
    sys.exit(0)
```

```bash
chmod +x bin/fleet-reap
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run.sh`
Expected: `39 tests, 0 failures`.

- [ ] **Step 5: Write the launchd agent**

Create `launchd/com.louisalexander.flightdeck.reaper.plist`. `__PYTHON__`, `__REPO__` and `__HOME__` are substituted by `install.sh` — **`__PYTHON__` is why this works under launchd**, whose `PATH` would otherwise resolve a different interpreter.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>com.louisalexander.flightdeck.reaper</string>
  <key>ProgramArguments</key>
  <array>
    <string>__PYTHON__</string>
    <string>__REPO__/bin/fleet-reap</string>
  </array>
  <key>StartInterval</key>    <integer>15</integer>
  <key>RunAtLoad</key>        <true/>
  <key>StandardErrorPath</key><string>__HOME__/.fleet/reaper.err.log</string>
</dict>
</plist>
```

- [ ] **Step 6: Commit**

```bash
git add bin/fleet-reap tests/reap.bats launchd
git commit -m "feat: reap crashed sessions on a 15s launchd tick"
```

---

### Task 6: `fleet-focus` — the iTerm2 host adapter

The only component requiring live hardware. Isolated so it is the sole thing verified by hand.

**Files:**
- Create: `bin/fleet-focus`, `tools/focus-smoke.sh`

**Interfaces:**
- Consumes: nothing from other tasks
- Produces: `bin/fleet-focus <host> <target>` where `host` is `iterm2` (target = iTerm session UUID) or `pinned-app` (target = application name). Exit 0 on success, 1 if the target no longer exists.

- [ ] **Step 1: Write `bin/fleet-focus`**

Direct `session id "<uuid>"` addressing fails with error -1728, verified during design. Iterate and match.

```python
#!/usr/bin/env python3
"""Brings a host into focus.

iterm2 targets are session UUIDs; pinned-app targets are application names.
"""

import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fleetlib  # noqa: E402

# Top-level `session id "..."` addressing errors with -1728, so walk the tree.
ITERM_SCRIPT = '''
tell application "iTerm2"
  set found to false
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if (id of s) is "{uuid}" then
          select w
          select t
          select s
          set found to true
        end if
      end repeat
    end repeat
  end repeat
  if found then activate
  if not found then error "no such session" number 1
end tell
'''


def main(argv):
    if len(argv) < 3:
        return 1
    host, target = argv[1], argv[2]

    if host == "pinned-app":
        proc = subprocess.run(["open", "-a", target],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return 0 if proc.returncode == 0 else 1

    if host == "iterm2":
        if not target:
            return 1
        proc = subprocess.run(["osascript", "-e", ITERM_SCRIPT.format(uuid=target)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if proc.returncode != 0:
            fleetlib.log("focus: iterm session {} not found".format(target))
            return 1
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

```bash
chmod +x bin/fleet-focus
```

`target` is interpolated into AppleScript, so `fleet-press` must only ever pass a UUID read from `slots.json`, never user input.

- [ ] **Step 2: Write the manual smoke test**

Create `tools/focus-smoke.sh`:

```bash
#!/usr/bin/env bash
# Manual check: focuses this very session, then reports on a bogus target.
set -u
BIN="$(cd "$(dirname "$0")/../bin" && pwd)"
UUID="${ITERM_SESSION_ID#*:}"
[ -n "$UUID" ] || { echo "not running inside iTerm2"; exit 1; }

echo "focusing this session ($UUID) ..."
if "$BIN/fleet-focus" iterm2 "$UUID"; then echo "  ok"; else echo "  FAILED ($?)"; fi

echo "focusing a bogus session ..."
if "$BIN/fleet-focus" iterm2 "00000000-0000-0000-0000-000000000000"; then
  echo "  FAILED - should have exited non-zero"
else
  echo "  ok (non-zero as expected)"
fi
```

```bash
chmod +x tools/focus-smoke.sh
```

- [ ] **Step 3: Run the smoke test by hand**

Run: `./tools/focus-smoke.sh`
Expected: both lines report `ok`.

**If macOS shows an automation permission dialog, approve it.** If it fails silently with no dialog, open System Settings → Privacy & Security → Automation and enable control of iTerm. This is the failure mode `fleet-doctor` exists to catch.

Then verify cross-window focus: open a second iTerm window, note its UUID via
`osascript -e 'tell application "iTerm2" to get id of current session of current tab of current window'`,
return to the first window, and run `./bin/fleet-focus iterm2 <that-uuid>`. The other window must come forward.

- [ ] **Step 4: Commit**

```bash
git add bin/fleet-focus tools/focus-smoke.sh
git commit -m "feat: iTerm2 and pinned-app focus adapters"
```

---

### Task 7: `fleet-press` — dispatch and the arm/confirm machine

**Files:**
- Create: `bin/fleet-press`, `tests/press.bats`

**Interfaces:**
- Consumes: `slots.json` (Task 4), `fleet-focus` (Task 6), `fleet-kill` (Task 8)
- Produces:
  - `bin/fleet-press <slotIndex> <short|long>`
  - **Arm marker** `$FLEET_HOME/armed.json`: `{"index": 3, "expires": 1755100003}`. Read by the plugin in Task 11 to paint the armed state.
  - Env `FLEET_FOCUS_CMD` / `FLEET_KILL_CMD` override adapter paths so tests can stub them. `FLEET_NOW` overrides the clock.

- [ ] **Step 1: Write the failing test**

Create `tests/press.bats`:

```bash
#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR"
  export FLEET_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  mkdir -p "$FLEET_CONFIG_DIR"
  cp "$ROOT/config/fleet.json" "$FLEET_CONFIG_DIR/fleet.json"

  printf '#!/usr/bin/env bash\nprintf "focus %%s\\n" "$*" >>"%s/calls.log"\n' \
    "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/focus-stub"
  printf '#!/usr/bin/env bash\nprintf "kill %%s\\n" "$*" >>"%s/calls.log"\n' \
    "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/kill-stub"
  chmod +x "$BATS_TEST_TMPDIR/focus-stub" "$BATS_TEST_TMPDIR/kill-stub"
  export FLEET_FOCUS_CMD="$BATS_TEST_TMPDIR/focus-stub"
  export FLEET_KILL_CMD="$BATS_TEST_TMPDIR/kill-stub"

  cat >"$BATS_TEST_TMPDIR/slots.json" <<'EOF'
{"ts":1,"overflow":0,"slots":[
 {"index":0,"state":"working","label_top":"r","label_bottom":"b","session_id":"S1","host":"iterm2","iterm_session":"U-1","cwd":"/tmp","app":""},
 {"index":1,"state":"empty","label_top":"","label_bottom":"","session_id":"","host":"","iterm_session":"","cwd":"","app":""},
 {"index":2,"state":"idle","label_top":"ask","label_bottom":"ChatGPT","session_id":"","host":"pinned-app","iterm_session":"","cwd":"","app":"ChatGPT"}
]}
EOF
}

calls() { cat "$BATS_TEST_TMPDIR/calls.log" 2>/dev/null; }
armed_exists() { [ -f "$BATS_TEST_TMPDIR/armed.json" ]; }
armfield() { python3 -c "import json;print(json.load(open('$BATS_TEST_TMPDIR/armed.json'))['$1'])"; }

@test "short press focuses the iTerm session behind that slot" {
  FLEET_NOW=1000 "$BIN/fleet-press" 0 short
  [ "$(calls)" = "focus iterm2 U-1" ]
}

@test "short press on a pinned slot activates the app" {
  FLEET_NOW=1000 "$BIN/fleet-press" 2 short
  [ "$(calls)" = "focus pinned-app ChatGPT" ]
}

@test "pressing an empty slot does nothing at all" {
  FLEET_NOW=1000 "$BIN/fleet-press" 1 short
  [ -z "$(calls)" ]
}

@test "long press ARMS and must not kill anything on the hold" {
  FLEET_NOW=1000 "$BIN/fleet-press" 0 long
  [ -z "$(calls)" ]
  armed_exists
  [ "$(armfield index)" = "0" ]
  [ "$(armfield expires)" = "1003" ]
}

@test "a second press inside the window confirms the teardown" {
  FLEET_NOW=1000 "$BIN/fleet-press" 0 long
  FLEET_NOW=1002 "$BIN/fleet-press" 0 short
  [ "$(calls)" = "kill S1" ]
  ! armed_exists
}

@test "a press after expiry focuses and never kills" {
  FLEET_NOW=1000 "$BIN/fleet-press" 0 long
  FLEET_NOW=1099 "$BIN/fleet-press" 0 short
  [ "$(calls)" = "focus iterm2 U-1" ]
  ! armed_exists
}

@test "pressing a different key while armed disarms without killing" {
  FLEET_NOW=1000 "$BIN/fleet-press" 0 long
  FLEET_NOW=1001 "$BIN/fleet-press" 2 short
  [ "$(calls)" = "focus pinned-app ChatGPT" ]
  ! armed_exists
}

@test "a pinned slot cannot be armed for teardown" {
  FLEET_NOW=1000 "$BIN/fleet-press" 2 long
  ! armed_exists
  [ -z "$(calls)" ]
}

@test "an empty slot cannot be armed for teardown" {
  FLEET_NOW=1000 "$BIN/fleet-press" 1 long
  ! armed_exists
}

@test "an out-of-range slot index is harmless" {
  run env FLEET_NOW=1000 "$BIN/fleet-press" 99 short
  [ "$status" -eq 0 ]
  [ -z "$(calls)" ]
}

@test "a non-numeric slot index is harmless" {
  run env FLEET_NOW=1000 "$BIN/fleet-press" "; rm -rf /" short
  [ "$status" -eq 0 ]
  [ -z "$(calls)" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./tests/run.sh`
Expected: FAIL — `bin/fleet-press` does not exist.

- [ ] **Step 3: Write `bin/fleet-press`**

```python
#!/usr/bin/env python3
"""Press dispatcher.

Short press focuses. Long press ARMS teardown -- it does not perform it.
A second press inside the arm window confirms. Anything else disarms.
"""

import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fleetlib  # noqa: E402

HERE = Path(__file__).resolve().parent


def now():
    override = os.environ.get("FLEET_NOW")
    return int(override) if override else int(time.time())


def main(argv):
    if len(argv) < 2:
        return 0
    try:
        index = int(argv[1])
    except ValueError:
        return 0                       # a plugin sends this; never trust it
    verb = argv[2] if len(argv) > 2 else "short"

    data = fleetlib.read_json(fleetlib.slots_path(), {}) or {}
    matches = [s for s in data.get("slots", []) if s.get("index") == index]
    if not matches:
        return 0
    slot = matches[0]
    if slot.get("state") == "empty":
        return 0

    focus_cmd = os.environ.get("FLEET_FOCUS_CMD") or str(HERE / "fleet-focus")
    kill_cmd = os.environ.get("FLEET_KILL_CMD") or str(HERE / "fleet-kill")

    # Read the arm marker, then clear it. Any press disarms; whether it
    # FIRES is decided below.
    arm = fleetlib.read_json(fleetlib.armed_path())
    try:
        fleetlib.armed_path().unlink()
    except Exception:
        pass

    armed_live = (isinstance(arm, dict)
                  and isinstance(arm.get("expires"), int)
                  and now() < arm["expires"])

    if armed_live and arm.get("index") == index:
        fleetlib.log("press: confirmed teardown of slot {} ({})".format(
            index, slot.get("session_id", "")))
        subprocess.run([kill_cmd, slot.get("session_id", "")])
        return 0

    if verb == "long":
        if not slot.get("session_id") or slot.get("host") == "pinned-app":
            return 0                   # only real agent sessions are torn down
        config = fleetlib.load_config()
        arm_ms = config.get("timings", {}).get("armMs", 3000)
        fleetlib.write_json_atomic(fleetlib.armed_path(), {
            "index": index, "expires": now() + max(1, arm_ms // 1000),
        })
        return 0

    host = slot.get("host")
    if host == "iterm2" and slot.get("iterm_session"):
        subprocess.run([focus_cmd, "iterm2", slot["iterm_session"]])
    elif host == "pinned-app" and slot.get("app"):
        subprocess.run([focus_cmd, "pinned-app", slot["app"]])
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as err:            # noqa: BLE001
        fleetlib.log("press: unhandled {!r}".format(err))
        sys.exit(0)
```

```bash
chmod +x bin/fleet-press
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run.sh`
Expected: `50 tests, 0 failures`. Watch "long press ARMS and must not kill anything on the hold" — that assertion is the guard between your thumb and a destroyed worktree.

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-press tests/press.bats
git commit -m "feat: press dispatch with arm/confirm guard on destructive teardown"
```

---

### Task 8: `fleet-kill` — guarded teardown

**The highest-stakes component in the project.** A bug here destroys work rather than pixels.

**Files:**
- Create: `bin/fleet-kill`, `tests/kill.bats`

**Interfaces:**
- Consumes: session files (Task 3)
- Produces: `bin/fleet-kill <session_id>` — kills the agent process, then removes the worktree **only if provably safe**. `FLEET_DRY_RUN=1` prints intended actions instead of performing them.

**Safety contract — a worktree is removed only if ALL hold:**
1. It is a linked worktree, not a repository's primary working tree.
2. `git status --porcelain` is empty (no modifications, no untracked files).
3. An upstream branch is configured **and** `git rev-list @{u}..HEAD` is empty.

Anything else: leave everything, mark the slot `failed`, log the reason.

- [ ] **Step 1: Write the failing test**

Create `tests/kill.bats`:

```bash
#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/state"
  export FLEET_DRY_RUN=1
  export FLEET_SKIP_RECONCILE=1
  mkdir -p "$FLEET_HOME/sessions" "$BATS_TEST_TMPDIR/repos"

  ORIGIN="$BATS_TEST_TMPDIR/repos/origin.git"
  MAIN="$BATS_TEST_TMPDIR/repos/main"
  git init -q --bare "$ORIGIN"
  git init -q "$MAIN"
  git -C "$MAIN" config user.email t@t
  git -C "$MAIN" config user.name t
  git -C "$MAIN" remote add origin "$ORIGIN"
  echo seed >"$MAIN/f.txt"
  git -C "$MAIN" add .
  git -C "$MAIN" commit -qm seed
  git -C "$MAIN" push -q -u origin HEAD:refs/heads/main
}

mkwt() {
  git -C "$MAIN" worktree add -q -b "$1" "$BATS_TEST_TMPDIR/repos/$1"
  git -C "$MAIN" push -q origin "$1:refs/heads/$1"
  git -C "$BATS_TEST_TMPDIR/repos/$1" branch --set-upstream-to="origin/$1" >/dev/null 2>&1
  git -C "$BATS_TEST_TMPDIR/repos/$1" config user.email t@t
  git -C "$BATS_TEST_TMPDIR/repos/$1" config user.name t
}

mksession() {
  python3 - "$FLEET_HOME/sessions/$1.json" "$1" "$2" <<'PY'
import json,sys
p,sid,cwd = sys.argv[1:4]
json.dump({"session_id":sid,"state":"idle","repo":"r","branch":"b","title":"",
           "cwd":cwd,"host":"iterm2","iterm_session":"U","pid":0,"ts":1},
          open(p,"w"))
PY
}

@test "a clean, pushed, linked worktree is eligible for removal" {
  mkwt clean; mksession CLEAN "$BATS_TEST_TMPDIR/repos/clean"
  run "$BIN/fleet-kill" CLEAN
  [ "$status" -eq 0 ]
  [[ "$output" == *"WOULD REMOVE"* ]]
}

@test "REFUSES when tracked files are modified" {
  mkwt dirty; echo change >>"$BATS_TEST_TMPDIR/repos/dirty/f.txt"
  mksession DIRTY "$BATS_TEST_TMPDIR/repos/dirty"
  run "$BIN/fleet-kill" DIRTY
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" == *"uncommitted"* ]]
  [[ "$output" != *"WOULD REMOVE"* ]]
}

@test "REFUSES when an untracked file is present" {
  mkwt untracked; echo new >"$BATS_TEST_TMPDIR/repos/untracked/brand-new.txt"
  mksession UNTRACKED "$BATS_TEST_TMPDIR/repos/untracked"
  run "$BIN/fleet-kill" UNTRACKED
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" != *"WOULD REMOVE"* ]]
}

@test "REFUSES when commits exist only locally" {
  mkwt unpushed
  echo more >>"$BATS_TEST_TMPDIR/repos/unpushed/f.txt"
  git -C "$BATS_TEST_TMPDIR/repos/unpushed" add .
  git -C "$BATS_TEST_TMPDIR/repos/unpushed" commit -qm "local only"
  mksession UNPUSHED "$BATS_TEST_TMPDIR/repos/unpushed"
  run "$BIN/fleet-kill" UNPUSHED
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" == *"unpushed"* ]]
  [[ "$output" != *"WOULD REMOVE"* ]]
}

@test "REFUSES when there is no upstream to prove the work is safe" {
  git -C "$MAIN" worktree add -q -b noups "$BATS_TEST_TMPDIR/repos/noups"
  mksession NOUPS "$BATS_TEST_TMPDIR/repos/noups"
  run "$BIN/fleet-kill" NOUPS
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" != *"WOULD REMOVE"* ]]
}

@test "REFUSES to remove a primary working tree, even a spotless one" {
  mksession MAINWT "$MAIN"
  run "$BIN/fleet-kill" MAINWT
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" != *"WOULD REMOVE"* ]]
}

@test "REFUSES a directory that is not a git repository" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  mksession PLAIN "$BATS_TEST_TMPDIR/plain"
  run "$BIN/fleet-kill" PLAIN
  [[ "$output" == *"REFUSING"* ]]
}

@test "REFUSES when the recorded directory no longer exists" {
  mksession GONE "$BATS_TEST_TMPDIR/repos/deleted-since"
  run "$BIN/fleet-kill" GONE
  [[ "$output" == *"REFUSING"* ]]
}

@test "a path containing spaces is handled as one argument" {
  git -C "$MAIN" worktree add -q -b spaced "$BATS_TEST_TMPDIR/repos/has space here"
  git -C "$MAIN" push -q origin "spaced:refs/heads/spaced"
  git -C "$BATS_TEST_TMPDIR/repos/has space here" branch --set-upstream-to=origin/spaced >/dev/null 2>&1
  mksession SPACED "$BATS_TEST_TMPDIR/repos/has space here"
  run "$BIN/fleet-kill" SPACED
  [[ "$output" == *"WOULD REMOVE"* ]]
}

@test "an unknown session id is harmless" {
  run "$BIN/fleet-kill" NOSUCHSESSION
  [ "$status" -eq 0 ]
}

@test "a refusal marks the session failed rather than silently doing nothing" {
  unset FLEET_DRY_RUN
  mkwt dirty2; echo change >>"$BATS_TEST_TMPDIR/repos/dirty2/f.txt"
  mksession DIRTY2 "$BATS_TEST_TMPDIR/repos/dirty2"
  run "$BIN/fleet-kill" DIRTY2
  [ "$(python3 -c "import json;print(json.load(open('$FLEET_HOME/sessions/DIRTY2.json'))['state'])")" = "failed" ]
  [ -d "$BATS_TEST_TMPDIR/repos/dirty2" ]
}
```

Every refusal test also asserts the *absence* of `WOULD REMOVE`. Asserting only that the warning appears would still pass if the script printed it and removed the worktree anyway. The spaces test is the one that would have caught the bash word-splitting bug.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./tests/run.sh`
Expected: FAIL — `bin/fleet-kill` does not exist.

- [ ] **Step 3: Write `bin/fleet-kill`**

```python
#!/usr/bin/env python3
"""Guarded teardown.

Kills the agent, then removes the worktree ONLY if provably safe.
A thumb on a Stream Deck must never be able to destroy uncommitted work.
"""

import os
import signal
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fleetlib  # noqa: E402

HERE = Path(__file__).resolve().parent


def say(message):
    print(message)
    fleetlib.log("kill: " + message)


def mark_failed(session_path, dry_run):
    if dry_run:
        return
    data = fleetlib.read_json(session_path)
    if isinstance(data, dict):
        data["state"] = "failed"
        try:
            fleetlib.write_json_atomic(session_path, data)
        except Exception:
            pass
    if os.environ.get("FLEET_SKIP_RECONCILE") != "1":
        try:
            subprocess.run([sys.executable, str(HERE / "fleet-reconcile")],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass


def unsafe_reason(cwd):
    """Returns a human reason the worktree must not be removed, or None."""
    if not cwd or not Path(cwd).is_dir():
        return "session has no usable working directory"

    code, top = fleetlib.git(["rev-parse", "--show-toplevel"], cwd)
    if code != 0 or not top:
        return "not a git repository"

    # A linked worktree has .git as a FILE; a primary working tree has a directory.
    if not (Path(top) / ".git").is_file():
        return "this is a primary working tree, not a linked worktree"

    code, status = fleetlib.git(["status", "--porcelain"], cwd)
    if code != 0:
        return "could not read git status"
    if status:
        return "uncommitted changes or untracked files present"

    code, _ = fleetlib.git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], cwd)
    if code != 0:
        return "no upstream branch configured, cannot prove work is pushed"

    code, ahead = fleetlib.git(["rev-list", "@{u}..HEAD"], cwd)
    if code != 0:
        return "could not compare against upstream"
    if ahead:
        return "unpushed commits present"

    return None


def main(argv):
    if len(argv) < 2 or not argv[1]:
        return 0
    session_id = argv[1]
    session_path = fleetlib.sessions_dir() / "{}.json".format(session_id)
    data = fleetlib.read_json(session_path)
    if not isinstance(data, dict):
        return 0

    dry_run = os.environ.get("FLEET_DRY_RUN") == "1"
    cwd = data.get("cwd", "")
    pid = data.get("pid", 0)

    # 1. Stop the agent regardless of what happens to the worktree.
    if isinstance(pid, int) and pid > 0:
        if dry_run:
            say("WOULD KILL pid {}".format(pid))
        else:
            try:
                os.kill(pid, signal.SIGTERM)
                fleetlib.log("kill: sent SIGTERM to pid {}".format(pid))
            except Exception:
                pass

    # 2. Decide whether the worktree may be removed.
    reason = unsafe_reason(cwd)
    if reason:
        say("REFUSING to remove worktree: {}".format(reason))
        say("  path: {}".format(cwd or "<unknown>"))
        mark_failed(session_path, dry_run)
        return 0

    _, top = fleetlib.git(["rev-parse", "--show-toplevel"], cwd)
    _, branch = fleetlib.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd)

    # 3. Safe. Remove the worktree -- but never delete the branch: worktree
    #    removal is reversible with `git worktree add`, branch deletion is not.
    if dry_run:
        say("WOULD REMOVE worktree {} (branch {})".format(top, branch))
        return 0

    say("removing worktree {} (branch {})".format(top, branch))
    code, _ = fleetlib.git(["worktree", "remove", top], top)
    if code != 0:
        say("git worktree remove failed; leaving everything in place")
        return 0

    try:
        session_path.unlink()
    except Exception:
        pass
    if os.environ.get("FLEET_SKIP_RECONCILE") != "1":
        try:
            subprocess.run([sys.executable, str(HERE / "fleet-reconcile")],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as err:            # noqa: BLE001
        fleetlib.log("kill: unhandled {!r}".format(err))
        sys.exit(0)
```

```bash
chmod +x bin/fleet-kill
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run.sh`
Expected: `62 tests, 0 failures`.

**Do not proceed with any test in this file failing.** This is the one component whose bugs destroy work rather than pixels.

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-kill tests/kill.bats
git commit -m "feat: guarded worktree teardown that refuses to destroy unpushed work"
```

---

### Task 9: `fleet-fail` — manual failure marking

**Files:**
- Create: `bin/fleet-fail`, `tests/fail.bats`

**Interfaces:**
- Consumes: `slots.json` (Task 4), session files (Task 3)
- Produces: `bin/fleet-fail <slotIndex>` sets that slot's session to `failed`; `--clear <slotIndex>` returns it to `idle`.

- [ ] **Step 1: Write the failing test**

Create `tests/fail.bats`:

```bash
#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR"
  export FLEET_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  export FLEET_SKIP_RECONCILE=1
  mkdir -p "$BATS_TEST_TMPDIR/sessions" "$FLEET_CONFIG_DIR"
  cp "$ROOT/config/fleet.json" "$FLEET_CONFIG_DIR/fleet.json"

  python3 -c "import json;json.dump({'session_id':'S1','state':'working','repo':'r',\
'branch':'b','title':'','cwd':'/tmp','host':'iterm2','iterm_session':'U','pid':0,'ts':1},\
open('$BATS_TEST_TMPDIR/sessions/S1.json','w'))"
  cat >"$BATS_TEST_TMPDIR/slots.json" <<'EOF'
{"ts":1,"overflow":0,"slots":[{"index":0,"state":"working","label_top":"r","label_bottom":"b","session_id":"S1","host":"iterm2","iterm_session":"U","cwd":"/tmp","app":""}]}
EOF
}

state() { python3 -c "import json;print(json.load(open('$BATS_TEST_TMPDIR/sessions/S1.json'))['state'])"; }

@test "fleet-fail marks the slot's session failed" {
  "$BIN/fleet-fail" 0
  [ "$(state)" = "failed" ]
}

@test "--clear returns it to idle" {
  "$BIN/fleet-fail" 0
  "$BIN/fleet-fail" --clear 0
  [ "$(state)" = "idle" ]
}

@test "an unknown slot exits 0 and changes nothing" {
  run "$BIN/fleet-fail" 99
  [ "$status" -eq 0 ]
  [ "$(state)" = "working" ]
}

@test "a non-numeric slot index is harmless" {
  run "$BIN/fleet-fail" "; rm -rf /"
  [ "$status" -eq 0 ]
  [ "$(state)" = "working" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./tests/run.sh`
Expected: FAIL — `bin/fleet-fail` does not exist.

- [ ] **Step 3: Write `bin/fleet-fail`**

```python
#!/usr/bin/env python3
"""Marks a slot's session failed (sticky red), or clears it back to idle.

  fleet-fail <slot>
  fleet-fail --clear <slot>
"""

import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fleetlib  # noqa: E402

HERE = Path(__file__).resolve().parent


def main(argv):
    args = argv[1:]
    new_state = "failed"
    if args and args[0] == "--clear":
        new_state = "idle"
        args = args[1:]
    if not args:
        return 0
    try:
        index = int(args[0])
    except ValueError:
        return 0

    data = fleetlib.read_json(fleetlib.slots_path(), {}) or {}
    matches = [s for s in data.get("slots", []) if s.get("index") == index]
    if not matches or not matches[0].get("session_id"):
        return 0

    path = fleetlib.sessions_dir() / "{}.json".format(matches[0]["session_id"])
    session = fleetlib.read_json(path)
    if not isinstance(session, dict):
        return 0
    session["state"] = new_state
    fleetlib.write_json_atomic(path, session)

    if os.environ.get("FLEET_SKIP_RECONCILE") != "1":
        try:
            subprocess.run([sys.executable, str(HERE / "fleet-reconcile")],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

```bash
chmod +x bin/fleet-fail
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run.sh`
Expected: `66 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-fail tests/fail.bats
git commit -m "feat: manual failure marking and clearing"
```

---

### Task 10: Stream Deck plugin — scaffold and renderer

**Files:**
- Create: `plugin/package.json`, `plugin/tsconfig.json`, `plugin/rollup.config.mjs`
- Create: `plugin/com.louisalexander.flightdeck.sdPlugin/manifest.json`
- Create: `plugin/src/types.ts`, `plugin/src/glyphs.ts`, `plugin/src/render.ts`
- Create: `plugin/src/render.test.mjs`

**Interfaces:**
- Consumes: `slots.json` schema (Task 4), `config/fleet.json` (Task 2)
- Produces:
  - `Slot`, `Config`, `StateStyle` types mirroring the schemas.
  - `renderSvg(slot, cfg, armed) -> string` — pure.
  - `toDataUri(svg) -> string`.
  - Action UUID `com.louisalexander.flightdeck.slot`, per-key setting `{ slotIndex: number }`.

- [ ] **Step 1: Scaffold the plugin package**

```bash
mkdir -p plugin/src plugin/com.louisalexander.flightdeck.sdPlugin/imgs
cd plugin
npm init -y >/dev/null
npm i @elgato/streamdeck
npm i -D typescript rollup @rollup/plugin-typescript @rollup/plugin-node-resolve @rollup/plugin-commonjs tslib @types/node
cd ..
```

Set `plugin/package.json` `"type": "module"` and add:

```json
{
  "type": "module",
  "scripts": {
    "build": "rollup -c",
    "test": "node src/render.test.mjs"
  }
}
```

- [ ] **Step 2: Write the failing render test**

Create `plugin/src/render.test.mjs`:

```javascript
import assert from "node:assert";
import { renderSvg, toDataUri } from "../com.louisalexander.flightdeck.sdPlugin/bin/render.js";

const cfg = {
  states: {
    working: { color: "#1256A3", glyph: "working", glyphColor: "#FFFFFFCC", textColor: "#FFFFFF" },
    blocked: { color: "#F5A623", glyph: "blocked", glyphColor: "#1A1200", textColor: "#1A1200" },
    empty:   { color: "#000000", glyph: "none",    glyphColor: "#000000",  textColor: "#000000" },
    armed:   { color: "#0A0A0A", glyph: "armed",   glyphColor: "#F5A623",  textColor: "#F5A623" }
  }
};
const slot = {
  index: 0, state: "working", label_top: "flightdeck", label_bottom: "main",
  session_id: "S1", host: "iterm2", iterm_session: "U", cwd: "/tmp", app: ""
};

let svg = renderSvg(slot, cfg, false);
assert.ok(svg.includes("#1256A3"), "uses the state colour");
assert.ok(svg.includes("FLIGHTDECK"), "repo line is uppercased");
assert.ok(svg.includes("main"), "renders the task line");

// Glyphs must be geometry, never text: Helvetica lacks U+25B2/U+25B6.
assert.ok(!svg.includes("▶") && !svg.includes("▲"),
  "no literal arrow characters anywhere in the output");
assert.ok(/<(polygon|path|circle|line)\b/.test(svg), "glyph is drawn as geometry");

// Empty must be genuinely blank: black, no glyph, no text.
const emptySvg = renderSvg({ ...slot, state: "empty", label_top: "", label_bottom: "" }, cfg, false);
assert.ok(emptySvg.includes("#000000"), "empty is pure black");
assert.ok(!/<(polygon|path|circle|line)\b/.test(emptySvg), "empty draws no glyph");

// Armed must NOT be red -- red is reserved for observed failure.
svg = renderSvg(slot, cfg, true);
assert.ok(svg.includes("#0A0A0A"), "armed uses the near-black background");
assert.ok(svg.includes("#F5A623"), "armed uses amber, not red");
assert.ok(!/#B42318/i.test(svg), "armed never uses the failure red");
assert.ok(svg.includes("CONFIRM"), "armed shows CONFIRM");

// XML injection through a branch name must not break the document.
svg = renderSvg({ ...slot, label_bottom: 'a<b>&"c' }, cfg, false);
assert.ok(!svg.includes("<b>"), "escapes angle brackets in labels");
assert.ok(svg.includes("&amp;"), "escapes ampersands in labels");

// Unknown states degrade instead of throwing.
svg = renderSvg({ ...slot, state: "no-such-state" }, cfg, false);
assert.ok(svg.includes("<svg"), "unknown state still renders");

assert.ok(toDataUri("<svg/>").startsWith("data:image/svg+xml;base64,"), "data uri prefix");

console.log("render tests passed");
```

- [ ] **Step 3: Run it to verify it fails**

Run: `cd plugin && npm test`
Expected: FAIL — module not found, nothing is built yet.

- [ ] **Step 4: Write the types and glyph geometry**

Create `plugin/src/types.ts`:

```typescript
export type Slot = {
  index: number;
  state: string;
  label_top: string;
  label_bottom: string;
  session_id: string;
  host: string;
  iterm_session: string;
  cwd: string;
  app: string;
};

export type SlotsFile = { ts: number; overflow: number; slots: Slot[] };

export type StateStyle = {
  color: string;
  glyph: string;
  glyphColor: string;
  textColor: string;
};

export type Config = { states: Record<string, StateStyle> };
```

Create `plugin/src/glyphs.ts`. Every glyph is geometry, positioned in a 48×48 box the renderer places at the top-left:

```typescript
/**
 * Lifecycle glyphs as SVG geometry rather than text.
 *
 * Helvetica has no U+25B2 or U+25B6, so a <text> glyph would fall back to
 * an arbitrary font with different metrics -- inconsistent positioning at
 * best, a blank key at worst. Geometry is exact and cannot fail to render.
 *
 * Each function draws inside a 48x48 box at the origin.
 */
export const GLYPHS: Record<string, (fill: string) => string> = {
  // ▲ blocked
  blocked: (f) => `<polygon points="24,8 42,38 6,38" fill="${f}"/>`,

  // ▶ working
  working: (f) => `<polygon points="12,8 40,24 12,40" fill="${f}"/>`,

  // ✓ done
  done: (f) =>
    `<path d="M9 25 l9 10 l21 -24" fill="none" stroke="${f}" stroke-width="7" ` +
    `stroke-linecap="round" stroke-linejoin="round"/>`,

  // · idle
  idle: (f) => `<circle cx="24" cy="24" r="6" fill="${f}"/>`,

  // × failed
  failed: (f) =>
    `<path d="M10 10 L38 38 M38 10 L10 38" stroke="${f}" stroke-width="7" ` +
    `stroke-linecap="round"/>`,

  // ⚠ armed — deliberately NOT red; red means observed failure
  armed: (f) =>
    `<polygon points="24,5 45,41 3,41" fill="none" stroke="${f}" stroke-width="5" ` +
    `stroke-linejoin="round"/>` +
    `<path d="M24 17 v11" stroke="${f}" stroke-width="5" stroke-linecap="round"/>` +
    `<circle cx="24" cy="35" r="2.6" fill="${f}"/>`,

  none: () => ""
};
```

- [ ] **Step 5: Write the renderer**

Create `plugin/src/render.ts`:

```typescript
import type { Slot, Config, StateStyle } from "./types.js";
import { GLYPHS } from "./glyphs.js";

const FALLBACK: StateStyle = {
  color: "#000000", glyph: "none", glyphColor: "#000000", textColor: "#000000"
};

function esc(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * One key at @2x (144px) for a 96px Stream Deck XL key. Pure.
 *
 * Three layers only: state background, one lifecycle glyph, two identity
 * lines anchored near the bottom. No chrome.
 */
export function renderSvg(slot: Slot, cfg: Config, armed: boolean): string {
  const style: StateStyle = armed
    ? cfg.states["armed"] ?? FALLBACK
    : cfg.states[slot.state] ?? FALLBACK;

  const drawGlyph = GLYPHS[style.glyph] ?? GLYPHS["none"];
  const glyph = `<g transform="translate(8,8)">${drawGlyph(style.glyphColor)}</g>`;

  const top = armed ? "" : esc((slot.label_top ?? "").toUpperCase());
  const bottom = armed ? "CONFIRM?" : esc(slot.label_bottom ?? "");

  return [
    '<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144">',
    `<rect width="144" height="144" fill="${style.color}"/>`,
    glyph,
    `<text x="72" y="103" text-anchor="middle" font-family="Helvetica,Arial" `,
    `font-size="17" font-weight="600" letter-spacing="0.6" `,
    `fill="${style.textColor}" fill-opacity="0.72">${top}</text>`,
    `<text x="72" y="128" text-anchor="middle" font-family="Helvetica,Arial" `,
    `font-size="23" font-weight="700" fill="${style.textColor}">${bottom}</text>`,
    "</svg>"
  ].join("");
}

export function toDataUri(svg: string): string {
  return "data:image/svg+xml;base64," + Buffer.from(svg, "utf8").toString("base64");
}
```

Create `plugin/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "bundler",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "outDir": "com.louisalexander.flightdeck.sdPlugin/bin"
  },
  "include": ["src/**/*.ts"]
}
```

Create `plugin/rollup.config.mjs`:

```javascript
import typescript from "@rollup/plugin-typescript";
import nodeResolve from "@rollup/plugin-node-resolve";
import commonjs from "@rollup/plugin-commonjs";

const OUT = "com.louisalexander.flightdeck.sdPlugin/bin";

export default [
  {
    input: "src/plugin.ts",
    output: { file: `${OUT}/plugin.js`, format: "es", sourcemap: true },
    plugins: [typescript(), nodeResolve({ browser: false }), commonjs()],
    external: ["node:fs", "node:path", "node:os", "node:child_process"]
  },
  {
    input: "src/render.ts",
    output: { file: `${OUT}/render.js`, format: "es" },
    plugins: [typescript()]
  }
];
```

- [ ] **Step 6: Write the manifest and icons**

Create `plugin/com.louisalexander.flightdeck.sdPlugin/manifest.json`:

```json
{
  "Name": "Flightdeck",
  "Version": "1.0.0.0",
  "Author": "louisalexander",
  "Description": "Live annunciator row for running Claude Code agents.",
  "Category": "Flightdeck",
  "Icon": "imgs/plugin",
  "URL": "https://github.com/louisalexander/flightdeck",
  "SDKVersion": 2,
  "CodePath": "bin/plugin.js",
  "Nodejs": { "Version": "20", "Debug": "enabled" },
  "Software": { "MinimumVersion": "6.5" },
  "OS": [{ "Platform": "mac", "MinimumVersion": "12.0" }],
  "Actions": [
    {
      "Name": "Fleet Slot",
      "UUID": "com.louisalexander.flightdeck.slot",
      "Icon": "imgs/action",
      "Tooltip": "One agent in the fleet",
      "PropertyInspectorPath": "ui/slot.html",
      "Controllers": ["Keypad"],
      "States": [{ "Image": "imgs/key", "TitleAlignment": "middle" }]
    }
  ]
}
```

Stream Deck refuses to load a plugin with missing icons, so create three PNGs:

```bash
cd plugin/com.louisalexander.flightdeck.sdPlugin/imgs
for n in plugin action key; do
  printf '%s' '<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144"><rect width="144" height="144" fill="#0A0A0A"/><polygon points="40,44 40,100 92,72" fill="#F5A623"/></svg>' > "$n.svg"
  sips -s format png "$n.svg" --out "$n.png" >/dev/null 2>&1 || \
    qlmanage -t -s 144 -o . "$n.svg" >/dev/null 2>&1
  rm -f "$n.svg"
done
ls -la
cd -
```

If neither converter produces a PNG, create solid 144×144 placeholders any way available; they only need to exist and be valid.

- [ ] **Step 7: Build and run the tests**

`src/plugin.ts` does not exist yet, so build only the renderer:

```bash
cd plugin && npx tsc && npm test
```

Expected: PASS — `render tests passed`.

- [ ] **Step 8: Commit**

```bash
git add plugin
git commit -m "feat: plugin scaffold with geometry glyphs and non-red armed state"
```

---

### Task 11: Plugin — watch, paint, and dispatch presses

**Files:**
- Create: `plugin/src/plugin.ts`
- Create: `plugin/com.louisalexander.flightdeck.sdPlugin/ui/slot.html`

**Interfaces:**
- Consumes: `renderSvg`/`toDataUri` (Task 10), `slots.json`/`armed.json` (Tasks 4, 7), `bin/fleet-press` (Task 7)
- Produces: a running plugin. Repo root from `FLIGHTDECK_REPO`, else `~/code/flightdeck`. **Python interpreter read from `~/.fleet/interpreter`**, written by `install.sh`, falling back to `python3`.

**Two critical implementation details:**

1. `fleet-reconcile` replaces `slots.json` via `os.replace()`. `fs.watch` bound to a *file* stops firing once the inode is swapped. **Watch the directory and filter by filename.**
2. The plugin is launched by the Stream Deck app, which does not inherit your shell `PATH`. `python3` may not resolve. Use the absolute interpreter path.

- [ ] **Step 1: Write the property inspector**

Create `plugin/com.louisalexander.flightdeck.sdPlugin/ui/slot.html`:

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <script src="https://sdpi-components.dev/releases/v4/sdpi-components.js"></script>
</head>
<body>
  <sdpi-item label="Slot">
    <sdpi-select setting="slotIndex" default="0">
      <option value="0">0</option><option value="1">1</option>
      <option value="2">2</option><option value="3">3</option>
      <option value="4">4</option><option value="5">5</option>
      <option value="6">6</option><option value="7">7</option>
    </sdpi-select>
  </sdpi-item>
</body>
</html>
```

The `sdpi-components` script is fetched by the Stream Deck app's own webview, which has network access. If the inspector renders blank, replace the select with a plain `<input type="number">` wired via the standard `sendToPlugin` handshake.

- [ ] **Step 2: Write the plugin**

Create `plugin/src/plugin.ts`:

```typescript
import streamDeck, {
  action, SingletonAction,
  type WillAppearEvent, type WillDisappearEvent,
  type KeyDownEvent, type KeyUpEvent, type DidReceiveSettingsEvent
} from "@elgato/streamdeck";
import { readFileSync, watch, existsSync } from "node:fs";
import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { renderSvg, toDataUri } from "./render.js";
import type { Slot, SlotsFile, Config } from "./types.js";

const FLEET_HOME = join(homedir(), ".fleet");
const REPO = process.env.FLIGHTDECK_REPO ?? join(homedir(), "code", "flightdeck");
const SLOTS_PATH = join(FLEET_HOME, "slots.json");
const ARMED_PATH = join(FLEET_HOME, "armed.json");

type Settings = { slotIndex?: number };

function readJson<T>(path: string): T | null {
  try {
    if (!existsSync(path)) return null;
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch {
    return null;                     // mid-write or corrupt: skip this tick
  }
}

/**
 * The Stream Deck app does not inherit a shell PATH, and this machine has
 * four python3 installs. install.sh records the chosen absolute path.
 */
function interpreter(): string {
  try {
    const pinned = readFileSync(join(FLEET_HOME, "interpreter"), "utf8").trim();
    if (pinned) return pinned;
  } catch { /* fall through */ }
  return "python3";
}

function loadConfig(): Config {
  const base = readJson<Config>(join(REPO, "config", "fleet.json"));
  const local = readJson<Partial<Config>>(join(REPO, "config", "fleet.local.json"));
  return { states: { ...(base?.states ?? {}), ...(local?.states ?? {}) } };
}

const EMPTY = (index: number): Slot => ({
  index, state: "empty", label_top: "", label_bottom: "",
  session_id: "", host: "", iterm_session: "", cwd: "", app: ""
});

@action({ UUID: "com.louisalexander.flightdeck.slot" })
export class FleetSlot extends SingletonAction<Settings> {
  private visible = new Map<string, { ev: WillAppearEvent<Settings>; index: number }>();
  private downAt = new Map<string, number>();
  private config: Config = loadConfig();
  private longPressMs = 800;

  constructor() {
    super();
    // Watch the DIRECTORY: fleet-reconcile replaces slots.json by rename,
    // which permanently breaks a watch bound to the old inode.
    try {
      watch(FLEET_HOME, (_type, filename) => {
        if (filename === "slots.json" || filename === "armed.json") this.repaintAll();
      });
    } catch (err) {
      streamDeck.logger.error(`cannot watch ${FLEET_HOME}: ${String(err)}`);
    }
    // Safety net for missed events, and it expires the armed state on time.
    setInterval(() => this.repaintAll(), 1000);
  }

  override onWillAppear(ev: WillAppearEvent<Settings>): void {
    const index = Number(ev.payload.settings?.slotIndex ?? 0);
    this.visible.set(ev.action.id, { ev, index });
    this.paint(ev, index);
  }

  override onWillDisappear(ev: WillDisappearEvent<Settings>): void {
    this.visible.delete(ev.action.id);
    this.downAt.delete(ev.action.id);
  }

  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<Settings>): void {
    const entry = this.visible.get(ev.action.id);
    if (entry) {
      entry.index = Number(ev.payload.settings?.slotIndex ?? 0);
      this.paint(entry.ev, entry.index);
    }
  }

  override onKeyDown(ev: KeyDownEvent<Settings>): void {
    this.downAt.set(ev.action.id, Date.now());
  }

  override onKeyUp(ev: KeyUpEvent<Settings>): void {
    const down = this.downAt.get(ev.action.id) ?? Date.now();
    this.downAt.delete(ev.action.id);
    const verb = Date.now() - down >= this.longPressMs ? "long" : "short";
    const index = this.visible.get(ev.action.id)?.index ?? 0;

    execFile(interpreter(), [join(REPO, "bin", "fleet-press"), String(index), verb], (err) => {
      if (err) streamDeck.logger.error(`fleet-press failed: ${err.message}`);
      this.repaintAll();
    });
  }

  private repaintAll(): void {
    this.config = loadConfig();
    for (const { ev, index } of this.visible.values()) this.paint(ev, index);
  }

  private paint(ev: WillAppearEvent<Settings>, index: number): void {
    const file = readJson<SlotsFile>(SLOTS_PATH);
    const slot = file?.slots?.find((s) => s.index === index) ?? EMPTY(index);

    const arm = readJson<{ index: number; expires: number }>(ARMED_PATH);
    const armed = !!arm && arm.index === index && Date.now() / 1000 < arm.expires;

    ev.action.setTitle("");            // the SVG carries all text
    ev.action.setImage(toDataUri(renderSvg(slot, this.config, armed)));
  }
}

streamDeck.actions.registerAction(new FleetSlot());
streamDeck.connect();
```

- [ ] **Step 3: Build**

```bash
cd plugin && npm run build && ls -la com.louisalexander.flightdeck.sdPlugin/bin/
```

Expected: `plugin.js` and `render.js` present.

- [ ] **Step 4: Verify the renderer tests still pass**

Run: `cd plugin && npm test`
Expected: PASS.

- [ ] **Step 5: Install the plugin and verify end to end**

```bash
DEST=~/Library/Application\ Support/com.elgato.StreamDeck/Plugins
ln -sfn "$PWD/plugin/com.louisalexander.flightdeck.sdPlugin" \
        "$DEST/com.louisalexander.flightdeck.sdPlugin"
command -v python3 > ~/.fleet/interpreter          # install.sh does this properly later
osascript -e 'quit app "Elgato Stream Deck"' 2>/dev/null
sleep 2 && open -a "Elgato Stream Deck"
```

Then by hand:
1. Drag **Fleet Slot** onto key 1 of Row 1, set Slot `0`. Repeat for keys 2–8 with slots 1–7.
2. Seed fake state:
   ```bash
   FLEET_SKIP_RECONCILE=1 printf '{"session_id":"DEMO","cwd":"'"$PWD"'"}' | ./bin/fleet-emit UserPromptSubmit
   ./bin/fleet-reconcile && cat ~/.fleet/slots.json
   ```
   Key 1 must turn dark blue with a ▶ triangle, `FLIGHTDECK` above the branch name.
3. `printf '{"session_id":"DEMO","cwd":"'"$PWD"'"}' | ./bin/fleet-emit Notification` → key 1 turns amber with ▲ and **dark** text.
4. Press key 1 → the iTerm session focuses.
5. Hold key 1 for a second → near-black with an amber warning triangle and `CONFIRM?`. **It must not be red.** Wait four seconds → it returns to its previous lifecycle colour without killing anything.
6. Clean up:
   ```bash
   printf '{"session_id":"DEMO","cwd":"'"$PWD"'"}' | ./bin/fleet-emit SessionEnd && ./bin/fleet-reconcile
   ```
   Key 1 goes fully black with no glyph and no text.

If keys stay blank, check `~/Library/Logs/ElgatoStreamDeck/` for the plugin's log output.

- [ ] **Step 6: Commit**

```bash
git add plugin
git commit -m "feat: plugin watches slot state, paints keys, and dispatches presses"
```

---

### Task 12: `install.sh`, `fleet-doctor`, and README

**Files:**
- Create: `bin/fleet-doctor`, `install.sh`, `README.md`, `hooks/settings.snippet.json`

**Interfaces:**
- Consumes: everything above
- Produces: `./install.sh` performs full machine setup and **pins the Python interpreter**; `bin/fleet-doctor` exits 0 if every check passes, 1 otherwise.

- [ ] **Step 1: Write the hooks snippet**

Create `hooks/settings.snippet.json`. `__PYTHON__` and `__REPO__` are substituted by `install.sh`; pinning the interpreter here is what keeps hooks working regardless of the caller's `PATH`.

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "__PYTHON__ __REPO__/bin/fleet-emit SessionStart" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "__PYTHON__ __REPO__/bin/fleet-emit UserPromptSubmit" }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "__PYTHON__ __REPO__/bin/fleet-emit Notification" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "__PYTHON__ __REPO__/bin/fleet-emit Stop" }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "__PYTHON__ __REPO__/bin/fleet-emit SessionEnd" }] }]
  }
}
```

- [ ] **Step 2: Write `bin/fleet-doctor`**

```python
#!/usr/bin/env python3
"""Verifies every moving part. Exits 0 only if all checks pass."""

import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fleetlib  # noqa: E402

GREEN, RED, RESET = "\033[32m", "\033[31m", "\033[0m"
failed = False


def ok(message):
    print("  {}ok{}    {}".format(GREEN, RESET, message))


def bad(message, hint=""):
    global failed
    failed = True
    print("  {}FAIL{}  {}".format(RED, RESET, message))
    if hint:
        print("        {}".format(hint))


def have(name):
    """`command -v` is a shell builtin and is not executable via subprocess."""
    return subprocess.run(["/usr/bin/which", name], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def main():
    print("flightdeck doctor\n")

    print("  python: {} ({})".format(sys.executable, sys.version.split()[0]))
    if sys.version_info < (3, 9):
        bad("python is older than 3.9")
    else:
        ok("python version supported")

    pinned = fleetlib.fleet_home() / "interpreter"
    if pinned.is_file():
        path = pinned.read_text().strip()
        if Path(path).exists():
            ok("interpreter pinned to {}".format(path))
        else:
            bad("pinned interpreter {} does not exist".format(path), "re-run ./install.sh")
    else:
        bad("no pinned interpreter", "re-run ./install.sh")

    for tool in ("git", "osascript", "node"):
        ok("{} present".format(tool)) if have(tool) else bad("{} missing".format(tool))

    home = fleetlib.fleet_home()
    try:
        fleetlib.sessions_dir().mkdir(parents=True, exist_ok=True)
        probe = home / ".probe"
        probe.write_text("x")
        probe.unlink()
        ok("{} writable".format(home))
    except Exception as err:
        bad("{} not writable: {}".format(home, err))

    settings = Path.home() / ".claude" / "settings.json"
    if settings.is_file():
        data = fleetlib.read_json(settings, {}) or {}
        count = sum(1 for v in (data.get("hooks") or {}).values()
                    if "fleet-emit" in json.dumps(v))
        if count == 5:
            ok("all 5 hooks registered")
        else:
            bad("expected 5 fleet-emit hooks, found {}".format(count), "re-run ./install.sh")
    else:
        bad("{} not found".format(settings), "run claude once, then ./install.sh")

    listing = subprocess.run(["launchctl", "list"], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL)
    if b"flightdeck.reaper" in listing.stdout:
        ok("launchd reaper loaded")
    else:
        bad("launchd reaper not loaded", "re-run ./install.sh")

    plugin = (Path.home() / "Library" / "Application Support" / "com.elgato.StreamDeck"
              / "Plugins" / "com.louisalexander.flightdeck.sdPlugin")
    if plugin.exists():
        ok("plugin installed")
    else:
        bad("plugin not installed", "re-run ./install.sh")
    if (plugin / "bin" / "plugin.js").is_file():
        ok("plugin is built")
    else:
        bad("plugin not built", "cd plugin && npm run build")

    running = subprocess.run(["pgrep", "-f", "Elgato Stream Deck"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if running.returncode == 0:
        ok("Stream Deck app running")
    else:
        bad("Stream Deck app not running")

    # The classic silent killer: automation permission denied with no dialog.
    probe = subprocess.run(
        ["osascript", "-e", 'tell application "iTerm2" to count of windows'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if probe.returncode == 0:
        ok("iTerm2 automation permitted")
    else:
        bad("iTerm2 automation DENIED or iTerm2 not running",
            "System Settings > Privacy & Security > Automation, then re-run")

    print("\n" + ("all checks passed" if not failed else "some checks failed"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
```

```bash
chmod +x bin/fleet-doctor
```

- [ ] **Step 3: Write `install.sh`**

This stays bash — it is the bootstrap and cannot assume anything about the environment. It is also the one file shellcheck still lints.

```bash
#!/usr/bin/env bash
# Sets up flightdeck on this machine. Safe to re-run.
set -eu
REPO="$(cd "$(dirname "$0")" && pwd)"
FLEET_HOME="${FLEET_HOME:-$HOME/.fleet}"

printf 'installing flightdeck from %s\n' "$REPO"
mkdir -p "$FLEET_HOME/sessions"

# 0. Pin the interpreter. This machine has several python3 installs and
#    launchd resolves a different one than an interactive shell, so every
#    automated caller gets an absolute path.
PY="$(command -v python3 || true)"
[ -n "$PY" ] || { printf 'ERROR: no python3 on PATH\n' >&2; exit 1; }
PY="$("$PY" -c 'import sys; print(sys.executable)')"
"$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3,9) else 1)' || {
  printf 'ERROR: %s is older than python 3.9\n' "$PY" >&2; exit 1; }
printf '%s' "$PY" >"$FLEET_HOME/interpreter"
printf '  interpreter pinned: %s\n' "$PY"

# 1. Local config from the example, if absent.
if [ ! -f "$REPO/config/fleet.local.json" ]; then
  cp "$REPO/config/fleet.local.example.json" "$REPO/config/fleet.local.json"
  printf '  created config/fleet.local.json - edit pins and vault path\n'
fi

# 2. Merge hooks into ~/.claude/settings.json, preserving everything else.
S="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -f "$S" ] || printf '{}' >"$S"
cp "$S" "$S.flightdeck-backup.$(date +%s)"
sed -e "s|__PYTHON__|$PY|g" -e "s|__REPO__|$REPO|g" \
  "$REPO/hooks/settings.snippet.json" >"$FLEET_HOME/.snippet.json"
"$PY" - "$S" "$FLEET_HOME/.snippet.json" <<'PY'
import json, sys
target, snippet = sys.argv[1], sys.argv[2]
def merge(a, b):
    out = dict(a)
    for k, v in b.items():
        out[k] = merge(out[k], v) if k in out and isinstance(out[k], dict) and isinstance(v, dict) else v
    return out
base = json.load(open(target))
json.dump(merge(base, json.load(open(snippet))), open(target, "w"), indent=2)
PY
rm -f "$FLEET_HOME/.snippet.json"
printf '  hooks merged into %s (backup written)\n' "$S"

# 3. launchd reaper.
LA="$HOME/Library/LaunchAgents"
mkdir -p "$LA"
PLIST="$LA/com.louisalexander.flightdeck.reaper.plist"
sed -e "s|__PYTHON__|$PY|g" -e "s|__REPO__|$REPO|g" -e "s|__HOME__|$HOME|g" \
  "$REPO/launchd/com.louisalexander.flightdeck.reaper.plist" >"$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
printf '  launchd reaper loaded\n'

# 4. Build and link the plugin.
( cd "$REPO/plugin" && npm install --silent && npm run build --silent )
DEST="$HOME/Library/Application Support/com.elgato.StreamDeck/Plugins"
mkdir -p "$DEST"
ln -sfn "$REPO/plugin/com.louisalexander.flightdeck.sdPlugin" \
        "$DEST/com.louisalexander.flightdeck.sdPlugin"
printf '  plugin linked\n'

# 5. Restart Stream Deck so it picks up the plugin.
osascript -e 'quit app "Elgato Stream Deck"' 2>/dev/null || true
open -a "Elgato Stream Deck" 2>/dev/null || true

printf '\nrunning doctor...\n\n'
"$REPO/bin/fleet-doctor" || true
printf '\nNext: drag "Fleet Slot" onto Row 1 keys and set Slot 0-7.\n'
```

```bash
chmod +x install.sh
```

- [ ] **Step 4: Run the installer and the doctor**

```bash
./install.sh
./bin/fleet-doctor; echo "doctor exit=$?"
```

Expected: `doctor exit=0`, all checks green. Approve any macOS automation prompt.

- [ ] **Step 5: Verify against a real agent, end to end**

Open a new terminal and start a genuine agent:

```bash
cd ~/code/homeassistant && claude
```

Expected: a Row 1 key claims a slot showing the repo above the branch. Submit a prompt → dark blue ▶. Ask for something needing approval → **amber ▲**. Approve → blue → green ✓ when it stops. Press the key from another window → that session focuses. `/exit` → the key goes fully black.

Confirm nothing was disturbed: `tail -5 ~/.fleet/fleet.log` shows no errors, and the agent behaves exactly as before.

- [ ] **Step 6: Write the README**

Cover: what it is, the one-paragraph architecture, `./install.sh`, `./tests/run.sh`, `./bin/fleet-doctor`, the state table with colours and glyphs, and the two-machine config split.

Include a Row 3 section with deep links **inside a code block**, because GitHub strips the `claude-cli:` scheme from rendered Markdown:

````markdown
Row 3 needs no plugin — use Stream Deck's built-in **Website** action with:

```
claude-cli://open?q=<url-encoded-prompt>&cwd=/absolute/path/to/worktree
```

The prompt lands in the input box unsent. Never build these links from
untrusted input — a patched RCE smuggled `--settings` through `q`.
````

- [ ] **Step 7: Run the full suite and commit**

```bash
./tests/run.sh && (cd plugin && npm test)
```

Expected: shellcheck clean, python clean, `66 tests, 0 failures`, `render tests passed`.

```bash
git add bin/fleet-doctor install.sh hooks README.md
git commit -m "feat: installer with interpreter pinning, doctor, and documentation"
git push origin main
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: architecture and data flow → 3, 4, 11; visual principles → 2 (config), 10 (renderer); state model, colours and glyph geometry → 2, 10; five-hook rule → 3, 12; `failed` semantics → 9; token-aware labels → 2 (`fleetlib.shorten` + `labels.bats`), applied in 4; sticky slots, pins, overflow → 4; press semantics and host dispatch → 6, 7; arm/confirm and the not-red rule → 7, 10, 11; teardown safety → 8; Python language decision and interpreter pinning → Global Constraints, 5 (plist), 11 (plugin), 12 (installer); atomic writes and exit-0 → 3, asserted in tests; `fleet-doctor` → 12; deep links → 12's README; memory substrate reservation → `events.jsonl` in 3 and `journal.vault` in 2's example config.

**Deliberately deferred, consistent with the spec:** Rows 2 and 4, the focus underline, title-glyph polling as a live state source (Task 1 records whether it is needed), seen-vs-unseen intensity, slot numbers on empty keys, journal export, and the branding asset package.

**Cumulative test counts** (each task's Step 4 asserts the running total, so a silently skipped file is caught):

| After task | File added | New | Total |
|---|---|---|---|
| 2 | `config.bats` + `labels.bats` | 12 | 12 |
| 3 | `emit.bats` | 13 | 25 |
| 4 | `reconcile.bats` | 9 | 34 |
| 5 | `reap.bats` | 5 | 39 |
| 7 | `press.bats` | 11 | 50 |
| 8 | `kill.bats` | 12 | 62 |
| 9 | `fail.bats` | 4 | 66 |

Task 6 (`fleet-focus`) adds no bats tests by design — it needs live iTerm2 and is verified by `tools/focus-smoke.sh`.

**Type consistency.** The `Slot` shape written by `fleet-reconcile` (Task 4) is consumed verbatim by `fleet-press` (7), `render.ts` (10) and `plugin.ts` (11) — nine fields, same names. The session-file shape from Task 3 is read by 4, 5, 8, 9. `armed.json` is written in 7 and read in 11 with matching `index`/`expires`. `fleetlib`'s public surface is fixed in Task 2 and unchanged thereafter. `FLEET_HOME`, `FLEET_CONFIG_DIR`, `FLEET_SKIP_RECONCILE`, `FLEET_DRY_RUN` and `FLEET_NOW` are honoured uniformly.

**Known ordering dependency.** Task 7's tests stub `fleet-kill`, which Task 8 builds — so 7 passes before 8 exists. Intentional: it keeps the arm/confirm machine testable in isolation.

**Interpreter pinning appears in four places** and all four must agree: `~/.fleet/interpreter` (written by `install.sh`), the hook commands in `settings.json`, the launchd plist's `ProgramArguments`, and the plugin's `interpreter()`. `fleet-doctor` checks the pin exists and resolves. Scripts keep `#!/usr/bin/env python3` so the repo tree is never dirtied by installation.
