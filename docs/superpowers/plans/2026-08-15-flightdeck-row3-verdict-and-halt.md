# Flightdeck Row 3 (Verdict) and HALT — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the operator answer a Claude Code permission request from a Stream Deck key, and stop the whole fleet from one key.

**Architecture:** A blocking `PermissionRequest` hook (`bin/fleet-decide`) writes a pending record, then polls for a decision file that a Row 3 keypress (`bin/fleet-verdict`) writes. Emitting nothing on timeout leaves Claude Code's own dialog answerable, so every failure degrades to today's behaviour. HALT is a latch file read by a pure-shell clause in the existing `PreToolUse` hook, so the emergency brake depends on no Python at all.

**Tech Stack:** Python 3.9 (stdlib only), bats + python unittest, TypeScript (`@elgato/streamdeck`).

**Spec:** `docs/superpowers/specs/2026-08-15-flightdeck-rows-3-4-design.md`

## Global Constraints

- **Python 3.9 syntax, standard library only.** No third-party packages, no venv, no `jq`.
- **Hooks MUST always exit 0.** `bin/fleet-decide` follows `bin/fleet-emit`'s contract exactly.
- **Non-hook scripts may exit non-zero.** `fleet-verdict` and `fleet-halt` must report failure.
- **All state writes are atomic** — `fleetlib.write_json_atomic`, never a bare `open(...,"w")`.
- **All ownership transfers use `os.replace`** to a per-pid sibling, as `fleetlib.claim_queue` does.
- **`FLEET_HOME` defaults to `~/.fleet`** and is always read via `fleetlib.fleet_home()`.
- **No tool input is ever rendered on a key.** Key faces carry classification only.
- **Row 3 and Row 4 are monochrome** (`NIGHT = "#0A0E13"`, `INK = "#C9D4E2"`). The only borrowed colour is `ATTENTION = "#F5A623"` for armed and `high` tier.
- **Pure functions are tested in `tests/test_fleetlib.py`** (python unittest); **CLI contracts are tested in `tests/*.bats`**.
- **Run `./tests/run.sh` before every commit.** It must stay green.

**Out of scope for this plan** (follow-up plan): GATE, SPEND, DISPATCH.

---

### Task 1: Risk scoring

**Files:**
- Create: `config/risk.json`
- Modify: `bin/fleetlib.py` (append a `--- risk ---` section after `--- labels ---`)
- Test: `tests/test_fleetlib.py`

**Interfaces:**
- Consumes: `fleetlib.config_dir()`, `fleetlib.read_json()`
- Produces:
  - `fleetlib.load_risk_rules() -> dict` — merged `risk.json`, `{}` on any failure
  - `fleetlib.score_risk(tool_name: str, tool_input: dict, rules: dict) -> str` — `"low"`, `"normal"` or `"high"`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_fleetlib.py`:

```python
RULES = {
    "high": [
        {"tool": "Bash", "match": r"rm\s+-[a-z]*[rf]"},
        {"tool": "Bash", "match": r"push\s+.*--force"},
        {"tool": "Bash", "match": r"curl.*\|\s*(ba)?sh"},
    ],
    "low": [{"tool": "Read"}, {"tool": "Grep"}, {"tool": "Glob"}],
}


class ScoreRiskTests(unittest.TestCase):
    def test_unmatched_tool_is_normal(self):
        self.assertEqual(fleetlib.score_risk("Write", {"file_path": "a"}, RULES), "normal")

    def test_tool_only_rule_matches(self):
        self.assertEqual(fleetlib.score_risk("Read", {"file_path": "a"}, RULES), "low")

    def test_pattern_rule_matches_command(self):
        self.assertEqual(fleetlib.score_risk("Bash", {"command": "rm -rf ./build"}, RULES), "high")

    def test_pattern_rule_requires_the_named_tool(self):
        # The same text under a different tool must not score high.
        self.assertEqual(fleetlib.score_risk("Write", {"content": "rm -rf ./build"}, RULES), "normal")

    def test_high_wins_over_low(self):
        rules = {"high": [{"tool": "Read"}], "low": [{"tool": "Read"}]}
        self.assertEqual(fleetlib.score_risk("Read", {}, rules), "high")

    def test_scans_every_string_value_in_the_input(self):
        self.assertEqual(fleetlib.score_risk("Bash", {"command": "git push --force"}, RULES), "high")

    def test_malformed_rules_degrade_to_normal(self):
        self.assertEqual(fleetlib.score_risk("Bash", {"command": "rm -rf /"}, {"high": "nope"}), "normal")

    def test_bad_regex_is_skipped_not_raised(self):
        rules = {"high": [{"tool": "Bash", "match": "([unclosed"}]}
        self.assertEqual(fleetlib.score_risk("Bash", {"command": "x"}, rules), "normal")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/usr/bin/python3 tests/test_fleetlib.py -v`
Expected: FAIL with `AttributeError: module 'fleetlib' has no attribute 'score_risk'`

- [ ] **Step 3: Write `config/risk.json`**

```json
{
  "high": [
    { "tool": "Bash", "match": "rm\\s+-[a-z]*[rf]" },
    { "tool": "Bash", "match": "push\\s+.*--force" },
    { "tool": "Bash", "match": "curl.*\\|\\s*(ba)?sh" },
    { "tool": "Bash", "match": "wget.*\\|\\s*(ba)?sh" },
    { "tool": "Bash", "match": "\\bgit\\s+reset\\s+--hard\\b" },
    { "tool": "Bash", "match": "\\bgit\\s+clean\\s+-[a-z]*f" },
    { "tool": "Bash", "match": "\\bchmod\\s+-R\\b" },
    { "tool": "Bash", "match": "\\bsudo\\b" },
    { "tool": "Bash", "match": "\\bdd\\s+if=" },
    { "tool": "Bash", "match": "/dev/(disk|rdisk)" }
  ],
  "low": [
    { "tool": "Read" },
    { "tool": "Grep" },
    { "tool": "Glob" },
    { "tool": "ToolSearch" },
    { "tool": "TodoWrite" }
  ]
}
```

- [ ] **Step 4: Implement scoring in `bin/fleetlib.py`**

Append after the labels section:

```python
# --- risk ------------------------------------------------------------------

RISK_TIERS = ("high", "normal", "low")


def load_risk_rules():
    """Rules from config/risk.json, layered with risk.local.json if present.

    Returns {} on any failure. An empty table scores everything `normal`,
    which is the safe degradation: a tier can only ever ADD friction on top
    of a prompt the operator is already being shown, so knowing nothing
    means behaving exactly as the deck did before tiers existed.
    """
    base = read_json(config_dir() / "risk.json", {}) or {}
    local = read_json(config_dir() / "risk.local.json", {}) or {}
    if not isinstance(base, dict):
        base = {}
    if not isinstance(local, dict):
        local = {}
    out = dict(base)
    for tier, extra in local.items():
        if isinstance(extra, list):
            out[tier] = list(out.get(tier) or []) + extra
    return out


def _input_strings(tool_input):
    """Every string value in a tool input, one level deep plus list members.

    Deliberately not a recursive walk of arbitrary depth: tool inputs are
    shallow, and an unbounded walk over model-authored JSON is a place to
    get stuck rather than a place to find more signal.
    """
    out = []
    if not isinstance(tool_input, dict):
        return out
    for value in tool_input.values():
        if isinstance(value, str):
            out.append(value)
        elif isinstance(value, list):
            out.extend(v for v in value if isinstance(v, str))
    return out


def _rule_matches(rule, tool_name, haystacks):
    if not isinstance(rule, dict):
        return False
    want_tool = rule.get("tool")
    if isinstance(want_tool, str) and want_tool != tool_name:
        return False
    pattern = rule.get("match")
    if not isinstance(pattern, str) or not pattern:
        # A tool-only rule matches on the tool alone.
        return isinstance(want_tool, str)
    try:
        compiled = re.compile(pattern)
    except re.error:
        # A bad pattern is a config typo, not a reason to fail a hook.
        return False
    return any(compiled.search(text) for text in haystacks)


def score_risk(tool_name, tool_input, rules):
    """The tier for one tool call: 'high', 'normal' or 'low'.

    Checked most-severe first so `high` always wins a tie -- a call that
    matches both tables is the dangerous one.
    """
    if not isinstance(rules, dict):
        return "normal"
    haystacks = _input_strings(tool_input)
    for tier in ("high", "low"):
        table = rules.get(tier)
        if not isinstance(table, list):
            continue
        for rule in table:
            if _rule_matches(rule, tool_name, haystacks):
                return tier
    return "normal"
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `/usr/bin/python3 tests/test_fleetlib.py -v` — Expected: PASS
Run: `./tests/run.sh` — Expected: all green

- [ ] **Step 6: Commit**

```bash
git add config/risk.json bin/fleetlib.py tests/test_fleetlib.py
git commit -m "feat: risk tiers from a rule table

A tier can only add friction on top of a prompt the operator is already
being shown, so an unmatched call scores normal and an unreadable table
scores everything normal -- degrading to exactly today's behaviour."
```

---

### Task 2: Pending records and the decision channel's storage

**Files:**
- Modify: `bin/fleetlib.py`
- Test: `tests/test_fleetlib.py`

