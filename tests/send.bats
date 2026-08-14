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
  # FIX 3 (fix wave, 2026-08-14): validation must run BEFORE claim_queue(),
  # not after. Every session not launched under iTerm2 has
  # iterm_session=="" (fleet-emit's default), so if the claim ran first
  # here, this refusal would have already destroyed the freshly staged
  # entry -- permanently, since each retry destroys the fresh one staged
  # in its place, and it also destroys the Stop-drain fallback that would
  # otherwise have delivered it. The entry must survive intact.
  [ -e "$(queued)" ]
}

@test "FIX 1: the wake script submits the pointer, not just types it" {
  stub_osascript
  idle_session idle
  "$BIN/fleet-send" test
  # write text does not self-submit in Claude Code's TUI (verified live) --
  # the script must send a second, session-addressed write text of an
  # empty line to actually submit the pointer it just typed. Matched on
  # "tell s to write text", not the bare phrase "write text", because the
  # script's own explanatory comment mentions "write text" in prose too.
  [ "$(grep -c 'tell s to write text' "$OSA_LOG")" -eq 2 ]
}

@test "FIX 4: a confirm:true verb is refused outright, never queued" {
  run "$BIN/fleet-send" issue
  [ "$status" -eq 1 ]
  [ ! -e "$FLEET_HOME/queue/S1.json" ]
}

@test "FIX 4: a non-confirm verb is unaffected by the confirm check" {
  run "$BIN/fleet-send" test
  [ "$status" -eq 0 ]
  [ -e "$(queued)" ]
}

@test "FIX 7: an unresolvable verb_path refuses rather than typing a bare pointer" {
  FAKEBIN="$BATS_TEST_TMPDIR/fakeverbsbin"
  mkdir -p "$FAKEBIN"
  cp "$BIN/fleet-send" "$FAKEBIN/fleet-send"
  chmod +x "$FAKEBIN/fleet-send"
  ln -s "$BIN/fleetlib.py" "$FAKEBIN/fleetlib.py"
  # Simulates fleet-verbs's `resolved-path` subcommand exiting 0 with
  # empty output -- e.g. the verb file vanishing in the gap between
  # resolve_verb()'s separate `show` and `resolved-path` subprocess
  # calls. resolve_verb() does not check `resolved-path`'s exit status,
  # so this must be caught by fleet-send's own validation instead.
  cat > "$FAKEBIN/fleet-verbs" <<'SH'
#!/usr/bin/env bash
case "$1" in
  show) echo "a real prompt"; exit 0 ;;
  resolved-path) exit 0 ;;
  flags) echo "interrupt=false confirm=false"; exit 0 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN/fleet-verbs"

  stub_osascript
  idle_session idle
  run "$FAKEBIN/fleet-send" test
  [ "$status" -eq 1 ]
  [ ! -e "$OSA_LOG" ]
}

@test "FIX 2: the file the wake pointer actually names contains no literal FLIGHTDECK_REPO token" {
  stub_osascript
  idle_session idle
  "$BIN/fleet-send" test
  # Ask fleet-verbs for the exact same file fleet-send just resolved and
  # pointed at -- `resolved-path`, not `path` (which reports the SOURCE
  # markdown and legitimately still contains the token). This is a
  # regression test for a real gap: the original FIX 2 substituted the
  # token only for `fleet-verbs show`, which feeds the Stop-drain path.
  # The wake path never reads that string -- it types "Read <path> and
  # follow it." and an idle agent opens whatever file `path` named, which
  # was the untouched source containing the literal "{{FLIGHTDECK_REPO}}"
  # token until this fix.
  run "$BIN/fleet-verbs" resolved-path test
  [ "$status" -eq 0 ]
  target="$output"
  [ -f "$target" ]
  run grep -c 'FLIGHTDECK_REPO' "$target"
  [ "$output" = "0" ]
  # And confirm the pointer fleet-send actually typed names this exact
  # file, not some other path -- otherwise the check above would be
  # testing the wrong file.
  run cat "$OSA_LOG"
  [[ "$output" == *"$target"* ]]
}

@test "FIX 2: issue.md and commit.md resolve with no literal FLIGHTDECK_REPO token either" {
  run "$BIN/fleet-verbs" resolved-path issue
  [ "$status" -eq 0 ]
  issue_target="$output"
  run grep -c 'FLIGHTDECK_REPO' "$issue_target"
  [ "$output" = "0" ]

  run "$BIN/fleet-verbs" resolved-path commit
  [ "$status" -eq 0 ]
  commit_target="$output"
  run grep -c 'FLIGHTDECK_REPO' "$commit_target"
  [ "$output" = "0" ]
}

@test "WAKE: an osascript failure refuses loudly rather than losing the verb silently" {
  cat > "$BATS_TEST_TMPDIR/osa_fail" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$BATS_TEST_TMPDIR/osa_fail"
  export FLEET_OSASCRIPT="$BATS_TEST_TMPDIR/osa_fail"
  idle_session idle
  run "$BIN/fleet-send" test
  # Non-zero exit (so the key flashes refused, not queued) and not
  # restaged (so a later drain cannot double-deliver a verb that
  # osascript may have already typed before failing for some other
  # reason).
  [ "$status" -eq 1 ] && [ ! -e "$(queued)" ]
}

