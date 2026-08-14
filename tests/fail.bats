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
