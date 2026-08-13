# Flightdeck v1 — Fleet Awareness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Row 1 of a Stream Deck XL into a live, ambient view of every running Claude Code agent — colour is state, label is repo and task, press focuses that session, long-press tears it down under guard.

**Architecture:** Claude Code hooks write one JSON file per agent into `~/.fleet/sessions/`. A shell script (`fleet-reconcile`) turns those files into a sticky slot→agent map at `~/.fleet/slots.json`. A deliberately dumb Stream Deck plugin watches that one file, paints eight keys, and shells out to `bin/fleet-press` on input. All decision logic lives in shell scripts editable without a rebuild.

**Tech Stack:** bash 3.2, jq 1.7, osascript (iTerm2 AppleScript), launchd, Node 23 + TypeScript + `@elgato/streamdeck` SDK v2. Tested with bats-core 1.14, linted with shellcheck 0.11.

**Spec:** `docs/superpowers/specs/2026-08-13-streamdeck-fleet-design.md`

## Global Constraints

- **bash 3.2 only, deliberately.** macOS ships bash 3.2.57 (frozen in 2007 over GPLv3). No associative arrays (`declare -A`), no `mapfile`/`readarray`, no `${var^^}`/`${var,,}`, no `&>>`. Use `jq` for anything resembling a data structure.

  **Do not "fix" this by installing a newer bash.** `launchctl getenv PATH` is unset on this machine, so a LaunchAgent runs with the bare `/usr/bin:/bin:/usr/sbin:/sbin`. If a brew bash existed, `#!/usr/bin/env bash` would resolve to 5.x in your terminal and 3.2 under launchd — the reaper would silently run a different interpreter than every test. Targeting 3.2 everywhere removes that split. Nothing in this plan needs bash 4+ anyway, because jq holds the data.

- **Dev tooling (not runtime):** `shellcheck` 0.11.0 and `bats-core` 1.14.0, both installed via brew. The **runtime** stays dependency-free — `git clone && ./install.sh` must work on a machine with no brew. Tests and linting may assume brew; the shipped system may not.
- **Hooks always `exit 0`.** No hook may ever fail, hang, or emit to stdout. A bug in this project must never break a real agent. Errors go to `~/.fleet/fleet.log` only.
- **All writes atomic.** Write to `$file.tmp.$$` then `mv` into place. The plugin must never read a partial file.
- **Exactly five hooks:** `SessionStart`, `UserPromptSubmit`, `Notification`, `Stop`, `SessionEnd`. **Never** `PreToolUse` or `PostToolUse` — they fire per tool call and would tax every agent action.
- **All state under `~/.fleet/`.** Identical path on every machine.
- **No new runtime dependencies.** `jq`, `osascript`, `git`, `node` only. No brew installs required to run or test.
- **Node ≥ 20** for the plugin (machine has v23.11.0). **Claude Code ≥ 2.1.91** for deep links (machine has 2.1.231).
- **Never build a `claude-cli://` link from untrusted input.** Literals in `fleet.local.json` only. A patched RCE smuggled `--settings` through the `q` parameter.
- **`config/fleet.local.json` is gitignored** and holds only pins and the vault path.

---

### Task 1: Hook contract spike

Everything downstream assumes five hook names and their payload shapes. The `claude` binary is compiled and could not be inspected. **This task is a gate: do not start Task 3 until `docs/hook-contract.md` exists.**

The probe must be scoped to this repo only, so it cannot disturb the agents already running on this machine.

**Files:**
- Create: `.claude/settings.json` (project-scoped, temporary probe config)
- Create: `tools/probe-hook.sh`
- Create: `docs/hook-contract.md`

**Interfaces:**
- Consumes: nothing
- Produces: `docs/hook-contract.md`, documenting for each of the five hooks: exact event name, whether it fires, and the full stdin JSON payload with field names. Task 3 reads field names from this file.

- [ ] **Step 1: Write the probe script**

Create `tools/probe-hook.sh`:

```bash
#!/usr/bin/env bash
# Dumps a hook's stdin payload for contract discovery. Never fails.
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

Create `.claude/settings.json`. Because it is project-scoped it applies only to sessions started inside `~/code/flightdeck`, leaving the other running agents untouched.

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

Then, in that session, drive each transition deliberately:
1. Session start happens on launch → expect `SessionStart`.
2. Submit any prompt, e.g. `list the files here` → expect `UserPromptSubmit`.
3. Let it finish → expect `Stop`.
4. Ask it to run a command needing approval, e.g. `run: rm -i /tmp/nonexistent-flightdeck-probe` → **expect `Notification` when the permission prompt appears.** This is the critical one.
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

### Task 2: Repo scaffold, test harness, and config loader

**Files:**
- Create: `.gitignore`, `config/fleet.json`, `config/fleet.local.example.json`
- Create: `bin/fleet-config`
- Create: `tests/run.sh`, `tests/config.bats`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `bin/fleet-config` — prints merged config JSON to stdout. Env override `FLEET_CONFIG_DIR` selects the config directory (used by tests).
  - `tests/run.sh` — the single entry point: runs shellcheck over `bin/` then the whole bats suite. Every later task's verification step calls it.
  - `FLEET_HOME` env var, defaulting to `$HOME/.fleet`, honoured by **every** script in `bin/`. Tests set it to bats' per-test temp dir.

**Test conventions used by every task from here on.** bats gives each `@test` a fresh `$BATS_TEST_TMPDIR`, so tests are isolated by construction and never need manual cleanup. `run <cmd>` captures `$status` and `$output`. A test that asserts an *ordered sequence* (slot stickiness, arm-then-confirm) keeps the whole sequence inside one `@test`, because state must not leak between tests.

- [ ] **Step 1: Write the failing test**

Create `tests/config.bats`:

```bash
#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  mkdir -p "$FLEET_CONFIG_DIR"
  cat >"$FLEET_CONFIG_DIR/fleet.json" <<'EOF'
{"slots":{"count":8},"timings":{"armMs":3000},"states":{"idle":{"color":"#4A4A4A"}}}
EOF
}

@test "base config is returned when no local file exists" {
  run "$BIN/fleet-config"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.slots.count')" = "8" ]
}

@test "local config deep-merges without clobbering siblings" {
  cat >"$FLEET_CONFIG_DIR/fleet.local.json" <<'EOF'
{"timings":{"armMs":5000},"pins":{"7":{"host":"pinned-app","app":"ChatGPT"}}}
EOF
  run "$BIN/fleet-config"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.timings.armMs')"     = "5000" ]
  [ "$(echo "$output" | jq -r '.pins["7"].app')"     = "ChatGPT" ]
  [ "$(echo "$output" | jq -r '.slots.count')"       = "8" ]
  [ "$(echo "$output" | jq -r '.states.idle.color')" = "#4A4A4A" ]
}

@test "malformed local config falls back to base instead of emitting garbage" {
  printf '{ this is not json' >"$FLEET_CONFIG_DIR/fleet.local.json"
  run "$BIN/fleet-config"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.slots.count')" = "8" ]
}

@test "missing base config emits valid empty JSON rather than nothing" {
  rm -f "$FLEET_CONFIG_DIR/fleet.json"
  run "$BIN/fleet-config"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r 'type')" = "object" ]
}
```

- [ ] **Step 2: Write the test entry point**

Create `tests/run.sh`. Linting runs *first* — a shellcheck failure should stop the suite before test output buries it.

```bash
#!/usr/bin/env bash
# Single entry point: lint every script, then run the bats suite.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rc=0

