#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
}

@test "no arguments exits 1" {
  run "$BIN/fleet-focus"
  [ "$status" -eq 1 ]
}

@test "only one argument exits 1" {
  run "$BIN/fleet-focus" iterm2
  [ "$status" -eq 1 ]
}

@test "an unknown host string exits 1" {
  run "$BIN/fleet-focus" bogus-host some-target
  [ "$status" -eq 1 ]
}

@test "an iterm2 host with an empty target exits 1" {
  run "$BIN/fleet-focus" iterm2 ""
  [ "$status" -eq 1 ]
}

@test "pinned-app with a nonexistent application exits non-zero" {
  run "$BIN/fleet-focus" pinned-app "NoSuchApp_flightdeck_test"
  [ "$status" -ne 0 ]
}