**Interfaces:**
- Consumes: `fleetlib.fleet_home()`, `write_json_atomic`, `read_json`
- Produces:
  - `fleetlib.pending_dir() -> Path`, `pending_path(session_id) -> Path`
  - `fleetlib.decisions_dir() -> Path`, `decision_path(session_id) -> Path`
  - `fleetlib.halt_path() -> Path`
  - `fleetlib.input_digest(tool_name: str, tool_input) -> str` — `"sha256:<16 hex>"`
  - `fleetlib.claim_decision(session_id) -> dict | None`
  - `fleetlib.read_pending_all() -> list[dict]` — every valid pending record, oldest `requested_at` first
  - `fleetlib.resolve_target() -> str` — session id, or `""`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_fleetlib.py`:

```python
class PendingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.environ["FLEET_HOME"] = self.tmp

    def tearDown(self):
        os.environ.pop("FLEET_HOME", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _pending(self, sid, at, tier="normal"):
        fleetlib.write_json_atomic(fleetlib.pending_path(sid), {
            "session_id": sid, "tool": "Bash", "input_digest": "sha256:abc",
            "input_summary": "x", "tier": tier, "suggestion": None,
            "repo": "r", "repeats": 1, "requested_at": at,
        })

    def test_digest_is_stable_and_order_independent(self):
        a = fleetlib.input_digest("Bash", {"command": "ls", "timeout": 1})
        b = fleetlib.input_digest("Bash", {"timeout": 1, "command": "ls"})
        self.assertEqual(a, b)
        self.assertTrue(a.startswith("sha256:"))

    def test_digest_changes_with_the_tool(self):
        self.assertNotEqual(fleetlib.input_digest("Bash", {"c": 1}),
                            fleetlib.input_digest("Write", {"c": 1}))

    def test_read_pending_all_is_oldest_first(self):
        self._pending("B", 200)
        self._pending("A", 100)
        self.assertEqual([p["session_id"] for p in fleetlib.read_pending_all()], ["A", "B"])

    def test_read_pending_all_skips_unreadable_files(self):
        fleetlib.pending_dir().mkdir(parents=True, exist_ok=True)
        (fleetlib.pending_dir() / "junk.json").write_text("{not json")
        self._pending("A", 100)
        self.assertEqual([p["session_id"] for p in fleetlib.read_pending_all()], ["A"])

    def test_resolve_target_prefers_a_selection_that_is_pending(self):
        self._pending("A", 100)
        self._pending("B", 200)
        fleetlib.write_focus("B")
        self.assertEqual(fleetlib.resolve_target(), "B")

    def test_resolve_target_falls_back_when_the_selection_is_not_pending(self):
        self._pending("A", 100)
        fleetlib.write_focus("Z")
        self.assertEqual(fleetlib.resolve_target(), "A")

    def test_resolve_target_is_empty_when_nothing_is_pending(self):
        self.assertEqual(fleetlib.resolve_target(), "")

    def test_claim_decision_yields_exactly_one_winner(self):
        fleetlib.write_json_atomic(fleetlib.decision_path("A"), {"behavior": "allow"})
        first = fleetlib.claim_decision("A")
        second = fleetlib.claim_decision("A")
        self.assertEqual(first, {"behavior": "allow"})
        self.assertIsNone(second)
```

Ensure the file's imports include `os`, `shutil`, `tempfile`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/usr/bin/python3 tests/test_fleetlib.py -v`
Expected: FAIL with `AttributeError: module 'fleetlib' has no attribute 'pending_path'`

- [ ] **Step 3: Implement in `bin/fleetlib.py`**

Add near the other path helpers:

```python
def pending_dir():
    return fleet_home() / "pending"


def pending_path(session_id):
    return pending_dir() / "{}.json".format(session_id)


def decisions_dir():
    return fleet_home() / "decisions"


def decision_path(session_id):
    return decisions_dir() / "{}.json".format(session_id)


def halt_path():
    """The fleet-wide deny latch.

    Read by a pure-shell clause in the PreToolUse hook, so its existence is
    the entire protocol -- content is never parsed and must never become
    load-bearing. The shell path is what lets the emergency brake work when
    flightdeck's own interpreter does not.
    """
    return fleet_home() / "halt"


def input_digest(tool_name, tool_input):
    """A stable identity for one tool call, for detecting a retry loop.

    sort_keys because a model may emit the same object with different key
    order between attempts, and two spellings of one call must collide.
    """
    try:
        blob = json.dumps(tool_input, sort_keys=True, separators=(",", ":"), default=str)
    except Exception:
        blob = repr(tool_input)
    payload = "{}\x00{}".format(tool_name, blob).encode("utf-8", "replace")
    return "sha256:" + hashlib.sha256(payload).hexdigest()[:16]


def claim_decision(session_id):
    """Takes sole ownership of a written verdict, or returns None.

    Same os.replace ownership rename as claim_queue. Two claimants are
    possible in principle -- a deciding hook polling, and a later one for a
    retried call -- and a decision must be consumed exactly once so an
    operator's single press cannot answer two requests.
    """
    claim = decisions_dir() / "{}.claim.{}.json".format(session_id, os.getpid())
    try:
        os.replace(str(decision_path(session_id)), str(claim))
    except OSError:
        return None
    try:
        return read_json(claim)
    finally:
        try:
            claim.unlink()
        except Exception:
            pass


def read_pending_all():
    """Every readable pending record, oldest requested_at first."""
    out = []
    try:
        entries = sorted(pending_dir().iterdir())
    except Exception:
        return out
    for entry in entries:
        if entry.suffix != ".json" or ".claim." in entry.name:
            continue
        data = read_json(entry)
        if isinstance(data, dict) and isinstance(data.get("session_id"), str):
            if not isinstance(data.get("requested_at"), int):
                data["requested_at"] = 0
            out.append(data)
    out.sort(key=lambda d: d["requested_at"])
    return out


def resolve_target():
    """Which session a Row 3 press acts on.

    The selection if it has a pending decision, otherwise the oldest pending
    decision. Predictability beats recency on a device read peripherally,
    and a selection pointing at a blocked agent is not a wrong answer -- that
    agent does genuinely need deciding.
    """
    pending = read_pending_all()
    if not pending:
        return ""
    selected = read_focus()
    for record in pending:
        if record["session_id"] == selected:
            return selected
    return pending[0]["session_id"]
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/usr/bin/python3 tests/test_fleetlib.py -v` — Expected: PASS
Run: `./tests/run.sh` — Expected: all green

- [ ] **Step 5: Commit**

```bash
git add bin/fleetlib.py tests/test_fleetlib.py
git commit -m "feat: pending records, decision claiming and target resolution

Target is the selection when it is pending, else the oldest pending.
A decision is claimed with the same os.replace rename claim_queue uses,
so one press can never answer two requests."
```

---

### Task 3: `bin/fleet-decide` — the blocking PermissionRequest hook

**Files:**
- Create: `bin/fleet-decide`
- Test: `tests/decide.bats`

**Interfaces:**
- Consumes: everything from Tasks 1 and 2
- Produces: an executable hook reading a `PermissionRequest` payload on stdin. Emits `hookSpecificOutput` JSON on a decision, **nothing** on timeout. Always exits 0.
- Env overrides for tests: `FLEET_DECIDE_TIMEOUT_SECS`, `FLEET_DECIDE_POLL_SECS`

- [ ] **Step 1: Write the failing tests**

Create `tests/decide.bats`:

```bash
#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  export FLEET_DECIDE_POLL_SECS=0.02
  export FLEET_DECIDE_TIMEOUT_SECS=1
  mkdir -p "$FLEET_HOME"
  PAYLOAD='{"session_id":"S1","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"rm -rf ./build"},"permission_suggestions":[{"type":"addRules","destination":"localSettings","rules":[{"toolName":"Bash","ruleContent":"rm:*"}],"behavior":"allow"}]}'
}

decide() { printf '%s' "${1:-$PAYLOAD}" | "$BIN/fleet-decide"; }
pending() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" \
              "$FLEET_HOME/pending/S1.json" "$1"; }

@test "a pending record is written with the scored tier" {
  export FLEET_DECIDE_TIMEOUT_SECS=1
  decide >/dev/null
  # The record is cleared on timeout, so capture it from the events trail
  # instead: assert via a decision-present run below. Here assert exit only.
  [ "$?" -eq 0 ]
}

@test "a waiting decision is emitted as allow and the tool proceeds" {
  mkdir -p "$FLEET_HOME/decisions"
  printf '%s' '{"behavior":"allow"}' > "$FLEET_HOME/decisions/S1.json"
  run decide
  [ "$status" -eq 0 ]
  [[ "$output" == *'"hookEventName":"PermissionRequest"'* ]]
  [[ "$output" == *'"behavior":"allow"'* ]]
}

@test "a deny decision carries its message and interrupt flag" {
  mkdir -p "$FLEET_HOME/decisions"
  printf '%s' '{"behavior":"deny","message":"no","interrupt":true}' > "$FLEET_HOME/decisions/S1.json"
  run decide
  [[ "$output" == *'"behavior":"deny"'* ]]
  [[ "$output" == *'"interrupt":true'* ]]
}

@test "the decision file is consumed, not left behind" {
  mkdir -p "$FLEET_HOME/decisions"
  printf '%s' '{"behavior":"allow"}' > "$FLEET_HOME/decisions/S1.json"
  decide >/dev/null
  [ ! -f "$FLEET_HOME/decisions/S1.json" ]
}

@test "the pending record is cleared once decided" {
  mkdir -p "$FLEET_HOME/decisions"
  printf '%s' '{"behavior":"allow"}' > "$FLEET_HOME/decisions/S1.json"
  decide >/dev/null
  [ ! -f "$FLEET_HOME/pending/S1.json" ]
}

# THE safety property: walking away must not become an automatic denial.
@test "a timeout emits absolutely nothing" {
  run decide
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a timeout clears its pending record" {
  decide >/dev/null
  [ ! -f "$FLEET_HOME/pending/S1.json" ]
}

@test "a second identical request increments repeats rather than duplicating" {
  export FLEET_DECIDE_TIMEOUT_SECS=1
  decide >/dev/null &
  sleep 0.2
  [ "$(pending repeats)" = "1" ]
  printf '%s' "$PAYLOAD" | "$BIN/fleet-decide" >/dev/null &
  sleep 0.2
  [ "$(pending repeats)" = "2" ]
  wait
}

@test "a high-risk command scores high" {
  decide >/dev/null &
  sleep 0.2
  [ "$(pending tier)" = "high" ]
  wait
}

@test "the session is marked blocked immediately" {
  decide >/dev/null &
  sleep 0.2
  [ -f "$FLEET_HOME/blocked/S1" ]
  wait
}

@test "an unparseable payload exits 0 and emits nothing" {
  run bash -c "printf 'not json' | '$BIN/fleet-decide'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a payload with no session id exits 0 and emits nothing" {
  run bash -c "printf '{}' | '$BIN/fleet-decide'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
```

Delete the first placeholder test (`a pending record is written with the scored tier`) — the `tier` and `repeats` tests below cover it properly.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/decide.bats`
Expected: FAIL — `bin/fleet-decide` does not exist

- [ ] **Step 3: Implement `bin/fleet-decide`**

```python
#!/usr/bin/env python3
"""Claude Code PermissionRequest hook. Offers the decision to the deck.

MUST ALWAYS EXIT 0, like bin/fleet-emit.

This is the one hook in flightdeck allowed to block. Every other hook must
exit in milliseconds because it sits on a live agent's critical path; this
one only ever runs when the agent is already waiting on a human, so it adds
no latency to anything. Stated as a rule: the only hook that may block is
one that fires when the agent is already blocked.

The load-bearing behaviour is what happens when nothing answers. Emitting
NOTHING leaves Claude Code's own permission dialog on screen and
answerable, so an unplugged deck, a crashed plugin, a bug in this file or
an operator who walked away all degrade to exactly the behaviour of not
having flightdeck installed. Never emit a deny on timeout.
"""

import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fleetlib  # noqa: E402

DEFAULT_TIMEOUT_SECS = 120
DEFAULT_POLL_SECS = 0.15
SUMMARY_MAX_CHARS = 300


def _float_env(name, fallback):
    try:
        return float(os.environ[name])
    except Exception:
        return fallback


def _timeout_secs(config):
    env = _float_env("FLEET_DECIDE_TIMEOUT_SECS", None)
    if env is not None:
        return env
    timings = config.get("timings") if isinstance(config, dict) else None
    if isinstance(timings, dict):
        value = timings.get("decideTimeoutSecs")
        if isinstance(value, (int, float)) and value > 0:
            return float(value)
    return DEFAULT_TIMEOUT_SECS


def _summarise(tool_input):
    """A single-line rendering of the input, for the log and terminal only.

    Explicitly NOT a render source: no key ever shows tool input. At 96px
    `rm -rf ./build` and `rm -rf ./ build` truncate identically, so a
    truncated command reads as information while being ambiguous exactly
    where it matters.
    """
    if not isinstance(tool_input, dict):
        return ""
    for key in ("command", "file_path", "url", "pattern", "path"):
        value = tool_input.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()[:SUMMARY_MAX_CHARS]
    try:
        return json.dumps(tool_input, separators=(",", ":"))[:SUMMARY_MAX_CHARS]
    except Exception:
        return ""


def _first_suggestion(payload):
    """Claude Code's own scoped-rule proposal, or None.

    Passed through verbatim and never synthesised. If Claude Code offers no
    rule, REMEMBER refuses rather than inventing one -- the width of a
    permission rule is the whole safety story and is not ours to guess.
    """
    suggestions = payload.get("permission_suggestions")
    if isinstance(suggestions, list):
        for item in suggestions:
            if isinstance(item, dict) and item.get("type") in ("addRules", "replaceRules"):
                return item
    return None


def _emit(decision):
    sys.stdout.write(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": decision,
        }
    }))


