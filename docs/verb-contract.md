# The verb contract

**What this is for.** `config/verbs/` holds seventeen verbs, and each one was written in
its own session. The result was twelve separate goods with no system behind them: the
staging rule written out three times and missing from a fourth verb that needed it, ten
of twelve files silent on the shape of the answer they wanted, and the single most
load-bearing fact about the product — that the operator is watching a panel and a press
is a glance — stated in exactly one file, by accident of who wrote it.

This document is what stops that recurring. It says what a verb file is required to
state, what the resolver supplies on its behalf, and what the test suite does and does
not check. Whoever writes verb number thirteen should be able to write it from this page
alone.

The design this implements is
[`docs/superpowers/specs/2026-08-16-verb-prompt-spine-design.md`](superpowers/specs/2026-08-16-verb-prompt-spine-design.md);
the mechanism is [`bin/fleet-verbs`](../bin/fleet-verbs).

## The three kinds of verb

The dispatcher already tells them apart by frontmatter, and the contract applies to
exactly one of the three.

| Kind | How it is recognised | What it carries |
|---|---|---|
| **Prompt verb** | no `key:`, no `steer: true` | a prompt delivered to an agent |
| **Steer verb** | `steer: true` | a deny message, read inside a refused tool call |
| **Keystroke verb** | `key: escape` / `key: enter` | a keystroke; the body is never delivered |

Today that is twelve prompt verbs (COMMIT, DIFF, DOUBT, EXPLAIN, FORK, ISSUE, NARROW,
NOTE, PR, PUSH, REVIEW, TEST), three steer verbs (DRY RUN, JUSTIFY, OTHER WAY) and two
keystroke verbs (STOP, CONFIRM).

**Everything below is about prompt verbs.** A steer verb is a different register — it is
the reason a call was refused, addressed to an agent mid-tool-call, and a preamble
telling it that the operator is glancing at a panel would read as nonsense there. A
keystroke verb's body is documentation for the person reading the file; no agent ever
sees it.

## The six-item contract

Every prompt verb states six things. Two of them are now supplied by the shared preamble
for all twelve at once; the rest are the verb file's own job.

| # | What it states | Where it lives |
|---|---|---|
| 1 | What the operator is asking for, and why they are asking *now* | the verb file |
| 2 | What the agent must not do | universal prohibitions in the preamble; verb-specific ones in the file |
| 3 | The shape and length of the answer | the verb file |
| 4 | What counts as done | the verb file |
| 5 | What an empty answer looks like | the preamble |
| 6 | What the verb leaves behind on the deck | the verb file, where there is anything |

Item 5 and the universal half of item 2 come from `config/verbs/_common.md` and must not
be restated in a verb file. Items 1, 3, 4, 6 and the verb-specific half of 2 are per-verb
and have no home anywhere else.

Item 6 is empty for most verbs and that is fine. TEST is the one verb today that can
change what the deck shows, via `bin/fleet-fail`; a verb that leaves no mark says
nothing about item 6 rather than saying "this leaves no mark".

## The contract governs coverage, never wording

This is the rule most likely to be broken by someone acting in good faith, so it is
stated first among the rules rather than last.

The contract is a list of things a verb file must *cover*. It is not a template, a
heading structure, or an order. The first-person operator register that runs through
these files — *I am looking at a panel of agents and cannot tell what this one is up
to* — is doing real work: it tells the agent who is asking and why they are asking now,
which is item 1, and it does so in a way a bulleted requirement cannot. A template
applied hard would flatten exactly the thing that makes these better than a checklist.

So: check a new verb against the six items by reading it, not by matching it to a shape.
Each file states its items in its own voice. If a verb covers all six in three
paragraphs of prose with no headings at all, it satisfies this document completely.

## The receipt distinction

This is the single most useful thing the contract encodes, because it resolves most of
item 3 for most verbs.

**Four verbs produce a written artifact, and their terminal reply is a receipt, not the
work.** ISSUE, PR, NOTE and FORK each write something durable — an issue body, a PR
body, a journal entry, a plan and a spawned agent. The artifact is the work. An agent
that writes a good issue body and then repeats it into the scrollback has spent the
operator's glance on a duplicate of something they can already open. Each of these four
ends with one line saying where the thing went: the issue number and URL, the PR URL,
where the note landed, what forked and where.

