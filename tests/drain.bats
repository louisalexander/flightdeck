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

# FIX 6 (fix wave, 2026-08-14): this test used to pin the OPPOSITE
# behaviour -- that stop_hook_active suppressed draining, as a loop
# backstop. That gate stranded verbs: press TEST while working, Stop
# blocks, the agent continues into TEST, a second verb gets pressed
# during that continuation, and the Stop ending IT carries
# stop_hook_active -- so the old gate skipped the drain, the session went
# idle, and no further Stop was ever coming to retry it. The queued verb
# sat forever having flashed "queued".
#
# The actual loop guard is drain-before-block (see fleet-emit): the queue
# entry is removed before the block is returned, so an empty queue on the
# very next Stop -- re-fired or not -- yields claim_queue() is None and no
# block. stop_hook_active is not load-bearing for correctness, so this
# test now asserts the corrected intent: a verb staged during a
# continuation IS drained, regardless of stop_hook_active.
@test "a verb staged during a stop_hook_active continuation is still drained" {
  queue
  run emit Stop '{"session_id":"S1","cwd":"/tmp","stop_hook_active":true}'
  [ "$status" -eq 0 ]
  run python3 -c "
import json,sys
d=json.loads('''$output''')
print(d['decision'], d['reason'])"
  [ "$output" = "block RUN THE TESTS" ]
  [ ! -e "$FLEET_HOME/queue/S1.json" ]
  [ "$(state)" = "working" ]
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

# --- an expired entry is discarded, never delivered ------------------------
#
# A confirm verb queued against a busy agent carries an expiry, so it cannot
# fire long after the operator stopped watching -- the exact outcome the
# never-queue rule originally existed to prevent. The drain is where that is
# enforced, because it is the only place that runs at delivery time.

expiring_queue() {
  python3 -c "
import json
json.dump({'verb':'issue','prompt':'FILE THE ISSUE','verb_path':'/v/issue.md',
           'queued_at':1,'expires_at':$1}, open('$FLEET_HOME/queue/S1.json','w'))"
}

@test "TTL: an expired entry is discarded without blocking the Stop" {
  expiring_queue 1
  run emit Stop
  [ "$status" -eq 0 ]
  [ -z "$output" ]                            # no block emitted
  [ ! -e "$FLEET_HOME/queue/S1.json" ]        # and not left to fire later
  [ "$(state)" = "done" ]
}

@test "TTL: an unexpired entry still delivers" {
  expiring_queue 99999999999
  run emit Stop
  run python3 -c "
import json;print(json.loads('''$output''')['reason'])"
  [ "$output" = "FILE THE ISSUE" ]
}

@test "TTL: an entry with no expiry is unaffected and still delivers" {
  queue
  run emit Stop
  [[ "$output" == *"RUN THE TESTS"* ]] || return 1
}
