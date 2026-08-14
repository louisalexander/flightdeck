#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  mkdir -p "$FLEET_HOME/verbs"
}

@test "a shipped verb resolves to its prompt body" {
  run "$BIN/fleet-verbs" show test
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet-fail"* ]]
}

@test "an unknown verb fails loudly rather than printing nothing" {
  # --separate-stderr: this bats keeps stdout+stderr merged in $output by
  # default, which would make the stderr message look like stdout output.
  # The claim under test is specifically that stdout stays empty *and*
  # something explaining the failure lands on stderr -- both halves of
  # "loudly", not just the empty-stdout half.
  run --separate-stderr "$BIN/fleet-verbs" show nosuchverb
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"nosuchverb"* ]]
}

@test "a local override wins over the shipped verb" {
  cat > "$FLEET_HOME/verbs/test.md" <<'MD'
---
id: test
label: TEST
---
overridden body
MD
  run "$BIN/fleet-verbs" show test
  [ "$output" = "overridden body" ]
}

@test "path reports which file won" {
  cat > "$FLEET_HOME/verbs/test.md" <<'MD'
---
id: test
label: TEST
---
body
MD
  run "$BIN/fleet-verbs" path test
  [ "$output" = "$FLEET_HOME/verbs/test.md" ]
}

@test "frontmatter flags are parsed, defaulting to false" {
  cat > "$FLEET_HOME/verbs/stop.md" <<'MD'
---
id: stop
label: STOP
interrupt: true
---
irrelevant
MD
  run "$BIN/fleet-verbs" flags stop
  [ "$output" = "interrupt=true confirm=false" ]
}

@test "a verb file with no frontmatter is rejected, not half-read" {
  printf 'just a body\n' > "$FLEET_HOME/verbs/broken.md"
  run "$BIN/fleet-verbs" show broken
  [ "$status" -eq 1 ]
}

@test "a verb file with a whitespace-only body is rejected, not shown as empty" {
  cat > "$FLEET_HOME/verbs/blank.md" <<'MD'
---
id: blank
label: BLANK
---


MD
  run "$BIN/fleet-verbs" show blank
  [ "$status" -eq 1 ]
}

@test "a verb id that tries to escape the verbs directory is rejected" {
  run "$BIN/fleet-verbs" show ../../../../etc/passwd
  [ "$status" -eq 1 ]
  run "$BIN/fleet-verbs" show /etc/passwd
  [ "$status" -eq 1 ]
}

# --- the FORK verb ------------------------------------------------------

@test "FORK resolves and names fleet-spawn by an absolute path" {
  run "$BIN/fleet-verbs" show fork
  [ "$status" -eq 0 ]
  [[ "$output" == *"$ROOT/bin/fleet-spawn"* ]]
}

@test "FORK leaves no literal FLIGHTDECK_REPO token behind" {
  run "$BIN/fleet-verbs" show fork
  [[ "$output" != *"FLIGHTDECK_REPO"* ]]
}

@test "FORK is a confirm verb" {
  # It files a public issue and starts an unsupervised agent. COMMIT,
  # PUSH and PR carry confirm for less.
  run "$BIN/fleet-verbs" flags fork
  [ "$output" = "interrupt=false confirm=true" ]
}

@test "FORK tells the agent about --explain" {
  run "$BIN/fleet-verbs" show fork
  [[ "$output" == *"--explain"* ]]
}

@test "FORK permits doing nothing" {
  # The most common bad fork is one where there was nothing to fork.
  run "$BIN/fleet-verbs" show fork
  [[ "$output" == *"do nothing"* ]]
}

@test "FORK tells the agent to return to what it was doing" {
  # Without this it writes a plan and then starts executing it, which is
  # the opposite of parking the work.
  run "$BIN/fleet-verbs" show fork
  [[ "$output" == *"Return to what you were doing"* ]]
}

# --- keystroke verbs ------------------------------------------------------
#
# STOP and CONFIRM are not instructions. A blocked agent cannot read a prompt
# until its dialog is answered, and an interrupt delivered at the end of a turn
# is not an interrupt. Both send a key, immediately, or not at all -- so a verb
# file can declare the key it sends and the target states in which sending it
# means anything.

@test "KEYSTROKE: a verb can declare the key it sends" {
  cat > "$FLEET_HOME/verbs/zap.md" <<'MD'
---
id: zap
label: ZAP
key: escape
requires: working,blocked
---
irrelevant, a keystroke verb sends no prompt
MD
  run "$BIN/fleet-verbs" keyinfo zap
  [ "$output" = "key=escape requires=working,blocked" ]
}

@test "KEYSTROKE: a prompt verb reports no key, so the two never blur" {
  run "$BIN/fleet-verbs" keyinfo test
  [ "$output" = "key= requires=" ]
}

@test "KEYSTROKE: an unrecognised key name is rejected, not passed through" {
  cat > "$FLEET_HOME/verbs/bad.md" <<'MD'
---
id: bad
label: BAD
key: rm-rf-slash
---
body
MD
  run "$BIN/fleet-verbs" keyinfo bad
  [ "$status" -eq 1 ]
}
