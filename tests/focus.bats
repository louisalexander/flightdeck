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

# --- UUID shape guard on the iterm2 branch ----------------------------------
#
# Stubs osascript on PATH so we can prove, by the absence/presence of a
# marker file, whether fleet-focus ever invoked it.

stub_osascript() {
  STUB_DIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  MARKER="$BATS_TEST_TMPDIR/osascript-invoked"
  rm -f "$MARKER"
  cat > "$STUB_DIR/osascript" <<STUB
#!/usr/bin/env bash
touch "$MARKER"
exit 1
STUB
  chmod +x "$STUB_DIR/osascript"
  export PATH="$STUB_DIR:$PATH"
}

@test "a target with an embedded quote and AppleScript fragment is rejected without invoking osascript" {
  stub_osascript
  run "$BIN/fleet-focus" iterm2 'x" then activate
end tell
tell application "System Events" to keystroke "pwned'
  [ "$status" -eq 1 ]
  [ ! -e "$MARKER" ]
}

@test "a plausible but malformed UUID is rejected without invoking osascript" {
  stub_osascript
  run "$BIN/fleet-focus" iterm2 "1234567-1234-1234-1234-123456789012"
  [ "$status" -eq 1 ]
  [ ! -e "$MARKER" ]

  rm -f "$MARKER"
  run "$BIN/fleet-focus" iterm2 "1234567g-1234-1234-1234-123456789012"
  [ "$status" -eq 1 ]
  [ ! -e "$MARKER" ]
}

@test "a well-formed but nonexistent UUID reaches osascript and returns 1" {
  stub_osascript
  run "$BIN/fleet-focus" iterm2 "00000000-0000-0000-0000-000000000000"
  [ "$status" -eq 1 ]
  [ -e "$MARKER" ]
}

@test "a well-formed UUID with a trailing newline is rejected without invoking osascript" {
  stub_osascript
  run "$BIN/fleet-focus" iterm2 $'00000000-0000-0000-0000-000000000000\n'
  [ "$status" -eq 1 ]
  [ ! -e "$MARKER" ]
}

# --- bounded subprocess timeout on the iterm2 osascript call ----------------
#
# Genuinely exercises the timeout branch (a stub that sleeps well past the
# 5s bound) and times the whole invocation, the same approach used for the
# wedged-ps test in tests/emit.bats, rather than asserting the timeout
# value by inspection.

@test "a wedged osascript does not hang fleet-focus; it returns promptly with non-zero exit" {
  STUB_DIR="$BATS_TEST_TMPDIR/wedged-stub"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/osascript" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  chmod +x "$STUB_DIR/osascript"

  start=$(date +%s)
  run env PATH="$STUB_DIR:$PATH" "$BIN/fleet-focus" iterm2 "00000000-0000-0000-0000-000000000000"
  end=$(date +%s)
  elapsed=$((end - start))

  [ "$status" -ne 0 ]
  [ "$elapsed" -lt 10 ]
}