**The other eight are read on the spot, and carry an explicit length budget.** COMMIT,
DIFF, DOUBT, EXPLAIN, NARROW, PUSH, REVIEW and TEST produce prose the operator reads in
a scrollback, competing with seven other sessions for attention. Each states its own
budget — a line, a screen, a capped list — in its own file, because the right budget is
a property of the ask.

A cap is preferable to "be thorough" for the verbs that produce findings. A sixth
finding the operator never scrolls to is worth less than the five they read, and an
uncapped instruction reliably produces the sixth.

When you write verb thirteen, decide which of the two it is before writing anything
else. That decision determines item 3, most of item 4, and whether the last line of the
prompt is a budget or a receipt.

## Fragments: which one a verb gets, and how

The shared rules do not live in the verb files. They live in `_`-prefixed fragments
alongside them, and [`bin/fleet-verbs`](../bin/fleet-verbs) prepends them at `show` time
in `compose()`.

| Fragment | Reaches | Opted in by |
|---|---|---|
| `config/verbs/_common.md` | every prompt verb | nothing — it is automatic |
| `config/verbs/_common-git.md` | COMMIT, PUSH, PR, FORK | `common: git` in frontmatter |

`_common.md` carries the panel context, *an empty answer is a valid answer*, and *do not
do the work you are describing*. `_common-git.md` carries the three rules that hold for
any key that writes to a repository: stage by name (never `git add -A`), branch first,
and the message carries the reasoning.

Two fragments rather than one, deliberately. A single monolithic preamble would send two
staging rules to the eight verbs that never touch a repository — noise in the agent's
context, and misleading to a human reading the composed prompt. A general named-section
system (`common: panel, empty-answer, git-staging`) was rejected as premature: it
replaces one list that can be wrong with twelve.

**Order is preamble, then git fragment if any, then the verb body.** The panel context
frames everything that follows; the specific ask is the last thing the agent reads.
Composition happens inside `load_verb()`, before any command reads the prompt, so `show`
and the resolved copy `resolved-path` materialises for the wake path get identical text
and nothing has to remember to ask for it.

**Neither fragment reaches a steer or keystroke verb.** `compose()` returns early on
`key:` or `steer: true`, for the reasons under *The three kinds of verb* above.

### Fragments are not verbs

`_common.md` and `_common-git.md` carry no frontmatter. Forcing an `id:` and a `label:`
onto a fragment would be meaningless ceremony, and `parse_verb()`'s job is to reject
files that do not look like verbs — which these deliberately do not.