printf '== shellcheck ==\n'
# Build the file list from what actually exists, so this works from the very
# first task (when bin/ holds one script) through to the last.
targets=""
for f in "$ROOT"/bin/* "$ROOT"/install.sh "$ROOT"/tools/*.sh; do
  [ -f "$f" ] && targets="$targets $f"
done

if [ -z "$targets" ]; then
  printf 'nothing to lint yet\n'
# -s bash pins the dialect; every script must be valid bash 3.2.
elif shellcheck -s bash -S warning $targets; then
  printf 'clean\n'
else
  rc=1
fi

printf '\n== bats ==\n'
bats "$ROOT/tests" || rc=1

exit "$rc"
```

```bash
chmod +x tests/run.sh
```

`$targets` is intentionally unquoted — it is a word list, and shellcheck's SC2086 warning is expected here. Add `# shellcheck disable=SC2086` above that line with a comment explaining why, per the suppression rule below.

The glob is built from what exists rather than a fixed list, so scripts added in later tasks are linted automatically and no plan step can forget one.

- [ ] **Step 3: Run the test to verify it fails**

Run: `./tests/run.sh`
Expected: FAIL — bats reports all four `config.bats` tests failing because `bin/fleet-config` does not exist.

- [ ] **Step 4: Write `bin/fleet-config`**

```bash
#!/usr/bin/env bash
# Prints merged configuration JSON. Base <- local. Malformed local is ignored.
set -u
DIR="${FLEET_CONFIG_DIR:-$(cd "$(dirname "$0")/../config" && pwd)}"
BASE="$DIR/fleet.json"
LOCAL="$DIR/fleet.local.json"

[ -f "$BASE" ] || { printf '{}\n'; exit 0; }

if [ -f "$LOCAL" ] && jq -e . "$LOCAL" >/dev/null 2>&1; then
  jq -s '.[0] * .[1]' "$BASE" "$LOCAL"
else
  cat "$BASE"
fi
```

```bash
chmod +x bin/fleet-config
```

- [ ] **Step 5: Write the real config files**

Create `config/fleet.json`:

```json
{
  "slots": { "count": 8 },
  "timings": { "armMs": 3000, "longPressMs": 800, "reaperSeconds": 15 },
  "labels": { "maxChars": 11, "stripPrefixes": ["feat/", "fix/", "chore/", "feature/"] },
  "states": {
    "blocked": { "color": "#F5A623", "glyph": "▲" },
    "working": { "color": "#1F4FD8", "glyph": "●" },
    "done":    { "color": "#2E9E4F", "glyph": "✓" },
    "idle":    { "color": "#3A3A3A", "glyph": "·" },
    "failed":  { "color": "#C62828", "glyph": "✕" },
    "empty":   { "color": "#101010", "glyph": "" },
    "armed":   { "color": "#C62828", "glyph": "⚠" }
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
.DS_Store
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./tests/run.sh`
Expected: shellcheck `clean`, then `4 tests, 0 failures`.

If shellcheck flags anything in `fleet-config`, fix it rather than suppressing it. The only legitimate suppressions in this project are `SC1091` (sourcing a file shellcheck cannot follow), and each must carry a comment saying why.

- [ ] **Step 7: Commit**

```bash
git add .gitignore config bin/fleet-config tests
git commit -m "feat: repo scaffold, bats+shellcheck test entry point, layered config loader"
```

---

### Task 3: `fleet-emit` — the hook entrypoint

**Files:**
- Create: `bin/fleet-emit`
- Create: `tests/emit.bats`

**Interfaces:**
- Consumes: `docs/hook-contract.md` (field names), `FLEET_HOME`
- Produces:
  - `bin/fleet-emit <EventName>` — reads hook JSON on stdin, writes `$FLEET_HOME/sessions/<session_id>.json`, appends to `$FLEET_HOME/events.jsonl`. Always exits 0.
  - **Session file schema**, relied on by Tasks 4, 6, 7:
    ```json
    { "session_id": "...", "state": "working", "repo": "flightdeck",
      "branch": "main", "title": "", "cwd": "/abs/path", "host": "iterm2",
      "iterm_session": "UUID", "pid": 1234, "ts": 1755100000 }
    ```
  - Env override `FLEET_SKIP_RECONCILE=1` suppresses the reconcile call (tests use it).

> **Adjust the stdin field paths below to match `docs/hook-contract.md` from Task 1.** The plan assumes `.session_id` and `.cwd`; if the contract shows different names, change the two `jq -r` extractions and nothing else.

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
state() { jq -r .state "$FLEET_HOME/sessions/S1.json"; }

@test "SessionStart maps to idle" {
  emit SessionStart
  [ "$(state)" = "idle" ]
}

@test "UserPromptSubmit maps to working" {
  emit UserPromptSubmit
  [ "$(state)" = "working" ]
}

@test "Notification maps to blocked" {
  emit Notification
  [ "$(state)" = "blocked" ]
}

@test "Stop maps to done" {
  emit Stop
  [ "$(state)" = "done" ]
}

@test "SessionEnd removes the session file" {
  emit SessionStart
  [ -f "$FLEET_HOME/sessions/S1.json" ]
  emit SessionEnd
  [ ! -f "$FLEET_HOME/sessions/S1.json" ]
}

@test "every event appends one line to the journal spine, removals included" {
  emit SessionStart
  emit UserPromptSubmit
  emit Stop
  emit SessionEnd
  [ "$(wc -l <"$FLEET_HOME/events.jsonl" | tr -d ' ')" = "4" ]
  [ "$(tail -1 "$FLEET_HOME/events.jsonl" | jq -r .event)" = "SessionEnd" ]
}

@test "iTerm session uuid is captured with its w/t/p prefix stripped" {
  ITERM_SESSION_ID="w1t2p0:ABC-123" emit SessionStart
  [ "$(jq -r .iterm_session "$FLEET_HOME/sessions/S1.json")" = "ABC-123" ]
  [ "$(jq -r .host "$FLEET_HOME/sessions/S1.json")" = "iterm2" ]
}

@test "host is unknown when not running under iTerm" {
  ITERM_SESSION_ID="" emit SessionStart
  [ "$(jq -r .host "$FLEET_HOME/sessions/S1.json")" = "unknown" ]
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./tests/run.sh`
Expected: FAIL — `bin/fleet-emit` does not exist.

- [ ] **Step 3: Write `bin/fleet-emit`**

```bash
#!/usr/bin/env bash
# Claude Code hook entrypoint. Records agent state. MUST ALWAYS EXIT 0.
set -u

FLEET_HOME="${FLEET_HOME:-$HOME/.fleet}"
SESSIONS="$FLEET_HOME/sessions"
LOG="$FLEET_HOME/fleet.log"
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$SESSIONS" 2>/dev/null

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null; }

# Everything of consequence happens inside main(); the trailing `exit 0` is absolute.
main() {
  EVENT="${1:-}"
  case "$EVENT" in
    SessionStart)     STATE="idle" ;;
    UserPromptSubmit) STATE="working" ;;
    Notification)     STATE="blocked" ;;
    Stop)             STATE="done" ;;
    SessionEnd)       STATE="__end__" ;;
    *) log "emit: ignoring unknown event '$EVENT'"; return 0 ;;
  esac

  PAYLOAD="$(cat)"
  printf '%s' "$PAYLOAD" | jq -e . >/dev/null 2>&1 || {
    log "emit: unparseable payload for $EVENT"; return 0
  }

  SID="$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty')"
  [ -n "$SID" ] || SID="${CLAUDE_CODE_SESSION_ID:-}"
  [ -n "$SID" ] || { log "emit: no session id for $EVENT"; return 0; }

  CWD="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty')"
  [ -n "$CWD" ] || CWD="$PWD"

  # iTerm exports w<win>t<tab>p<pane>:<uuid>; only the uuid is addressable.
  ITERM_UUID="${ITERM_SESSION_ID:-}"
  ITERM_UUID="${ITERM_UUID#*:}"
  if [ -n "$ITERM_UUID" ]; then HOST="iterm2"; else HOST="unknown"; fi

  REPO=""; BRANCH=""
  if TOP="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)"; then
    REPO="$(basename "$TOP")"
    BRANCH="$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  fi

  TS="$(date +%s)"

  # Append to the journal spine before any early return, so removals are recorded too.
  jq -nc --arg e "$EVENT" --arg s "$SID" --arg r "$REPO" --arg b "$BRANCH" \
         --arg c "$CWD" --argjson t "$TS" \
    '{event:$e, session_id:$s, repo:$r, branch:$b, cwd:$c, ts:$t}' \
    >>"$FLEET_HOME/events.jsonl" 2>/dev/null

  if [ "$STATE" = "__end__" ]; then
    rm -f "$SESSIONS/$SID.json" 2>/dev/null
  else
    PID="$(find_agent_pid)"
    TMP="$SESSIONS/.$SID.json.tmp.$$"
    jq -nc --arg id "$SID" --arg st "$STATE" --arg r "$REPO" --arg b "$BRANCH" \
           --arg c "$CWD" --arg h "$HOST" --arg iu "$ITERM_UUID" \
           --argjson p "${PID:-0}" --argjson t "$TS" \
      '{session_id:$id, state:$st, repo:$r, branch:$b, title:"",
        cwd:$c, host:$h, iterm_session:$iu, pid:$p, ts:$t}' \
      >"$TMP" 2>/dev/null && mv -f "$TMP" "$SESSIONS/$SID.json" 2>/dev/null
  fi

  [ "${FLEET_SKIP_RECONCILE:-0}" = "1" ] || "$HERE/fleet-reconcile" >/dev/null 2>&1
  return 0
}

# Walk up the process tree to find the agent process this hook was spawned from.
find_agent_pid() {
  p="$PPID"; i=0
  while [ -n "$p" ] && [ "$p" != "1" ] && [ "$i" -lt 6 ]; do
    c="$(ps -o comm= -p "$p" 2>/dev/null | sed 's|.*/||')"
    case "$c" in claude|node) printf '%s' "$p"; return 0 ;; esac
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    i=$((i + 1))
  done
  printf '0'
}