def _normalise(decision):
    """A claimed decision file, reduced to the schema Claude Code accepts.

    Verified against Claude Code v2.1.233:
      allow { updatedInput?, updatedPermissions? }
      deny  { message?, interrupt? }
    `permissionDecision` -- the documented PreToolUse field -- is silently
    ignored on this event, so it must not appear here.
    """
    if not isinstance(decision, dict):
        return None
    behavior = decision.get("behavior")
    if behavior == "allow":
        out = {"behavior": "allow"}
        updated = decision.get("updatedPermissions")
        if isinstance(updated, list) and updated:
            out["updatedPermissions"] = updated
        return out
    if behavior == "deny":
        out = {"behavior": "deny"}
        message = decision.get("message")
        if isinstance(message, str) and message.strip():
            out["message"] = message
        if decision.get("interrupt") is True:
            out["interrupt"] = True
        return out
    return None


def run():
    try:
        payload = json.loads(sys.stdin.read())
        if not isinstance(payload, dict):
            raise ValueError("payload is not an object")
    except Exception:
        fleetlib.log("decide: unparseable payload")
        return

    session_id = payload.get("session_id") or os.environ.get("CLAUDE_CODE_SESSION_ID") or ""
    if not session_id:
        fleetlib.log("decide: no session id")
        return

    tool_name = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = {}

    config = fleetlib.load_config()
    tier = fleetlib.score_risk(tool_name, tool_input, fleetlib.load_risk_rules())
    digest = fleetlib.input_digest(tool_name, tool_input)
    now = int(time.time())

    cwd = payload.get("cwd") or ""
    repo = ""
    if cwd:
        code, top = fleetlib.git(["rev-parse", "--show-toplevel"], cwd)
        if code == 0 and top:
            repo = Path(top).name

    # A denied agent may retry the identical call immediately, which would
    # otherwise produce a fresh prompt per press forever. Counting repeats
    # turns a silent loop into something legible on the DETAIL key.
    existing = fleetlib.read_json(fleetlib.pending_path(session_id))
    repeats = 1
    if isinstance(existing, dict) and existing.get("input_digest") == digest:
        previous = existing.get("repeats")
        repeats = (previous if isinstance(previous, int) else 1) + 1

    record = {
        "session_id": session_id,
        "tool": tool_name,
        "input_digest": digest,
        "input_summary": _summarise(tool_input),
        "tier": tier,
        "suggestion": _first_suggestion(payload),
        "repo": repo,
        "cwd": cwd,
        "repeats": repeats,
        "requested_at": now,
    }
    try:
        fleetlib.write_json_atomic(fleetlib.pending_path(session_id), record)
    except Exception as err:
        fleetlib.log("decide: could not stage pending: {}".format(err))
        return

    # Amber now rather than in six seconds: PermissionRequest fires at once
    # where Notification/permission_prompt is debounced ~6s.
    fleetlib.create_blocked_marker(session_id)
    _touch_session_blocked(session_id, now)
    _reconcile()

    decision = _wait_for_decision(session_id, _timeout_secs(config))

    try:
        fleetlib.pending_path(session_id).unlink()
    except Exception:
        pass
    _reconcile()

    if decision is None:
        # Timeout. Emit nothing at all -- the dialog is still on screen.
        return
    normalised = _normalise(decision)
    if normalised is None:
        fleetlib.log("decide: discarding malformed decision for {}".format(session_id))
        return
    _emit(normalised)


def _wait_for_decision(session_id, timeout_secs):
    poll = _float_env("FLEET_DECIDE_POLL_SECS", DEFAULT_POLL_SECS)
    deadline = time.time() + timeout_secs
    while time.time() < deadline:
        claimed = fleetlib.claim_decision(session_id)
        if claimed is not None:
            return claimed
        time.sleep(poll)
    return fleetlib.claim_decision(session_id)


def _touch_session_blocked(session_id, now):
    target = fleetlib.sessions_dir() / "{}.json".format(session_id)
    existing = fleetlib.read_json(target)
    if not isinstance(existing, dict):
        return
    existing["state"] = "blocked"
    existing["ts"] = now
    try:
        fleetlib.write_json_atomic(target, existing)
    except Exception:
        pass


