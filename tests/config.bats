#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  mkdir -p "$FLEET_CONFIG_DIR"
  cat >"$FLEET_CONFIG_DIR/fleet.json" <<'EOF'
{"slots":{"count":8},"timings":{"armMs":3000},"states":{"idle":{"color":"#25282D"}}}
EOF
}

@test "base config is returned when no local file exists" {
  run "$BIN/fleet-config"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | python3 -c 'import json,sys;print(json.load(sys.stdin)["slots"]["count"])')" = "8" ]
}

@test "local config deep-merges without clobbering siblings" {
  cat >"$FLEET_CONFIG_DIR/fleet.local.json" <<'EOF'
{"timings":{"armMs":5000},"pins":{"7":{"host":"pinned-app","app":"ChatGPT"}}}
EOF
  run "$BIN/fleet-config"
  [ "$status" -eq 0 ]
  py() { echo "$output" | python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }
  [ "$(py 'd["timings"]["armMs"]')"      = "5000" ]
  [ "$(py 'd["pins"]["7"]["app"]')"      = "ChatGPT" ]
  [ "$(py 'd["slots"]["count"]')"        = "8" ]
  [ "$(py 'd["states"]["idle"]["color"]')" = "#25282D" ]
}

@test "malformed local config falls back to base instead of emitting garbage" {
  printf '{ this is not json' >"$FLEET_CONFIG_DIR/fleet.local.json"
  run "$BIN/fleet-config"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | python3 -c 'import json,sys;print(json.load(sys.stdin)["slots"]["count"])')" = "8" ]
}

@test "missing base config emits valid empty JSON rather than nothing" {
  rm -f "$FLEET_CONFIG_DIR/fleet.json"
  run "$BIN/fleet-config"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | python3 -c 'import json,sys;print(type(json.load(sys.stdin)).__name__)')" = "dict" ]
}