main "$@" 2>>"$LOG"
exit 0
```

```bash
chmod +x bin/fleet-emit
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run.sh`
Expected: shellcheck clean, `15 tests, 0 failures` (4 config + 11 emit).

The last emit test is the important one: an unwritable `FLEET_HOME` must still exit 0. That is the exit-0 guarantee, asserted rather than assumed.

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-emit tests/emit.bats
git commit -m "feat: fleet-emit hook entrypoint with atomic writes and exit-0 guarantee"
```

---

### Task 4: `fleet-reconcile` — sticky slot assignment

The heart of the system. Slot stickiness is what makes the row usable without looking, so it gets the most thorough test.

**Files:**
- Create: `bin/fleet-reconcile`
- Create: `tests/reconcile.bats`

**Interfaces:**
- Consumes: session files from Task 3; `bin/fleet-config`
- Produces:
  - `bin/fleet-reconcile` — reads `$FLEET_HOME/sessions/*.json`, writes `$FLEET_HOME/slots.json` atomically.
  - **`slots.json` schema**, consumed by Tasks 6 and 10:
    ```json
    { "ts": 1755100000, "overflow": 0,
      "slots": [ { "index": 0, "state": "working", "label_top": "flightdeck",
                   "label_bottom": "main", "session_id": "S1", "host": "iterm2",
                   "iterm_session": "UUID", "cwd": "/abs/path", "app": "" } ] }
    ```
    Empty slots have `state: "empty"`, empty strings elsewhere, `index` always present. The array always has exactly `slots.count` entries, ordered by index.

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
  jq -nc --arg id "$1" --arg st "$2" --arg r "$3" --arg b "$4" --arg t "${5:-}" \
    '{session_id:$id, state:$st, repo:$r, branch:$b, title:$t,
      cwd:"/tmp", host:"iterm2", iterm_session:("U-"+$id), pid:1, ts:1}' \
    >"$FLEET_HOME/sessions/$1.json"
}
sf() { jq -r --argjson i "$1" '.slots[] | select(.index==$i) | .'"$2" "$FLEET_HOME/slots.json"; }

@test "sessions claim the lowest free slot and the file always has 8 entries" {
  mksession A working flightdeck main
  mksession B blocked sisko feat/login
  run "$BIN/fleet-reconcile"
  [ "$status" -eq 0 ]
  [ "$(sf 0 session_id)" = "A" ]
  [ "$(sf 1 session_id)" = "B" ]
  [ "$(jq '.slots | length' "$FLEET_HOME/slots.json")" = "8" ]
  [ "$(sf 7 state)" = "empty" ]
}

@test "STICKINESS: a freed slot does not shift its neighbours, and is reused" {
  mksession A working flightdeck main
  mksession B blocked sisko feat/login
  "$BIN/fleet-reconcile"

  # A dies. B must not move.
  rm -f "$FLEET_HOME/sessions/A.json"
  "$BIN/fleet-reconcile"
  [ "$(sf 0 state)" = "empty" ]
  [ "$(sf 1 session_id)" = "B" ]

  # A new session takes the freed slot, and B still has not moved.
  mksession C idle homeassistant main
  "$BIN/fleet-reconcile"
  [ "$(sf 0 session_id)" = "C" ]
  [ "$(sf 1 session_id)" = "B" ]
}

@test "labels put repo on top and strip known branch prefixes" {
  mksession B blocked sisko feat/login
  "$BIN/fleet-reconcile"
  [ "$(sf 0 label_top)" = "sisko" ]
  [ "$(sf 0 label_bottom)" = "login" ]
}

@test "labels are truncated to maxChars" {
  mksession D working averyverylongreponame some/very-long-branch-name
  "$BIN/fleet-reconcile"
  [ "$(jq -r '.slots[0].label_top    | length <= 11' "$FLEET_HOME/slots.json")" = "true" ]
  [ "$(jq -r '.slots[0].label_bottom | length <= 11' "$FLEET_HOME/slots.json")" = "true" ]
}

@test "task title beats branch for the bottom label" {
  mksession B blocked sisko feat/login break-state
  "$BIN/fleet-reconcile"
  [ "$(sf 0 label_bottom)" = "break-state" ]
}

@test "OVERFLOW: only 8 are slotted and the remainder is counted, not shuffled in" {
  i=1; while [ $i -le 9 ]; do mksession "S$i" working "repo$i" main; i=$((i+1)); done
  "$BIN/fleet-reconcile"
  [ "$(jq '[.slots[] | select(.state!="empty")] | length' "$FLEET_HOME/slots.json")" = "8" ]
  [ "$(jq -r .overflow "$FLEET_HOME/slots.json")" = "1" ]
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
  [ "$(jq -r .overflow "$FLEET_HOME/slots.json")" = "1" ]
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
  [ "$(jq '.slots | length' "$FLEET_HOME/slots.json")" = "8" ]
  [ "$(jq -r .overflow "$FLEET_HOME/slots.json")" = "0" ]
}
```

Truncation is asserted through `jq`, not shell string length — the character count in the emitted JSON is what the key actually renders.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./tests/run.sh`
Expected: FAIL — `bin/fleet-reconcile` does not exist.

- [ ] **Step 3: Write `bin/fleet-reconcile`**

All list manipulation is done in jq, because bash 3.2 has no associative arrays.

```bash
#!/usr/bin/env bash
# Turns session files into a sticky slot map. Writes $FLEET_HOME/slots.json atomically.
set -u

FLEET_HOME="${FLEET_HOME:-$HOME/.fleet}"
SESSIONS="$FLEET_HOME/sessions"
SLOTS="$FLEET_HOME/slots.json"
LOG="$FLEET_HOME/fleet.log"
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$SESSIONS" 2>/dev/null

CFG="$("$HERE/fleet-config" 2>/dev/null)"
[ -n "$CFG" ] || CFG='{}'

# Gather valid session files; silently skip unparseable ones.
LIVE="$(
  for f in "$SESSIONS"/*.json; do
    [ -e "$f" ] || continue
    jq -c . "$f" 2>/dev/null || printf ''
  done | jq -sc 'map(select(type=="object" and .session_id != null)) | sort_by(.ts, .session_id)'
)"
[ -n "$LIVE" ] || LIVE='[]'

PREV='{}'
if [ -f "$SLOTS" ]; then
  PREV="$(jq -c '[.slots[] | select(.session_id != "" and .session_id != null)
                 | {key: (.index|tostring), value: .session_id}] | from_entries' \
          "$SLOTS" 2>/dev/null)" || PREV='{}'
fi
[ -n "$PREV" ] || PREV='{}'

TMP="$FLEET_HOME/.slots.json.tmp.$$"

jq -n \
  --argjson live "$LIVE" \
  --argjson prev "$PREV" \
  --argjson cfg  "$CFG" \
  --argjson ts   "$(date +%s)" '

  ($cfg.slots.count // 8)          as $count
| ($cfg.pins // {})                as $pins
| ($cfg.labels.maxChars // 11)     as $max
| ($cfg.labels.stripPrefixes // []) as $strip

# Shorten a label: drop known prefixes, then truncate.
| def shorten($s):
    ($strip | reduce .[] as $p ($s; if startswith($p) then .[($p|length):] else . end))
    | if length > $max then .[0:$max] else . end;

| ($live | map(.session_id))                                as $liveids
| ($live | map({key: .session_id, value: .}) | from_entries) as $byid

# Pass 1: each index is a pin, a retained session, or free.
| [ range(0; $count) as $i
  | if ($pins[$i|tostring]) then {index:$i, kind:"pin", pin:$pins[$i|tostring]}
    elif (($prev[$i|tostring]) as $s | $s != null and ($liveids | index($s)) != null)
      then {index:$i, kind:"session", session_id:$prev[$i|tostring]}
    else {index:$i, kind:"free"} end ] as $base

# Pass 2: fill free slots with sessions not already retained, lowest index first.
| ($liveids - ($base | map(select(.kind=="session") | .session_id))) as $pending
| (reduce $base[] as $e ({out:[], pend:$pending};
     if $e.kind == "free" and (.pend | length) > 0
     then .out += [{index:$e.index, kind:"session", session_id:.pend[0]}] | .pend = .pend[1:]
     else .out += [$e] end)) as $filled

# Pass 3: hydrate into the render schema.
| { ts: $ts,
    overflow: ($filled.pend | length),
    slots: [ $filled.out[]
      | if .kind == "pin" then
          { index, state:"idle", label_top:(.pin.label_top // ""),
            label_bottom:(.pin.label_bottom // ""), session_id:"",
            host:(.pin.host // "pinned-app"), iterm_session:"", cwd:"",
            app:(.pin.app // "") }
        elif .kind == "session" then
          ($byid[.session_id]) as $s
          | { index, state:($s.state // "idle"),
              label_top: shorten($s.repo // ""),
              label_bottom: shorten( if ($s.title // "") != "" then $s.title else ($s.branch // "") end ),
              session_id: $s.session_id,
              host: ($s.host // "unknown"), iterm_session: ($s.iterm_session // ""),
              cwd: ($s.cwd // ""), app: "" }
        else
          { index, state:"empty", label_top:"", label_bottom:"", session_id:"",
            host:"", iterm_session:"", cwd:"", app:"" }
        end ] }
' >"$TMP" 2>>"$LOG" && mv -f "$TMP" "$SLOTS" 2>/dev/null

rm -f "$TMP" 2>/dev/null
exit 0
```

