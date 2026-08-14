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
  [ ! -e "$(queued)" ]
}

# Sequential, not concurrent: this proves the already-claimed case (a
# second call finds the entry gone) but does not exercise an actual race
# between simultaneous claimants. That race is covered by
# tests/test_fleetlib.py's ThreadPoolExecutor test, which is the right
# home for genuine concurrency (bats/subshells can't easily race threads
# against one shared claim_queue() call).
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
  # Combined into one statement: bash's errexit does not propagate out of
  # a function called in a condition context, so an earlier bare
  # assertion here could fail silently if only the later one were left
  # to determine the test's outcome.
  [ ! -e "$OSA_LOG" ] && [ -e "$(queued)" ]
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
  [[ "$output" == *"test.md"* && "$output" != *"fleet-fail"* ]]
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
  [ "$status" -eq 1 ] && [ ! -e "$OSA_LOG" ]
}