`verb_file()` rejects any id beginning with `_`, alongside its existing rejection of
`/`, `\`, `..` and `.`. So `fleet-verbs show _common` fails exactly like an unknown
verb:

```
$ ./bin/fleet-verbs show _common
fleet-verbs: no such verb: _common
```

The rejection is explicit rather than incidental. A fragment is not a thing a Row 2 key
can be bound to, and that must be true because it is the rule, not as a side effect of
how the fragment happens to be written.

### Overriding a fragment

Fragments resolve by the same local-beats-shipped rule as verbs, per file:
`$FLEET_HOME/verbs/_common.md` wins over `config/verbs/_common.md`. This is not a new
concept, only one more file through the existing lookup — see `fragment_file()`.

The consequence worth knowing: a local override of a *verb* still receives the shipped
preamble. The documented Obsidian NOTE override
(`config/verb-overrides/note-obsidian.md`, installed to `~/.fleet/verbs/note.md`) gets
the same preamble as the shipped NOTE, with no edit. An override file taken exactly as
written was rejected for precisely this reason: it would have silently downgraded that
override the moment it was installed, reintroducing by design the drift this mechanism
removes.

### Failure modes, and what they cost

**An unrecognised `common:` value rejects the verb.** `common: gti` must fail loudly
rather than silently drop the staging rule its author believed they were getting — that
is exactly the bug class the fragments exist to remove. The allow-list is
`COMMON_FRAGMENTS` in `bin/fleet-verbs`, and the mechanism is the same one `KEY_NAMES`
already uses for `key:`. Note the message: rejection happens in `parse_verb()`, so the
verb reports as unresolvable rather than as a bad `common:` value.

```
$ FLEET_HOME=/tmp/fh ./bin/fleet-verbs show zz     # zz.md declares `common: gti`
fleet-verbs: no such verb: zz
```

**A missing, unreadable or empty fragment fails loudly, and names itself.** Degrading to
body-only would reintroduce the drift being fixed and do it invisibly: the prompts would
still be delivered, just quietly missing the rules that make them safe. `FragmentError`
exists as its own exception so the failure can be reported naming the *fragment* — "no
such verb: diff" would send whoever is holding the deck hunting through `diff.md` for a
problem that is not there.

```
$ FLEET_HOME=/tmp/fh ./bin/fleet-verbs show explain   # /tmp/fh/verbs/_common.md is empty
fleet-verbs: empty fragment: _common.md (/tmp/fh/verbs/_common.md)
```

**The cost, stated plainly: a broken `$FLEET_HOME/verbs/_common.md` stops all twelve
prompt verbs at once** — and with them every Row 2 key bound to one — where a broken
override used to stop exactly one verb. That is a real
widening of the blast radius and it was accepted knowingly, because the alternative —
degrading silently to body-only — reintroduces the drift and hides it. To make the
failure diagnosable rather than mysterious at the deck, `bin/fleet-doctor` runs
`fleet-verbs show` over every shipped verb and reports which ones do not resolve; a
broken preamble shows up there as all of them at once, which is itself the diagnosis.

## What is tested, and what is not

`tests/verbs.bats` holds the **structure** of the spine. Its `SPINE:` tests assert:

- every prompt verb's `show` output begins with the content of `config/verbs/_common.md`
  — compared against the file itself rather than a grepped phrase, so rewording the
  preamble cannot break the test;
- no steer verb's `--steer` output and no keystroke verb's `show` output contains the
  preamble;
- `git add -A` appears in `config/verbs/_common-git.md` and in **no other file** under
  `config/verbs/` — this is the anti-drift test, and it is what makes the triplicated
  staging rule unrepeatable;
- exactly COMMIT, FORK, PR and PUSH declare `common: git`, and the git rules reach those
  four and no others;
- an unrecognised `common:` value rejects the verb;
- `fleet-verbs show _common` fails;
- a local `_common.md` wins over the shipped one;
- an empty or missing preamble fails loudly, with the fragment named on stderr;
- a local verb override receives the preamble exactly once.

### No test checks whether a prompt is good

This is stated in as many words because the failure it guards against is a specific one.

Nothing in `tests/verbs.bats`, or anywhere else in this repository, distinguishes a
well-written COMMIT prompt from a badly-written one. The tests check that the spine
holds — that the shared rules reach the verbs that need them and no others, and that
nothing has been copied back into a verb file that the preamble owns. A prompt could
satisfy every one of them and still be useless.

**Prose quality is reviewed by hand, deliberately.** Golden transcripts — a corpus of
prompts, recorded model replies, and a diff on rewrite — were considered during design
and deferred, not rejected outright: the corpus goes stale, running it is manual, and
nothing in CI can execute it. See decision 4 in the design document. If verb prose starts
changing often enough that taste stops being sufficient, that is the thing to build.

Until then: **a green suite is not evidence that a rewrite was an improvement.** It is
evidence that the rewrite did not break the spine. Mistaking the one for the other is
precisely what issue #21 was filed about, and it is the reason this section exists.

## Writing verb thirteen

1. Decide whether it produces an artifact or prose read on the spot. That answers most
   of item 3 and much of item 4.
2. Write items 1, 3, 4 and any verb-specific prohibitions in the file, in the operator's
   own voice. Do not restate the panel context, *an empty answer is a valid answer*, or
   *do not do the work you are describing* — those arrive from the preamble, and the
   suite will not stop you duplicating them, only your own reading will.
3. If it writes to a git repository, add `common: git` to the frontmatter and delete
   whatever staging, branching or commit-message prose you were about to write. The
   `git add -A` test will fail if you keep it.
4. If it changes what the deck shows, say so — that is item 6. `bin/fleet-fail` is the
   only sink a verb can reach today; `fleet-fail --explain` prints its own contract, and
   `fleet-fail` with no arguments resolves the calling agent's own slot, so a prompt
   never has to teach an agent a slot number it cannot know.
5. Run `./bin/fleet-verbs show <id>` and read the whole composed prompt, top to bottom,
   as the agent will receive it. That is the only check that catches a verb whose body
   contradicts the preamble.
6. Run `./tests/run.sh`, and remember what a pass means. See the section above.