```bash
chmod +x bin/fleet-reconcile
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run.sh`
Expected: shellcheck clean, `24 tests, 0 failures`. The `STICKINESS` test is the one to watch — it is the behaviour the whole row depends on.

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-reconcile tests/reconcile.bats
git commit -m "feat: sticky slot assignment with pins, overflow, and label shortening"
```

---

### Task 5: Reaping crashed sessions

A crashed agent never runs `SessionEnd`, so its file lingers and its slot never frees.

**Files:**
- Create: `bin/fleet-reap`
- Create: `tests/reap.bats`
- Create: `launchd/com.louisalexander.flightdeck.reaper.plist`

**Interfaces:**
- Consumes: session files from Task 3
- Produces: `bin/fleet-reap` — removes session files whose `pid` is dead, then calls `fleet-reconcile`. Exits 0 always. Env `FLEET_SKIP_RECONCILE=1` honoured.

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
  jq -nc --arg id "$1" --argjson p "$2" \
    '{session_id:$id, state:"working", repo:"r", branch:"b", title:"",
      cwd:"/tmp", host:"iterm2", iterm_session:"U", pid:$p, ts:1}' \
    >"$FLEET_HOME/sessions/$1.json"
}

@test "a session whose process is alive is kept" {
  mk ALIVE "$$"
  "$BIN/fleet-reap"
  [ -f "$FLEET_HOME/sessions/ALIVE.json" ]
}

@test "a session whose process is gone is reaped" {
  mk DEAD 999999
  "$BIN/fleet-reap"
  [ ! -f "$FLEET_HOME/sessions/DEAD.json" ]
}

@test "an unknown pid is never guessed at — the session is kept" {
  mk NOPID 0
  "$BIN/fleet-reap"
  [ -f "$FLEET_HOME/sessions/NOPID.json" ]
}

@test "a non-numeric pid is treated as unknown, not as dead" {
  jq -nc '{session_id:"WEIRD", state:"working", repo:"r", branch:"b", title:"",
           cwd:"/tmp", host:"iterm2", iterm_session:"U", pid:"not-a-number", ts:1}' \
    >"$FLEET_HOME/sessions/WEIRD.json"
  "$BIN/fleet-reap"
  [ -f "$FLEET_HOME/sessions/WEIRD.json" ]
}

@test "reaping an empty directory is safe and idempotent" {
  run "$BIN/fleet-reap"
  [ "$status" -eq 0 ]
  run "$BIN/fleet-reap"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./tests/run.sh`
Expected: FAIL — `bin/fleet-reap` does not exist.

- [ ] **Step 3: Write `bin/fleet-reap`**

```bash
#!/usr/bin/env bash
# Removes session files whose agent process is gone. Conservative: pid 0 is never reaped.
set -u

FLEET_HOME="${FLEET_HOME:-$HOME/.fleet}"
SESSIONS="$FLEET_HOME/sessions"
LOG="$FLEET_HOME/fleet.log"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ -d "$SESSIONS" ] || exit 0

for f in "$SESSIONS"/*.json; do
  [ -e "$f" ] || continue
  pid="$(jq -r '.pid // 0' "$f" 2>/dev/null)"
  case "$pid" in ''|*[!0-9]*) pid=0 ;; esac
  [ "$pid" -eq 0 ] && continue            # unknown pid: keep, never guess
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$f" 2>/dev/null
    printf '%s reap: removed %s (pid %s gone)\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$f")" "$pid" >>"$LOG" 2>/dev/null
  fi
done

[ "${FLEET_SKIP_RECONCILE:-0}" = "1" ] || "$HERE/fleet-reconcile" >/dev/null 2>&1
exit 0
```

```bash
chmod +x bin/fleet-reap
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run.sh`
Expected: shellcheck clean, `29 tests, 0 failures`.

- [ ] **Step 5: Write the launchd agent**

Create `launchd/com.louisalexander.flightdeck.reaper.plist`. `__REPO__` is substituted by `install.sh` in Task 12.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>com.louisalexander.flightdeck.reaper</string>
  <key>ProgramArguments</key> <array><string>__REPO__/bin/fleet-reap</string></array>
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
- Create: `bin/fleet-focus`
- Create: `tools/focus-smoke.sh`

**Interfaces:**
- Consumes: nothing from other tasks
- Produces: `bin/fleet-focus <host> <target>` where `host` is `iterm2` (target = iTerm session UUID) or `pinned-app` (target = application name). Exits 0 on success, 1 if the target no longer exists.

- [ ] **Step 1: Write `bin/fleet-focus`**

Direct `session id "<uuid>"` addressing fails with error -1728, verified during design. Iterate and match.

```bash
#!/usr/bin/env bash
# Brings a host into focus. iterm2 targets are session UUIDs; pinned-app targets are app names.
set -u
HOST="${1:-}"; TARGET="${2:-}"
[ -n "$HOST" ] && [ -n "$TARGET" ] || exit 1

case "$HOST" in
  pinned-app)
    open -a "$TARGET" >/dev/null 2>&1 || exit 1
    ;;
  iterm2)
    osascript <<APPLESCRIPT >/dev/null 2>&1 || exit 1
tell application "iTerm2"
  set found to false
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if (id of s) is "$TARGET" then
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
APPLESCRIPT
    ;;
  *) exit 1 ;;
esac
exit 0
```

```bash
chmod +x bin/fleet-focus
```

- [ ] **Step 2: Write the manual smoke test**

Create `tools/focus-smoke.sh`:

```bash
#!/usr/bin/env bash
# Manual check: focuses this very session, then reports on a bogus target.
set -u
HERE="$(cd "$(dirname "$0")/../bin" && pwd)"
UUID="${ITERM_SESSION_ID#*:}"
[ -n "$UUID" ] || { echo "not running inside iTerm2"; exit 1; }

echo "focusing this session ($UUID) ..."
"$HERE/fleet-focus" iterm2 "$UUID" && echo "  ok (exit 0)" || echo "  FAILED (exit $?)"

echo "focusing a bogus session ..."
if "$HERE/fleet-focus" iterm2 "00000000-0000-0000-0000-000000000000"; then
  echo "  FAILED — should have exited non-zero"
else
  echo "  ok (exit non-zero as expected)"
fi
```

```bash
chmod +x tools/focus-smoke.sh
```

- [ ] **Step 3: Run the smoke test by hand**

Run: `./tools/focus-smoke.sh`
Expected: both lines report `ok`.

**If macOS shows an automation permission dialog, approve it.** If it fails silently with no dialog, open System Settings → Privacy & Security → Automation and enable Terminal/iTerm control of iTerm. This is the failure mode `fleet-doctor` exists to catch.

Then verify cross-window focus: open a second iTerm window, note its UUID via
`osascript -e 'tell application "iTerm2" to get id of current session of current tab of current window'`,
switch back to the first window, and run `./bin/fleet-focus iterm2 <that-uuid>`. The other window must come forward.

- [ ] **Step 4: Commit**

```bash
git add bin/fleet-focus tools/focus-smoke.sh
git commit -m "feat: iTerm2 and pinned-app focus adapters"
```

---

### Task 7: `fleet-press` — dispatch and the arm/confirm machine

**Files:**
- Create: `bin/fleet-press`
- Create: `tests/press.bats`

