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
