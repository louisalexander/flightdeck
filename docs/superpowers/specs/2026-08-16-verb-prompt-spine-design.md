# Verb prompt spine — design

**Issue:** #21 — *The verb prompts were each written alone: shared rules
drift between files, output shape is unspecified, and no rewrite can be
shown to be an improvement.*

**Date:** 2026-08-16

## The problem, restated

`config/verbs/` holds seventeen files. Two are keystroke verbs (STOP,
CONFIRM) that send a key and carry no prompt. Three are steer verbs
(DRY RUN, JUSTIFY, OTHER WAY) whose body is a deny message — a different
register by design. The remaining **twelve are prompt verbs**: COMMIT,
DIFF, DOUBT, EXPLAIN, FORK, ISSUE, NARROW, NOTE, PR, PUSH, REVIEW, TEST.

Each was written in its own session, and the result is twelve separate
goods with no system behind them:

1. The staging rule (`never git add -A`) is written three times — in
   `commit.md`, `push.md` and `pr.md` — and missing from `fork.md`, which
   commits a plan file into a repository the prompt itself says carries
   untracked scratch.
2. Only `explain.md` and `diff.md` say anything about the shape or length
   of the answer. The other ten do not, including REVIEW, DOUBT, NARROW
   and NOTE, whose output is prose the operator reads on the spot.
3. Only `explain.md` tells the agent what it is talking to — that the
   operator is watching a panel and a press is a glance. That is the most
   load-bearing fact about the product and it appears in one file out of
   twelve by accident of who wrote it.
4. The guard clauses that make the good prompts good — *doing nothing is
   a valid answer*, *do not do the work you are describing* — are where
   the author happened to think of them, not where they are needed.
5. Only TEST can change what the deck shows, and its instruction to do so
   does not work (see *Discovered during design* below).
6. No test or protocol distinguishes today's COMMIT prompt from an empty
   file, so a rewrite ships on taste and a regression is invisible.

## Discovered during design

Two facts not in the issue, both established by reading the code:

**`fleet-fail --explain` does not exist.** Only `bin/fleet-spawn`
implements `--explain` (`bin/fleet-spawn:229`). `bin/fleet-fail` checks
for `--clear`, then calls `int()` on its first argument; `--explain`
raises `ValueError` and the script returns 0 having done and printed
nothing. `config/verbs/test.md` tells the agent to run it and "follow what
it tells you". It tells the agent nothing. The gap was knowingly deferred
(`docs/superpowers/plans/2026-08-14-flightdeck-fork-verb.md:1129`).

**`fleet-fail` requires a slot index the agent cannot know.** Its usage is
`fleet-fail <slot>`; nothing passes the agent its slot. `slots.json`
records an `iterm_session` per slot and `$ITERM_SESSION_ID` is present in
every agent's environment, so an agent's slot *is* derivable — but no
prompt could reasonably be expected to explain that derivation, and none
does.

Between them, the one sink a verb can reach is unreachable as documented.

**Issue #13 is partly resolved already.** `fork.md` carries the
branch-first rule and `tests/verbs.bats` asserts it. The staging half that
issue #21 names is genuinely still absent, and this work closes it.

## Decisions

Five decisions, taken with the operator during brainstorming. Each names
the alternatives it beat, so a later reader can tell what was considered.

### 1. There is a spine, and it lives in the resolver

`config/verbs/_common.md` is prepended by `bin/fleet-verbs` at `show`
time. Rejected: keeping each verb bespoke (the status quo, whose cost is
problems 1 and 4); and generating composed files from sections at build
time (drift moves from "forgot to copy" to "forgot to rebuild", and costs
a build step — the same shape as option 2 on issue #14, and better decided
alongside it).

### 2. Local overrides inherit the preamble, and can replace it

The preamble resolves by the rule already in `verb_file()`:
`$FLEET_HOME/verbs/_common.md` beats `config/verbs/_common.md`. This is
not a new concept, only one more file through the existing lookup.

The alternative — an override file taken exactly as written — was
rejected because it would silently downgrade the documented Obsidian NOTE
override the moment it was installed, reintroducing by design the drift
this work removes.

### 3. Two fragments, not one, and not a section system

`_common.md` carries only what is true for all twelve prompt verbs.
`_common-git.md` carries the rules for the four verbs that commit, opted
into by `common: git` in frontmatter.

A single monolithic preamble was rejected: it would send two staging rules
to the eight verbs that never touch a repository — noise in the agent's
context, and misleading to a human reading the composed prompt. A general
named-section system (`common: panel, empty-answer, git-staging`) was
rejected as premature: it replaces one list that can be wrong with twelve.

### 4. Structure is tested; prose is not, and that is written down

Tests assert the spine — that the preamble reaches every prompt verb, that
it reaches no steer or keystroke verb, and that no verb body restates a
rule the preamble owns. That last test makes problem 1 unrepeatable.

