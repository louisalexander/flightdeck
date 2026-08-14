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

@test "note is on the panel and never blocks on a confirm" {
  run "$BIN/fleet-verbs" flags note
  [ "$status" -eq 0 ]
  [ "$output" = "interrupt=false confirm=false" ]
}

@test "the shipped note verb names no vault and no MCP tool" {
  # The shipped verb must stay dependency-free: it ships to checkouts with
  # no Obsidian server, no vault, and no journal at all. The Obsidian
  # flavour is a local override, and the failure this guards against is
  # someone folding that override back into the shipped file -- which
  # reads fine on the machine it was written on and is broken everywhere
  # else. Both halves matter: a vault path is machine-specific, and an
  # `obsidian_*` tool name is server-specific.
  run "$BIN/fleet-verbs" show note
  [ "$status" -eq 0 ]
  [[ "$output" != *"obsidian_"* ]]
  [[ "$output" != *"Obsidian Vaults"* ]]
  [[ "$output" != *"/Users/"* ]]
}

@test "the shipped Obsidian override parses and wins once installed" {
  # config/verb-overrides/ is documentation you copy, not code anything
  # loads -- so nothing else would notice it rotting into a file the
  # resolver rejects. Installing it exactly as the README says to is the
  # only thing that catches that.
  cp "$ROOT/config/verb-overrides/note-obsidian.md" "$FLEET_HOME/verbs/note.md"
  run "$BIN/fleet-verbs" show note
  [ "$status" -eq 0 ]
  [[ "$output" == *"obsidian_"* ]]
  run "$BIN/fleet-verbs" path note
  [ "$output" = "$FLEET_HOME/verbs/note.md" ]
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
