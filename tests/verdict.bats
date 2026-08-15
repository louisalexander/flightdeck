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
  #
  # requested_at is stamped to "now", not a fixed epoch literal: fleetlib's
  # read_pending_all() (used by fleet-verdict's resolve_target()) silently
  # drops any pending record older than timings.pendingTtlSecs (300s
  # default) -- that TTL is load-bearing production behaviour, proven dead
  # for a leaked record from a killed fleet-decide, not a test artifact to
  # route around. A literal old timestamp here would make every staged
  # fixture instantly stale and resolve_target() would return "" for
  # every test in this file regardless of what fleet-verdict does, which
  # is not the property any of these tests are trying to assert.
  python3 - "$FLEET_HOME/pending/$1.json" "$1" "$2" "${3:-null}" <<'PY'
import json,sys,time
path,sid,tier,sugg = sys.argv[1:5]
json.dump({"session_id":sid,"tool":"Bash","input_digest":"sha256:a",
           "request_id":"req-"+sid,
           "input_summary":"x","tier":tier,"suggestion":json.loads(sugg),
           "repo":"flightdeck","cwd":"/tmp","repeats":1,
           "requested_at":int(time.time())}, open(path,"w"))
PY
}
decision() { python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1]))))" \
               "$FLEET_HOME/decisions/$1.json"; }

stage_without_request_id() {  # stage_without_request_id <session> <tier>
  # Same requested_at fix as stage() above, same reason.
  python3 - "$FLEET_HOME/pending/$1.json" "$1" "$2" <<'PY'
import json,sys,time
path,sid,tier = sys.argv[1:4]
json.dump({"session_id":sid,"tool":"Bash","input_digest":"sha256:a",
           "input_summary":"x","tier":tier,"suggestion":None,
           "repo":"flightdeck","cwd":"/tmp","repeats":1,
           "requested_at":int(time.time())}, open(path,"w"))
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
  [[ "$(decision S1)" == *'"behavior": "allow"'* ]] || return 1
}

@test "a decision carries the pending record's request_id verbatim" {
  stage S1 normal
  run "$BIN/fleet-verdict" approve
  [ "$status" -eq 0 ]
  [[ "$(decision S1)" == *'"request_id": "req-S1"'* ]] || return 1
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
  [[ "$(decision S1)" == *'"behavior": "allow"'* ]] || return 1
}

@test "deny writes a deny decision with a message" {
  stage S1 normal
  run "$BIN/fleet-verdict" deny
  [ "$status" -eq 0 ]
  [[ "$(decision S1)" == *'"behavior": "deny"'* ]] || return 1
}

