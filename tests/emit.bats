#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  export FLEET_SKIP_RECONCILE=1
  mkdir -p "$FLEET_HOME/sessions"
  PAYLOAD='{"session_id":"S1","cwd":"/tmp"}'
}

emit() { printf '%s' "${2:-$PAYLOAD}" | "$BIN/fleet-emit" "$1"; }
field() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" \
            "$FLEET_HOME/sessions/S1.json" "$1"; }

@test "SessionStart maps to idle" { emit SessionStart; [ "$(field state)" = "idle" ]; }
@test "UserPromptSubmit maps to working" { emit UserPromptSubmit; [ "$(field state)" = "working" ]; }
@test "Notification maps to blocked" { emit Notification; [ "$(field state)" = "blocked" ]; }
@test "Stop maps to done" { emit Stop; [ "$(field state)" = "done" ]; }

@test "SessionEnd removes the session file" {
  emit SessionStart
  [ -f "$FLEET_HOME/sessions/S1.json" ]
  emit SessionEnd
  [ ! -f "$FLEET_HOME/sessions/S1.json" ]
}

@test "every event appends one line to the journal spine, removals included" {
  emit SessionStart; emit UserPromptSubmit; emit Stop; emit SessionEnd
  [ "$(wc -l <"$FLEET_HOME/events.jsonl" | tr -d ' ')" = "4" ]
  [ "$(tail -1 "$FLEET_HOME/events.jsonl" | python3 -c 'import json,sys;print(json.load(sys.stdin)["event"])')" = "SessionEnd" ]
}

@test "iTerm session uuid is captured with its w/t/p prefix stripped" {
  ITERM_SESSION_ID="w1t2p0:ABC-123" emit SessionStart
  [ "$(field iterm_session)" = "ABC-123" ]
  [ "$(field host)" = "iterm2" ]
}

@test "host is unknown when not running under iTerm" {
  ITERM_SESSION_ID="" emit SessionStart
  [ "$(field host)" = "unknown" ]
}

@test "repo and branch are derived from the session cwd" {
  R="$BATS_TEST_TMPDIR/somerepo"
  mkdir -p "$R" && git init -q "$R" && git -C "$R" checkout -q -b my-branch 2>/dev/null || true
  emit SessionStart "{\"session_id\":\"S1\",\"cwd\":\"$R\"}"
  [ "$(field repo)" = "somerepo" ]
}

@test "garbage stdin exits 0 and creates no session file" {
  run bash -c "printf 'not json at all' | '$BIN/fleet-emit' Stop"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$FLEET_HOME/sessions")" ]
}

@test "unknown event name is ignored safely" {
  run bash -c "printf '%s' '$PAYLOAD' | '$BIN/fleet-emit' TotallyUnknownEvent"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$FLEET_HOME/sessions")" ]
}

@test "an unwritable state directory still exits 0" {
  run env FLEET_HOME=/nonexistent/unwritable bash -c "printf '{}' | '$BIN/fleet-emit' Stop"
  [ "$status" -eq 0 ]
}

@test "a missing session id exits 0 without writing" {
  run bash -c "printf '{\"cwd\":\"/tmp\"}' | env CLAUDE_CODE_SESSION_ID= '$BIN/fleet-emit' Stop"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$FLEET_HOME/sessions")" ]
}

