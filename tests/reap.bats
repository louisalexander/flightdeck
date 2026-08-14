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

# --- bounded subprocess timeout on the fleet-reconcile call -----------------
#
# fleet-reap is the launchd job firing every 15s (timings.reaperSeconds), so
# an unbounded fleet-reconcile call is worse than most: invocations would
# pile up indefinitely rather than just stalling one press. fleet-reconcile
# is resolved relative to fleet-reap's own directory, so (mirroring the
# equivalent test in tests/emit.bats) a full copy of fleet-reap plus a
# symlink to the real fleetlib.py is staged in a scratch bin alongside a
# stub fleet-reconcile that sleeps well past the 10s timeout. This
# genuinely exercises the timeout branch rather than asserting the timeout
# value by inspection.

@test "a wedged fleet-reconcile does not hang fleet-reap; it still exits 0 promptly" {
  FAKEBIN="$BATS_TEST_TMPDIR/fakereapbin"
  mkdir -p "$FAKEBIN"
  cp "$BIN/fleet-reap" "$FAKEBIN/fleet-reap"
  chmod +x "$FAKEBIN/fleet-reap"
  ln -s "$BIN/fleetlib.py" "$FAKEBIN/fleetlib.py"
  cat > "$FAKEBIN/fleet-reconcile" <<'PY'
#!/usr/bin/env python3
import time
time.sleep(30)
PY
  chmod +x "$FAKEBIN/fleet-reconcile"

  unset FLEET_SKIP_RECONCILE
  start=$(date +%s)
  run "$FAKEBIN/fleet-reap"
  end=$(date +%s)
  elapsed=$((end - start))

  [ "$status" -eq 0 ]
  [ "$elapsed" -lt 15 ]
}
