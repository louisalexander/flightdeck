#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_CONFIG_DIR="$ROOT/config"
}

short() { "$BIN/fleet-config" --shorten "$1" "${2:-11}"; }

@test "an already-short label is unchanged" {
  [ "$(short flightdeck)" = "flightdeck" ]
}

@test "a single long token is truncated" {
  [ "$(short averyverylongsingletoken)" = "averyverylo" ]
}

@test "keeps first and last token, trimming the longer one" {
  [ "$(short break-state-exit-handling)" = "break-handl" ]
}

@test "protects the last token when the first already fits" {
  [ "$(short agent-hook-notification)" = "agent-notif" ]
}

@test "strips known branch prefixes before shortening" {
  [ "$(short feat/stream-deck-renderer)" = "strea-rende" ]
}

@test "splits on underscores and slashes as well as hyphens" {
  [ "$(short my_module/deep_nested_thing)" = "my-thing" ]
}

@test "empty input yields empty output" {
  [ -z "$(short '')" ]
}

@test "output never exceeds the maximum" {
  result="$(short some-extremely-long-branch-name-here 11)"
  [ "${#result}" -le 11 ]
}