@test "interrupt sets the interrupt flag" {
  stage S1 normal
  run "$BIN/fleet-verdict" interrupt
  [ "$status" -eq 0 ]
  [[ "$(decision S1)" == *'"interrupt": true'* ]] || return 1
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
  [[ "$(decision S1)" == *'"updatedPermissions"'* ]] || return 1
  [[ "$(decision S1)" == *'"ruleContent": "ls:*"'* ]] || return 1
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

# --- round-1 review fixes ---------------------------------------------------

@test "C1: the arm is keyed by request_id too, so a new request for the same session re-arms" {
  stage S1 high
  "$BIN/fleet-verdict" approve || true    # arms "approve:S1:req-S1"
  # req-S1 resolves (e.g. the operator answered the dialog manually in the
  # terminal) and a NEW request is staged for the same session, with its own
  # fresh request_id -- fleet-decide mints one per request, not per session.
  python3 - "$FLEET_HOME/pending/S1.json" <<'PY'
import json,sys
path = sys.argv[1]
record = json.load(open(path))
record["request_id"] = "req-S1-v2"
json.dump(record, open(path, "w"))
PY
  run "$BIN/fleet-verdict" approve
  [ "$status" -eq 2 ]                     # re-armed against the new request, did not fire
  [ ! -f "$FLEET_HOME/decisions/S1.json" ]
}

@test "I1: a Row 2 verb arm and a Row 3 verdict arm live in separate files and do not consume each other" {
  stage S1 high
  # A live Row 2 confirm-verb arm, in fleet-send's own file and shape --
  # simulated directly rather than driving fleet-send end to end, since that
  # needs a configured verb, a live session record and a stubbed osascript
  # that tests/send.bats already exercises in full; what this test isolates
  # is purely whether the two arm files interfere.
  python3 - "$FLEET_HOME/armed-verb.json" <<'PY'
import json,sys,time
json.dump({"verb":"issue","session_id":"S1","expires": int(time.time())+30},
           open(sys.argv[1], "w"))
PY
  run "$BIN/fleet-verdict" approve
  [ "$status" -eq 2 ]                        # verdict arms on its own file
  [ -f "$FLEET_HOME/armed-verb.json" ]       # Row 2's arm is untouched
  [ -f "$FLEET_HOME/armed-verdict.json" ]    # verdict has its own arm file

  # Confirming (which fires and clears the verdict arm) must not touch the
  # still-live Row 2 arm either.
  run "$BIN/fleet-verdict" approve
  [ "$status" -eq 0 ]
  [ -f "$FLEET_HOME/armed-verb.json" ]
  [ ! -f "$FLEET_HOME/armed-verdict.json" ]
}

@test "I2: detail pins the selection to the target and writes no decision" {
  stage S1 normal
  run "$BIN/fleet-verdict" detail
  # Single-bracket here: this repo's bash is 3.2.57, where set -e does not
  # apply to a double-bracket compound in a non-final position, so a failing
  # double-bracket assertion here would have been silently swallowed and this
  # test would pass even with write_focus() deleted from _focus -- exactly
  # what round-2 review found and reproduced. Single-bracket has no such
  # exemption, and the repo-wide `|| return 1` convention (tests/run.sh)
  # now closes the same hole for double-bracket assertions too.
  [ "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['session_id'])" "$FLEET_HOME/focus.json")" = "S1" ]
  [ ! -f "$FLEET_HOME/decisions/S1.json" ]
}

@test "I3: the arm is keyed by action too, so a different action does not consume it" {
  stage S1 high '{"type":"addRules","destination":"localSettings","rules":[{"toolName":"Bash","ruleContent":"ls:*"}],"behavior":"allow"}'
  "$BIN/fleet-verdict" approve || true     # arms "approve:S1:req-S1"
  run "$BIN/fleet-verdict" remember        # different action -- must re-arm, not fire
  [ "$status" -eq 2 ]
  [ ! -f "$FLEET_HOME/decisions/S1.json" ]
}

# --- HALT disarms the allow half of Row 3 -----------------------------------
#
# The PreToolUse latch cannot cover the request Row 3 is targeting: that call
# already passed PreToolUse and is now sitting in PermissionRequest, so an
# allow written from here runs with the brake on. Reproduced before the guard
# existed -- stage high, halt, press APPROVE twice, and the allow landed.

@test "HALT: approve refuses while the fleet is halted, and arms nothing" {
  stage S1 normal
  touch "$FLEET_HOME/halt"
  run "$BIN/fleet-verdict" approve
  [ "$status" -eq 1 ]
  [ ! -f "$FLEET_HOME/decisions/S1.json" ]
  [ ! -f "$FLEET_HOME/armed-verdict.json" ]
}

@test "HALT: a second approve press cannot deliver an allow either" {
  stage S1 high
  touch "$FLEET_HOME/halt"
  "$BIN/fleet-verdict" approve || true
  run "$BIN/fleet-verdict" approve
  [ "$status" -eq 1 ]
  [ ! -f "$FLEET_HOME/decisions/S1.json" ]
}

@test "HALT: an arm raised before the latch cannot be confirmed after it" {
  stage S1 high
  "$BIN/fleet-verdict" approve || true      # armed while the fleet was running
  [ -f "$FLEET_HOME/armed-verdict.json" ]
  touch "$FLEET_HOME/halt"
  run "$BIN/fleet-verdict" approve
  [ "$status" -eq 1 ]
  [ ! -f "$FLEET_HOME/decisions/S1.json" ]
}

@test "HALT: remember refuses while the fleet is halted" {
  stage S1 low '{"type":"addRules","destination":"localSettings","rules":[{"toolName":"Bash","ruleContent":"ls:*"}],"behavior":"allow"}'
  touch "$FLEET_HOME/halt"
  run "$BIN/fleet-verdict" remember
  [ "$status" -eq 1 ]
  [ ! -f "$FLEET_HOME/decisions/S1.json" ]
}

# Deny, interrupt and steer are the safe direction and must keep working: an
# operator who has just hit the brake may well want to send one, and they
# release an agent the latch would otherwise leave hanging.

@test "HALT: deny still delivers while the fleet is halted" {
  stage S1 normal
  touch "$FLEET_HOME/halt"
  run "$BIN/fleet-verdict" deny
  [ "$status" -eq 0 ]
  [[ "$(decision S1)" == *'"behavior": "deny"'* ]] || return 1
}

@test "HALT: interrupt still delivers while the fleet is halted" {
  stage S1 normal
  touch "$FLEET_HOME/halt"
  run "$BIN/fleet-verdict" interrupt
  [ "$status" -eq 0 ]
  [[ "$(decision S1)" == *'"interrupt": true'* ]] || return 1
}

@test "HALT: steer still delivers while the fleet is halted" {
  stage S1 normal
  touch "$FLEET_HOME/halt"
  run "$BIN/fleet-verdict" steer justify
  [ "$status" -eq 0 ]
  [[ "$(decision S1)" == *'"behavior": "deny"'* ]] || return 1
}

# --- REACHABLE: ui/verdict.html mirrors what it must offer -----------------
#
# tests/verbs.bats gained its REACHABLE test because FORK shipped valid and
# working but absent from ui/command.html, so no key could ever be bound to
# it -- see commit 09c1b31. ui/verdict.html hardcodes two lists of its own:
# fleet-verdict's ACTIONS tuple, and the property-inspector's steer-verb
# picker. Nothing asserted either mirror stayed true, so a fourth action or
# steer verb could ship and silently be unreachable from Row 3. Both are
# read from their real source -- ACTIONS out of this script, steer verbs out
# of config/verbs/*.md's frontmatter -- rather than duplicated as a second
# hardcoded list here, which would only move the drift risk, not close it.

@test "REACHABLE: every fleet-verdict action appears in the property inspector" {
  local pi="$ROOT/plugin/com.louisalexander.flightdeck.sdPlugin/ui/verdict.html"
  local actions
  actions="$(python3 -c "
import re
text = open('$BIN/fleet-verdict').read()
m = re.search(r'ACTIONS = \(([^)]*)\)', text)
print(' '.join(re.findall(r'\"([a-z]+)\"', m.group(1))))
")"
  [ -n "$actions" ] || { echo "could not parse ACTIONS out of fleet-verdict"; false; }
  local missing=""
  for action in $actions; do
    grep -q "value=\"$action\"" "$pi" || missing="$missing $action"
  done
  [ -z "$missing" ] || { echo "not offered in the verdict picker:$missing"; false; }
}

@test "REACHABLE: every steer verb appears in the property inspector's steer-verb picker" {
  local pi="$ROOT/plugin/com.louisalexander.flightdeck.sdPlugin/ui/verdict.html"
  local missing=""
  for f in "$ROOT"/config/verbs/*.md; do
    grep -q "^steer: true$" "$f" || continue
    local id
    id="$(basename "$f" .md)"
    grep -q "value=\"$id\"" "$pi" || missing="$missing $id"
  done
  [ -z "$missing" ] || { echo "not offered in the steer-verb picker:$missing"; false; }
}
