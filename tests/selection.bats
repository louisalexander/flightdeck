#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  export FLEET_SKIP_RECONCILE=1
  mkdir -p "$FLEET_HOME/sessions"
  # A press resolves the slot out of slots.json, so one must exist.
  # Slot 2 is a second live slot (distinct session), used to pin the
  # switching-target behaviour below; slot 1 stays empty for the
  # empty-slot test.
  cat > "$FLEET_HOME/slots.json" <<'JSON'
{"ts":1,"overflow":0,"slots":[
 {"index":0,"state":"working","label_top":"repo","label_bottom":"main",
  "session_id":"S1","host":"iterm2","iterm_session":"U1","cwd":"/tmp","app":""},
 {"index":1,"state":"empty","label_top":"","label_bottom":"",
  "session_id":"","host":"","iterm_session":"","cwd":"","app":""},
 {"index":2,"state":"working","label_top":"repo","label_bottom":"other",
  "session_id":"S2","host":"iterm2","iterm_session":"U2","cwd":"/tmp","app":""}]}
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

@test "a long press on a live slot records no selection" {
  "$BIN/fleet-press" 0 long
  [ ! -e "$(focus)" ]
}

@test "a second short press on a different live slot replaces the selection" {
  "$BIN/fleet-press" 0 short
  "$BIN/fleet-press" 2 short
  run python3 -c "import json;print(json.load(open('$FLEET_HOME/focus.json'))['session_id'])"
  [ "$output" = "S2" ]
}

# These two hit early returns in fleet-press (unknown index, empty slot)
# that pre-date this feature -- they guard against a *future* regression
# where those paths gain a session_id and start writing a selection, not
# against the write path added here. Coverage for the new write path
# itself is above (short/long, and the switch-target case).
@test "a press on an empty slot records no selection" {
  "$BIN/fleet-press" 1 short
  [ ! -e "$(focus)" ]
}

@test "a press on an unknown index records no selection" {
  "$BIN/fleet-press" 7 short
  [ ! -e "$(focus)" ]
}

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

# --- the deck must repaint on the press, not on the next reaper tick --------
#
# fleet-press writes focus.json, but slots.json is the only file the plugin
# watches. Without a reconcile here the border does not move until something
# else rebuilds slots.json -- the launchd reaper's 15s tick, or an unrelated
# hook event. Observed live: pressing four Row 1 keys in ten seconds left the
# border on whichever slot was selected at the last tick, which reads as a
# stuck border rather than a slow one.

@test "REPAINT: a short press rebuilds slots.json so the border moves at once" {
  cat > "$FLEET_HOME/sessions/S1.json" <<'JSON'
{"session_id":"S1","state":"working","repo":"repo","branch":"main","title":"",
 "cwd":"/tmp","host":"iterm2","iterm_session":"U1","pid":0,"ts":1}
JSON
  # Deliberately NOT skipping reconcile: the repaint IS the behaviour here.
  # slots.json must stay in place -- fleet-press reads it to resolve which
  # slot was pressed -- and the fixture carries no `focused` key at all, so
  # this can only pass if the press rebuilt the file.
  unset FLEET_SKIP_RECONCILE
  run python3 -c "
import json
print('focused' in json.load(open('$FLEET_HOME/slots.json'))['slots'][0])"
  [ "$output" = "False" ]

  "$BIN/fleet-press" 0 short

  run python3 -c "
import json
s=json.load(open('$FLEET_HOME/slots.json'))['slots']
print([x['focused'] for x in s if x['session_id']=='S1'][0])"
  [ "$output" = "True" ]
}
