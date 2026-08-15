#!/usr/bin/env bats
# HALT has two mechanisms and they are deliberately unlike each other: the
# latch is a file read by a pure-shell PreToolUse clause (no interpreter,
# so it survives flightdeck's own Python being broken), and the interrupt
# is ESC sent only to sessions already known to be `working`.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  export FLEET_SKIP_RECONCILE=1
  export FLEET_OSASCRIPT="$BATS_TEST_TMPDIR/stub-osascript"
  mkdir -p "$FLEET_HOME/sessions"
  cat > "$FLEET_OSASCRIPT" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$FLEET_HOME/osascript.calls"
EOF
  chmod +x "$FLEET_OSASCRIPT"
}

session() {  # session <id> <state>
  python3 -c "
import json,sys
json.dump({'session_id':sys.argv[1],'state':sys.argv[2],'host':'iterm2',
           'iterm_session':'UUID-'+sys.argv[1],'repo':'r','branch':'b','cwd':'/tmp',
           'pid':1,'ts':1,'permission_mode':''}, open(sys.argv[3],'w'))" \
  "$1" "$2" "$FLEET_HOME/sessions/$1.json"
}

@test "halt writes the latch" {
  run "$BIN/fleet-halt"
  [ "$status" -eq 0 ]
  [ -f "$FLEET_HOME/halt" ]
}

@test "--off removes the latch" {
  touch "$FLEET_HOME/halt"
  run "$BIN/fleet-halt" --off
  [ "$status" -eq 0 ]
  [ ! -f "$FLEET_HOME/halt" ]
}

@test "halt is idempotent" {
  "$BIN/fleet-halt"; run "$BIN/fleet-halt"
  [ "$status" -eq 0 ]
}

@test "ESC goes to working sessions" {
  session W working
  "$BIN/fleet-halt"
  grep -q "UUID-W" "$FLEET_HOME/osascript.calls"
}

@test "ESC does NOT go to a blocked session" {
  session B blocked
  "$BIN/fleet-halt"
  [ ! -f "$FLEET_HOME/osascript.calls" ] || ! grep -q "UUID-B" "$FLEET_HOME/osascript.calls"
}

@test "ESC does NOT go to an idle or done session" {
  session I idle
  session D done
  "$BIN/fleet-halt"
  [ ! -f "$FLEET_HOME/osascript.calls" ] || ! grep -q "UUID-I" "$FLEET_HOME/osascript.calls"
}

# The emergency brake must work when flightdeck's own interpreter does not.
# PATH is left alone (unlike the brief's draft): the gate's fallthrough
# still needs `cat` off PATH, and pointing __PYTHON__ at a nonexistent
# path is what actually proves no interpreter is required for the deny.
@test "the PreToolUse shell gate denies with NO python available" {
  touch "$FLEET_HOME/halt"
  gate=$(python3 - "$ROOT/hooks/settings.snippet.json" <<'PY'
import json,sys
h=json.load(open(sys.argv[1]))["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
print(h)
PY
)
  gate="${gate//__PYTHON__//nonexistent/python3}"
  gate="${gate//__REPO__/$ROOT}"
  run env FLEET_HOME="$FLEET_HOME" CLAUDE_CODE_SESSION_ID=S1 \
      /bin/sh -c "printf '{}' | $gate"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"deny"'* ]] || return 1
}

@test "the shell gate is silent when not halted" {
  gate=$(python3 - "$ROOT/hooks/settings.snippet.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["hooks"]["PreToolUse"][0]["hooks"][0]["command"])
PY
)
  gate="${gate//__PYTHON__//nonexistent/python3}"
  gate="${gate//__REPO__/$ROOT}"
  run env FLEET_HOME="$FLEET_HOME" CLAUDE_CODE_SESSION_ID=S1 \
      /bin/sh -c "printf '{}' | $gate"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