**Interfaces:**
- Consumes: `slots.json` (Task 4), `bin/fleet-focus` (Task 6), `bin/fleet-kill` (Task 8)
- Produces:
  - `bin/fleet-press <slotIndex> <short|long>`
  - **Arm marker** `$FLEET_HOME/armed.json`: `{"index": 3, "expires": 1755100003}`. Consumed by the plugin in Task 11 to paint `CONFIRM?`.
  - Env `FLEET_FOCUS_CMD` / `FLEET_KILL_CMD` override the adapter paths so tests can stub them.
  - Env `FLEET_NOW` overrides the clock in tests.

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

  # Stub adapters record their arguments instead of acting.
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
  [ "$(jq -r .index "$BATS_TEST_TMPDIR/armed.json")"   = "0" ]
  [ "$(jq -r .expires "$BATS_TEST_TMPDIR/armed.json")" = "1003" ]
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

The final test is deliberate: the slot index arrives from a plugin and must never reach a shell in a way that could be interpreted. The numeric guard in `fleet-press` is what makes it inert.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./tests/run.sh`
Expected: FAIL — `bin/fleet-press` does not exist.

- [ ] **Step 3: Write `bin/fleet-press`**

```bash
#!/usr/bin/env bash
# Press dispatcher. Short press focuses; long press arms teardown; a second press confirms.
set -u

FLEET_HOME="${FLEET_HOME:-$HOME/.fleet}"
SLOTS="$FLEET_HOME/slots.json"
ARMED="$FLEET_HOME/armed.json"
LOG="$FLEET_HOME/fleet.log"
HERE="$(cd "$(dirname "$0")" && pwd)"

FOCUS="${FLEET_FOCUS_CMD:-$HERE/fleet-focus}"
KILL="${FLEET_KILL_CMD:-$HERE/fleet-kill}"
NOW="${FLEET_NOW:-$(date +%s)}"

IDX="${1:-}"; VERB="${2:-short}"
case "$IDX" in ''|*[!0-9]*) exit 0 ;; esac
[ -f "$SLOTS" ] || exit 0

SLOT="$(jq -c --argjson i "$IDX" '.slots[]? | select(.index==$i)' "$SLOTS" 2>/dev/null)"
[ -n "$SLOT" ] || exit 0

STATE="$(printf '%s' "$SLOT" | jq -r '.state')"
HOST="$(printf '%s' "$SLOT" | jq -r '.host')"
SID="$(printf '%s' "$SLOT" | jq -r '.session_id')"
IUUID="$(printf '%s' "$SLOT" | jq -r '.iterm_session')"
APP="$(printf '%s' "$SLOT" | jq -r '.app')"

[ "$STATE" = "empty" ] && exit 0

# Is there a live arm marker, and is it for this slot?
ARM_IDX=""; ARM_EXP=0
if [ -f "$ARMED" ]; then
  ARM_IDX="$(jq -r '.index // empty' "$ARMED" 2>/dev/null)"
  ARM_EXP="$(jq -r '.expires // 0' "$ARMED" 2>/dev/null)"
  case "$ARM_EXP" in ''|*[!0-9]*) ARM_EXP=0 ;; esac
fi
ARM_LIVE=0
[ -n "$ARM_IDX" ] && [ "$NOW" -lt "$ARM_EXP" ] && ARM_LIVE=1

# Any press clears the marker; whether it fires is decided below.
rm -f "$ARMED" 2>/dev/null

if [ "$ARM_LIVE" = "1" ] && [ "$ARM_IDX" = "$IDX" ]; then
  # Confirmed teardown.
  printf '%s press: confirmed teardown of slot %s (%s)\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$IDX" "$SID" >>"$LOG" 2>/dev/null
  "$KILL" "$SID"
  exit 0
fi

if [ "$VERB" = "long" ]; then
  # Only real agent sessions can be torn down.
  if [ -z "$SID" ] || [ "$HOST" = "pinned-app" ]; then exit 0; fi
  CFG="$("$HERE/fleet-config" 2>/dev/null)"; [ -n "$CFG" ] || CFG='{}'
  ARM_MS="$(printf '%s' "$CFG" | jq -r '.timings.armMs // 3000')"
  ARM_S=$(( ARM_MS / 1000 )); [ "$ARM_S" -gt 0 ] || ARM_S=3
  TMP="$FLEET_HOME/.armed.json.tmp.$$"
  jq -nc --argjson i "$IDX" --argjson e "$(( NOW + ARM_S ))" '{index:$i, expires:$e}' \
    >"$TMP" 2>/dev/null && mv -f "$TMP" "$ARMED" 2>/dev/null
  exit 0
fi

# Default: focus.
case "$HOST" in
  iterm2)     [ -n "$IUUID" ] && "$FOCUS" iterm2 "$IUUID" ;;
  pinned-app) [ -n "$APP" ]   && "$FOCUS" pinned-app "$APP" ;;
esac
exit 0
```

```bash
chmod +x bin/fleet-press
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run.sh`
Expected: shellcheck clean, `40 tests, 0 failures`. Watch "long press ARMS and must not kill anything on the hold" — that assertion is the guard between your thumb and a destroyed worktree.

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-press tests/press.bats
git commit -m "feat: press dispatch with arm/confirm guard on destructive teardown"
```

---

### Task 8: `fleet-kill` — guarded teardown

**The highest-stakes component in the project.** A bug here destroys real work rather than painting a wrong colour. Test it hardest.

**Files:**
- Create: `bin/fleet-kill`
- Create: `tests/kill.bats`

**Interfaces:**
- Consumes: session files (Task 3)
- Produces: `bin/fleet-kill <session_id>` — kills the agent process, then removes the worktree **only if it is provably safe**. Env `FLEET_DRY_RUN=1` prints intended actions instead of performing them (tests use it).

**Safety contract — a worktree is removed only if ALL hold:**
1. It is a linked worktree, not a repository's main working tree.
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

  # A real origin, so upstream tracking is genuine rather than simulated.
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

# Creates a linked worktree whose branch is pushed and tracking.
mkwt() {
  git -C "$MAIN" worktree add -q -b "$1" "$BATS_TEST_TMPDIR/repos/$1"
  git -C "$MAIN" push -q origin "$1:refs/heads/$1"
  git -C "$BATS_TEST_TMPDIR/repos/$1" branch --set-upstream-to="origin/$1" >/dev/null 2>&1
  git -C "$BATS_TEST_TMPDIR/repos/$1" config user.email t@t
  git -C "$BATS_TEST_TMPDIR/repos/$1" config user.name t
}

mksession() {
  jq -nc --arg id "$1" --arg c "$2" \
    '{session_id:$id, state:"idle", repo:"r", branch:"b", title:"",
      cwd:$c, host:"iterm2", iterm_session:"U", pid:0, ts:1}' \
    >"$FLEET_HOME/sessions/$1.json"
}

@test "a clean, pushed, linked worktree is eligible for removal" {
  mkwt clean
  mksession CLEAN "$BATS_TEST_TMPDIR/repos/clean"
  run "$BIN/fleet-kill" CLEAN
  [ "$status" -eq 0 ]
  [[ "$output" == *"WOULD REMOVE"* ]]
}

@test "REFUSES when tracked files are modified" {
  mkwt dirty
  echo change >>"$BATS_TEST_TMPDIR/repos/dirty/f.txt"
  mksession DIRTY "$BATS_TEST_TMPDIR/repos/dirty"
  run "$BIN/fleet-kill" DIRTY
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" == *"uncommitted"* ]]
  [[ "$output" != *"WOULD REMOVE"* ]]
}

