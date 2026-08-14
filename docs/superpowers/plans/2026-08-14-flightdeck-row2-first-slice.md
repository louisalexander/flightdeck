# Flightdeck Row 2 — First Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Press a Row 2 key and have the focused agent carry out a verb, with the verb staged to a queue and delivered either by blocking the `Stop` hook (working session) or by waking an idle one.

**Architecture:** A press stages a verb in `~/.fleet/queue/<session_id>.json`. Delivery splits on the session state flightdeck already tracks: a working session is served by the `Stop` hook returning `{"decision":"block","reason":<prompt>}` so the agent continues into the verb; an idle session is woken by AppleScript typing one short line pointing at the verb file. Both paths take the queue entry through the same atomic claim, so exactly one delivers.

**Tech Stack:** Python 3 (stdlib only) for `bin/`, TypeScript + rollup for the Stream Deck plugin, bats for shell/integration tests, `python3 -m unittest` for pure Python, `node:assert` for plugin units.

**Spec:** `docs/superpowers/specs/2026-08-14-flightdeck-row2-commands-design.md`

## Global Constraints

- **Python 3 stdlib only.** No third-party imports anywhere in `bin/`.
- **Hook scripts MUST ALWAYS EXIT 0.** `bin/fleet-emit` carries this contract in its module docstring. Blocking a `Stop` is expressed as JSON on stdout with exit 0, never as a non-zero exit.
- **A hook must print nothing on its ordinary path.** `fleet-emit` runs for every turn of every session; stray stdout is a much better way to break Claude Code than slow code.
- **`bin/fleet-send` is exempt from exit-0** — a press that could not be staged must report failure.
- **All state writes are atomic** via `fleetlib.write_json_atomic`, which writes a temp file and `os.replace`s it.
- **`FLEET_HOME` overrides `~/.fleet`** everywhere; tests rely on this.
- **`FLEET_SKIP_RECONCILE=1`** suppresses the reconcile subprocess in tests.
- **Amber (`#F5A623`) means operator attention.** Never use it decoratively; Row 2 is monochrome.
- **Key images are 144×144** (@2x for the XL's 96px keys).
- **No new plugin runtime dependencies.** The bundle is rollup-built from `plugin/src/`.

---

### Task 1: Selection state in `fleetlib`, written by a Row 1 press

**Files:**
- Modify: `bin/fleetlib.py` (add after `armed_path`, around line 28)
- Modify: `bin/fleet-press:92-140` (in `main`, after slot resolution)
- Test: `tests/selection.bats` (create)

**Interfaces:**
- Consumes: `fleetlib.fleet_home()`, `fleetlib.read_json()`, `fleetlib.write_json_atomic()`
- Produces: `fleetlib.focus_path() -> Path`, `fleetlib.read_focus() -> str` (session id or `""`), `fleetlib.write_focus(session_id: str) -> None`, `fleetlib.clear_focus() -> None`

- [ ] **Step 1: Write the failing test**

Create `tests/selection.bats`:

```bash
#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  export FLEET_SKIP_RECONCILE=1
  mkdir -p "$FLEET_HOME/sessions"
  # A press resolves the slot out of slots.json, so one must exist.
  cat > "$FLEET_HOME/slots.json" <<'JSON'
{"ts":1,"overflow":0,"slots":[
 {"index":0,"state":"working","label_top":"repo","label_bottom":"main",
  "session_id":"S1","host":"iterm2","iterm_session":"U1","cwd":"/tmp","app":""},
 {"index":1,"state":"empty","label_top":"","label_bottom":"",
  "session_id":"","host":"","iterm_session":"","cwd":"","app":""}]}
JSON
  # Never let a test invoke the real focus/kill helpers.
  export FLEET_FOCUS_CMD=/usr/bin/true
  export FLEET_KILL_CMD=/usr/bin/true
}

focus() { printf '%s' "$FLEET_HOME/focus.json"; }

@test "a short press on a live slot records it as the selection" {
  "$BIN/fleet-press" 0 short
  [ -e "$(focus)" ]
  run python3 -c "import json;print(json.load(open('$FLEET_HOME/focus.json'))['session_id'])"
  [ "$output" = "S1" ]
}

@test "a press on an empty slot records no selection" {
  "$BIN/fleet-press" 1 short
  [ ! -e "$(focus)" ]
}

@test "a press on an unknown index records no selection" {
  "$BIN/fleet-press" 7 short
  [ ! -e "$(focus)" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/selection.bats`
Expected: FAIL — the first test fails at `[ -e "$(focus)" ]` because nothing writes `focus.json`.

- [ ] **Step 3: Add the fleetlib helpers**

In `bin/fleetlib.py`, immediately after `def armed_path():`:

```python
def focus_path():
    return fleet_home() / "focus.json"


def read_focus():
    """The session id the operator last selected, or "" if none."""
    data = read_json(focus_path())
    if isinstance(data, dict) and isinstance(data.get("session_id"), str):
        return data["session_id"]
    return ""


def write_focus(session_id):
    write_json_atomic(focus_path(), {"session_id": session_id})


def clear_focus():
    try:
        focus_path().unlink()
    except Exception:
        pass
```

- [ ] **Step 4: Record the selection on a short press**

In `bin/fleet-press`, in `main`, immediately before `if verb == "long":`:

```python
    # A short press both raises the terminal and declares the Row 2 target.
    # Recorded before focusing, so a focus failure cannot leave the deck
    # showing a selection that was never actually made.
    if verb == "short" and slot.get("session_id"):
        fleetlib.write_focus(slot["session_id"])
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/selection.bats`
Expected: 3 tests, all PASS.

- [ ] **Step 6: Run the whole suite for regressions**

Run: `bats tests/ && python3 -m unittest discover -s tests -p 'test_*.py'`
Expected: all PASS. `tests/press.bats` in particular must be unaffected.

- [ ] **Step 7: Commit**

```bash
git add bin/fleetlib.py bin/fleet-press tests/selection.bats
git commit -m "feat: record the Row 2 target on a Row 1 short press"
```

---

### Task 2: `fleet-reconcile` publishes the selection to the deck

**Files:**
- Modify: `bin/fleet-reconcile:46-72` (the three slot constructors)
- Test: `tests/selection.bats` (append)

**Interfaces:**
- Consumes: `fleetlib.read_focus()`, `fleetlib.clear_focus()` from Task 1
- Produces: every slot dict in `slots.json` carries `focused: bool`

- [ ] **Step 1: Write the failing test**

Append to `tests/selection.bats`:

```bash
@test "reconcile marks the selected session's slot as focused" {
  cat > "$FLEET_HOME/sessions/S1.json" <<'JSON'
{"session_id":"S1","state":"working","repo":"repo","branch":"main","title":"",
 "cwd":"/tmp","host":"iterm2","iterm_session":"U1","pid":0,"ts":1}
JSON
  printf '{"session_id":"S1"}' > "$FLEET_HOME/focus.json"
  "$BIN/fleet-reconcile"
  run python3 -c "
import json
s=json.load(open('$FLEET_HOME/slots.json'))['slots']
print([x['focused'] for x in s if x['session_id']=='S1'][0])"
  [ "$output" = "True" ]
}

@test "every slot carries a focused field, so the plugin never sees undefined" {
  "$BIN/fleet-reconcile"
  run python3 -c "
import json
s=json.load(open('$FLEET_HOME/slots.json'))['slots']
print(all('focused' in x for x in s), len(s))"
  [ "$output" = "True 8" ]
}

@test "a selection naming a dead session is cleared, not left stale" {
  printf '{"session_id":"GONE"}' > "$FLEET_HOME/focus.json"
  "$BIN/fleet-reconcile"
  [ ! -e "$FLEET_HOME/focus.json" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/selection.bats -f focused`
Expected: FAIL with `KeyError: 'focused'`.

- [ ] **Step 3: Stamp the field in the slot constructors**

In `bin/fleet-reconcile`, add `"focused": False` to the dict returned by `empty_slot` and by `pinned_slot`. In `session_slot`, add a `focused` parameter and field:

```python
def empty_slot(index):
    return {"index": index, "state": "empty", "label_top": "", "label_bottom": "",
            "session_id": "", "host": "", "iterm_session": "", "cwd": "", "app": "",
            "focused": False}
```

```python
def session_slot(index, session, max_chars, prefixes, focus_id=""):
    ...
    return {"index": index,
            ...
            "focused": bool(focus_id) and session.get("session_id") == focus_id,
            ...}
```

Add `"focused": False` to `pinned_slot`'s returned dict as well.

- [ ] **Step 4: Read and prune the selection in `main`**

In `bin/fleet-reconcile`'s `main`, after the live sessions are loaded and before the slot passes:

```python
    # A selection outliving its session would leave a border on a key that
    # has been reassigned to someone else -- worse than no border at all.
    focus_id = fleetlib.read_focus()
    if focus_id and focus_id not in live:
        fleetlib.clear_focus()
        focus_id = ""
```

Then pass `focus_id` into each `session_slot(...)` call site.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/selection.bats`
Expected: 6 tests, all PASS.

- [ ] **Step 6: Run the whole suite**

Run: `bats tests/ && python3 -m unittest discover -s tests -p 'test_*.py'`
Expected: all PASS. `tests/reconcile.bats` asserts slot shape — if it compares whole dicts it needs the new key added.

- [ ] **Step 7: Commit**

```bash
git add bin/fleet-reconcile tests/selection.bats
git commit -m "feat: publish the selected slot to the deck as focused"
```

---

### Task 3: The focus border

**Files:**
- Modify: `plugin/src/types.ts:1-11` (the `Slot` type)
- Modify: `plugin/src/render.ts:22-56` (`renderSvg`)
- Test: `plugin/src/render.test.mjs` (append)

**Interfaces:**
- Consumes: `focused: boolean` on each slot, from Task 2
- Produces: `renderSvg` draws an inset white border when `slot.focused` is true

- [ ] **Step 1: Write the failing test**

Append to `plugin/src/render.test.mjs`:

```javascript
// --- focus border -------------------------------------------------------
const focusedSlot = {
  index: 0, state: "working", label_top: "REPO", label_bottom: "main",
  session_id: "S1", host: "iterm2", iterm_session: "U1", cwd: "/tmp", app: "",
  focused: true
};
const unfocusedSlot = { ...focusedSlot, focused: false };

assert.ok(
  renderSvg(focusedSlot, cfg, false).includes('stroke="#FFFFFF"'),
  "a focused slot draws a white border"
);
assert.ok(
  !renderSvg(unfocusedSlot, cfg, false).includes('stroke="#FFFFFF"'),
  "an unfocused slot draws no border"
);
// The lifecycle fill must still dominate: a thin stroke, not a thick frame.
{
  const m = renderSvg(focusedSlot, cfg, false).match(/stroke-width="(\d+)"/);
  assert.ok(m && Number(m[1]) <= 6, "focus border stays thin (<=6 at 144px)");
}
// Selection is not a state. The background must be the lifecycle colour.
assert.ok(
  renderSvg(focusedSlot, cfg, false).includes('fill="#1256A3"'),
  "focus does not replace the lifecycle background"
);
// Arming owns the whole key; a stale selection must not draw over it.
assert.ok(
  !renderSvg(focusedSlot, cfg, true).includes('stroke="#FFFFFF"'),
  "an armed key shows no focus border"
);
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugin && npm run build && node src/render.test.mjs`
Expected: FAIL on "a focused slot draws a white border".

- [ ] **Step 3: Add `focused` to the Slot type**

In `plugin/src/types.ts`, add to `Slot`:

```typescript
  focused: boolean;
```

- [ ] **Step 4: Draw the border**

In `plugin/src/render.ts`, after the `bottomText` const:

```typescript
  // Selection, not state. Inset and thin so the lifecycle fill still reads as
  // the key's colour -- a heavy frame would compete with the one channel that
  // carries the actual information. Suppressed while armed, which owns the
  // whole key.
  const focusBorder = slot.focused && !armed
    ? `<rect x="2" y="2" width="140" height="140" rx="3" fill="none" ` +
      `stroke="#FFFFFF" stroke-width="4" stroke-opacity="0.92"/>`
    : "";
```

Add `focusBorder` to the returned array, after `bottomText` so it draws over the text:

```typescript
    bottomText,
    focusBorder,
    "</svg>"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd plugin && npm run build && node src/render.test.mjs`
Expected: PASS, no assertion output.

- [ ] **Step 6: Commit**

```bash
git add plugin/src/types.ts plugin/src/render.ts plugin/src/render.test.mjs
git commit -m "feat: draw a thin inset border on the selected slot"
```

---

### Task 4: Verb files and resolution

**Files:**
- Create: `bin/fleet-verbs`
- Create: `config/verbs/test.md`
- Test: `tests/verbs.bats` (create)

**Interfaces:**
- Consumes: `fleetlib.repo_root()`, `fleetlib.fleet_home()`
- Produces: `bin/fleet-verbs show <id>` prints the resolved prompt to stdout, exit 0; exit 1 with a message on stderr for an unknown verb. `bin/fleet-verbs path <id>` prints the resolved file path. Importable as a module: `parse_verb(text) -> dict` with keys `id`, `label`, `interrupt`, `confirm`, `prompt`.

- [ ] **Step 1: Write the failing test**

Create `tests/verbs.bats`:

```bash
#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  mkdir -p "$FLEET_HOME/verbs"
}