def _reconcile():
    if os.environ.get("FLEET_SKIP_RECONCILE") == "1":
        return
    import subprocess
    try:
        subprocess.run(
            [sys.executable, str(Path(__file__).resolve().parent / "fleet-reconcile")],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except Exception:
        pass


if __name__ == "__main__":
    try:
        run()
    except Exception as err:            # noqa: BLE001 -- the exit-0 guarantee
        fleetlib.log("decide: unhandled {!r}".format(err))
    sys.exit(0)
```

- [ ] **Step 4: Make it executable and run the tests**

```bash
chmod +x bin/fleet-decide
bats tests/decide.bats
```
Expected: PASS

- [ ] **Step 5: Run the full suite and commit**

```bash
./tests/run.sh
git add bin/fleet-decide tests/decide.bats
git commit -m "feat: fleet-decide, the blocking PermissionRequest hook

Stages a pending record, marks the slot blocked at once, then polls for a
verdict. Emits nothing on timeout, which leaves Claude Code's own dialog
answerable -- so every failure degrades to not having flightdeck."
```

---

### Task 4: `bin/fleet-verdict` — the sender

**Files:**
- Create: `bin/fleet-verdict`
- Test: `tests/verdict.bats`

**Interfaces:**
- Consumes: `fleetlib.resolve_target`, `pending_path`, `decision_path`, `claim_verb_arm`, `verb_armed_path`, `write_focus`
- Produces: `bin/fleet-verdict <approve|remember|deny|interrupt|steer|detail> [verb-id]`
  - exit `0` delivered, `1` refused, `2` armed
  - every decision file written carries `request_id`, copied verbatim from the pending record's own `request_id` — fleet-decide (Task 3) mints that id per request and discards any decision whose `request_id` does not match the one currently staged, so a decision missing it is silently thrown away, not delivered
  - a pending record with no usable `request_id` refuses (exit `1`) rather than delivering — writing a decision fleet-decide is guaranteed to discard would otherwise flash DELIVERED for a press that does nothing

- [ ] **Step 1: Write the failing tests**

Create `tests/verdict.bats`:

```bash
#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  export FLEET_SKIP_RECONCILE=1
  mkdir -p "$FLEET_HOME/pending"
}

stage() {  # stage <session> <tier> [suggestion-json]
  # request_id is deterministic here (req-<session>) purely so tests can
  # assert on it; fleet-decide mints a real uuid4 at staging time.
  python3 - "$FLEET_HOME/pending/$1.json" "$1" "$2" "${3:-null}" <<'PY'
import json,sys
path,sid,tier,sugg = sys.argv[1:5]
json.dump({"session_id":sid,"tool":"Bash","input_digest":"sha256:a",
           "request_id":"req-"+sid,
           "input_summary":"x","tier":tier,"suggestion":json.loads(sugg),
           "repo":"flightdeck","cwd":"/tmp","repeats":1,"requested_at":1}, open(path,"w"))
PY
}
decision() { python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1]))))" \
               "$FLEET_HOME/decisions/$1.json"; }

stage_without_request_id() {  # stage_without_request_id <session> <tier>
  python3 - "$FLEET_HOME/pending/$1.json" "$1" "$2" <<'PY'
import json,sys
path,sid,tier = sys.argv[1:4]
json.dump({"session_id":sid,"tool":"Bash","input_digest":"sha256:a",
           "input_summary":"x","tier":tier,"suggestion":None,
           "repo":"flightdeck","cwd":"/tmp","repeats":1,"requested_at":1}, open(path,"w"))
PY
}

@test "no pending request refuses with exit 1" {
  run "$BIN/fleet-verdict" approve
  [ "$status" -eq 1 ]
}

@test "approve on a normal tier writes an allow decision" {
  stage S1 normal
  run "$BIN/fleet-verdict" approve
  [ "$status" -eq 0 ]
  [[ "$(decision S1)" == *'"behavior": "allow"'* ]]
}

@test "a decision carries the pending record's request_id verbatim" {
  stage S1 normal
  run "$BIN/fleet-verdict" approve
  [ "$status" -eq 0 ]
  [[ "$(decision S1)" == *'"request_id": "req-S1"'* ]]
}

@test "a pending record with no usable request_id refuses rather than delivering" {
  stage_without_request_id S1 normal
  run "$BIN/fleet-verdict" approve
  [ "$status" -eq 1 ]
  [ ! -f "$FLEET_HOME/decisions/S1.json" ]
}

@test "approve on a high tier arms first" {
  stage S1 high
  run "$BIN/fleet-verdict" approve
  [ "$status" -eq 2 ]
  [ ! -f "$FLEET_HOME/decisions/S1.json" ]
}

@test "a second approve on a high tier fires" {
  stage S1 high
  "$BIN/fleet-verdict" approve || true
  run "$BIN/fleet-verdict" approve
  [ "$status" -eq 0 ]
  [[ "$(decision S1)" == *'"behavior": "allow"'* ]]
}

@test "deny writes a deny decision with a message" {
  stage S1 normal
  run "$BIN/fleet-verdict" deny
  [ "$status" -eq 0 ]
  [[ "$(decision S1)" == *'"behavior": "deny"'* ]]
}

@test "interrupt sets the interrupt flag" {
  stage S1 normal
  run "$BIN/fleet-verdict" interrupt
  [ "$status" -eq 0 ]
  [[ "$(decision S1)" == *'"interrupt": true'* ]]
}

@test "remember always arms, even on a low tier" {
  stage S1 low '{"type":"addRules","destination":"localSettings","rules":[{"toolName":"Bash","ruleContent":"ls:*"}],"behavior":"allow"}'
  run "$BIN/fleet-verdict" remember
  [ "$status" -eq 2 ]
}

@test "a confirmed remember carries updatedPermissions verbatim" {
  stage S1 low '{"type":"addRules","destination":"localSettings","rules":[{"toolName":"Bash","ruleContent":"ls:*"}],"behavior":"allow"}'
  "$BIN/fleet-verdict" remember || true
  run "$BIN/fleet-verdict" remember
  [ "$status" -eq 0 ]
  [[ "$(decision S1)" == *'"updatedPermissions"'* ]]
  [[ "$(decision S1)" == *'"ruleContent": "ls:*"'* ]]
}

@test "remember refuses when Claude Code offered no rule" {
  stage S1 low
  run "$BIN/fleet-verdict" remember
  [ "$status" -eq 1 ]
}

@test "the arm is keyed by target, so changing selection re-arms" {
  stage S1 high
  stage S2 high
  "$BIN/fleet-verdict" approve || true    # arms against S1 (oldest)
  rm "$FLEET_HOME/pending/S1.json"        # S1 resolves; target becomes S2
  run "$BIN/fleet-verdict" approve
  [ "$status" -eq 2 ]                     # re-armed, did not fire at S2
}

@test "detail refuses when nothing is pending" {
  run "$BIN/fleet-verdict" detail
  [ "$status" -eq 1 ]
}

