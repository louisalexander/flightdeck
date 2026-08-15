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

# uuid_for <id> -- a deterministic, VALID-shaped (8-4-4-4-12 hex) iTerm2
# session id for a test fixture, derived from <id> so it stays distinct
# and grep-able per session without being a literal UUID string in every
# test. Real-shaped rather than "UUID-<id>": bin/fleet-halt now validates
# with the same strict UUID_RE as bin/fleet-focus (B5), which a string
# like "UUID-W" does not match.
uuid_for() {
  python3 -c "
import hashlib, sys
h = hashlib.md5(sys.argv[1].encode()).hexdigest()
print('{}-{}-{}-{}-{}'.format(h[0:8], h[8:12], h[12:16], h[16:20], h[20:32]))
" "$1"
}

session() {  # session <id> <state>
  python3 -c "
import json,sys
json.dump({'session_id':sys.argv[1],'state':sys.argv[2],'host':'iterm2',
           'iterm_session':sys.argv[4],'repo':'r','branch':'b','cwd':'/tmp',
           'pid':1,'ts':1,'permission_mode':''}, open(sys.argv[3],'w'))" \
  "$1" "$2" "$FLEET_HOME/sessions/$1.json" "$(uuid_for "$1")"
}

# gate_cmd -- the PreToolUse command from the real snippet, with
# __PYTHON__ pointed at a path that does not exist and __REPO__
# substituted. Shared by every gate test so there is exactly one place
# that parses hooks/settings.snippet.json.
gate_cmd() {
  local gate
  gate=$(python3 - "$ROOT/hooks/settings.snippet.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["hooks"]["PreToolUse"][0]["hooks"][0]["command"])
PY
)
  gate="${gate//__PYTHON__//nonexistent/python3}"
  gate="${gate//__REPO__/$ROOT}"
  printf '%s' "$gate"
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

@test "an unrecognised flag refuses rather than silently halting" {
  run "$BIN/fleet-halt" --of
  [ "$status" -eq 1 ]
  [ ! -f "$FLEET_HOME/halt" ]
}

@test "ESC goes to working sessions" {
  session W working
  "$BIN/fleet-halt"
  grep -q "$(uuid_for W)" "$FLEET_HOME/osascript.calls"
}

# B4: each exclusion test also stages a `working` session, so
# osascript.calls must exist and the negative assertion is doing real
# work -- without it, an empty/missing calls file would satisfy the `[ !
# -f ... ]' arm of the assertion regardless of whether exclusion actually
# happened.

@test "ESC does NOT go to a blocked session" {
  session W working
  session B blocked
  "$BIN/fleet-halt"
  grep -q "$(uuid_for W)" "$FLEET_HOME/osascript.calls"
  ! grep -q "$(uuid_for B)" "$FLEET_HOME/osascript.calls"
}

@test "ESC does NOT go to an idle session" {
  session W working
  session I idle
  "$BIN/fleet-halt"
  grep -q "$(uuid_for W)" "$FLEET_HOME/osascript.calls"
  ! grep -q "$(uuid_for I)" "$FLEET_HOME/osascript.calls"
}

@test "ESC does NOT go to a done session" {
  session W working
  session D done
  "$BIN/fleet-halt"
  grep -q "$(uuid_for W)" "$FLEET_HOME/osascript.calls"
  ! grep -q "$(uuid_for D)" "$FLEET_HOME/osascript.calls"
}

# B5: a malformed id must never reach osascript -- it is interpolated
# directly into an AppleScript string literal. Deliberately alphanumeric
# plus hyphen only (no quote, no backslash): this proves the STRICT
# UUID-shape check (bin/fleet-focus's UUID_RE), not just the old
# metacharacter check that was already in place.
@test "a malformed iterm_session is refused, not passed to osascript" {
  session W working
  python3 -c "
import json
json.dump({'session_id':'M','state':'working','host':'iterm2',
           'iterm_session':'not-a-real-uuid','repo':'r','branch':'b','cwd':'/tmp',
           'pid':1,'ts':1,'permission_mode':''}, open('$FLEET_HOME/sessions/M.json','w'))"
  "$BIN/fleet-halt"
  grep -q "$(uuid_for W)" "$FLEET_HOME/osascript.calls"
  ! grep -q "not-a-real-uuid" "$FLEET_HOME/osascript.calls"
}

# B1: this is the most important test in the file. With BOTH the latch
# and this session's own blocked marker present, the ordering inside the
# PreToolUse command is what decides the outcome -- the halt clause must
# win, or a fleet mid-resume never sees a deny at all (empty stdout, exit
# 0), which is exactly the case the clause exists to cover.
@test "the halt clause wins even when the Resumed guard would otherwise fire" {
  touch "$FLEET_HOME/halt"
  mkdir -p "$FLEET_HOME/blocked"
  touch "$FLEET_HOME/blocked/S1"
  run env FLEET_HOME="$FLEET_HOME" CLAUDE_CODE_SESSION_ID=S1 \
      /bin/sh -c "printf '{}' | $(gate_cmd)"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"deny"'* ]] || return 1
}

# The emergency brake must work when flightdeck's own interpreter does
# not, and PATH=/nonexistent is what actually proves it: the deny branch
# still calls `cat` to drain stdin, but that call is joined with `;`, not
# `&&`, so `cat` failing (command not found) does not stop the `printf`
# deny or the `exit 0` that follows it.
@test "the PreToolUse shell gate denies with NO python or other interpreter available" {
  touch "$FLEET_HOME/halt"
  run env PATH=/nonexistent FLEET_HOME="$FLEET_HOME" CLAUDE_CODE_SESSION_ID=S1 \
      /bin/sh -c "printf '{}' | $(gate_cmd)"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"deny"'* ]] || return 1
}

@test "the shell gate is silent when not halted" {
  run env FLEET_HOME="$FLEET_HOME" CLAUDE_CODE_SESSION_ID=S1 \
      /bin/sh -c "printf '{}' | $(gate_cmd)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
