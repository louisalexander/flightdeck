#!/usr/bin/env bats
# Exercises the PreToolUse shell guard exactly as it is registered in
# hooks/settings.snippet.json -- __PYTHON__/__REPO__ substituted the same
# way install.sh does it, then run through `sh -c`, exactly how Claude Code
# invokes a "type": "command" hook.
#
# The guard's whole reason for existing is COST: PreToolUse fires on every
# single tool call, so in the overwhelmingly common case (no marker, i.e.
# the session is not currently blocked) it must exit immediately without
# ever starting python. Its second job is safety: when the guard's `test`
# short-circuits before python runs, the shell must still drain stdin so a
# large payload from Claude Code can never see a broken pipe / EPIPE, and
# it must always exit 0 with nothing on stdout -- a non-zero or noisy exit
# from a hook is visible to Claude Code and would misreport as a hook
# failure.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  export FLEET_SKIP_RECONCILE=1
  mkdir -p "$FLEET_HOME/sessions"

  PY="$(command -v python3)"
  GUARD="$(python3 -c "
import json
d = json.load(open('$ROOT/hooks/settings.snippet.json'))
print(d['hooks']['PreToolUse'][0]['hooks'][0]['command'])
" | sed -e "s|__PYTHON__|$PY|g" -e "s|__REPO__|$ROOT|g")"

  # A large payload -- bigger than a single pipe buffer -- so a guard that
  # fails to drain stdin before exiting would make the writer's blocking
  # write() see a reader that already went away.
  BIGPAYLOAD="$BATS_TEST_TMPDIR/big.json"
  python3 -c "
import json
json.dump({'session_id': 'S1', 'cwd': '/tmp', 'pad': 'x' * 5000000}, open('$BIGPAYLOAD', 'w'))
"

  field() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" \
              "$FLEET_HOME/sessions/S1.json" "$1"; }
}

run_guard() {
  # args: SESSION_ID PAYLOAD_FILE
  run env CLAUDE_CODE_SESSION_ID="$1" FLEET_HOME="$FLEET_HOME" FLEET_SKIP_RECONCILE=1 \
    bash -c "sh -c '$GUARD' <'$2'"
}

@test "GUARD: no marker present -- exits 0, silently, even with a large payload" {
  run_guard S1 "$BIGPAYLOAD"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "GUARD: no CLAUDE_CODE_SESSION_ID at all -- exits 0, silently, large payload" {
  run bash -c "env -u CLAUDE_CODE_SESSION_ID FLEET_HOME='$FLEET_HOME' sh -c '$GUARD' <'$BIGPAYLOAD'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "GUARD: no marker present -- never writes or touches a session file" {
  run_guard S1 "$BIGPAYLOAD"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$FLEET_HOME/sessions")" ]
}

@test "GUARD: marker present -- runs fleet-emit Resumed end to end and clears it" {
  mkdir -p "$FLEET_HOME/blocked"
  : > "$FLEET_HOME/blocked/S1"
  python3 -c "
import json
json.dump({'session_id': 'S1', 'state': 'blocked', 'repo': 'r', 'branch': 'b',
           'title': '', 'cwd': '/tmp', 'host': 'unknown', 'iterm_session': '',
           'pid': 0, 'ts': 1000}, open('$FLEET_HOME/sessions/S1.json', 'w'))
"
  SMALLPAYLOAD="$BATS_TEST_TMPDIR/small.json"
  printf '{"session_id":"S1","cwd":"/tmp"}' >"$SMALLPAYLOAD"

  run_guard S1 "$SMALLPAYLOAD"
  [ "$status" -eq 0 ]

  [ "$(field state)" = "working" ]
  [ ! -e "$FLEET_HOME/blocked/S1" ]
}