# --- confirm verbs: arm, then fire ----------------------------------------
#
# An outward-facing verb (ISSUE, PUSH, PR, COMMIT) must not fire on a single
# press, and must not sit in a queue to fire later at an agent nobody is
# watching. Two rules, both from the spec:
#
#   1. it never queues -- the target must be deliverable right now, or the
#      press is refused outright;
#   2. the first press arms and the second press inside the window fires.
#
# The arm deliberately does NOT share armed.json with fleet-press. That file
# means "slot N is armed for destructive teardown", and fleet-press fires
# fleet-kill off it. Sharing would let the two arms clobber each other, and a
# shape collision could turn a verb arm into a session teardown.

armfile() { printf '%s' "$FLEET_HOME/armed-verb.json"; }

idle_target() {
  python3 -c "
import json
p='$FLEET_HOME/sessions/S1.json'
d=json.load(open(p)); d['state']='${1:-idle}'; json.dump(d, open(p,'w'))"
}

@test "CONFIRM: a first press arms rather than delivering" {
  stub_osascript
  idle_target idle
  run "$BIN/fleet-send" issue
  [ "$status" -eq 2 ]                 # 2 = armed, press again
  [ -e "$(armfile)" ]
  [ ! -e "$OSA_LOG" ] && [ ! -e "$(queued)" ]
}

@test "CONFIRM: a second press of the same verb fires" {
  stub_osascript
  idle_target idle
  "$BIN/fleet-send" issue || true    # arms; exit 2 is the point
  run "$BIN/fleet-send" issue
  [ "$status" -eq 0 ] && [ -e "$OSA_LOG" ]
}

@test "CONFIRM: firing consumes the arm, so a third press re-arms" {
  stub_osascript
  idle_target idle
  "$BIN/fleet-send" issue || true    # arms; exit 2 is the point
  "$BIN/fleet-send" issue || true    # arms; exit 2 is the point
  run "$BIN/fleet-send" issue
  [ "$status" -eq 2 ]
}

@test "CONFIRM: a different verb does not fire an arm raised by another" {
  stub_osascript
  idle_target idle
  "$BIN/fleet-send" issue || true    # arms; exit 2 is the point
  run "$BIN/fleet-send" commit
  [ "$status" -eq 2 ]                 # re-arms as commit, never fires issue
  [ ! -e "$OSA_LOG" ]
}

@test "CONFIRM: changing the target between presses refuses to fire" {
  stub_osascript
  idle_target idle
  "$BIN/fleet-send" issue || true    # arms; exit 2 is the point
  python3 -c "
import json
json.dump({'session_id':'S1','state':'idle','repo':'r','branch':'b','title':'',
 'cwd':'/tmp','host':'iterm2','iterm_session':'22222222-3333-4444-5555-666666666666',
 'pid':0,'ts':1}, open('$FLEET_HOME/sessions/S2.json','w'))
json.dump({'session_id':'S2'}, open('$FLEET_HOME/focus.json','w'))"
  run "$BIN/fleet-send" issue
  [ "$status" -eq 2 ] && [ ! -e "$OSA_LOG" ]
}

@test "CONFIRM: an expired arm does not fire; it re-arms" {
  stub_osascript
  idle_target idle
  "$BIN/fleet-send" issue || true    # arms; exit 2 is the point
  python3 -c "
import json
d=json.load(open('$FLEET_HOME/armed-verb.json')); d['expires']=1
json.dump(d, open('$FLEET_HOME/armed-verb.json','w'))"
  run "$BIN/fleet-send" issue
  [ "$status" -eq 2 ] && [ ! -e "$OSA_LOG" ]
}

@test "CONFIRM: a working target refuses outright -- confirm verbs never queue" {
  stub_osascript
  idle_target working
  run "$BIN/fleet-send" issue
  [ "$status" -eq 1 ]
  [ ! -e "$(armfile)" ] && [ ! -e "$(queued)" ]
}

@test "CONFIRM: a blocked target refuses too, and is never typed into" {
  stub_osascript
  idle_target blocked
  run "$BIN/fleet-send" issue
  [ "$status" -eq 1 ] && [ ! -e "$OSA_LOG" ]
}

@test "CONFIRM: the verb arm never touches fleet-press's teardown arm" {
  stub_osascript
  idle_target idle
  printf '{"index":0,"expires":9999999999}' > "$FLEET_HOME/armed.json"
  "$BIN/fleet-send" issue || true    # arms; exit 2 is the point
  [ -e "$FLEET_HOME/armed.json" ]
  run python3 -c "
import json;print(json.load(open('$FLEET_HOME/armed.json'))['index'])"
  [ "$output" = "0" ]
}

@test "CONFIRM: a non-confirm verb is unaffected and delivers on one press" {
  stub_osascript
  idle_target idle
  run "$BIN/fleet-send" test
  [ "$status" -eq 0 ] && [ -e "$OSA_LOG" ] && [ ! -e "$(armfile)" ]
}