Output quality remains a matter of taste. Golden transcripts were
considered and rejected for now: the corpus goes stale, running it is
manual, and nothing in CI can execute it. The choice is recorded in
`docs/verb-contract.md` so nobody later mistakes the structural tests for
a quality check.

### 5. Repair the one sink; add none

`bin/fleet-fail` gains `--explain` and no-argument self-resolution. No new
deck state, no new colour, no plugin change. Routing REVIEW, DOUBT and
NARROW to `fleet-fail` was rejected: `failed` means *observed failure*,
and making a review finding, a killed approach and a crashed suite the
same red would leave the operator unable to tell which by looking. Whether
those verbs deserve a mark of their own is filed separately.

## The mechanism

### Fragments are not verbs

`_common.md` and `_common-git.md` are plain markdown with **no
frontmatter**. Forcing `id:` and `label:` onto a fragment would be
meaningless ceremony, and `parse_verb()`'s job is to reject files that do
not look like verbs — which these deliberately do not.

`verb_file()` gains a rejection for any id beginning with `_`, alongside
its existing rejection of `/`, `\`, `..` and `.`. The principle is
unchanged: a verb id must never name something that is not a verb.
`fleet-verbs show _common` fails exactly like an unknown verb. A separate
internal loader reads fragments, using the same local-beats-shipped
lookup.

### Composition

Preamble first, verb body last. The panel context frames everything that
follows; the specific ask is the last thing the agent reads.

A prompt verb is one with no `key:` and no `steer: true` — already how the
dispatcher distinguishes them. `--steer` never composes: a deny message
stays a deny message, and a preamble addressed to an agent doing work
would read as nonsense inside a refused tool call.

| Verbs | `_common.md` | `_common-git.md` |
|---|---|---|
| COMMIT, PUSH, PR, FORK | yes | yes, via `common: git` |
| DIFF, DOUBT, EXPLAIN, ISSUE, NARROW, NOTE, REVIEW, TEST | yes | no |
| STOP, CONFIRM | no | no |
| DRY RUN, JUSTIFY, OTHER WAY | no | no |

### Failure modes

An unrecognised `common:` value **rejects the verb**, exactly as an
unrecognised `key:` already does via `KEY_NAMES`. `common: gti` must fail
loudly rather than silently drop the staging rule its author believed they
were getting — that is precisely the bug class this work exists to remove.

A missing or empty fragment **fails loudly**, consistent with
`parse_verb()` refusing a half-written verb rather than sending a
half-written prompt to an agent.

The cost is stated plainly: a broken `$FLEET_HOME/verbs/_common.md` stops
all twelve Row 2 prompt keys at once, where today a broken override stops
one. This is accepted because the alternative — degrading silently to
body-only — reintroduces the drift being fixed, and does so invisibly. To
make the failure diagnosable rather than mysterious at the deck,
`bin/fleet-doctor` gains a check that every shipped verb resolves.

## The contract

Every prompt verb file must state six things. Two now come from the
preamble; four are per-verb.

| # | What | Where it lives |
|---|---|---|
| 1 | What the operator is asking for, and why they are asking now | the verb file |
| 2 | What the agent must not do | universal prohibitions in the preamble; verb-specific ones in the file |
| 3 | The shape and length of the answer | the verb file |
| 4 | What counts as done | the verb file |
| 5 | What an empty answer looks like | the preamble |
| 6 | What the verb leaves behind on the deck | the verb file, where there is anything (TEST today) |

**The contract governs coverage, never wording.** The first-person
operator register — *"I am looking at a panel of agents and cannot tell
what this one is up to"* — is doing real work: it tells the agent who is
asking and why. A template applied hard would flatten the thing that makes
these better than a checklist. Each file states its four items in its own
voice.

### `config/verbs/_common.md`

> You are one of several agents on a panel in front of the operator. They
> pressed one key to send this and are watching other sessions while you
> answer — your reply competes for a glance, not a reading, and it lands
> in a scrollback they may not read for an hour, so it has to make sense
> read cold. Lead with the thing that changes what they do next.
>
> - **An empty answer is a valid answer.** If the honest response is that
>   there is nothing to report, say so in a sentence and stop. Never
>   manufacture a finding, an objection or a concern to look thorough — an
>   invented one costs more time than it saves.
> - **Do not do the work you are describing.** Reporting, filing,
>   summarising and challenging are each a complete job. Unless the key
>   says otherwise, stop when the answer is written and wait.

Wording is indicative, not binding; the implementation may improve it.
What is binding is that these two rules and the panel context live here
and nowhere else.

### `config/verbs/_common-git.md`

The three paragraphs currently triplicated across `commit.md`, `push.md`
and `pr.md`:

- **Stage by name.** Review what is actually staged and unstaged, and add
  the files this change needs by name. Never `git add -A` or
  `git commit -a` — repositories in this fleet carry untracked scratch
  that must not enter history.
- **Branch first.** If you are on the default branch, create a branch
  before committing, and say which one.
- **The message carries the reasoning.** What changed and why it is right,
  in prose. A reader six months from now needs the argument, not a
  restatement of the diff they can already see.

COMMIT, PUSH and PR each get shorter by these three. FORK gains them.

## Output shape

The largest single gap: ten of twelve files say nothing about the form of
the answer. The distinction that resolves most of it:

**Four verbs produce a written artifact, and their reply is a receipt.**
ISSUE, PR, NOTE and FORK each write something durable — an issue body, a
PR body, a journal entry, a plan and a spawned agent. Nothing today tells
them that the *terminal reply* is not the work. An agent that writes a
good issue body and then repeats it into the scrollback has spent the
operator's glance on a duplicate.

- ISSUE ends with the issue number and URL, one line.
- PR ends with the PR URL, one line.
- NOTE ends with where the note landed, one line.
- FORK ends with what forked and where it went, one line (it already says
  this; it is now the general rule rather than a local one).

**Eight verbs are read on the spot and get an explicit budget.**

- COMMIT — one line: what was committed, on which branch.
- DIFF — unchanged; it already specifies a screen.
- DOUBT — the strongest single objection first, at most three; one
  sentence if the approach survives.
- EXPLAIN — unchanged; it already specifies three or four lines.
- NARROW — two lists, then one line of recommendation.
- PUSH — one line: branch and remote.
- REVIEW — worst-first, at most five findings; the ones worth fixing
  separated from the ones worth leaving. A cap rather than "be thorough":
  a sixth finding the operator never scrolls to is worth less than the
  five they read.
- TEST — the failing test names and the one-line reason each, not the
  suite's output, which the operator can read for themselves.

## Sink repair

`bin/fleet-fail` gains:

- `--explain`, printing a real contract in the shape `fleet-spawn`
  established: what it does, how to call it, what each exit status means.
- **No-argument self-resolution.** With no slot given, resolve the
  caller's own slot by matching `$ITERM_SESSION_ID` against
  `iterm_session` in `slots.json`. Exit non-zero when it cannot identify
  itself, rather than marking the wrong slot or silently doing nothing.
  The explicit `fleet-fail <slot>` form is unchanged.

`config/verbs/test.md` then stops pointing at a no-op, and item 6 of the
contract — what the verb leaves behind on the deck — becomes true for the
one verb that has an answer.

## Testing

### `tests/verbs.bats`

- Every prompt verb's `show` output **begins with** the content of
  `config/verbs/_common.md`, compared against the file itself rather than
  a grepped phrase, so rewording the preamble cannot break the test.
- No steer verb's `--steer` output contains the preamble.
- No keystroke verb's `show` output contains the preamble.
- `git add -A` appears in `config/verbs/_common-git.md` and in **no other
  file** under `config/verbs/`. This is the anti-drift test; it makes
  problem 1 unrepeatable.
- COMMIT, PUSH, PR and FORK carry `common: git`; the other eight prompt
  verbs do not.
- An unrecognised `common:` value rejects the verb.
- `fleet-verbs show _common` fails.
- A `$FLEET_HOME/verbs/_common.md` wins over the shipped one.
- A missing `_common.md` fails loudly, with the failure named on stderr.
- A local verb override receives the preamble exactly once.
- The existing REACHABLE test skips `_`-prefixed files.

### `tests/fail.bats`

- `--explain` exits 0 and prints a non-empty contract.
- No-argument invocation resolves the slot from `ITERM_SESSION_ID`.
- No-argument invocation with no match, or with the variable unset, exits
  non-zero and marks nothing.
- The explicit `fleet-fail <slot>` form still behaves as it does today.

### Not tested, deliberately

Prose quality. No test here checks whether a prompt is good; they check
that the spine holds. `docs/verb-contract.md` says so in as many words, so
a later reader does not mistake a green suite for evidence that a rewrite
was an improvement.

## Documentation

- **`docs/verb-contract.md`** (new) — the six-item contract, the split
  between preamble and verb file, the rule that the contract governs
  coverage rather than wording, and the explicit statement that prose is
  reviewed by hand and not tested.
- **`README.md`**, *Verbs* section — the preamble, the `common:` flag, the
  fragment naming rule, and the local-override behaviour.

## Out of scope

- **A deck mark for REVIEW, DOUBT and NARROW.** Needs a state that is not
  `failed`, which means a new colour, a new glyph and plugin work. Filed
  separately, with the evidence this design turned up.
- **Issue #14** — `label:` drift between verb frontmatter and the property
  inspector. Same directory, different surface. Its build-step option
  should be decided alongside decision 1's rejected option (c).
- **The resolver's existing behaviour** — per-verb override, token
  substitution, rejection of half-written files. Untouched except for the
  preamble mechanism and the `_` rejection.
- **Golden transcripts.** Considered under decision 4 and deferred, not
  rejected outright; if verb prose starts changing often enough that taste
  stops being sufficient, this is the thing to build.
