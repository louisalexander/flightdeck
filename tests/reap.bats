#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  export FLEET_SKIP_RECONCILE=1
  mkdir -p "$FLEET_HOME/sessions"
}

mk() {
  python3 - "$FLEET_HOME/sessions/$1.json" "$1" "$2" <<'PY'
import json,sys
p,sid,pid = sys.argv[1:4]
try: pid = int(pid)
except ValueError: pass
json.dump({"session_id":sid,"state":"working","repo":"r","branch":"b","title":"",
           "cwd":"/tmp","host":"iterm2","iterm_session":"U","pid":pid,"ts":1},
          open(p,"w"))
PY
}

@test "a session whose process is alive is kept" {
  mk ALIVE "$$"; "$BIN/fleet-reap"; [ -f "$FLEET_HOME/sessions/ALIVE.json" ]
}

@test "a session whose process is gone is reaped" {
  mk DEAD 999999; "$BIN/fleet-reap"; [ ! -f "$FLEET_HOME/sessions/DEAD.json" ]
}

@test "an unknown pid is never guessed at — the session is kept" {
  mk NOPID 0; "$BIN/fleet-reap"; [ -f "$FLEET_HOME/sessions/NOPID.json" ]
}

@test "a non-numeric pid is treated as unknown, not as dead" {
  mk WEIRD "not-a-number"; "$BIN/fleet-reap"; [ -f "$FLEET_HOME/sessions/WEIRD.json" ]
}

@test "reaping an empty directory is safe and idempotent" {
  run "$BIN/fleet-reap"; [ "$status" -eq 0 ]
  run "$BIN/fleet-reap"; [ "$status" -eq 0 ]
}