@test "a shipped verb resolves to its prompt body" {
  run "$BIN/fleet-verbs" show test
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet-fail"* ]]
}

@test "an unknown verb fails loudly rather than printing nothing" {
  run "$BIN/fleet-verbs" show nosuchverb
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "a local override wins over the shipped verb" {
  cat > "$FLEET_HOME/verbs/test.md" <<'MD'
---
id: test
label: TEST
---
overridden body
MD
  run "$BIN/fleet-verbs" show test
  [ "$output" = "overridden body" ]
}

@test "path reports which file won" {
  cat > "$FLEET_HOME/verbs/test.md" <<'MD'
---
id: test
label: TEST
---
body
MD
  run "$BIN/fleet-verbs" path test
  [ "$output" = "$FLEET_HOME/verbs/test.md" ]
}

@test "frontmatter flags are parsed, defaulting to false" {
  cat > "$FLEET_HOME/verbs/stop.md" <<'MD'
---
id: stop
label: STOP
interrupt: true
---
irrelevant
MD
  run "$BIN/fleet-verbs" flags stop
  [ "$output" = "interrupt=true confirm=false" ]
}

@test "a verb file with no frontmatter is rejected, not half-read" {
  printf 'just a body\n' > "$FLEET_HOME/verbs/broken.md"
  run "$BIN/fleet-verbs" show broken
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/verbs.bats`
Expected: FAIL — `bin/fleet-verbs` does not exist.

- [ ] **Step 3: Write the shipped TEST verb**

Create `config/verbs/test.md`:

```markdown
---
id: test
label: TEST
interrupt: false
confirm: false
---
Run this project's test suite and report what fails.

Report the outcome so the deck can show it:

- If the suite fails, run `bin/fleet-fail` from the repository root.
- If you are unsure what that does or how flightdeck expects it to be
  called, run `bin/fleet-fail --explain` and follow what it tells you.

Do not fix anything yet. Report first; wait to be told to fix.
```

- [ ] **Step 4: Write the resolver**

Create `bin/fleet-verbs` (`chmod +x`):

```python
#!/usr/bin/env python3
"""Resolves a Row 2 verb id to its prompt.

A verb is a markdown file: frontmatter for the flags the dispatcher needs,
body for the prompt the agent receives. Local files in $FLEET_HOME/verbs
win over the shipped ones in config/verbs, per verb rather than wholesale,
so overriding one verb does not mean maintaining copies of the rest.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fleetlib  # noqa: E402

TRUE_WORDS = ("true", "yes", "1")


def verb_file(verb_id):
    """The file that wins for this id, or None. Local beats shipped."""
    for base in (fleetlib.fleet_home() / "verbs",
                 fleetlib.repo_root() / "config" / "verbs"):
        candidate = base / "{}.md".format(verb_id)
        if candidate.is_file():
            return candidate
    return None


def parse_verb(text):
    """Splits frontmatter from body. Returns None if the shape is wrong.

    Rejecting rather than guessing matters: a file without frontmatter is
    far more likely to be a half-written verb than a deliberate one, and
    sending a half-written prompt to an agent is worse than sending none.
    """
    if not text.startswith("---"):
        return None
    parts = text.split("---", 2)
    if len(parts) < 3:
        return None
    meta = {}
    for line in parts[1].strip().splitlines():
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        meta[key.strip()] = value.strip()
    return {
        "id": meta.get("id", ""),
        "label": meta.get("label", ""),
        "interrupt": meta.get("interrupt", "").lower() in TRUE_WORDS,
        "confirm": meta.get("confirm", "").lower() in TRUE_WORDS,
        "prompt": parts[2].strip(),
    }


def load_verb(verb_id):
    path = verb_file(verb_id)
    if path is None:
        return None, None
    try:
        parsed = parse_verb(path.read_text(encoding="utf-8"))
    except Exception:
        return None, None
    return parsed, path


def main(argv):
    if len(argv) < 3:
        return 1
    command, verb_id = argv[1], argv[2]
    parsed, path = load_verb(verb_id)
    if parsed is None:
        sys.stderr.write("fleet-verbs: no such verb: {}\n".format(verb_id))
        return 1
    if command == "show":
        sys.stdout.write(parsed["prompt"] + "\n")
    elif command == "path":
        sys.stdout.write(str(path) + "\n")
    elif command == "flags":
        sys.stdout.write("interrupt={} confirm={}\n".format(
            str(parsed["interrupt"]).lower(), str(parsed["confirm"]).lower()))
    else:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `chmod +x bin/fleet-verbs && bats tests/verbs.bats`
Expected: 6 tests, all PASS.

- [ ] **Step 6: Commit**

```bash
git add bin/fleet-verbs config/verbs/test.md tests/verbs.bats
git commit -m "feat: resolve Row 2 verbs from markdown files with local override"
```

---

### Task 5: Staging a verb, and the atomic claim

**Files:**
- Modify: `bin/fleetlib.py` (after the focus helpers from Task 1)
- Create: `bin/fleet-send`
- Test: `tests/send.bats` (create)

**Interfaces:**
- Consumes: `fleetlib.read_focus()` (Task 1), `bin/fleet-verbs` (Task 4)
- Produces: `fleetlib.queue_dir() -> Path`, `fleetlib.queue_path(session_id) -> Path`, `fleetlib.claim_queue(session_id) -> dict | None`. `bin/fleet-send <verb>` exits 0 on staged, 1 on refused.
- Queue entry shape: `{"verb": str, "prompt": str, "verb_path": str, "queued_at": int}`

- [ ] **Step 1: Write the failing test**

Create `tests/send.bats`:

```bash
#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  export FLEET_SKIP_RECONCILE=1
  mkdir -p "$FLEET_HOME/sessions"
  # Never let a test drive real AppleScript.
  export FLEET_OSASCRIPT=/usr/bin/true
  cat > "$FLEET_HOME/sessions/S1.json" <<'JSON'
{"session_id":"S1","state":"working","repo":"repo","branch":"main","title":"",
 "cwd":"/tmp","host":"iterm2","iterm_session":"11111111-2222-3333-4444-555555555555",
 "pid":0,"ts":1}
JSON
  printf '{"session_id":"S1"}' > "$FLEET_HOME/focus.json"
}

queued() { printf '%s' "$FLEET_HOME/queue/S1.json"; }

@test "sending a verb stages it for the selected session" {
  run "$BIN/fleet-send" test
  [ "$status" -eq 0 ]
  [ -e "$(queued)" ]
  run python3 -c "
import json;d=json.load(open('$FLEET_HOME/queue/S1.json'))
print(d['verb'], 'fleet-fail' in d['prompt'], isinstance(d['queued_at'], int))"
  [ "$output" = "test True True" ]
}

@test "sending with no selection refuses and stages nothing" {
  rm -f "$FLEET_HOME/focus.json"
  run "$BIN/fleet-send" test
  [ "$status" -eq 1 ]
  [ ! -e "$(queued)" ]
}

@test "sending an unknown verb refuses and stages nothing" {
  run "$BIN/fleet-send" nosuchverb
  [ "$status" -eq 1 ]
  [ ! -e "$(queued)" ]
}

@test "a selection naming a vanished session refuses" {
  rm -f "$FLEET_HOME/sessions/S1.json"
  run "$BIN/fleet-send" test
  [ "$status" -eq 1 ]
}

@test "CLAIM: exactly one claimant wins; the loser gets nothing" {
  "$BIN/fleet-send" test
  run python3 -c "
import sys; sys.path.insert(0,'$BIN')
import fleetlib
a = fleetlib.claim_queue('S1')
b = fleetlib.claim_queue('S1')
print(a is not None, b is None)"
  [ "$output" = "True True" ]
}

@test "CLAIM: claiming removes the entry from the queue" {
  "$BIN/fleet-send" test
  python3 -c "
import sys; sys.path.insert(0,'$BIN')
import fleetlib; fleetlib.claim_queue('S1')"
  [ ! -e "$(queued)" ]
}

@test "CLAIM: claiming an empty queue is not an error" {
  run python3 -c "
import sys; sys.path.insert(0,'$BIN')
import fleetlib; print(fleetlib.claim_queue('S1') is None)"
  [ "$output" = "True" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/send.bats`
Expected: FAIL — `bin/fleet-send` does not exist.

- [ ] **Step 3: Add the queue helpers to fleetlib**

In `bin/fleetlib.py`, after `clear_focus`:

```python
def queue_dir():
    return fleet_home() / "queue"


def queue_path(session_id):
    return queue_dir() / "{}.json".format(session_id)


def claim_queue(session_id):
    """Takes sole ownership of a queued verb, or returns None.

    Two deliverers can race for the same entry: the Stop drain when a turn
    ends, and fleet-send's wake path when it judged the session idle. A
    read-then-delete is racy -- both could read the same entry before
    either removed it, and the verb would run twice. Rename to a unique
    per-pid sibling with os.replace() instead, which is atomic: exactly one
    caller can win, and the loser's rename finds the source already gone.

    This is the same ownership trick fleet-press's claim_arm() uses for
    arming, for the same reason.
    """
    claim = queue_dir() / "{}.claim.{}.json".format(session_id, os.getpid())
    try:
        os.replace(str(queue_path(session_id)), str(claim))
    except OSError:
        return None
    try:
        return read_json(claim)
    finally:
        try:
            claim.unlink()
        except Exception:
            pass
```

- [ ] **Step 4: Write the sender**

Create `bin/fleet-send` (`chmod +x`):

```python
#!/usr/bin/env python3
"""Stages a Row 2 verb for the selected session.

A press never types a prompt. It writes the verb to
$FLEET_HOME/queue/<session_id>.json and lets delivery happen on whichever
path suits the session's state -- the Stop drain for a working session, a
wake for an idle one. Staging is the whole contract; delivery is separate
and can fail without losing the operator's intent.

Not a hook: unlike fleet-emit this may exit non-zero, because a press that
could not be staged must be visible rather than silently dropped.
"""

import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fleetlib  # noqa: E402

VERBS_TIMEOUT_SECS = 5


def resolve_verb(verb_id):
    """(prompt, verb_path) for a verb id, or (None, None)."""
    try:
        proc = subprocess.run(
            [sys.executable, str(HERE / "fleet-verbs"), "show", verb_id],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=VERBS_TIMEOUT_SECS)
        if proc.returncode != 0:
            return None, None
        prompt = proc.stdout.decode("utf-8", "replace").strip()
        path = subprocess.run(
            [sys.executable, str(HERE / "fleet-verbs"), "path", verb_id],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=VERBS_TIMEOUT_SECS).stdout.decode("utf-8", "replace").strip()
        return (prompt or None), (path or None)
    except Exception as err:
        fleetlib.log("send: could not resolve verb {}: {}".format(verb_id, err))
        return None, None


def main(argv):
    if len(argv) < 2:
        return 1
    verb_id = argv[1]

    session_id = fleetlib.read_focus()
    if not session_id:
        fleetlib.log("send: no selection; press a Row 1 key first")
        return 1

    session = fleetlib.read_json(fleetlib.sessions_dir() / "{}.json".format(session_id))
    if not isinstance(session, dict):
        fleetlib.log("send: selected session {} is gone".format(session_id))
        return 1

    prompt, verb_path = resolve_verb(verb_id)
    if not prompt:
        fleetlib.log("send: no such verb: {}".format(verb_id))
        return 1

    fleetlib.write_json_atomic(fleetlib.queue_path(session_id), {
        "verb": verb_id,
        "prompt": prompt,
        "verb_path": verb_path or "",
        "queued_at": int(time.time()),
    })
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as err:
        fleetlib.log("send: unhandled error: {}".format(err))
        sys.exit(1)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `chmod +x bin/fleet-send && bats tests/send.bats`
Expected: 7 tests, all PASS.

- [ ] **Step 6: Commit**

```bash
git add bin/fleetlib.py bin/fleet-send tests/send.bats
git commit -m "feat: stage Row 2 verbs to a queue with single-claim ownership"
```

---

### Task 6: The `Stop` drain

**Files:**
- Modify: `bin/fleet-emit` (in `run`, in the `else` branch that writes session state)
- Test: `tests/drain.bats` (create)

**Interfaces:**
- Consumes: `fleetlib.claim_queue()` from Task 5
- Produces: on `Stop` with a queued verb, `fleet-emit` prints `{"decision":"block","reason":<prompt>}` to stdout and sets the session state to `working`

- [ ] **Step 1: Write the failing test**

Create `tests/drain.bats`:

```bash
#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  export FLEET_SKIP_RECONCILE=1
  mkdir -p "$FLEET_HOME/sessions" "$FLEET_HOME/queue"
  PAYLOAD='{"session_id":"S1","cwd":"/tmp"}'
}

emit() { printf '%s' "${2:-$PAYLOAD}" | "$BIN/fleet-emit" "$1"; }
state() { python3 -c "import json;print(json.load(open('$FLEET_HOME/sessions/S1.json'))['state'])"; }

queue() {
  python3 -c "
import json,sys
json.dump({'verb':'test','prompt':'RUN THE TESTS','verb_path':'/v/test.md',
           'queued_at':1}, open('$FLEET_HOME/queue/S1.json','w'))"
}

@test "an ordinary Stop prints nothing at all" {
  run emit Stop
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(state)" = "done" ]
}

@test "a queued verb blocks the Stop with its prompt as the reason" {
  queue
  run emit Stop
  [ "$status" -eq 0 ]
  run python3 -c "
import json,sys
d=json.loads('''$output''')
print(d['decision'], d['reason'])"
  [ "$output" = "block RUN THE TESTS" ]
}

@test "a blocked Stop leaves the slot working, because the agent continues" {
  queue
  emit Stop
  [ "$(state)" = "working" ]
}

@test "draining removes the entry so the next Stop does not re-fire it" {
  queue
  emit Stop
  [ ! -e "$FLEET_HOME/queue/S1.json" ]
  run emit Stop
  [ -z "$output" ]
  [ "$(state)" = "done" ]
}

@test "stop_hook_active suppresses draining, as a loop backstop" {
  queue
  run emit Stop '{"session_id":"S1","cwd":"/tmp","stop_hook_active":true}'
  [ -z "$output" ]
  [ "$(state)" = "done" ]
}

@test "a queued verb for another session is not drained by this one" {
  python3 -c "
import json
json.dump({'verb':'test','prompt':'X','verb_path':'','queued_at':1},
          open('$FLEET_HOME/queue/OTHER.json','w'))"
  run emit Stop
  [ -z "$output" ]
  [ -e "$FLEET_HOME/queue/OTHER.json" ]
}

@test "a malformed queue entry is discarded, never emitted as a block" {
  printf 'not json' > "$FLEET_HOME/queue/S1.json"
  run emit Stop
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(state)" = "done" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/drain.bats`
Expected: FAIL on "a queued verb blocks the Stop" — nothing is printed.

- [ ] **Step 3: Implement the drain**

In `bin/fleet-emit`, add near the other constants:

```python
# A Stop that carries a queued verb is not the end of the turn: blocking it
# hands the verb to the agent, which then continues. The slot must therefore
# read `working`, not `done` -- painting it green for the instant before the
# agent picks up would be a lie the operator could actually catch.
DRAIN_STATE = "working"
```

In `run`, replace the `else:` branch body's state write so the drain is decided first:

```python
    else:
        drained = None
        if event == "Stop" and not payload.get("stop_hook_active"):
            claimed = fleetlib.claim_queue(session_id)
            if isinstance(claimed, dict) and isinstance(claimed.get("prompt"), str) \
                    and claimed["prompt"].strip():
                drained = claimed

        fleetlib.write_json_atomic(target, {
            "session_id": session_id,
            "state": DRAIN_STATE if drained else state,
            "repo": repo, "branch": branch, "title": "", "cwd": cwd, "host": host,
            "iterm_session": iterm_uuid, "pid": find_agent_pid(), "ts": now,
        })
        if state == "blocked":
            fleetlib.create_blocked_marker(session_id)
        elif event in MARKER_CLEARING_EVENTS:
            fleetlib.clear_blocked_marker(session_id)

        if drained:
            # The only path on which this hook prints anything. Claimed and
            # removed above, so a crash between here and the write costs one
            # verb rather than looping forever.
            sys.stdout.write(json.dumps({
                "decision": "block", "reason": drained["prompt"],
            }))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/drain.bats`
Expected: 7 tests, all PASS.

- [ ] **Step 5: Run the whole suite for regressions**

Run: `bats tests/ && python3 -m unittest discover -s tests -p 'test_*.py'`
Expected: all PASS. `tests/emit.bats` and `tests/guard.bats` cover the untouched paths and must stay green — in particular the notification classification from `dff42e3`.

- [ ] **Step 6: Commit**

```bash
git add bin/fleet-emit tests/drain.bats
git commit -m "feat: drain a queued verb by blocking the Stop hook"
```

---

### Task 7: The Row 2 key

**Files:**
- Create: `plugin/src/command.ts`
- Modify: `plugin/com.louisalexander.flightdeck.sdPlugin/manifest.json` (Actions array)
- Modify: `plugin/src/plugin.ts` (register the action)
- Test: `plugin/src/render.test.mjs` (append)

**Interfaces:**
- Consumes: nothing from earlier tasks at render time — the key's appearance depends only on its own verb and press state
- Produces: `renderCommandSvg(label: string, feedback: "" | "queued" | "refused") -> string`

- [ ] **Step 1: Write the failing test**

Append to `plugin/src/render.test.mjs`:

```javascript
// --- Row 2 command keys -------------------------------------------------
import { renderCommandSvg } from "../com.louisalexander.flightdeck.sdPlugin/bin/command.js";

const plain = renderCommandSvg("TEST", "");
assert.ok(plain.includes("TEST"), "the verb label is drawn");
// Row 1 owns saturation because state is the information. Row 2 must not
// compete, and must never borrow the one colour that means "come look".
assert.ok(!plain.includes("#F5A623"), "a command key is never amber");
assert.ok(!plain.includes("#1256A3"), "a command key is never lifecycle blue");
assert.ok(!plain.includes("#238636"), "a command key is never lifecycle green");

// Queued and delivered are different moments; the key must not claim success
// at press time, so queued gets its own restrained treatment.
const queued = renderCommandSvg("TEST", "queued");
assert.notStrictEqual(queued, plain, "queued looks different from idle");
assert.ok(!queued.includes("#F5A623"), "queued is not amber either");

const refused = renderCommandSvg("TEST", "refused");
assert.notStrictEqual(refused, plain, "refused looks different from idle");
assert.notStrictEqual(refused, queued, "refused is distinguishable from queued");
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugin && npm run build && node src/render.test.mjs`
Expected: FAIL — `command.js` does not exist.

- [ ] **Step 3: Write the command renderer**

Create `plugin/src/command.ts`:

```typescript
/**
 * Row 2 command keys.
 *
 * Deliberately monochrome. Row 1 owns saturated colour because lifecycle
 * state is the information on this panel; a command key that competed for
 * that channel would make the deck harder to read, not richer. Feedback is
 * a brief change of ink, never a change of hue into lifecycle territory.
 */

const NIGHT = "#0A0E13";
const INK = "#C9D4E2";
const INK_DIM = "#5A6675";
const INK_BRIGHT = "#FFFFFF";

export type Feedback = "" | "queued" | "refused";

export function renderCommandSvg(label: string, feedback: Feedback): string {
  const safe = label.replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;");

  // Queued is not success: the verb may not run for minutes. It gets a dimmed
  // label and a small marker rather than anything that reads as "done".
  const ink = feedback === "refused" ? INK_BRIGHT
    : feedback === "queued" ? INK_DIM : INK;

  const marker = feedback === "queued"
    ? `<circle cx="72" cy="112" r="5" fill="${INK}" fill-opacity="0.55"/>`
    : feedback === "refused"
      ? `<rect x="34" y="108" width="76" height="4" rx="2" fill="${INK_BRIGHT}"/>`
      : "";

  return [
    '<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144">',
    `<rect width="144" height="144" fill="${NIGHT}"/>`,
    `<text x="72" y="80" text-anchor="middle" font-family="Helvetica,Arial" ` +
      `font-size="22" font-weight="700" letter-spacing="1.2" fill="${ink}">${safe}</text>`,
    marker,
    "</svg>"
  ].join("");
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugin && npm run build && node src/render.test.mjs`
Expected: PASS.

- [ ] **Step 5: Register the action**

In `manifest.json`, add to `Actions`:

```json
{
  "Icon": "imgs/actions/command/icon",
  "Name": "Command",
  "States": [{ "Image": "imgs/actions/command/key" }],
  "Tooltip": "Send a verb to the focused agent",
  "UUID": "com.louisalexander.flightdeck.command",
  "PropertyInspectorPath": "ui/command.html"
}
```

In `plugin/src/plugin.ts`, add the dispatcher above the action class. It mirrors
the existing `fleet-press` call at `plugin/src/plugin.ts:146`, reusing the same
`interpreter()` and `REPO` helpers already defined in that file — the only
difference is that this one resolves to whether the press was staged, because
`fleet-send` is allowed to exit non-zero and the key must say which happened:

```typescript
function runFleetSend(verb: string): Promise<boolean> {
  return new Promise((resolve) => {
    execFile(interpreter(), [join(REPO, "bin", "fleet-send"), verb], (err) => {
      if (err) streamDeck.logger.error(`fleet-send ${verb} refused: ${err.message}`);
      resolve(!err);
    });
  });
}

@action({ UUID: "com.louisalexander.flightdeck.command" })
export class Command extends SingletonAction<{ verb?: string }> {
  override onWillAppear(ev: WillAppearEvent<{ verb?: string }>): void {
    const verb = ev.payload.settings?.verb ?? "";
    ev.action.setImage(toDataUri(renderCommandSvg(verb.toUpperCase(), "")));
  }

  override async onKeyUp(ev: KeyUpEvent<{ verb?: string }>): Promise<void> {
    const verb = ev.payload.settings?.verb ?? "";
    if (!verb) return;
    const ok = await runFleetSend(verb);
    ev.action.setImage(toDataUri(
      renderCommandSvg(verb.toUpperCase(), ok ? "queued" : "refused")));
    setTimeout(() => {
      ev.action.setImage(toDataUri(renderCommandSvg(verb.toUpperCase(), "")));
    }, 1200);
  }
}

streamDeck.actions.registerAction(new Command());
```

- [ ] **Step 6: Rebuild and commit**

```bash
cd plugin && npm run build && node src/render.test.mjs && cd ..
git add plugin/src/command.ts plugin/src/plugin.ts plugin/src/render.test.mjs \
        plugin/com.louisalexander.flightdeck.sdPlugin/manifest.json
git commit -m "feat: add the Row 2 command key with queued and refused feedback"
```

---

### Task 8: Waking an idle session

**Files:**
- Modify: `bin/fleet-send` (after staging)
- Test: `tests/send.bats` (append)

**Interfaces:**
- Consumes: `fleetlib.claim_queue()` (Task 5), the session's `state` and `iterm_session` fields
- Produces: for an idle session, `fleet-send` claims the entry and invokes `$FLEET_OSASCRIPT` (default `osascript`) to type a pointer at the verb file

- [ ] **Step 1: Write the failing test**

Append to `tests/send.bats`:

```bash
# A recording stub stands in for osascript so the wake path is testable
# without a terminal. It appends its arguments to a log.
stub_osascript() {
  cat > "$BATS_TEST_TMPDIR/osa" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OSA_LOG"
exit 0
SH
  chmod +x "$BATS_TEST_TMPDIR/osa"
  export FLEET_OSASCRIPT="$BATS_TEST_TMPDIR/osa"
  export OSA_LOG="$BATS_TEST_TMPDIR/osa.log"
}

idle_session() {
  python3 -c "
import json
p='$FLEET_HOME/sessions/S1.json'
d=json.load(open(p)); d['state']='$1'; json.dump(d, open(p,'w'))"
}

@test "WAKE: a working session is not woken; the drain will serve it" {
  stub_osascript
  idle_session working
  "$BIN/fleet-send" test
  [ ! -e "$OSA_LOG" ]
  [ -e "$(queued)" ]
}

@test "WAKE: an idle session is woken" {
  stub_osascript
  idle_session idle
  "$BIN/fleet-send" test
  [ -e "$OSA_LOG" ]
}

@test "WAKE: the typed text points at the verb file, never the prompt body" {
  stub_osascript
  idle_session done
  "$BIN/fleet-send" test
  run cat "$OSA_LOG"
  [[ "$output" == *"test.md"* ]]
  [[ "$output" != *"fleet-fail"* ]]
}

@test "WAKE: the entry is claimed before typing, so the drain cannot re-serve it" {
  stub_osascript
  idle_session idle
  "$BIN/fleet-send" test
  [ ! -e "$(queued)" ]
}

@test "WAKE: a malformed iterm uuid is never passed to osascript" {
  stub_osascript
  idle_session idle
  python3 -c "
import json
p='$FLEET_HOME/sessions/S1.json'
d=json.load(open(p)); d['iterm_session']='not-a-uuid; rm -rf /'
json.dump(d, open(p,'w'))"
  run "$BIN/fleet-send" test
  [ "$status" -eq 1 ]
  [ ! -e "$OSA_LOG" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/send.bats -f WAKE`
Expected: FAIL on "an idle session is woken" — nothing invokes osascript.

- [ ] **Step 3: Implement the wake**

In `bin/fleet-send`, add near the top:

```python
import os
import re

UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}"
                     r"-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
OSASCRIPT_TIMEOUT_SECS = 10
WORKING_STATES = ("working",)

# Addressed by UUID across every window and tab, never by window index.
# `window 1` is whichever window is frontmost, which during design was
# observed delivering a message into the wrong session entirely.
WAKE_SCRIPT = '''
tell application "iTerm2"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if (id of s) is "{uuid}" then
          tell s to write text "{line}"
          return "sent"
        end if
      end repeat
    end repeat
  end repeat
  return "not found"
end tell
'''
```

And after the `write_json_atomic` staging call in `main`:

```python
    # A working session needs nothing more: its Stop drain will serve the
    # verb when the turn ends, with no keystrokes and no race.
    if session.get("state") in WORKING_STATES:
        return 0

    # An idle session will never fire a Stop, so input is the only wake.
    # Claim first: a pointer typed for an entry the drain has already taken
    # would send the agent to a file that is no longer queued.
    claimed = fleetlib.claim_queue(session_id)
    if not isinstance(claimed, dict):
        return 0                       # someone else delivered it; fine

    uuid = session.get("iterm_session", "")
    if not UUID_RE.match(uuid or ""):
        fleetlib.log("send: refusing malformed iterm target {!r}".format(uuid))
        return 1

    # The pointer, never the prompt. Short text keeps the fragile channel
    # small, and a pointer that collides with a half-typed draft produces
    # something the agent queries rather than a mangled instruction.
    line = "Read {} and follow it.".format(claimed.get("verb_path", ""))
    script = WAKE_SCRIPT.format(uuid=uuid, line=line.replace('"', '\\"'))
    osa = os.environ.get("FLEET_OSASCRIPT") or "osascript"
    try:
        subprocess.run([osa, "-e", script],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=OSASCRIPT_TIMEOUT_SECS)
    except Exception as err:
        fleetlib.log("send: wake failed for {}: {}".format(session_id, err))
        return 1
    return 0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/send.bats`
Expected: 12 tests, all PASS.

- [ ] **Step 5: Run the whole suite**

Run: `bats tests/ && python3 -m unittest discover -s tests -p 'test_*.py' && cd plugin && node src/render.test.mjs`
Expected: all PASS.

- [ ] **Step 6: Live check on a real session**

The stub proves the guards; only a real terminal proves submission. In a scratch repo, start a real `claude`, press a Row 1 key to select it, let it go idle, then run `bin/fleet-send test` and confirm the prompt is both typed **and submitted**. Then repeat while the agent is mid-turn and confirm the verb arrives at turn end via the drain instead.

- [ ] **Step 7: Commit**

```bash
git add bin/fleet-send tests/send.bats
git commit -m "feat: wake an idle session with a pointer to the verb file"
```

---

## Deferred from this slice

Recorded so they are not mistaken for oversights. Each is in the spec.

- **The other seven panel verbs** (DIFF, LOG, ISSUE, PUSH, PR, DOUBT, STOP). Once Task 4 lands they are markdown files, not code — except STOP, which needs the `interrupt` path, and ISSUE/PUSH/PR, which need `confirm`. `config/verbs/issue.md` and `config/verbs/commit.md` already exist; the rest do not.
- **COMMIT is written but off-panel** (`config/verbs/commit.md`). It needs no work — it exists so the eighth slot can be swapped without writing anything new.
- **`confirm: true` enforcement**, including the rule that confirm verbs never queue.
- **Queued-state visibility on Row 1**, so a waiting verb is visible on the target slot rather than only on the Row 2 key.
- **The TTL and stale-entry policy.** `queued_at` is written by Task 5 but nothing reads it yet.
- **Queue depth** — whether a second press replaces, queues behind, or is refused.
- **`bin/fleet-fail --explain`**, which `config/verbs/test.md` already tells the agent to run.
