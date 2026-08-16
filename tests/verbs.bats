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
  [[ "$output" == *"fleet-fail"* ]] || return 1
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
  [[ "$output" != *"obsidian_"* ]] || return 1
  [[ "$output" != *"Obsidian Vaults"* ]] || return 1
  [[ "$output" != *"/Users/"* ]] || return 1
}

@test "the shipped Obsidian override parses and wins once installed" {
  # config/verb-overrides/ is documentation you copy, not code anything
  # loads -- so nothing else would notice it rotting into a file the
  # resolver rejects. Installing it exactly as the README says to is the
  # only thing that catches that.
  cp "$ROOT/config/verb-overrides/note-obsidian.md" "$FLEET_HOME/verbs/note.md"
  run "$BIN/fleet-verbs" show note
  [ "$status" -eq 0 ]
  [[ "$output" == *"obsidian_"* ]] || return 1
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
  [[ "$stderr" == *"nosuchverb"* ]] || return 1
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
  [[ "$output" == *"$ROOT/bin/fleet-spawn"* ]] || return 1
}

@test "FORK leaves no literal FLIGHTDECK_REPO token behind" {
  run "$BIN/fleet-verbs" show fork
  [[ "$output" != *"FLIGHTDECK_REPO"* ]] || return 1
}

@test "FORK is a confirm verb" {
  # It files a public issue and starts an unsupervised agent. COMMIT,
  # PUSH and PR carry confirm for less.
  run "$BIN/fleet-verbs" flags fork
  [ "$output" = "interrupt=false confirm=true" ]
}

@test "FORK tells the agent about --explain" {
  run "$BIN/fleet-verbs" show fork
  [[ "$output" == *"--explain"* ]] || return 1
}

@test "FORK permits doing nothing" {
  # The most common bad fork is one where there was nothing to fork.
  run "$BIN/fleet-verbs" show fork
  [[ "$output" == *"do nothing"* ]] || return 1
}

@test "FORK tells the agent to return to what it was doing" {
  # Without this it writes a plan and then starts executing it, which is
  # the opposite of parking the work.
  run "$BIN/fleet-verbs" show fork
  [[ "$output" == *"Return to what you were doing"* ]] || return 1
}

@test "FORK branches first when on the default branch" {
  # The plan file is a side effect of parking work, not a commit the
  # operator asked for -- so landing it on main is worse here than it
  # would be for COMMIT, which at least says "commit" on the key.
  run "$BIN/fleet-verbs" show fork
  [[ "$output" == *"default branch"* ]] || return 1
  [[ "$output" == *"branch first"* ]] || return 1
}

@test "FORK's branch-first rule sits with the commit step, not at the end" {
  # A rule stated after step 4 is a rule the agent reads after it has
  # already committed.
  run "$BIN/fleet-verbs" show fork
  before=$(printf '%s' "$output" | grep -n "branch first" | head -1 | cut -d: -f1)
  after=$(printf '%s' "$output" | grep -n "fleet-spawn" | head -1 | cut -d: -f1)
  [ -n "$before" ]
  [ -n "$after" ]
  [ "$before" -lt "$after" ]
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

# --- every verb must be reachable -----------------------------------------
#
# A verb file that no key can select is dead weight: it resolves, it works,
# and the operator cannot get to it. That happened to FORK -- shipped, valid,
# and absent from the property inspector, so it could not be assigned to a key
# at all. The design says the operator assigns it "when wanted", which needs
# it to be offerable in the first place.

@test "REACHABLE: every shipped verb appears in the property inspector" {
  local pi="$ROOT/plugin/com.louisalexander.flightdeck.sdPlugin/ui/command.html"
  local missing=""
  for f in "$ROOT"/config/verbs/*.md; do
    local id
    id="$(basename "$f" .md)"
    # A steer verb is not a Row 2 command verb: it is never bound to a Row 2
    # key, so it has no property-inspector entry by design. It is reached
    # only via `fleet-verbs --steer <id>`, wired to Row 3 steer keys
    # elsewhere -- see the STEER tests below. Excluding it here is not
    # weakening this check: a steer verb that silently gained a `key:` or
    # got dropped into the picker markup would still need to be caught, and
    # nothing here does that today, but that is a different property than
    # "reachable from Row 2", which is all this test asserts.
    #
    # Asking fleet-verbs itself, via --steer, rather than grepping for
    # "^steer: true$" here: the real parser accepts true/yes/1
    # case-insensitively (TRUE_WORDS in bin/fleet-verbs), so a plain grep on
    # the literal string "true" would misclassify a steer verb written
    # `steer: yes` as a Row 2 verb missing from the picker. Reusing the
    # parser keeps this test unable to drift from the rule it is checking.
    "$BIN/fleet-verbs" --steer "$id" >/dev/null 2>&1 && continue
    grep -q "value=\"$id\"" "$pi" || missing="$missing $id"
  done
  [ -z "$missing" ] || { echo "not offered in the picker:$missing"; false; }
}

# --- steer verbs ------------------------------------------------------
#
# A Row 2 verb's body is a task instruction, read by an agent that is idle
# or working normally. A steer verb's body is a deny message: it arrives
# inside a refused tool call, as the reason the call was refused. Different
# register, so the two must never blur -- a Row 2 verb bound to a steer key
# would read as a justification for a refusal it never wrote. `steer: true`
# in the frontmatter is the only thing that lets a verb be used this way.

@test "STEER: a steer verb's body is printed by --steer" {
  run "$BIN/fleet-verbs" --steer justify
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "STEER: a non-steer verb is refused on a steer key" {
  run "$BIN/fleet-verbs" --steer push
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "STEER: an unknown verb is refused" {
  run "$BIN/fleet-verbs" --steer nosuchverb
  [ "$status" -eq 1 ]
}

@test "STEER: every shipped steer verb forbids an immediate retry" {
  for v in justify otherway dryrun; do
    run "$BIN/fleet-verbs" --steer "$v"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not retry"* || "$output" == *"Do not retry"* ]] || return 1
  done
}

@test "STEER: dryrun ships but is not bound to a key by default" {
  [ -f "$ROOT/config/verbs/dryrun.md" ]
}
