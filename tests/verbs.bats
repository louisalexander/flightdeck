#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  mkdir -p "$FLEET_HOME/verbs"
}

# True when any non-blank line of the fragment file $2 appears verbatim as a
# line of the text $1. Line-wise and fixed-string, rather than grepping for a
# phrase someone chose today: reword the fragment and these checks still test
# the same claim, because the fragment file is the pattern.
#
# `awk NF` rather than a grep character class, only because a bracket
# expression here would look like an assertion to run.sh's inert-assertion
# lint, which greps this file for a doubled open bracket.
carries_fragment() {
  local lines="$BATS_TEST_TMPDIR/fragment-lines"
  awk 'NF' "$2" > "$lines"
  printf '%s\n' "$1" | grep -qxFf "$lines"
}

# The shipped verbs that receive a prompt: everything that is not a fragment
# (`_`-prefixed), not a steer verb (its body is a deny message) and not a
# keystroke verb (it sends a key and no prompt at all). Asked of fleet-verbs
# rather than grepped out of the frontmatter, for the reason the REACHABLE
# test gives below: the parser's own rule cannot drift from itself.
prompt_verbs() {
  local f id
  for f in "$ROOT"/config/verbs/*.md; do
    id="$(basename "$f" .md)"
    case "$id" in _*) continue ;; esac
    "$BIN/fleet-verbs" --steer "$id" >/dev/null 2>&1 && continue
    [ "$("$BIN/fleet-verbs" keyinfo "$id")" = "key= requires=" ] || continue
    printf '%s\n' "$id"
  done
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
  # The body is the override's and none of the shipped one's. Asserted as
  # "ends with" rather than "equals" since the shared preamble goes in front
  # of every prompt verb -- an override inherits the spine, deliberately
  # (see the SPINE tests below), and replacing a verb was never meant to
  # mean opting out of the rules that hold for all of them.
  cat > "$FLEET_HOME/verbs/test.md" <<'MD'
---
id: test
label: TEST
---
overridden body
MD
  run "$BIN/fleet-verbs" show test
  [ "$status" -eq 0 ]
  [ "${output: -15}" = "overridden body" ]
  [[ "$output" != *"fleet-fail"* ]] || return 1
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

@test "FORK gets the branch-first rule from the fragment, and says it once" {
  # It used to say it itself, in step 2. `_common-git.md` owns the rule now
  # and FORK opts in with `common: git`, so a copy in the body is the same
  # drift the staging rule had -- two statements of one rule, free to
  # disagree. The claim is both halves: the rule arrives, and it arrives
  # exactly once.
  local rule
  rule="$(grep -F 'Branch first' "$ROOT/config/verbs/_common-git.md")"
  [ -n "$rule" ]
  run "$BIN/fleet-verbs" show fork
  [ "$status" -eq 0 ]
  # -e, because the rule is a markdown bullet and grep would read a leading
  # dash as an option.
  [ "$(printf '%s\n' "$output" | grep -cF -e "$rule")" -eq 1 ]
  if grep -iq 'branch first' "$ROOT/config/verbs/fork.md"; then
    echo "fork.md restates a rule _common-git.md owns"
    false
  fi
}

@test "FORK reads the branch-first rule before the step that commits" {
  # A rule stated after the commit step is a rule the agent reads once it
  # has already committed. Composition puts it in front of the whole body,
  # which is what makes it true now -- worth pinning, because "the preamble
  # goes first" is the thing that would break silently if the order ever
  # flipped.
  run "$BIN/fleet-verbs" show fork
  before=$(printf '%s' "$output" | grep -n "Branch first" | head -1 | cut -d: -f1)
  after=$(printf '%s' "$output" | grep -n "Commit the plan" | head -1 | cut -d: -f1)
  [ -n "$before" ]
  [ -n "$after" ]
  [ "$before" -lt "$after" ]
}

@test "FORK requires the plan committed before the worktree is spawned" {
  # The one thing about the old step 2 that was genuinely FORK's and not
  # the shared rule's: fleet-spawn branches the new worktree from this
  # branch, so an uncommitted plan is a plan the spawned agent cannot read.
  run "$BIN/fleet-verbs" show fork
  before=$(printf '%s' "$output" | grep -n "committed before" | head -1 | cut -d: -f1)
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
    # A `_`-prefixed file is a shared fragment, not a verb: it has no
    # frontmatter, no id, and `fleet-verbs show _common` is refused by
    # design. Nothing in the picker could name it, and nothing should.
    case "$id" in _*) continue ;; esac
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

# --- the prompt spine -----------------------------------------------------
#
# Each verb was written in its own session, so the rules that are true for all
# of them ended up wherever their author happened to think of them: the
# staging rule was written three times and missing from the fourth verb that
# commits, and the fact that the operator is watching a panel -- the most
# load-bearing thing an agent can know here -- appeared in one file out of
# twelve. `_common.md` and `_common-git.md` now own those rules, and
# `fleet-verbs` prepends them at resolve time.
#
# These tests assert the spine, never the prose. Nothing here can tell whether
# a prompt is any good; they check that the shared rules reach exactly the
# verbs they apply to and no others, and that no verb body restates one.

@test "SPINE: every prompt verb's prompt begins with the shared preamble" {
  # Compared against the file itself rather than a phrase grepped out of it,
  # so rewording the preamble cannot break this test -- the claim is
  # structural: the panel context frames everything the agent then reads.
  local pre id offenders=""
  pre="$(cat "$ROOT/config/verbs/_common.md")"
  [ -n "$(prompt_verbs)" ]
  for id in $(prompt_verbs); do
    run "$BIN/fleet-verbs" show "$id"
    [ "$status" -eq 0 ]
    [ "${output:0:${#pre}}" = "$pre" ] || offenders="$offenders $id"
  done
  [ -z "$offenders" ] || { echo "does not begin with the preamble:$offenders"; false; }
}

@test "SPINE: a steer verb's deny message carries no preamble" {
  # A deny message is read inside a refused tool call. A preamble addressed
  # to an agent doing work would read as nonsense there.
  local v
  for v in justify otherway dryrun; do
    run "$BIN/fleet-verbs" --steer "$v"
    [ "$status" -eq 0 ]
    if carries_fragment "$output" "$ROOT/config/verbs/_common.md"; then
      echo "steer verb $v carries the preamble"
      false
    fi
  done
}

@test "SPINE: a keystroke verb carries no preamble" {
  # STOP and CONFIRM send a key. Their bodies are never delivered to anyone,
  # and composing a prompt onto them would be a prompt with no reader.
  local v
  for v in stop confirm; do
    run "$BIN/fleet-verbs" show "$v"
    [ "$status" -eq 0 ]
    if carries_fragment "$output" "$ROOT/config/verbs/_common.md"; then
      echo "keystroke verb $v carries the preamble"
      false
    fi
  done
}

@test "SPINE: the staging rule is written in exactly one file" {
  # The anti-drift test, and the whole point of issue #21: `git add -A` was
  # forbidden in three verb files and unmentioned in the fourth verb that
  # commits. It iterates the directory rather than naming files, so a verb
  # added later that restates the rule fails here rather than quietly
  # starting the next round of drift.
  local f name offenders=""
  grep -q 'git add -A' "$ROOT/config/verbs/_common-git.md"
  for f in "$ROOT"/config/verbs/*.md; do
    name="$(basename "$f")"
    if [ "$name" = "_common-git.md" ]; then continue; fi
    if grep -q 'git add -A' "$f"; then offenders="$offenders $name"; fi
  done
  [ -z "$offenders" ] || { echo "restates a rule _common-git.md owns:$offenders"; false; }
}

@test "SPINE: exactly COMMIT, FORK, PR and PUSH declare common: git" {
  local id got=""
  for id in $(prompt_verbs); do
    if grep -q '^common: *git *$' "$ROOT/config/verbs/$id.md"; then
      got="$got $id"
    fi
  done
  [ "$got" = " commit fork pr push" ]
}

@test "SPINE: the git rules reach the four verbs that ask for them and no others" {
  # The eight verbs that never touch a repository must not be sent two
  # staging rules: noise in the agent's context, and misleading to a human
  # reading the composed prompt.
  local id
  for id in $(prompt_verbs); do
    run "$BIN/fleet-verbs" show "$id"
    [ "$status" -eq 0 ]
    case " commit fork pr push " in
      *" $id "*)
        carries_fragment "$output" "$ROOT/config/verbs/_common-git.md" \
          || { echo "$id declares common: git but did not receive it"; false; } ;;
      *)
        if carries_fragment "$output" "$ROOT/config/verbs/_common-git.md"; then
          echo "$id received git rules it never asked for"
          false
        fi ;;
    esac
  done
}

@test "SPINE: an unrecognised common: value rejects the verb" {
  # Same class as an unrecognised `key:`. A `common: gti` that silently
  # dropped the staging rule its author believed they were getting would be
  # precisely the bug this work exists to remove.
  cat > "$FLEET_HOME/verbs/typo.md" <<'MD'
---
id: typo
label: TYPO
common: gti
---
body
MD
  run "$BIN/fleet-verbs" show typo
  [ "$status" -eq 1 ]
}

@test "SPINE: a bad common: value names the flag, not 'no such verb'" {
  # The file is right there and resolves fine; only the flag is wrong.
  # Reporting it as a missing verb sends the reader hunting for a file that
  # exists, which is the same wrong turn the fragment errors were shaped to
  # avoid. Name the flag and the values that would have worked.
  cat > "$FLEET_HOME/verbs/typo.md" <<'MD'
---
id: typo
label: TYPO
common: gti
---
body
MD
  run --separate-stderr "$BIN/fleet-verbs" show typo
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"common"* ]] || return 1
  [[ "$stderr" == *"gti"* ]] || return 1
  [[ "$stderr" != *"no such verb"* ]] || return 1
}

@test "SPINE: a fragment is not a verb and cannot be resolved as one" {
  run "$BIN/fleet-verbs" show _common
  [ "$status" -eq 1 ]
  run "$BIN/fleet-verbs" show _common-git
  [ "$status" -eq 1 ]
  # And not even when one is sitting in the local verbs directory, which is
  # exactly where a local preamble override is meant to live.
  printf 'a local preamble\n' > "$FLEET_HOME/verbs/_common.md"
  run "$BIN/fleet-verbs" path _common
  [ "$status" -eq 1 ]
}

@test "SPINE: a local preamble wins over the shipped one" {
  # The same local-beats-shipped rule the verbs themselves follow -- one more
  # file through the existing lookup, not a new concept.
  printf 'LOCAL PREAMBLE, nothing else.\n' > "$FLEET_HOME/verbs/_common.md"
  run "$BIN/fleet-verbs" show test
  [ "$status" -eq 0 ]
  [ "${output:0:29}" = "LOCAL PREAMBLE, nothing else." ]
  if carries_fragment "$output" "$ROOT/config/verbs/_common.md"; then
    echo "the shipped preamble was composed in as well"
    false
  fi
}

@test "SPINE: an empty preamble fails loudly rather than degrading to the body" {
  : > "$FLEET_HOME/verbs/_common.md"
  run --separate-stderr "$BIN/fleet-verbs" show test
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"_common.md"* ]] || return 1
}

@test "SPINE: a missing preamble names the fragment on stderr, not the verb" {
  # Degrading silently to body-only would reintroduce the drift this work
  # removes, and do it invisibly -- so it fails. The cost is that one broken
  # fragment stops all twelve prompt keys, which is why the message has to
  # name the fragment: "no such verb: test" would send whoever is holding
  # the deck hunting for a problem in the wrong file.
  local fake="$BATS_TEST_TMPDIR/fake"
  mkdir -p "$fake/bin" "$fake/config/verbs"
  cp "$BIN/fleet-verbs" "$BIN/fleetlib.py" "$fake/bin/"
  cat > "$fake/config/verbs/solo.md" <<'MD'
---
id: solo
label: SOLO
---
a body with no preamble to prepend
MD
  run --separate-stderr "$fake/bin/fleet-verbs" show solo
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"_common.md"* ]] || return 1
  [[ "$stderr" != *"no such verb"* ]] || return 1
}

@test "SPINE: a local verb override receives the preamble exactly once" {
  # The rejected alternative was to take an override file exactly as
  # written, which would have silently downgraded the documented Obsidian
  # NOTE override the moment it was installed.
  cat > "$FLEET_HOME/verbs/note.md" <<'MD'
---
id: note
label: NOTE
---
an overriding body
MD
  local pre first
  pre="$(cat "$ROOT/config/verbs/_common.md")"
  run "$BIN/fleet-verbs" show note
  [ "$status" -eq 0 ]
  [ "${output:0:${#pre}}" = "$pre" ]
  [[ "$output" == *"an overriding body"* ]] || return 1
  first="$(awk 'NF' "$ROOT/config/verbs/_common.md" | head -1)"
  [ "$(printf '%s\n' "$output" | grep -cxF "$first")" -eq 1 ]
}