@test "REFUSES when an untracked file is present" {
  mkwt untracked
  echo new >"$BATS_TEST_TMPDIR/repos/untracked/brand-new.txt"
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

@test "an unknown session id is harmless" {
  run "$BIN/fleet-kill" NOSUCHSESSION
  [ "$status" -eq 0 ]
}

@test "a refusal marks the session failed rather than silently doing nothing" {
  unset FLEET_DRY_RUN
  mkwt dirty2
  echo change >>"$BATS_TEST_TMPDIR/repos/dirty2/f.txt"
  mksession DIRTY2 "$BATS_TEST_TMPDIR/repos/dirty2"
  run "$BIN/fleet-kill" DIRTY2
  [ "$(jq -r .state "$FLEET_HOME/sessions/DIRTY2.json")" = "failed" ]
  [ -d "$BATS_TEST_TMPDIR/repos/dirty2" ]
}
```

Every refusal test also asserts the absence of `WOULD REMOVE`. Asserting only that the refusal message appears would still pass if the script printed the warning and then removed the worktree anyway.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./tests/run.sh`
Expected: FAIL — `bin/fleet-kill` does not exist.

- [ ] **Step 3: Write `bin/fleet-kill`**

```bash
#!/usr/bin/env bash
# Guarded teardown. Kills the agent; removes the worktree ONLY if provably safe.
set -u

FLEET_HOME="${FLEET_HOME:-$HOME/.fleet}"
SESSIONS="$FLEET_HOME/sessions"
LOG="$FLEET_HOME/fleet.log"
HERE="$(cd "$(dirname "$0")" && pwd)"
DRY="${FLEET_DRY_RUN:-0}"

SID="${1:-}"
[ -n "$SID" ] || exit 0
SFILE="$SESSIONS/$SID.json"
[ -f "$SFILE" ] || exit 0

log() { printf '%s kill[%s]: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SID" "$*" >>"$LOG" 2>/dev/null; }
say() { printf '%s\n' "$*"; log "$*"; }

CWD="$(jq -r '.cwd // empty' "$SFILE" 2>/dev/null)"
PID="$(jq -r '.pid // 0' "$SFILE" 2>/dev/null)"
case "$PID" in ''|*[!0-9]*) PID=0 ;; esac

refuse() {
  say "REFUSING to remove worktree: $1"
  say "  path: ${CWD:-<unknown>}"
  if [ "$DRY" != "1" ]; then
    TMP="$SESSIONS/.$SID.json.tmp.$$"
    jq -c '.state="failed"' "$SFILE" >"$TMP" 2>/dev/null && mv -f "$TMP" "$SFILE" 2>/dev/null
    [ "${FLEET_SKIP_RECONCILE:-0}" = "1" ] || "$HERE/fleet-reconcile" >/dev/null 2>&1
  fi
  exit 0
}

# 1. Stop the agent first, regardless of what happens to the worktree.
if [ "$PID" -gt 0 ] && kill -0 "$PID" 2>/dev/null; then
  if [ "$DRY" = "1" ]; then say "WOULD KILL pid $PID"; else kill "$PID" 2>/dev/null; log "killed pid $PID"; fi
fi

# 2. Decide whether the worktree may be removed.
[ -n "$CWD" ] && [ -d "$CWD" ] || refuse "session has no usable working directory"

TOP="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" || refuse "not a git repository"

# A linked worktree has .git as a FILE; a primary working tree has it as a directory.
[ -f "$TOP/.git" ] || refuse "this is a primary working tree, not a linked worktree"

[ -z "$(git -C "$CWD" status --porcelain 2>/dev/null)" ] \
  || refuse "uncommitted changes or untracked files present"

git -C "$CWD" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 \
  || refuse "no upstream branch configured, cannot prove work is pushed"

[ -z "$(git -C "$CWD" rev-list '@{u}..HEAD' 2>/dev/null)" ] \
  || refuse "unpushed commits present"

BRANCH="$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)"

# 3. Safe. Remove.
if [ "$DRY" = "1" ]; then
  say "WOULD REMOVE worktree $TOP (branch $BRANCH)"
else
  say "removing worktree $TOP (branch $BRANCH)"
  git -C "$TOP" worktree remove "$TOP" 2>>"$LOG" || {
    say "git worktree remove failed; leaving everything in place"; exit 0
  }
  rm -f "$SFILE" 2>/dev/null
  [ "${FLEET_SKIP_RECONCILE:-0}" = "1" ] || "$HERE/fleet-reconcile" >/dev/null 2>&1
fi
exit 0
```

```bash
chmod +x bin/fleet-kill
```

Note the branch is deliberately **not** deleted. Removing the worktree is reversible via `git worktree add`; deleting the branch reference is closer to permanent, and the spec's rule is that the key makes only the safe path fast.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run.sh`
Expected: shellcheck clean, `50 tests, 0 failures`.

**Do not proceed with any test in this file failing.** This is the one component whose bugs destroy work rather than pixels. If shellcheck flags an unquoted expansion here, treat it as a defect, not a style note — a repo path containing a space is exactly how a `git -C $CWD` becomes two arguments.

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-kill tests/kill.bats
git commit -m "feat: guarded worktree teardown that refuses to destroy unpushed work"
```

---

### Task 9: `fleet-fail` — manual failure marking

**Files:**
- Create: `bin/fleet-fail`
- Create: `tests/fail.bats`

**Interfaces:**
- Consumes: `slots.json` (Task 4), session files (Task 3)
- Produces: `bin/fleet-fail <slotIndex>` sets that slot's session to `failed`; `bin/fleet-fail --clear <slotIndex>` returns it to `idle`.

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

  jq -nc '{session_id:"S1",state:"working",repo:"r",branch:"b",title:"",
           cwd:"/tmp",host:"iterm2",iterm_session:"U",pid:0,ts:1}' \
    >"$BATS_TEST_TMPDIR/sessions/S1.json"
  cat >"$BATS_TEST_TMPDIR/slots.json" <<'EOF'
{"ts":1,"overflow":0,"slots":[{"index":0,"state":"working","label_top":"r","label_bottom":"b","session_id":"S1","host":"iterm2","iterm_session":"U","cwd":"/tmp","app":""}]}
EOF
}

state() { jq -r .state "$BATS_TEST_TMPDIR/sessions/S1.json"; }

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

```bash
#!/usr/bin/env bash
# Marks a slot's session failed (sticky red), or clears it back to idle.
set -u
FLEET_HOME="${FLEET_HOME:-$HOME/.fleet}"
SESSIONS="$FLEET_HOME/sessions"
SLOTS="$FLEET_HOME/slots.json"
HERE="$(cd "$(dirname "$0")" && pwd)"

NEW="failed"
if [ "${1:-}" = "--clear" ]; then NEW="idle"; shift; fi
IDX="${1:-}"
case "$IDX" in ''|*[!0-9]*) exit 0 ;; esac
[ -f "$SLOTS" ] || exit 0

SID="$(jq -r --argjson i "$IDX" '.slots[]? | select(.index==$i) | .session_id' "$SLOTS" 2>/dev/null)"
[ -n "$SID" ] && [ -f "$SESSIONS/$SID.json" ] || exit 0

TMP="$SESSIONS/.$SID.json.tmp.$$"
jq -c --arg s "$NEW" '.state=$s' "$SESSIONS/$SID.json" >"$TMP" 2>/dev/null \
  && mv -f "$TMP" "$SESSIONS/$SID.json" 2>/dev/null
rm -f "$TMP" 2>/dev/null

[ "${FLEET_SKIP_RECONCILE:-0}" = "1" ] || "$HERE/fleet-reconcile" >/dev/null 2>&1
exit 0
```

```bash
chmod +x bin/fleet-fail
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run.sh`
Expected: shellcheck clean, `54 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add bin/fleet-fail tests/fail.bats
git commit -m "feat: manual failure marking and clearing"
```

---

### Task 10: Stream Deck plugin — scaffold and rendering

**Files:**
- Create: `plugin/package.json`, `plugin/tsconfig.json`, `plugin/rollup.config.mjs`
- Create: `plugin/com.louisalexander.flightdeck.sdPlugin/manifest.json`
- Create: `plugin/src/render.ts`, `plugin/src/types.ts`
- Create: `plugin/src/render.test.mjs`

**Interfaces:**
- Consumes: `slots.json` schema (Task 4), `config/fleet.json` (Task 2)
- Produces:
  - `Slot`, `Config` TypeScript types mirroring the schemas.
  - `renderSvg(slot: Slot, cfg: Config, armed: boolean): string` — pure, returns SVG markup.
  - `toDataUri(svg: string): string` — returns `data:image/svg+xml;base64,…`.
  - Plugin action UUID `com.louisalexander.flightdeck.slot`, with per-key setting `{ slotIndex: number }`.

- [ ] **Step 1: Scaffold the plugin package**

```bash
mkdir -p plugin/src plugin/com.louisalexander.flightdeck.sdPlugin/imgs
cd plugin
npm init -y >/dev/null
npm i @elgato/streamdeck
npm i -D typescript rollup @rollup/plugin-typescript @rollup/plugin-node-resolve @rollup/plugin-commonjs tslib @types/node
cd ..
```

Set `plugin/package.json` `"type"` to `"module"` and add scripts:

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

Create `plugin/src/render.test.mjs`. It imports the compiled output, so it fails until Step 4 builds.

```javascript
import assert from "node:assert";
import { renderSvg, toDataUri } from "../com.louisalexander.flightdeck.sdPlugin/bin/render.js";

