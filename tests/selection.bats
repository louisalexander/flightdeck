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
