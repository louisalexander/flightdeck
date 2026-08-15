#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  export FLEET_DECIDE_POLL_SECS=0.02
  export FLEET_DECIDE_TIMEOUT_SECS=1
  export FLEET_SKIP_RECONCILE=1
  mkdir -p "$FLEET_HOME"
  PAYLOAD='{"session_id":"S1","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"rm -rf ./build"},"permission_suggestions":[{"type":"addRules","destination":"localSettings","rules":[{"toolName":"Bash","ruleContent":"rm:*"}],"behavior":"allow"}]}'
}

decide() { printf '%s' "${1:-$PAYLOAD}" | "$BIN/fleet-decide"; }
pending() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" \
              "$FLEET_HOME/pending/S1.json" "$1"; }

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