const cfg = {
  states: {
    working: { color: "#1F4FD8", glyph: "●" },
    empty:   { color: "#101010", glyph: "" },
    armed:   { color: "#C62828", glyph: "⚠" }
  }
};
const slot = {
  index: 0, state: "working", label_top: "flightdeck", label_bottom: "main",
  session_id: "S1", host: "iterm2", iterm_session: "U", cwd: "/tmp", app: ""
};

let svg = renderSvg(slot, cfg, false);
assert.ok(svg.includes("#1F4FD8"), "uses the state colour");
assert.ok(svg.includes("flightdeck"), "renders the top label");
assert.ok(svg.includes("main"), "renders the bottom label");
assert.ok(svg.includes("●"), "renders the glyph");

// Armed overrides colour and copy, regardless of underlying state.
svg = renderSvg(slot, cfg, true);
assert.ok(svg.includes("#C62828"), "armed uses the armed colour");
assert.ok(svg.includes("CONFIRM"), "armed shows CONFIRM");

// XML injection through a branch name must not break the document.
const nasty = { ...slot, label_bottom: 'a<b>&"c' };
svg = renderSvg(nasty, cfg, false);
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

- [ ] **Step 4: Write the types and renderer**

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

export type StateStyle = { color: string; glyph: string };
export type Config = { states: Record<string, StateStyle> };
```

Create `plugin/src/render.ts`:

```typescript
import type { Slot, Config, StateStyle } from "./types.js";

const FALLBACK: StateStyle = { color: "#101010", glyph: "" };

function esc(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Renders one key at @2x (144px) for a 96px Stream Deck XL key. Pure. */
export function renderSvg(slot: Slot, cfg: Config, armed: boolean): string {
  const style: StateStyle = armed
    ? cfg.states["armed"] ?? { color: "#C62828", glyph: "⚠" }
    : cfg.states[slot.state] ?? FALLBACK;

  const top = armed ? "" : esc(slot.label_top);
  const bottom = armed ? "CONFIRM?" : esc(slot.label_bottom);

  return [
    '<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144">',
    `<rect width="144" height="144" fill="${style.color}"/>`,
    `<text x="10" y="30" font-family="Helvetica,Arial" font-size="22" fill="#ffffffcc">${esc(style.glyph)}</text>`,
    `<text x="72" y="74" text-anchor="middle" font-family="Helvetica,Arial" font-size="19" fill="#ffffffaa">${top}</text>`,
    `<text x="72" y="104" text-anchor="middle" font-family="Helvetica,Arial" font-size="22" font-weight="bold" fill="#ffffff">${bottom}</text>`,
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

- [ ] **Step 5: Write the manifest**

Create `plugin/com.louisalexander.flightdeck.sdPlugin/manifest.json`:

```json
{
  "Name": "Flightdeck",
  "Version": "1.0.0.0",
  "Author": "louisalexander",
  "Description": "Live view of every running Claude Code agent.",
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

Create the three required PNGs (Stream Deck refuses to load a plugin with missing icons):

```bash
cd plugin/com.louisalexander.flightdeck.sdPlugin/imgs
for n in plugin action key; do
  printf '<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144"><rect width="144" height="144" fill="#1F4FD8"/><text x="72" y="92" text-anchor="middle" font-family="Helvetica" font-size="64" fill="#fff">F</text></svg>' > "$n.svg"
  sips -s format png "$n.svg" --out "$n.png" >/dev/null 2>&1 || \
    qlmanage -t -s 144 -o . "$n.svg" >/dev/null 2>&1
  rm -f "$n.svg"
done
cd -
```

If neither converter produces a PNG, create solid 144×144 placeholders any way available; the images only need to exist and be valid PNGs.

- [ ] **Step 6: Build and run the tests**

Because `src/plugin.ts` does not exist yet, temporarily build only the renderer:

```bash
cd plugin && npx tsc && npm test
```

Expected: PASS — `render tests passed`.

- [ ] **Step 7: Commit**

```bash
git add plugin
git commit -m "feat: Stream Deck plugin scaffold with pure SVG key renderer"
```

---

### Task 11: Plugin — watch, paint, and dispatch presses

**Files:**
- Create: `plugin/src/plugin.ts`
- Create: `plugin/com.louisalexander.flightdeck.sdPlugin/ui/slot.html`
- Modify: `plugin/package.json` (build script)

**Interfaces:**
- Consumes: `renderSvg`/`toDataUri` (Task 10), `slots.json` and `armed.json` (Tasks 4 and 7), `bin/fleet-press` (Task 7)
- Produces: a running plugin. Repo root is resolved from the `FLIGHTDECK_REPO` environment variable, falling back to `~/code/flightdeck`.

**Critical implementation detail:** `fleet-reconcile` replaces `slots.json` via `mv`. `fs.watch` on a *file* stops firing once the inode is swapped. **Watch the directory `~/.fleet` and filter events by filename.**

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

The `sdpi-components` script is fetched by the Stream Deck app's own webview, which has network access. If the property inspector renders blank, replace the select with a plain `<input type="number">` wired via the standard `sendToPlugin` handshake.

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
    return null;               // mid-write or corrupt: skip this tick
  }
}

function loadConfig(): Config {
  const base = readJson<Config>(join(REPO, "config", "fleet.json"));
  const local = readJson<Partial<Config>>(join(REPO, "config", "fleet.local.json"));
  const states = { ...(base?.states ?? {}), ...(local?.states ?? {}) };
  return { states };
}

const EMPTY = (index: number): Slot => ({
  index, state: "empty", label_top: "", label_bottom: "",
  session_id: "", host: "", iterm_session: "", cwd: "", app: ""
});

@action({ UUID: "com.louisalexander.flightdeck.slot" })
export class FleetSlot extends SingletonAction<Settings> {
  /** Every visible key, so a file change can repaint all of them. */
  private visible = new Map<string, { ev: WillAppearEvent<Settings>; index: number }>();
  private downAt = new Map<string, number>();
  private config: Config = loadConfig();
  private armTimer: NodeJS.Timeout | null = null;

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
    // Safety net for missed events and for arm expiry.
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
    const verb = Date.now() - down >= 800 ? "long" : "short";
    const index = this.visible.get(ev.action.id)?.index ?? 0;

    execFile(join(REPO, "bin", "fleet-press"), [String(index), verb], (err) => {
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

    ev.action.setTitle("");                                  // the SVG carries all text
    ev.action.setImage(toDataUri(renderSvg(slot, this.config, armed)));
  }
}

streamDeck.actions.registerAction(new FleetSlot());
streamDeck.connect();
```

- [ ] **Step 3: Build**

Restore the full build now that `src/plugin.ts` exists:

```bash
cd plugin && npm run build && ls -la com.louisalexander.flightdeck.sdPlugin/bin/
```

Expected: both `plugin.js` and `render.js` present.

- [ ] **Step 4: Verify the renderer tests still pass**

Run: `cd plugin && npm test`
Expected: PASS.

- [ ] **Step 5: Install the plugin and verify end to end**

```bash
DEST=~/Library/Application\ Support/com.elgato.StreamDeck/Plugins
ln -sfn "$PWD/plugin/com.louisalexander.flightdeck.sdPlugin" "$DEST/com.louisalexander.flightdeck.sdPlugin"
osascript -e 'quit app "Elgato Stream Deck"' 2>/dev/null
sleep 2 && open -a "Elgato Stream Deck"
```

Then, by hand:
1. Drag **Fleet Slot** onto key 1 of Row 1; set Slot to `0`. Repeat for keys 2–8 with slots 1–7.
2. Seed fake state and confirm the keys paint:
   ```bash
   FLEET_SKIP_RECONCILE=1 printf '{"session_id":"DEMO","cwd":"'"$PWD"'"}' | ./bin/fleet-emit UserPromptSubmit
   ./bin/fleet-reconcile && jq . ~/.fleet/slots.json
   ```
   Key 1 must turn blue and read `flightdeck` over the branch name.
3. `printf '{"session_id":"DEMO","cwd":"'"$PWD"'"}' | ./bin/fleet-emit Notification` → key 1 turns amber.
4. Press key 1 → the iTerm session focuses.
5. Hold key 1 for a second → it turns red and reads `CONFIRM?`; wait four seconds → it reverts without killing anything.
6. Clean up: `printf '{"session_id":"DEMO","cwd":"'"$PWD"'"}' | ./bin/fleet-emit SessionEnd && ./bin/fleet-reconcile`

If keys stay blank, check `streamDeck.logger` output under
`~/Library/Logs/ElgatoStreamDeck/` for the plugin's messages.

- [ ] **Step 6: Commit**

```bash
git add plugin
git commit -m "feat: plugin watches slot state, paints keys, and dispatches presses"
```

---

### Task 12: `install.sh`, `fleet-doctor`, and README

**Files:**
- Create: `bin/fleet-doctor`, `install.sh`, `README.md`
- Create: `hooks/settings.snippet.json`

**Interfaces:**
- Consumes: everything above
- Produces: `./install.sh` performs a full machine setup; `bin/fleet-doctor` exits 0 if every check passes, 1 otherwise.

- [ ] **Step 1: Write the hooks snippet**

Create `hooks/settings.snippet.json`. `__REPO__` is substituted by `install.sh`.

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "__REPO__/bin/fleet-emit SessionStart" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "__REPO__/bin/fleet-emit UserPromptSubmit" }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "__REPO__/bin/fleet-emit Notification" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "__REPO__/bin/fleet-emit Stop" }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "__REPO__/bin/fleet-emit SessionEnd" }] }]
  }
}
```

- [ ] **Step 2: Write `bin/fleet-doctor`**

```bash
#!/usr/bin/env bash
# Verifies every moving part. Exits 0 only if all checks pass.
set -u
FLEET_HOME="${FLEET_HOME:-$HOME/.fleet}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; FAILED=1; }

