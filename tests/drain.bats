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
  # The distinguishing assertion: the entry survives un-drained. Without
  # this, deleting the drain feature entirely would still pass this test.
  [ -e "$FLEET_HOME/queue/S1.json" ]
}

@test "a queued verb for another session is not drained by this one" {
  python3 -c "
import json
json.dump({'verb':'test','prompt':'X','verb_path':'','queued_at':1},
          open('$FLEET_HOME/queue/OTHER.json','w'))"
  run emit Stop
  [ -z "$output" ]
  [ -e "$FLEET_HOME/queue/OTHER.json" ]
  # Not just present but intact and unclaimed -- proves isolation, not
  # merely that some file with this name still exists.
  run python3 -c "
import json
print(json.load(open('$FLEET_HOME/queue/OTHER.json'))['prompt'])"
  [ "$output" = "X" ]
}

@test "a malformed queue entry is discarded, never emitted as a block" {
  printf 'not json' > "$FLEET_HOME/queue/S1.json"
  run emit Stop
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(state)" = "done" ]
  [ ! -e "$FLEET_HOME/queue/S1.json" ]
}