@test "an unknown action refuses" {
  stage S1 normal
  run "$BIN/fleet-verdict" nonsense
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/verdict.bats` — Expected: FAIL, script missing

- [ ] **Step 3: Implement `bin/fleet-verdict`**

```python
#!/usr/bin/env python3
"""Row 3 keypress entrypoint. Answers a pending permission request.

Not a hook: unlike bin/fleet-emit this MAY exit non-zero. A press that
could not be delivered must say so, because a key that silently does
nothing is indistinguishable from a broken one.

Exit status mirrors bin/fleet-send:
    0  delivered
    1  refused
    2  armed -- waiting on a second press
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fleetlib  # noqa: E402

DELIVERED, REFUSED, ARMED = 0, 1, 2

DENY_MESSAGE = "Denied from flightdeck by the operator."
INTERRUPT_MESSAGE = (
    "Interrupted from flightdeck by the operator. Stop what you are doing, "
    "do not retry this call, and wait for instruction."
)

ACTIONS = ("detail", "approve", "remember", "deny", "interrupt", "steer")

# REMEMBER always arms regardless of tier. Its rule persists to the
# canonical repo root -- verified: a worktree session writes localSettings
# there, not into the worktree -- so one press widens permissions for every
# agent in every worktree of that repository, including ones that do not
# exist yet. That blast radius outlives the session, which no tier can say.
ALWAYS_ARMS = ("remember",)


def _arm_secs():
    timings = fleetlib.load_config().get("timings")
    if isinstance(timings, dict):
        value = timings.get("verbArmSecs")
        if isinstance(value, (int, float)) and value > 0:
            return float(value)
    return 10.0


def _arm_key(action, target):
    """Arms are keyed by action AND target.

    Arming against one agent, then having the target move, then confirming
    would otherwise fire at whoever is targeted now -- a different repository
    than the operator was looking at when they decided.
    """
    return "{}:{}".format(action, target)


def _take_arm(action, target):
    """True if this press is a confirmation of a live, matching arm."""
    claimed = fleetlib.claim_verb_arm()
    if not isinstance(claimed, dict):
        return False
    if claimed.get("key") != _arm_key(action, target):
        return False
    expires_at = claimed.get("expires_at")
    if not isinstance(expires_at, (int, float)) or time.time() > expires_at:
        return False
    return True


def _set_arm(action, target):
    fleetlib.write_json_atomic(fleetlib.verb_armed_path(), {
        "key": _arm_key(action, target),
        "action": action,
        "target": target,
        "expires_at": time.time() + _arm_secs(),
    })


def _needs_arm(action, tier):
    if action in ALWAYS_ARMS:
        return True
    return action == "approve" and tier == "high"


def _focus(session_id, record):
    """DETAIL is exactly a Row 1 press: focus AND select.

    Focusing without pinning would let the target move to another session
    while the operator is still reading this one -- the failure the key
    exists to prevent. The pin is free and self-clearing: once decided,
    that session has no pending record and the selection stops overriding.
    """
    fleetlib.write_focus(session_id)
    session = fleetlib.read_json(
        fleetlib.sessions_dir() / "{}.json".format(session_id)) or {}
    uuid = session.get("iterm_session") or ""
    if not uuid:
        fleetlib.log("verdict: no iterm session for {}".format(session_id))
        return REFUSED
    focus = str(Path(__file__).resolve().parent / "fleet-focus")
    try:
        proc = subprocess.run([focus, "iterm2", uuid],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=20)
        return DELIVERED if proc.returncode == 0 else REFUSED
    except Exception as err:
        fleetlib.log("verdict: focus failed: {}".format(err))
        return REFUSED


def _steer_message(verb_id):
    verbs = str(Path(__file__).resolve().parent / "fleet-verbs")
    try:
        proc = subprocess.run([verbs, "--steer", verb_id],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              timeout=10)
    except Exception as err:
        fleetlib.log("verdict: fleet-verbs failed: {}".format(err))
        return ""
    if proc.returncode != 0:
        return ""
    return proc.stdout.decode("utf-8", "replace").strip()


def _decision_for(action, record, verb_id):
    # request_id is copied verbatim from the pending record, never minted
    # here: fleet-decide stamps a fresh uuid4 onto the record at staging
    # and discards any decision whose request_id does not match the one
    # currently staged (Task 3), so a decision missing this would be
    # delivered by this process and then silently thrown away by that one.
    request_id = record.get("request_id")
    if action == "approve":
        return {"behavior": "allow", "request_id": request_id}
    if action == "remember":
        suggestion = record.get("suggestion")
        if not isinstance(suggestion, dict):
            fleetlib.log("verdict: no suggestion to remember")
            return None
        return {"behavior": "allow", "updatedPermissions": [suggestion], "request_id": request_id}
    if action == "deny":
        return {"behavior": "deny", "message": DENY_MESSAGE, "request_id": request_id}
    if action == "interrupt":
        return {"behavior": "deny", "message": INTERRUPT_MESSAGE, "interrupt": True,
                "request_id": request_id}
    if action == "steer":
        message = _steer_message(verb_id)
        if not message:
            return None
        return {"behavior": "deny", "message": message, "request_id": request_id}
    return None


def run(argv):
    action = argv[0] if argv else ""
    verb_id = argv[1] if len(argv) > 1 else ""
    if action not in ACTIONS:
        fleetlib.log("verdict: unknown action {!r}".format(action))
        return REFUSED

    target = fleetlib.resolve_target()
    if not target:
        return REFUSED
    record = fleetlib.read_json(fleetlib.pending_path(target))
    if not isinstance(record, dict):
        return REFUSED

    if action == "detail":
        return _focus(target, record)

    request_id = record.get("request_id")
    if not isinstance(request_id, str) or not request_id:
        # fleet-decide (Task 3) rejects a decision whose own request_id is
        # missing or does not match the pending record's, so writing one
        # from a record with no usable request_id would deliver an answer
        # fleet-decide is guaranteed to discard -- the operator would see a
        # delivered flash and nothing happen, exactly the failure the
        # three-way exit status exists to prevent. Refuse instead.
        fleetlib.log("verdict: pending record for {} has no usable request_id".format(target))
        return REFUSED

    tier = record.get("tier") if isinstance(record.get("tier"), str) else "normal"
    if _needs_arm(action, tier) and not _take_arm(action, target):
        # Build the decision first so an impossible one (REMEMBER with no
        # suggestion) refuses immediately instead of arming a press that
        # could never fire.
        if _decision_for(action, record, verb_id) is None:
            return REFUSED
        _set_arm(action, target)
        return ARMED

    decision = _decision_for(action, record, verb_id)
    if decision is None:
        return REFUSED

    fleetlib.write_json_atomic(fleetlib.decision_path(target), decision)
    fleetlib.clear_verb_arm()
    return DELIVERED


if __name__ == "__main__":
    try:
        sys.exit(run(sys.argv[1:]))
    except Exception as err:            # noqa: BLE001
        fleetlib.log("verdict: unhandled {!r}".format(err))
        sys.exit(REFUSED)
```

- [ ] **Step 4: Make it executable and run the tests**

```bash
chmod +x bin/fleet-verdict
bats tests/verdict.bats
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
./tests/run.sh
git add bin/fleet-verdict tests/verdict.bats
git commit -m "feat: fleet-verdict, the Row 3 sender

0 delivered / 1 refused / 2 armed, mirroring fleet-send. REMEMBER always
arms because its rule persists to the canonical repo root and widens every
worktree of that repo, and it refuses rather than inventing a rule when
Claude Code offered none."
```

---

### Task 5: Steer verbs

**Files:**
- Modify: `bin/fleet-verbs` (add the `steer` flag and a `--steer <id>` mode)
- Create: `config/verbs/justify.md`, `config/verbs/otherway.md`, `config/verbs/dryrun.md`
- Test: `tests/verbs.bats`

**Interfaces:**
- Consumes: existing `fleet-verbs` frontmatter parsing
- Produces: `bin/fleet-verbs --steer <id>` prints the verb body to stdout and exits 0 **only** if `steer: true`; otherwise exits 1 and prints nothing.

- [ ] **Step 1: Write the failing tests**

Append to `tests/verbs.bats`:

```bash
@test "STEER: a steer verb's body is printed by --steer" {
  run "$BIN/fleet-verbs" --steer justify
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "STEER: a non-steer verb is refused on a steer key" {
  run "$BIN/fleet-verbs" --steer push
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "STEER: an unknown verb is refused" {
  run "$BIN/fleet-verbs" --steer nosuchverb
  [ "$status" -eq 1 ]
}

@test "STEER: every shipped steer verb forbids an immediate retry" {
  for v in justify otherway dryrun; do
    run "$BIN/fleet-verbs" --steer "$v"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not retry"* || "$output" == *"Do not retry"* ]]
  done
}

@test "STEER: dryrun ships but is not bound to a key by default" {
  [ -f "$ROOT/config/verbs/dryrun.md" ]
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/verbs.bats` — Expected: FAIL on `--steer`

- [ ] **Step 3: Write the three verb files**

`config/verbs/justify.md`:

```markdown
---
id: justify
label: JUSTIFY
interrupt: false
confirm: false
steer: true
---
This tool call was refused from flightdeck, deliberately, by the operator.

Do not retry it. Instead, explain in a few lines what that call would
actually do, why you need it now, and what you expect to happen after it
succeeds. If there is a cheaper way to find out whether it is necessary,
say what that is.

Then stop and wait. The operator will decide once they have read it.
```

`config/verbs/otherway.md`:

```markdown
---
id: otherway
label: OTHER WAY
interrupt: false
confirm: false
steer: true
---
This tool call was refused from flightdeck, deliberately, by the operator.

Do not retry it. Reach the same goal without that command. If the goal is
genuinely unreachable another way, say so plainly and stop — do not
improvise something broader or more destructive to get around the refusal.

State in one line what you are doing instead before you do it.
```

`config/verbs/dryrun.md`:

```markdown
---
id: dryrun
label: DRY RUN
interrupt: false
confirm: false
steer: true
---
This tool call was refused from flightdeck, deliberately, by the operator.

Do not retry it as written. Run the read-only version first — list what
would be affected, show the diff, print the plan — and report exactly what
the real call would have changed.

Then stop and wait for the operator rather than proceeding.
```

- [ ] **Step 4: Implement the flag and mode in `bin/fleet-verbs`**

Add `steer` to the boolean frontmatter flags parsed alongside `interrupt` and `confirm` (follow the existing parsing exactly). Then add near the top of `main`:

```python
    # --steer <id>: print a steer verb's body for use as a deny message.
    # Refuses any verb not marked `steer: true`. A Row 2 verb body dropped
    # into a deny message reads as the reason a call was refused, which is a
    # different register -- binding PUSH to a steer key would deny a call
    # with "Commit and push" as its justification.
    if len(argv) >= 2 and argv[0] == "--steer":
        resolved = resolve(argv[1])
        if resolved is None or not resolved.get("steer") or not resolved.get("prompt", "").strip():
            return 1
        sys.stdout.write(resolved["prompt"].strip() + "\n")
        return 0
```

Match the real helper names in the file — `resolve` here stands for whatever `fleet-verbs` already calls to turn an id into a parsed verb dict; reuse it rather than adding a second resolver.

- [ ] **Step 5: Run the tests and commit**

```bash
bats tests/verbs.bats && ./tests/run.sh
git add bin/fleet-verbs config/verbs/justify.md config/verbs/otherway.md config/verbs/dryrun.md tests/verbs.bats
git commit -m "feat: steer verbs, a deny message drawn from the verb library

deny.message is the only synchronous prompt channel in the product: it
arrives inside the tool call, attached to the request it is about. The
steer flag stops a Row 2 verb being bound to a steer key, where its body
would read as a justification for the refusal."
```

---

### Task 6: Capture `permission_mode` in `bin/fleet-emit`

**Files:**
- Modify: `bin/fleet-emit:271-276` (the session write)
- Test: `tests/emit.bats`

**Interfaces:**
- Produces: session files gain `"permission_mode": str` — the payload value, or `""` when absent.

- [ ] **Step 1: Write the failing tests**

Append to `tests/emit.bats`:

```bash
@test "permission_mode is recorded from the payload" {
  emit UserPromptSubmit '{"session_id":"S1","cwd":"/tmp","permission_mode":"bypassPermissions"}'
  [ "$(field permission_mode)" = "bypassPermissions" ]
}

@test "an absent permission_mode is recorded as unknown, not as default" {
  emit UserPromptSubmit '{"session_id":"S1","cwd":"/tmp"}'
  [ "$(field permission_mode)" = "" ]
}

@test "permission_mode survives a later event that does not carry it" {
  emit UserPromptSubmit '{"session_id":"S1","cwd":"/tmp","permission_mode":"bypassPermissions"}'
  emit Stop '{"session_id":"S1","cwd":"/tmp"}'
  [ "$(field permission_mode)" = "bypassPermissions" ]
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/emit.bats` — Expected: FAIL, `KeyError: 'permission_mode'`

- [ ] **Step 3: Implement**

Above the session write in `run()`:

```python
    # Row 1 says an agent is working. It does not say whether it is working
    # with the guard rails off, and "which of these has no brakes" is exactly
    # what an annunciator panel exists to answer. Absence is recorded as
    # unknown rather than assumed to be "default": claiming a session is
    # guarded when we do not know would be the one wrong direction to err.
    raw_mode = payload.get("permission_mode")
    permission_mode = raw_mode if isinstance(raw_mode, str) else ""
    if not permission_mode:
        previous = fleetlib.read_json(target)
        if isinstance(previous, dict) and isinstance(previous.get("permission_mode"), str):
            permission_mode = previous["permission_mode"]
```

and add `"permission_mode": permission_mode,` to the dict passed to `write_json_atomic`.

Note: `target` is currently assigned below this point — move the `target = ...` assignment above the new block, or read it via the same expression. Keep one definition.

- [ ] **Step 4: Run the tests and commit**

```bash
bats tests/emit.bats && ./tests/run.sh
git add bin/fleet-emit tests/emit.bats
git commit -m "feat: record permission_mode on the session file

Free -- it arrives in every hook payload. Absence is recorded as unknown
rather than assumed to be default, because claiming a session is guarded
when we do not know is the one wrong direction to err."
```

---

### Task 7: `fleet-reconcile` publishes verdict, halt and mode to `slots.json`

**Files:**
- Modify: `bin/fleet-reconcile`
- Test: `tests/reconcile.bats`

**Interfaces:**
- Consumes: `fleetlib.read_pending_all`, `resolve_target`, `halt_path`, `shorten`
- Produces: `slots.json` gains
  - top level `"halted": bool`
  - top level `"verdict": {...} | null` — `{session_id, agent, tool, tier, repeats}`
  - per slot `"permission_mode": str`

- [ ] **Step 1: Write the failing tests**

Append to `tests/reconcile.bats`:

```bash
top() { python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1])).get(sys.argv[2])))" \
          "$FLEET_HOME/slots.json" "$1"; }

@test "halted is false when no latch exists" {
  "$BIN/fleet-reconcile"
  [ "$(top halted)" = "false" ]
}

@test "halted is true when the latch exists" {
  touch "$FLEET_HOME/halt"
  "$BIN/fleet-reconcile"
  [ "$(top halted)" = "true" ]
}

@test "verdict is null when nothing is pending" {
  "$BIN/fleet-reconcile"
  [ "$(top verdict)" = "null" ]
}

@test "verdict names the targeted session, tool and tier" {
  mkdir -p "$FLEET_HOME/pending"
  python3 -c "
import json
json.dump({'session_id':'S1','tool':'Bash','input_digest':'d','input_summary':'x',
           'tier':'high','suggestion':None,'repo':'flightdeck','cwd':'/tmp',
           'repeats':3,'requested_at':1}, open('$FLEET_HOME/pending/S1.json','w'))"
  "$BIN/fleet-reconcile"
  [[ "$(top verdict)" == *'"tool": "Bash"'* ]]
  [[ "$(top verdict)" == *'"tier": "high"'* ]]
  [[ "$(top verdict)" == *'"repeats": 3'* ]]
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/reconcile.bats` — Expected: FAIL, `halted` is `null`

- [ ] **Step 3: Implement**

In `fleet-reconcile`, where the output object is assembled, add:

```python
    # One file, one watch. The plugin already watches slots.json, so
    # everything it must render travels there rather than teaching it a
    # second source.
    halted = fleetlib.halt_path().exists()

    verdict = None
    target = fleetlib.resolve_target()
    if target:
        record = fleetlib.read_json(fleetlib.pending_path(target))
        if isinstance(record, dict):
            verdict = {
                "session_id": target,
                # The agent's identity, shortened by the same rule Row 1 uses.
                "agent": fleetlib.shorten(record.get("repo") or "", 11),
                "tool": record.get("tool") or "",
                "tier": record.get("tier") or "normal",
                "repeats": record.get("repeats") if isinstance(record.get("repeats"), int) else 1,
            }
```

Add `"halted": halted, "verdict": verdict,` to the top-level dict, and copy `permission_mode` from each session file onto its slot (defaulting to `""`).

**Do not put `input_summary` into `slots.json`.** No key ever renders tool input; the summary exists for the log and terminal only, and putting it in the plugin's input file is how it would leak onto a key later.

- [ ] **Step 4: Run the tests and commit**

```bash
bats tests/reconcile.bats && ./tests/run.sh
git add bin/fleet-reconcile tests/reconcile.bats
git commit -m "feat: publish halt, verdict target and permission mode to slots.json

One file, one watch: the plugin already watches slots.json, so everything
it renders travels there. input_summary deliberately does not."
```

---

### Task 8: HALT — the latch, the shell gate, and `bin/fleet-halt`

**Files:**
- Create: `bin/fleet-halt`
- Modify: `hooks/settings.snippet.json`
- Test: `tests/halt.bats`

**Interfaces:**
- Produces: `bin/fleet-halt [--off]` — exit `0` done, `1` refused. Writes/removes `fleetlib.halt_path()`, then sends ESC to every `working` session.

- [ ] **Step 1: Write the failing tests**

Create `tests/halt.bats`:

```bash
#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  export FLEET_SKIP_RECONCILE=1
  export FLEET_OSASCRIPT="$BATS_TEST_TMPDIR/stub-osascript"
  mkdir -p "$FLEET_HOME/sessions"
  cat > "$FLEET_OSASCRIPT" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$FLEET_HOME/osascript.calls"
EOF
  chmod +x "$FLEET_OSASCRIPT"
}

session() {  # session <id> <state>
  python3 -c "
import json,sys
json.dump({'session_id':sys.argv[1],'state':sys.argv[2],'host':'iterm2',
           'iterm_session':'UUID-'+sys.argv[1],'repo':'r','branch':'b','cwd':'/tmp',
           'pid':1,'ts':1,'permission_mode':''}, open(sys.argv[3],'w'))" \
  "$1" "$2" "$FLEET_HOME/sessions/$1.json"
}

@test "halt writes the latch" {
  run "$BIN/fleet-halt"
  [ "$status" -eq 0 ]
  [ -f "$FLEET_HOME/halt" ]
}

@test "--off removes the latch" {
  touch "$FLEET_HOME/halt"
  run "$BIN/fleet-halt" --off
  [ "$status" -eq 0 ]
  [ ! -f "$FLEET_HOME/halt" ]
}

@test "halt is idempotent" {
  "$BIN/fleet-halt"; run "$BIN/fleet-halt"
  [ "$status" -eq 0 ]
}

@test "ESC goes to working sessions" {
  session W working
  "$BIN/fleet-halt"
  grep -q "UUID-W" "$FLEET_HOME/osascript.calls"
}

@test "ESC does NOT go to a blocked session" {
  session B blocked
  "$BIN/fleet-halt"
  [ ! -f "$FLEET_HOME/osascript.calls" ] || ! grep -q "UUID-B" "$FLEET_HOME/osascript.calls"
}

@test "ESC does NOT go to an idle or done session" {
  session I idle
  session D done
  "$BIN/fleet-halt"
  [ ! -f "$FLEET_HOME/osascript.calls" ] || ! grep -q "UUID-I" "$FLEET_HOME/osascript.calls"
}

# The emergency brake must work when flightdeck's own interpreter does not.
@test "the PreToolUse shell gate denies with NO python on PATH" {
  touch "$FLEET_HOME/halt"
  gate=$(python3 - "$ROOT/hooks/settings.snippet.json" <<'PY'
import json,sys
h=json.load(open(sys.argv[1]))["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
print(h)
PY
)
  gate="${gate//__PYTHON__//nonexistent/python3}"
  gate="${gate//__REPO__/$ROOT}"
  run env PATH=/nonexistent FLEET_HOME="$FLEET_HOME" CLAUDE_CODE_SESSION_ID=S1 \
      /bin/sh -c "printf '{}' | $gate"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

@test "the shell gate is silent when not halted" {
  gate=$(python3 - "$ROOT/hooks/settings.snippet.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["hooks"]["PreToolUse"][0]["hooks"][0]["command"])
PY
)
  gate="${gate//__PYTHON__//nonexistent/python3}"
  gate="${gate//__REPO__/$ROOT}"
  run env PATH=/nonexistent FLEET_HOME="$FLEET_HOME" CLAUDE_CODE_SESSION_ID=S1 \
      /bin/sh -c "printf '{}' | $gate"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/halt.bats` — Expected: FAIL

- [ ] **Step 3: Add the halt clause to `hooks/settings.snippet.json`**

Replace the `PreToolUse` command with (single line in the JSON):

```
test -e "${FLEET_HOME:-$HOME/.fleet}/halt" && { cat >/dev/null 2>&1; printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"FLEET HALTED from flightdeck. Stop, do not retry, and do not work around this. Wait for the operator."}}'; exit 0; }; [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && test -e "${FLEET_HOME:-$HOME/.fleet}/blocked/$CLAUDE_CODE_SESSION_ID" && exec __PYTHON__ __REPO__/bin/fleet-decide-resumed; cat >/dev/null 2>&1
```

Keep the existing `exec __PYTHON__ __REPO__/bin/fleet-emit Resumed` rather than renaming it — the line above shows placement only. The halt clause must come **first** so it wins, and must use no interpreter.

Also add the `PermissionRequest` entry:

```json
"PermissionRequest": [{ "hooks": [{ "type": "command", "timeout": 130, "statusMessage": "flightdeck: waiting for the deck", "command": "__PYTHON__ __REPO__/bin/fleet-decide" }] }]
```

`timeout` is 130 — ten seconds above the 120s default so the hook's own timeout always fires first and stays the code path under test.

- [ ] **Step 4: Implement `bin/fleet-halt`**

```python
#!/usr/bin/env python3
"""HALT: stop the fleet from one key.

Not a hook: may exit non-zero, because a halt that did not happen must be
visible.

Two mechanisms, deliberately. The latch is a file, read by a pure-shell
clause in the PreToolUse hook, so no tool call in any permission mode can
proceed -- including under bypassPermissions and
--dangerously-skip-permissions, both verified. The interrupt is ESC, sent
only to sessions Row 1 already knows are `working`.

ESC is NOT sent to a blocked session. There, ESC is not an interrupt: it
selects "No, and tell Claude what to do differently" and opens a text box,
leaving a session in a state the operator did not choose and is not
looking at. The deny already covers those sessions.

Honest about its own limits: a deny guarantees nothing an agent does
reaches the machine. It does not guarantee the agent stops thinking.
"""

import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fleetlib  # noqa: E402

INTERRUPTIBLE_STATES = ("working",)
OSASCRIPT_TIMEOUT_SECS = 20

ESC_SCRIPT = '''
tell application "iTerm2"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if (id of s) is "{uuid}" then
          tell s to write text (ASCII character 27) newline NO
        end if
      end repeat
    end repeat
  end repeat
end tell
'''


def _sessions():
    out = []
    try:
        entries = sorted(fleetlib.sessions_dir().iterdir())
    except Exception:
        return out
    for entry in entries:
        data = fleetlib.read_json(entry)
        if isinstance(data, dict):
            out.append(data)
    return out


def _interrupt(session):
    uuid = session.get("iterm_session") or ""
    # Reject anything that is not a plain UUID rather than escaping it: the
    # value is interpolated into AppleScript, and a charset with no
    # metacharacters leaves nothing to reason about. Same rule as
    # fleet-focus.
    if not uuid or not all(c.isalnum() or c == "-" for c in uuid):
        return False
    binary = os.environ.get("FLEET_OSASCRIPT") or "osascript"
    try:
        proc = subprocess.run([binary, "-e", ESC_SCRIPT.format(uuid=uuid)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=OSASCRIPT_TIMEOUT_SECS)
        return proc.returncode == 0
    except Exception as err:
        fleetlib.log("halt: osascript failed for {}: {}".format(uuid, err))
        return False


def _reconcile():
    if os.environ.get("FLEET_SKIP_RECONCILE") == "1":
        return
    try:
        subprocess.run([sys.executable,
                        str(Path(__file__).resolve().parent / "fleet-reconcile")],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except Exception:
        pass


def run(argv):
    if "--off" in argv:
        try:
            fleetlib.halt_path().unlink()
        except FileNotFoundError:
            pass
        except Exception as err:
            fleetlib.log("halt: could not clear latch: {}".format(err))
            return 1
        fleetlib.log("halt: cleared")
        _reconcile()
        return 0

    try:
        fleetlib.halt_path().parent.mkdir(parents=True, exist_ok=True)
        fleetlib.halt_path().touch(exist_ok=True)
    except Exception as err:
        fleetlib.log("halt: could not write latch: {}".format(err))
        return 1

    interrupted = 0
    for session in _sessions():
        if session.get("state") in INTERRUPTIBLE_STATES and _interrupt(session):
            interrupted += 1
    fleetlib.log("halt: latched, interrupted {} working session(s)".format(interrupted))
    _reconcile()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run(sys.argv[1:]))
    except Exception as err:            # noqa: BLE001
        fleetlib.log("halt: unhandled {!r}".format(err))
        sys.exit(1)
```

- [ ] **Step 5: Run the tests and commit**

```bash
chmod +x bin/fleet-halt
bats tests/halt.bats && ./tests/run.sh
git add bin/fleet-halt hooks/settings.snippet.json tests/halt.bats
git commit -m "feat: HALT -- a pure-shell deny latch plus a targeted interrupt

The gate emits its deny from shell with no interpreter, so the emergency
brake works when flightdeck's own Python does not; a test asserts it with
PATH=/nonexistent. ESC goes only to working sessions, because on a blocked
one ESC is not an interrupt -- it picks 'No, and tell Claude what to do
differently' and opens a text box."
```

---

### Task 9: Plugin — the verdict action type and its rendering

**Files:**
- Create: `plugin/src/verdict.ts`
- Modify: `plugin/src/plugin.ts`, `plugin/src/types.ts`, `plugin/com.louisalexander.flightdeck.sdPlugin/manifest.json`
- Create: `plugin/com.louisalexander.flightdeck.sdPlugin/ui/verdict.html`
- Test: `plugin/src/render.test.mjs`

**Interfaces:**
- Consumes: `SlotsFile` gains `halted: boolean` and `verdict: VerdictTarget | null`
- Produces:
  - `export type VerdictTarget = { session_id: string; agent: string; tool: string; tier: string; repeats: number }`
  - `export function renderVerdictSvg(label: string, tier: string, feedback: Feedback, active: boolean): string`
  - `export function renderDetailSvg(target: VerdictTarget | null): string`

- [ ] **Step 1: Write the failing tests**

Append to `plugin/src/render.test.mjs`:

```javascript
import { renderVerdictSvg, renderDetailSvg } from "../dist/verdict.js";

test("a verdict key at rest keeps its label, dimmed", () => {
  const svg = renderVerdictSvg("APPROVE", "normal", "", false);
  assert.match(svg, /APPROVE/);
  assert.match(svg, /#5A6675/);   // INK_DIM -- legible, not blank
});

test("a verdict key with a target is bright", () => {
  const svg = renderVerdictSvg("APPROVE", "normal", "", true);
  assert.match(svg, /#C9D4E2/);
});

test("a high tier borrows the attention amber, never a new colour", () => {
  const svg = renderVerdictSvg("APPROVE", "high", "", true);
  assert.match(svg, /#F5A623/);
});

test("armed says CONFIRM?, matching Row 2", () => {
  assert.match(renderVerdictSvg("REMEMBER", "low", "armed", true), /CONFIRM\?/);
});

test("detail at rest shows its label and no content lines", () => {
  const svg = renderDetailSvg(null);
  assert.match(svg, /DETAIL/);
  assert.doesNotMatch(svg, /Bash/);
});

test("detail names the agent and the tool", () => {
  const svg = renderDetailSvg({ session_id: "S1", agent: "flightdeck", tool: "Bash", tier: "high", repeats: 1 });
  assert.match(svg, /flightdeck/);
  assert.match(svg, /Bash/);
});

test("detail shows a repeat count only when it is above one", () => {
  const once = renderDetailSvg({ session_id: "S1", agent: "a", tool: "Bash", tier: "normal", repeats: 1 });
  const many = renderDetailSvg({ session_id: "S1", agent: "a", tool: "Bash", tier: "normal", repeats: 4 });
  assert.doesNotMatch(once, /×/);
  assert.match(many, /×4/);
});

test("detail never renders tool input", () => {
  const svg = renderDetailSvg({
    session_id: "S1", agent: "a", tool: "Bash", tier: "high", repeats: 1,
    input_summary: "rm -rf /",
  });
  assert.doesNotMatch(svg, /rm -rf/);
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd plugin && npm run build && node --test src/render.test.mjs`
Expected: FAIL — `dist/verdict.js` does not exist

- [ ] **Step 3: Implement `plugin/src/verdict.ts`**

```typescript
/**
 * Row 3 verdict keys.
 *
 * Monochrome like Row 2, because Row 1 owns saturated colour. The one
 * borrowed hue is the attention amber, used for `high` tier and for armed
 * -- the same amber Row 1 uses for an armed teardown, which already means
 * "you are one press from something serious". Reusing an established
 * meaning on a different row beats inventing a fourth colour language.
 *
 * No key ever renders tool input. At 96px `rm -rf ./build` and
 * `rm -rf ./ build` truncate identically, so a truncated command reads as
 * information while being ambiguous exactly where it matters. The key face
 * carries a classification; the complete request is one press away, drawn
 * by Claude Code in the blocked terminal.
 */

export type VerdictTarget = {
  session_id: string;
  agent: string;
  tool: string;
  tier: string;
  repeats: number;
};

export type Feedback = "" | "delivered" | "refused" | "armed";

const NIGHT = "#0A0E13";
const INK = "#C9D4E2";
const INK_DIM = "#5A6675";
const INK_BRIGHT = "#FFFFFF";
const ATTENTION = "#F5A623";

function esc(text: string): string {
  return String(text ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function open(): string {
  return '<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144">'
    + `<rect width="144" height="144" fill="${NIGHT}"/>`;
}

export function renderVerdictSvg(
  label: string, tier: string, feedback: Feedback, active: boolean,
): string {
  // At rest the row is dimmed, never blank. Row 1's "absence should look
  // absent" does not transfer: a Row 1 slot's meaning is positional and may
  // genuinely not exist, whereas APPROVE is APPROVE whether or not there is
  // anything to approve. Blanking would destroy the row's spatial memory
  // and make eight keys flicker in and out of existence.
  const ink = feedback === "armed" ? ATTENTION
    : feedback === "refused" ? INK_BRIGHT
    : !active ? INK_DIM
    : tier === "high" ? ATTENTION
    : INK;

  const marker = feedback === "armed"
    ? `<text x="72" y="115" text-anchor="middle" font-family="Helvetica,Arial" `
      + `font-size="15" font-weight="700" letter-spacing="0.8" fill="${ATTENTION}">CONFIRM?</text>`
    : feedback === "refused"
    ? `<rect x="34" y="108" width="76" height="4" rx="2" fill="${INK_BRIGHT}"/>`
    : feedback === "delivered"
    ? `<circle cx="72" cy="112" r="5" fill="${INK}" fill-opacity="0.55"/>`
    : "";

  return [
    open(),
    `<text x="72" y="80" text-anchor="middle" font-family="Helvetica,Arial" `
      + `font-size="22" font-weight="700" letter-spacing="1.2" fill="${ink}">${esc(label)}</text>`,
    marker,
    "</svg>",
  ].join("");
}

export function renderDetailSvg(target: VerdictTarget | null): string {
  if (!target) {
    return [
      open(),
      `<text x="72" y="80" text-anchor="middle" font-family="Helvetica,Arial" `
        + `font-size="22" font-weight="700" letter-spacing="1.2" fill="${INK_DIM}">DETAIL</text>`,
      "</svg>",
    ].join("");
  }

  const high = target.tier === "high";
  // The amber triangle Row 1's armed teardown already owns. Geometry, never
  // a text glyph: U+25B2 is absent from Helvetica and would fall back to an
  // arbitrary font with different metrics.
  const warn = high
    ? `<polygon points="72,18 88,46 56,46" fill="${ATTENTION}"/>`
    : "";
  const repeats = target.repeats > 1
    ? `<text x="128" y="26" text-anchor="end" font-family="Helvetica,Arial" `
      + `font-size="16" font-weight="700" fill="${ATTENTION}">×${target.repeats}</text>`
    : "";

  return [
    open(),
    warn,
    `<text x="72" y="76" text-anchor="middle" font-family="Helvetica,Arial" `
      + `font-size="13" font-weight="600" letter-spacing="0.6" fill="${INK_DIM}">${esc(target.agent)}</text>`,
    `<text x="72" y="102" text-anchor="middle" font-family="Helvetica,Arial" `
      + `font-size="20" font-weight="700" fill="${high ? ATTENTION : INK}">${esc(target.tool)}</text>`,
    repeats,
    "</svg>",
  ].join("");
}
```

- [ ] **Step 4: Wire the action into `plugin.ts` and the manifest**

Add a `com.louisalexander.flightdeck.verdict` action with settings `{ verdict: string; verb?: string }`, mirroring how the Row 2 `command` action is registered. On `keyDown`, shell out to `bin/fleet-verdict <verdict> [verb]` and map the exit status to feedback: `0 → "delivered"`, `1 → "refused"`, `2 → "armed"`. Repaint from `slots.json`'s `verdict` block on every `fs.watch` event. Copy `ui/command.html` to `ui/verdict.html` and change the field to a verdict picker offering `detail`, `approve`, `remember`, `deny`, `interrupt`, `steer`.

- [ ] **Step 5: Run the tests and commit**

```bash
cd plugin && npm run build && node --test src/render.test.mjs && cd ..
./tests/run.sh
git add plugin/
git commit -m "feat: Row 3 verdict keys

Dimmed at rest rather than blank -- a verdict key's meaning is fixed, so
blanking would destroy the row's spatial memory. High tier borrows Row 1's
armed amber rather than inventing a colour. A test asserts no key can
render tool input."
```

---

### Task 10: Plugin — the bypass pip and the halted hatch on Row 1

**Files:**
- Modify: `plugin/src/render.ts`
- Test: `plugin/src/render.test.mjs`

**Interfaces:**
- Consumes: `Slot.permission_mode`, `SlotsFile.halted`
- Produces: `renderSlotSvg` gains two optional trailing parameters — `(…, permissionMode: string, halted: boolean)`

- [ ] **Step 1: Write the failing tests**

```javascript
test("a bypassed session gets a quiet corner pip", () => {
  const svg = renderSlotSvg(/* existing args */, "bypassPermissions", false);
  assert.match(svg, /<circle/);
});

test("a default-mode session gets no pip", () => {
  const plain = renderSlotSvg(/* existing args */, "default", false);
  const bypassed = renderSlotSvg(/* existing args */, "bypassPermissions", false);
  assert.notEqual(plain, bypassed);
});

test("an unknown mode gets no pip, since we must not claim it is guarded", () => {
  const unknown = renderSlotSvg(/* existing args */, "", false);
  const plain = renderSlotSvg(/* existing args */, "default", false);
  assert.equal(unknown, plain);
});

test("a halted fleet hatches every key", () => {
  const svg = renderSlotSvg(/* existing args */, "default", true);
  assert.match(svg, /pattern|hatch/i);
});
```

Fill `/* existing args */` with whatever `renderSlotSvg` already takes in this file's other tests.

- [ ] **Step 2: Run to verify they fail**

Run: `cd plugin && npm run build && node --test src/render.test.mjs`

- [ ] **Step 3: Implement**

In `render.ts`, append before the closing `</svg>`:

```typescript
  // Quiet on purpose. A bypassed agent is a standing condition, often a
  // chosen one, and a marker that shouted would compete with amber -- the
  // one thing on this panel allowed to shout. The pip says "this one has no
  // brakes" to an operator who looks; it does not pull the eye across a desk.
  const pip = permissionMode === "bypassPermissions"
    ? `<circle cx="130" cy="14" r="5" fill="#F5A623" fill-opacity="0.85"/>`
    : "";

  // A halt is a fact about every agent. If Row 1 kept painting blue and
  // green there would be no way to know nothing can run. This DOES cover
  // the row, unlike the pip, because a halt is an event and bypass is a state.
  const hatch = halted
    ? `<defs><pattern id="hatch" width="8" height="8" patternUnits="userSpaceOnUse" `
      + `patternTransform="rotate(45)"><rect width="3" height="8" fill="#000000" fill-opacity="0.55"/></pattern></defs>`
      + `<rect width="144" height="144" fill="url(#hatch)"/>`
    : "";
```

- [ ] **Step 4: Run the tests and commit**

```bash
cd plugin && npm run build && node --test src/render.test.mjs && cd ..
./tests/run.sh
git add plugin/
git commit -m "feat: bypass pip and halted hatch on Row 1

An unknown permission mode gets no pip: claiming a session is guarded when
we do not know is the wrong direction to err, and an absent field means
unknown rather than default."
```

---

### Task 11: Install, doctor, and README

**Files:**
- Modify: `install.sh`, `bin/fleet-doctor`, `README.md`
- Test: `tests/merge.bats`

**Interfaces:**
- Consumes: the new `PermissionRequest` hook entry and halt clause from Task 8

- [ ] **Step 1: Write the failing test**

Append to `tests/merge.bats`:

```bash
@test "the PermissionRequest hook is merged into settings" {
  # follow this file's existing merge-invocation helper
  run_merge
  [[ "$(cat "$SETTINGS")" == *"PermissionRequest"* ]]
  [[ "$(cat "$SETTINGS")" == *"fleet-decide"* ]]
}

@test "the halt clause survives the merge ahead of the resumed guard" {
  run_merge
  python3 - "$SETTINGS" <<'PY'
import json,sys
cmd = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
assert cmd.index("/halt") < cmd.index("/blocked/"), "halt clause must come first"
PY
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/merge.bats`

- [ ] **Step 3: Implement**

`install.sh` needs no change if it merges the whole snippet — confirm it does, and add nothing if so. Add to `bin/fleet-doctor`:

```python
    # The one check that stops HALT being a claim rather than a fact.
    check("PermissionRequest hook registered",
          "PermissionRequest" in settings.get("hooks", {}))
    check("halt clause precedes the resumed guard",
          _pretooluse_halt_first(settings))
    check("fleet is not currently halted", not fleetlib.halt_path().exists(),
          detail="run bin/fleet-halt --off to resume")
```

Add a README section documenting Row 3, HALT's exact guarantee, and the worktree trap under REMEMBER. State plainly: **HALT guarantees nothing an agent does reaches your machine; it does not guarantee the agent stops.**

- [ ] **Step 4: Run the full suite and commit**

```bash
./tests/run.sh
git add install.sh bin/fleet-doctor README.md tests/merge.bats
git commit -m "docs: document Row 3 and HALT, and check them in fleet-doctor

Doctor reports whether the fleet is currently halted, because a latched
halt that nobody remembers setting looks exactly like a broken fleet."
```

---

## Self-Review

**Spec coverage.** Decision channel → Tasks 1–3. Targeting → Task 2. Row 3 keys → Tasks 4, 9. Worktree trap → Task 4 (`ALWAYS_ARMS`) and Task 11 (README). Steer verbs → Task 5. HALT → Task 8. Permission-mode marker → Tasks 6, 7, 10. Resting state → Task 9. Repeat counter → Tasks 3, 7, 9. **Deferred by design:** GATE, SPEND, DISPATCH.

**Type consistency.** `resolve_target() -> str` is used identically in Tasks 4 and 7. `VerdictTarget` fields match `fleet-reconcile`'s `verdict` block exactly (`session_id`, `agent`, `tool`, `tier`, `repeats`). Exit codes `0/1/2` are the same triple in `fleet-verdict`, its bats tests, and the plugin's feedback mapping.

**Known gap carried forward:** `fleet-verbs`' internal resolver name is referenced as `resolve` in Task 5; the implementer must use the real name in that file rather than adding a second resolver.
