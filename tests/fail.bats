#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR"
  export FLEET_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  export FLEET_SKIP_RECONCILE=1
  mkdir -p "$BATS_TEST_TMPDIR/sessions" "$FLEET_CONFIG_DIR"
  cp "$ROOT/config/fleet.json" "$FLEET_CONFIG_DIR/fleet.json"

  python3 -c "import json;json.dump({'session_id':'S1','state':'working','repo':'r',\
'branch':'b','title':'','cwd':'/tmp','host':'iterm2','iterm_session':'U','pid':0,'ts':1},\
open('$BATS_TEST_TMPDIR/sessions/S1.json','w'))"
  cat >"$BATS_TEST_TMPDIR/slots.json" <<'EOF'
{"ts":1,"overflow":0,"slots":[{"index":0,"state":"working","label_top":"r","label_bottom":"b","session_id":"S1","host":"iterm2","iterm_session":"U","cwd":"/tmp","app":""}]}
EOF
}

state() { python3 -c "import json;print(json.load(open('$BATS_TEST_TMPDIR/sessions/S1.json'))['state'])"; }

@test "fleet-fail marks the slot's session failed" {
  "$BIN/fleet-fail" 0
  [ "$(state)" = "failed" ]
}

@test "--clear returns it to idle" {
  "$BIN/fleet-fail" 0
  "$BIN/fleet-fail" --clear 0
  [ "$(state)" = "idle" ]
}

@test "an unknown slot exits 0 and changes nothing" {
  run "$BIN/fleet-fail" 99
  [ "$status" -eq 0 ]
  [ "$(state)" = "working" ]
}

@test "a non-numeric slot index is harmless" {
  run "$BIN/fleet-fail" "; rm -rf /"
  [ "$status" -eq 0 ]
  [ "$(state)" = "working" ]
}

@test "--explain exits 0 and prints a contract" {
  run "$BIN/fleet-fail" --explain
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "${#output}" -gt 200 ]
  [[ "$output" == *"fleet-fail"* ]] || return 1
  [[ "$output" == *"ITERM_SESSION_ID"* ]] || return 1
  [[ "$output" == *"Exit status"* ]] || return 1
  # --explain is a read: it must not mark anything.
  [ "$(state)" = "working" ]
}

@test "no argument resolves the caller's own slot and marks it failed" {
  export ITERM_SESSION_ID="w0t0p0:U"
  run "$BIN/fleet-fail"
  [ "$status" -eq 0 ]
  [ "$(state)" = "failed" ]
}

@test "--clear with no argument resolves the caller's own slot and clears it" {
  export ITERM_SESSION_ID="w0t0p0:U"
  "$BIN/fleet-fail"
  [ "$(state)" = "failed" ]
  run "$BIN/fleet-fail" --clear
  [ "$status" -eq 0 ]
  [ "$(state)" = "idle" ]
}

@test "no argument with ITERM_SESSION_ID unset exits non-zero and marks nothing" {
  unset ITERM_SESSION_ID
  run "$BIN/fleet-fail"
  [ "$status" -ne 0 ]
  [ "$(state)" = "working" ]
  [[ "$output" == *"fleet-fail"* ]] || return 1
}

@test "no argument with a malformed ITERM_SESSION_ID exits non-zero and marks nothing" {
  export ITERM_SESSION_ID="no-colon-here"
  run "$BIN/fleet-fail"
  [ "$status" -ne 0 ]
  [ "$(state)" = "working" ]
}

@test "no argument whose session matches no slot exits non-zero and marks nothing" {
  export ITERM_SESSION_ID="w0t0p0:NOT-ON-THE-DECK"
  run "$BIN/fleet-fail"
  [ "$status" -ne 0 ]
  [ "$(state)" = "working" ]
  [[ "$output" == *"fleet-fail"* ]] || return 1
}

@test "an explicit slot ignores ITERM_SESSION_ID entirely" {
  export ITERM_SESSION_ID="w0t0p0:NOT-ON-THE-DECK"
  run "$BIN/fleet-fail" 0
  [ "$status" -eq 0 ]
  [ "$(state)" = "failed" ]
}

@test "a wedged fleet-reconcile subprocess does not hang fleet-fail; it returns promptly with exit 0" {
  # Disable FLEET_SKIP_RECONCILE so fleet-fail will invoke fleet-reconcile
  unset FLEET_SKIP_RECONCILE

  # Temporarily replace fleet-reconcile with our sleeping stub
  RECONCILE_BACKUP="$BATS_TEST_TMPDIR/fleet-reconcile.backup"
  cp "$BIN/fleet-reconcile" "$RECONCILE_BACKUP"

  cat > "$BIN/fleet-reconcile" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  chmod +x "$BIN/fleet-reconcile"

  start=$(date +%s)
  run "$BIN/fleet-fail" 0
  end=$(date +%s)
  elapsed=$((end - start))

  # Restore the original
  mv "$RECONCILE_BACKUP" "$BIN/fleet-reconcile"

  # Verify it exited 0 and didn't hang (should be under 15 seconds)
  [ "$status" -eq 0 ]
  [ "$elapsed" -lt 15 ]
}