printf 'flightdeck doctor\n\n'

for t in jq git osascript node; do
  command -v "$t" >/dev/null 2>&1 && ok "$t present" || bad "$t missing"
done

mkdir -p "$FLEET_HOME/sessions" 2>/dev/null
if touch "$FLEET_HOME/.probe" 2>/dev/null; then rm -f "$FLEET_HOME/.probe"; ok "$FLEET_HOME writable"
else bad "$FLEET_HOME not writable"; fi

S="$HOME/.claude/settings.json"
if [ -f "$S" ]; then
  n="$(jq '[.hooks // {} | to_entries[] | select(.value | tostring | contains("fleet-emit"))] | length' "$S" 2>/dev/null)"
  [ "${n:-0}" -eq 5 ] && ok "all 5 hooks registered" \
    || bad "expected 5 fleet-emit hooks, found ${n:-0}" "re-run ./install.sh"
else
  bad "$S not found" "run claude once, then ./install.sh"
fi

launchctl list 2>/dev/null | grep -q flightdeck.reaper \
  && ok "launchd reaper loaded" \
  || bad "launchd reaper not loaded" "launchctl load ~/Library/LaunchAgents/com.louisalexander.flightdeck.reaper.plist"

P="$HOME/Library/Application Support/com.elgato.StreamDeck/Plugins/com.louisalexander.flightdeck.sdPlugin"
[ -e "$P" ] && ok "plugin installed" || bad "plugin not installed" "re-run ./install.sh"
[ -f "$P/bin/plugin.js" ] && ok "plugin is built" || bad "plugin not built" "cd plugin && npm run build"

pgrep -f "Elgato Stream Deck" >/dev/null 2>&1 \
  && ok "Stream Deck app running" || bad "Stream Deck app not running"

# The classic silent killer: automation permission denied with no dialog.
if osascript -e 'tell application "iTerm2" to count of windows' >/dev/null 2>&1; then
  ok "iTerm2 automation permitted"
else
  bad "iTerm2 automation DENIED or iTerm2 not running" \
      "System Settings > Privacy & Security > Automation, then re-run"
fi

printf '\n'
[ "$FAILED" -eq 0 ] && printf 'all checks passed\n' || printf 'some checks failed\n'
exit "$FAILED"
```

```bash
chmod +x bin/fleet-doctor
```

- [ ] **Step 3: Write `install.sh`**

```bash
#!/usr/bin/env bash
# Sets up flightdeck on this machine. Safe to re-run.
set -eu
REPO="$(cd "$(dirname "$0")" && pwd)"
FLEET_HOME="${FLEET_HOME:-$HOME/.fleet}"

printf 'installing flightdeck from %s\n' "$REPO"
mkdir -p "$FLEET_HOME/sessions"

# 1. Local config from the example, if absent.
if [ ! -f "$REPO/config/fleet.local.json" ]; then
  cp "$REPO/config/fleet.local.example.json" "$REPO/config/fleet.local.json"
  printf '  created config/fleet.local.json — edit pins and vault path\n'
fi

# 2. Merge hooks into ~/.claude/settings.json, preserving everything else.
S="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -f "$S" ] || printf '{}' >"$S"
cp "$S" "$S.flightdeck-backup.$(date +%s)"
SNIP="$(sed "s|__REPO__|$REPO|g" "$REPO/hooks/settings.snippet.json")"
printf '%s' "$SNIP" | jq -s '.[0] * .[1]' "$S" - >"$S.tmp" && mv "$S.tmp" "$S"
printf '  hooks merged into %s (backup written)\n' "$S"

# 3. launchd reaper.
LA="$HOME/Library/LaunchAgents"
mkdir -p "$LA"
PLIST="$LA/com.louisalexander.flightdeck.reaper.plist"
sed -e "s|__REPO__|$REPO|g" -e "s|__HOME__|$HOME|g" \
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

# 5. Restart Stream Deck so it picks the plugin up.
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

Expected: a Row 1 key claims a slot and reads `homeassistan` over its branch. Submit a prompt → blue. Ask for something needing approval → **amber**. Approve → blue → green when it stops. Press the key from another window → that session focuses. `/exit` → the key goes dark.

Confirm nothing was disturbed: `tail -5 ~/.fleet/fleet.log` should show no errors, and the agent must behave exactly as before.

- [ ] **Step 6: Write the README**

Create `README.md` covering: what it is, the one-paragraph architecture, `./install.sh`, `./tests/run.sh`, `./bin/fleet-doctor`, the state table, and the two-machine config split.

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

Expected: shellcheck clean over all of `bin/`, `install.sh` and `tools/`, then `54 tests, 0 failures`, then `render tests passed`.

```bash
git add bin/fleet-doctor install.sh hooks README.md
git commit -m "feat: installer, doctor, and documentation"
git push origin main
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: architecture and data flow → 3, 4, 11; state model and colours → 2 (config), 3 (transitions), 10 (render); five-hook rule → 3, 12; `failed` semantics → 9; labels with title-beats-branch → 4; sticky slots, pins, overflow → 4; press semantics and host dispatch → 6, 7; arm/confirm → 7, 10, 11; teardown safety → 8; repo layout and layered config → 2; atomic writes and exit-0 → 3, and asserted in tests; `fleet-doctor` → 12; testing strategy → the harness in 2 plus per-task suites; deep links → 12's README; memory substrate reservation → `events.jsonl` in Task 3 and `journal.vault` in Task 2's example config.

**Deliberately deferred, consistent with the spec:** Rows 2 and 4, the focused-slot border, title-glyph polling as a live state source (Task 1 records whether it is needed), and journal export.

**Type consistency.** The `Slot` shape produced by `fleet-reconcile` in Task 4 is consumed verbatim by `fleet-press` (Task 7), `render.ts` (Task 10) and `plugin.ts` (Task 11) — nine fields, same names throughout. The session-file shape from Task 3 is read by Tasks 4, 5, 8, 9. `armed.json` is written in Task 7 and read in Task 11 with matching `index`/`expires` keys. `FLEET_HOME`, `FLEET_CONFIG_DIR`, `FLEET_SKIP_RECONCILE` and `FLEET_DRY_RUN` are honoured uniformly.

**Cumulative test counts** (each task's Step 4 asserts the running total, so a silently skipped file is caught):

| After task | File added | New | Total |
|---|---|---|---|
| 2 | `config.bats` | 4 | 4 |
| 3 | `emit.bats` | 11 | 15 |
| 4 | `reconcile.bats` | 9 | 24 |
| 5 | `reap.bats` | 5 | 29 |
| 7 | `press.bats` | 11 | 40 |
| 8 | `kill.bats` | 10 | 50 |
| 9 | `fail.bats` | 4 | 54 |

Task 6 (`fleet-focus`) adds no bats tests by design — it needs live iTerm2 and is verified by `tools/focus-smoke.sh`. It is still linted, because `tests/run.sh` globs `bin/*`.

**Known ordering dependency.** Task 7's tests stub `fleet-kill` and Task 8 builds it, so 7 passes before 8 exists. That is intentional — it keeps the arm/confirm machine testable in isolation.

**Shellcheck policy.** `-S warning` is the gate. The only acceptable suppression is an inline `# shellcheck disable=SCxxxx` carrying a comment that says why; `SC2086` on the `$targets` word list in `tests/run.sh` is the one known case. In `bin/fleet-kill` an unquoted expansion is a defect, not a style note — a repo path with a space turns `git -C $CWD` into two arguments inside a teardown script.