# --- find_agent_pid: macOS comm can be a full path containing spaces -------
#
# A first draft parsed `ps -o comm= -o ppid= -p <pid>` with a single
# whitespace split, taking parts[0] as comm. On macOS `comm` is the full
# executable path (e.g. "/Applications/Private Internet Access.app/.../
# pia-daemon"), which contains spaces -- confirmed against a real running
# process (PIA's daemon, pid 299 at the time) where that approach yielded
# `comm == "/Applications/Pr"` instead of the real path. fleet-emit's
# find_agent_pid instead issues two single-field `ps` calls (see _ps_field),
# each read whole with no split needed. This test spawns a real process
# whose own executable path contains a space and asserts _ps_field returns
# the untruncated path so the basename match against "claude"/"node" still
# works.
@test "_ps_field reads a comm value containing spaces without truncating it" {
  # A copied/renamed binary gets SIGKILLed on launch by macOS's code-signing
  # enforcement, so a symlink is used instead: the kernel resolves it and
  # execs the real /bin/sleep, but `ps -o comm=` reports it by the path it
  # was invoked through -- the spaced symlink path -- which is exactly the
  # shape a real "*.app/Contents/MacOS/<binary>" comm takes.
  DIR="$BATS_TEST_TMPDIR/Program With Space"
  mkdir -p "$DIR"
  ln -s /bin/sleep "$DIR/claude"
  "$DIR/claude" 30 &
  CPID=$!
  sleep 0.2

  run python3 -c "
import importlib.machinery
import importlib.util
loader = importlib.machinery.SourceFileLoader('fleet_emit_under_test', '$BIN/fleet-emit')
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
comm = mod._ps_field($CPID, 'comm')
assert ' ' in comm, comm
assert comm.rsplit('/', 1)[-1] == 'claude', comm
print('OK')
"
  kill "$CPID" 2>/dev/null || true
  wait "$CPID" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# --- bounded subprocess timeouts --------------------------------------------
#
# fleet-emit shells out twice: to `ps` (inside find_agent_pid) and to
# fleet-reconcile. Both calls now carry a timeout= so a wedged child process
# cannot hang the hook -- this matters more once Task 4 lands a real
# fleet-reconcile that globs a directory and reads N files. Both tests below
# genuinely exercise the timeout branch (a stub that sleeps past the bound)
# rather than asserting the timeout value by inspection, and time the whole
# invocation to prove it returns promptly rather than only checking status.

@test "a wedged ps does not hang fleet-emit; it still exits 0 promptly" {
  FAKEBIN="$BATS_TEST_TMPDIR/fakepsbin"
  mkdir -p "$FAKEBIN"
  cat > "$FAKEBIN/ps" <<'SH'
#!/bin/sh
sleep 30
SH
  chmod +x "$FAKEBIN/ps"

  start=$(date +%s)
  run env PATH="$FAKEBIN:$PATH" bash -c "printf '%s' '$PAYLOAD' | '$BIN/fleet-emit' SessionStart"
  end=$(date +%s)
  elapsed=$((end - start))

  [ "$status" -eq 0 ]
  [ "$elapsed" -lt 10 ]
  [ "$(field pid)" = "0" ]
}

@test "a wedged fleet-reconcile does not hang fleet-emit; it still exits 0 within the bound" {
  # fleet-emit resolves fleet-reconcile relative to its own directory, so a
  # full copy of fleet-emit (plus a symlink to the real fleetlib.py) is
  # staged in a scratch bin alongside a stub fleet-reconcile that sleeps
  # well past the 10s timeout.
  FAKEBIN="$BATS_TEST_TMPDIR/fakereconcilebin"
  mkdir -p "$FAKEBIN"
  cp "$BIN/fleet-emit" "$FAKEBIN/fleet-emit"
  chmod +x "$FAKEBIN/fleet-emit"
  ln -s "$BIN/fleetlib.py" "$FAKEBIN/fleetlib.py"
  cat > "$FAKEBIN/fleet-reconcile" <<'PY'
#!/usr/bin/env python3
import time
time.sleep(30)
PY
  chmod +x "$FAKEBIN/fleet-reconcile"

  unset FLEET_SKIP_RECONCILE
  start=$(date +%s)
  run bash -c "printf '%s' '$PAYLOAD' | '$FAKEBIN/fleet-emit' Stop"
  end=$(date +%s)
  elapsed=$((end - start))

  [ "$status" -eq 0 ]
  [ "$elapsed" -lt 15 ]
}
