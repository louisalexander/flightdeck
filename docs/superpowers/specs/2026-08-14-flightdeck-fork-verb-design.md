# Flightdeck FORK — the verb that hands work to a new agent

Design doc. Follows `2026-08-14-flightdeck-row2-commands-design.md`, which
settled what Row 2 is and shipped a set of eight verbs. This adds a ninth to the
inventory.

FORK is the first verb whose prompt does more than instruct the focused agent —
it manufactures another one. That makes it the first real test of the claim in
the parent spec that the capability seam is "the intended way to grow" Row 2:
one markdown file, one sink script, no plugin change and no release.

## The problem

You are working on branch A. Mid-conversation, something surfaces that is
clearly a separate piece of work — a bug you just walked past, a refactor the
current change makes obvious, a second thing the spec forgot. Two bad options
follow. Chase it, and you lose your place on A. Write yourself a note, and you
lose the context that made it legible: the reasoning is in a conversation that
will be summarised away.

FORK is one press: capture the thing properly, hand it to a fresh agent in its
own worktree, and carry on with A.

## Decisions taken

### 1. The context transfer is the feature; the spawn is plumbing

A fresh agent handed a one-line issue title starts from nothing, and the fork is
worse than doing the work yourself would have been. So the originating agent
first writes a **plan** — `docs/superpowers/plans/YYYY-MM-DD-<slug>.md`, via
`superpowers:writing-plans` — and commits it to the branch it is on.

**Why a plan file rather than a long issue body:** this is decision 4 of the
parent spec applied to a second artifact. A multi-paragraph brief held in an
issue body does not diff line by line, cannot be edited in an editor, and is not
in the repository at all. As a committed markdown file it is reviewable, it
survives the issue being edited, and it is exactly the artifact
`superpowers:executing-plans` already knows how to consume. The spawned agent
does not need to be taught a new format, because there isn't one.

**Cost, accepted:** pressing FORK puts a commit on your current branch that you
did not explicitly ask for. That is a real side effect on a key whose whole
premise is that you are mid-flow and do not want to be interrupted. It is
accepted because the alternative — an uncommitted plan file — cannot be reached
from the new worktree at all, which would defeat the point of the verb.

### 2. The new worktree branches from the branch the issue came from

`git worktree add -b issue-<n>-<slug> <path> <origin-branch>`.

**Why:** the forked work surfaced *because* of what is on that branch, and
usually depends on it. Branching from the default branch instead would hand the
fresh agent a plan describing code its worktree does not contain — a plan that
reads correctly and cannot be executed, which is the worst failure available
here because it looks like it should work.

**Cost, accepted:** the fork inherits the origin branch's unmerged work. When
the forked task is genuinely independent that is pollution. Branching from the
origin branch and later rebasing is recoverable; starting from a tree where the
plan does not apply is not.

### 3. The spawned agent starts working on arrival

Not loaded-and-waiting.

**Why:** a fork you have to go back and confirm is not a fork. The premise is
that you keep working on A while B proceeds without you; a window sitting on an
unsent prompt turns FORK into a bookmark with extra steps.

**Cost, accepted, and it is the largest one here:** an agent begins work on a
plan a model wrote seconds ago and nobody read. It appears in Row 1 as a working
slot the operator never inspected. This is what `confirm: true` is answering —
see decision 6 — and it is why the verb prompt's refusal clause matters as much
as its instructions.

**This rules out the `claude-cli://` deep link**, which the v1 spec identified as
Row 3's spawn mechanism. A deep link deliberately leaves the prompt in the input
box, unsent, behind a "Prompt from an external link" warning. That is the right
behaviour for a hand-authored Row 3 template and the wrong behaviour here.

### 4. Model-authored text never crosses a shell or an AppleScript boundary

The v1 spec carries a hard rule, written against a patched RCE:

> Never generate a deep link from untrusted input. Links are built only from
> literals in `fleet.local.json` — never from issue titles, CI output, branch
> names, or model output.

A verb that files an issue and spawns an agent on it is, read plainly, the thing
that rule forbids. It is not answered by an exception. It is answered by making
the launch path carry no model-authored text at all:

| Value | Derived from | Crosses | Safe because |
|---|---|---|---|
| Issue number | GitHub | shell, AppleScript | validated `^[0-9]+\Z` |
| Worktree path `.../issue-<n>` | the issue number only | shell, AppleScript | contains no model text |
| Branch `issue-<n>-<slug>` | the issue title | `git` argv **only** | never reaches a shell; slug sanitised to `[a-z0-9-]`, length-capped |
| Launch prompt | a literal in `bin/fleet-spawn` | shell, AppleScript | fixed template; `<n>` is the only substitution |

**The slug goes in the branch name and deliberately not in the path.** A path
like `.claude/worktrees/issue-7-splash-on-lock` reads better, and buying that
means dragging model-authored text into a shell string and an AppleScript string
literal. The branch name gets the slug instead, because `fleetlib.git()` passes
an argument list and never a shell string — the property its docstring already
records as "what makes a repo path containing a space safe."

**The issue is the channel.** Everything the fresh agent needs travels through
GitHub and through a file on a branch. The command line carries an integer. That
is not a workaround for the rule; it is the rule holding.

### 5. Verb prompts address sink scripts through `{{FLIGHTDECK_REPO}}`

A verb prompt runs in whatever repo the *selected agent* is working in, not in
flightdeck's. So a verb naming one of flightdeck's own sinks by a relative path
— `bin/fleet-fail` — sends the agent hunting for something that does not exist
there. FORK cannot work around this: it depends on a sink script by definition.

**Resolved upstream, not here.** This design originally specified a `{FLEET_BIN}`
placeholder to fix it. While it was being written, Row 2's implementation hit the
same bug independently, verified it live, and shipped `{{FLIGHTDECK_REPO}}` in
`bin/fleet-verbs` — substituted by `parse_verb` at every `show`, and materialised
to `$FLEET_HOME/verbs-resolved/<id>.md` for the wake path, which points an idle
agent at a *file* and would otherwise hand it the raw token.

FORK therefore adopts the existing token and adds nothing. Introducing a second
placeholder for the same job would be the worse outcome by some distance.

### 6. `confirm: true`, and it is enforced

FORK files a public issue and starts an unsupervised agent. COMMIT, PUSH and PR
carry `confirm` for less.

This was specified when `confirm` enforcement was still deferred, on the
assumption the flag would ship inert. It no longer is: `bin/fleet-send` arms on
first press and fires on a second, within a window (`verbArmSecs`, 10s by
default) deliberately separate from `fleet-press`'s 3s teardown arm, and the arm
is keyed by verb **and** target session so arming against one agent and
confirming against another cannot fire.

One inherited rule is superseded rather than upheld. The parent spec said
`confirm` verbs never queue. Row 2 relaxed that: a confirm verb may queue against
a busy target, bounded by an expiry (`confirmQueueSecs`, 300s). The reasoning
transfers to FORK unchanged — the danger was never "queued", it was "twenty
minutes later, forgotten", and an expiry addresses the danger without discarding
the operator's intent the moment their agent happens to be mid-turn.

## Non-goals

- **No text input from the deck.** The verb prompt is fixed at press time; what
  gets forked is whatever the conversation makes obvious. If that is ambiguous,
  the correct behaviour is to refuse, not to guess.
- **FORK does not manage the forked work.** No tracking, no follow-up, no
  reporting back to the originating session. The new agent appears in Row 1 and
  is thereafter an ordinary slot.
- **Not on a key by default.** Row 2's eight are spoken for. FORK is a ninth
  verb in the inventory, assigned to a key by the operator when wanted.

## Sequencing: deliberately not part of Row 2

This design was written on its own branch and deliberately did not land with Row
2. Row 2 had a queue, a drain, a claim race and an AppleScript wake to get right;
adding a verb that spawns worktrees into that slice would have blurred what was
being proven when something broke.

**Row 2 has since landed**, so FORK is unblocked and this section is history
rather than a gate. Two things changed under it while it waited, both recorded in
the decisions above: `{{FLIGHTDECK_REPO}}` arrived upstream and made decision 5's
proposed change unnecessary, and `confirm` enforcement arrived and made decision
6's "inert" caveat obsolete.

Keeping FORK separate is what made both of those cheap to absorb. Had it been
folded into Row 2's slice, the same two collisions would have been merge
conflicts in a branch that was also trying to prove a claim race.

## Relationship to the ISSUE verb

Row 2 shipped `config/verbs/issue.md` — capture what is live right now as a
GitHub issue, written for someone who was not here, and *do not fix it*.

FORK is its sibling, and the split is worth stating so the two do not drift into
each other:

- **ISSUE** puts the depth in the **issue body**. Nothing else happens; the
  capture is the whole job.
- **FORK** puts the depth in a **committed plan file** and keeps the issue body
  thin — a pointer to the plan, the branch, and the SHA — then hands it to an
  agent.

The reason for the asymmetry is the consumer. ISSUE's reader is a human scanning
a backlog later, and an issue body is the right shape for that. FORK's reader is
an agent that must execute, immediately, with no memory of the conversation —
which is what `superpowers:executing-plans` already consumes, and why the plan
file rather than the issue body carries the weight.

## Architecture

### `config/verbs/fork.md`

Frontmatter `id: fork`, `label: FORK`, `confirm: true`, `interrupt: false`.
`FORK` is four characters, comfortably inside the 96px budget that `DOUBT` was
chosen against.

The prompt instructs the focused agent to:

1. Identify the distinct piece of work that has surfaced and is *not* the
   current task.
2. Write it up as a plan with `superpowers:writing-plans`, at
   `docs/superpowers/plans/YYYY-MM-DD-<slug>.md`, carrying the context that
   makes it executable by an agent with no memory of this conversation:
   background, why it matters, constraints, what "done" is.
3. Commit the plan to the current branch.
4. File the issue with `gh issue create`, its body naming the plan path, the
   origin branch, and the SHA the plan was committed at.
5. Run `{{FLIGHTDECK_REPO}}/bin/fleet-spawn <n>`, falling back to
   `{{FLIGHTDECK_REPO}}/bin/fleet-spawn --explain` if unsure how it is called.
6. **Return to what it was doing**, with one line saying what was forked.

Step 6 is what makes this "park it and fork it" rather than "abandon task A",
and it needs stating explicitly — an agent that has just written a plan will
otherwise start executing it.

The prompt closes with a refusal clause, in the register DOUBT already
established: if there is no distinct piece of work to fork, say so and do
nothing. Do not invent an issue to justify a keypress.

### `bin/fleet-spawn <issue-number>`

The sink. It is invoked by the focused agent, so it runs with that agent's
working directory — which is how it learns everything it is not told. The repo
is whatever `gh` and `git` resolve from `cwd`; the origin branch is
`git rev-parse --abbrev-ref HEAD` there. Neither is passed as an argument, and
that is the point: an argument is a channel, and decision 4 is about keeping the
number of channels at one.

Validate the number, then:

1. Read the issue with `gh issue view <n> --json title` to recover the title
   (for the slug) and confirm it exists in this repo.
2. Compute the slug: lowercase, non-alphanumerics to `-`, collapse runs, strip
   ends, cap the length. Sanitising rather than escaping — the charset is
   narrow enough that there is nothing left to escape.
3. `git worktree add -b issue-<n>-<slug> <path> <origin-branch>` through
   `fleetlib.git()`.
4. Open an iTerm2 **tab** and start `claude` there with the fixed launch prompt.

**`--explain`**, per the capability-seam convention: prints, for an agent to
read and act on, what the script does, that it takes one issue number and
nothing else, what it expects the issue body to contain, and that it is safe to
re-run.

**Idempotent**, and this is the property `--explain` exists to communicate:
called twice for issue 7, the second call focuses the existing tab rather than
building a second worktree. The parent spec requires sink idempotency generally;
here it is load-bearing, because the failure it prevents is two agents working
the same issue in two worktrees.

**Exit code carries meaning.** Like `fleet-send` and unlike the hooks,
`fleet-spawn` may exit non-zero. A fork that did not happen must be visible.

### The launch prompt

A literal in the script, with the validated number substituted:

> Read GitHub issue #`<n>` with `gh issue view <n>`. It names a plan file that
> is present in this worktree. Execute that plan with the
> `superpowers:executing-plans` skill, task by task. If the plan is missing, or
> does not match this repository, stop and say so rather than guessing.

The last sentence is the guard against decision 2 having gone wrong. If the
worktree was somehow branched from the wrong place, the agent stops instead of
executing a plan against code it does not describe.

### The iTerm2 tab

Reuses `fleet-focus`'s AppleScript shape, and more importantly its discipline.
`fleet-focus` validates its UUID against an anchored pattern *before* `osascript`
is ever invoked, with a comment recording why the anchor is `\Z` and not `$`.
There is no UUID here — a new tab has no id yet — but the rule generalises: every
value interpolated into the script is checked at the point it enters the program,
not at the point it is used. Under decision 4 that check is trivial, because the
only values are an integer and a path built from it.

One addition `fleet-focus` does not need — `current window` errors when no
iTerm2 window exists, so the tab path falls back to creating a window. A verb
that only works when a terminal is already open would fail in exactly the
situation where forking is most useful.

The spawned session flows into the state bus through the ordinary hook chain, so
it appears in Row 1 with no integration code, exactly as the v1 spec observed
for deep-link spawns.

### Worktree location

`.claude/worktrees/issue-<n>`, matching where this repository's worktrees
already live. One place for the operator to look, and `fleet-kill`'s
linked-worktree safety checks apply unchanged.

**`.claude/worktrees/` is gitignored**, decided here and applied. It was
neither tracked nor ignored, with no global excludes file, so a worktree created
there left the origin branch's `git status` showing an untracked `.claude/`.
Already true of the worktrees living there today — FORK inherits the condition
rather than creating it — but FORK is the verb that also commits a plan to that
same branch, and a key that both commits to a branch and dirties it muddles two
things the operator reads as one signal.

Scoped to `worktrees/` rather than all of `.claude/` deliberately: the untracked
directory is the entire defect, and ignoring the parent would silently prevent
this repo from ever tracking `.claude/settings.json` — project hooks and
permissions, which is close to what this repo is *about*.

## Testing

`fleet-spawn` splits along the line the parent spec's testing section draws:

- **Pure** — the issue-number guard and slug sanitisation. Property-ish cases
  matter more than examples here: a title of only punctuation, a title long
  enough to hit the cap, a title carrying quotes, backticks, `$(...)` and a
  newline. The assertion is that the output matches `^[a-z0-9-]*\Z` in every
  case, not that any particular title produces any particular slug.
- **Against a real temp repo** — worktree creation, branch point, and the
  idempotent second call, following the fixture pattern `tests/kill.bats`
  already uses.
- **Stubbed** — `$FLEET_OSASCRIPT` records the launch string, so the assertions
  that matter can run without a terminal: the tab command contains the issue
  number and the worktree path, and contains **no** text from the issue title.
  That last one is the executable form of decision 4 and should be written as
  such, with a title deliberately full of shell metacharacters.
- **Live, because no stub can prove it** — that `claude "<prompt>"` submits on
  arrival rather than leaving the prompt in the box, and that a real iTerm2 tab
  opens in the worktree. See *Live verification* below.

## Live verification

Run on 2026-08-14 against real iTerm2, real `gh` and real agents. Recorded as
observed, including what was not covered.

| Check | Result |
|---|---|
| `claude '<prompt>'` submits on arrival | **Verified.** Answered `SUBMIT CHECK OK` with no Return pressed. |
| Tab opens with no iTerm2 window present | **Not run** — see below. |
| Ordinary path: new tab in an existing window | **Verified.** Agent running in the worktree, launch prompt submitted. |
| Spawned session reaches Row 1 unaided | **Verified.** Registered in the state bus on its own, no integration code. |
| Idempotent re-run focuses the existing tab | **Verified.** `spawn: issue 4 already spawned; focusing`, exactly one worktree, exit 0. |
| FORK's refusal clause | **Verified.** See below. |
| FORK's happy path — plan, issue, spawn, return | **NOT VERIFIED.** |

**Decision 3 holds.** This was the assumption the whole design rested on, and
the one the `claude-cli://` deep link fails. The CLI's positional prompt does
submit.

**The no-window case was not run** for a structural reason worth recording: the
verifying session was itself running inside iTerm2, so quitting iTerm2 to reach
the `count of windows is 0` branch would have killed the verifier. It needs an
operator, or a session driven from a different terminal. The branch is
implemented and reviewed but unexercised.

**The refusal clause works, and it is the half that got proven.** FORK was fired
at an idle agent whose conversation contained no genuinely separate work. It
declined, unprompted, with the right reasoning: the only thing it had found was
"the precondition of the task I was handed, already tracked by the issue
itself", and forking it would have meant filing a duplicate. That is precisely
the invented-issue failure the clause exists to prevent, and it was the part of
the prompt most likely to be ignored.

**The happy path was not reached.** Producing it needs an agent that is (a) in a
repo with a GitHub remote, (b) not on the default branch, and (c) holding a
conversation with a real forkable tangent. Repeated attempts to seed one failed
on a mundane mechanical problem — a new iTerm2 tab inherits the *frontmost*
session's directory, so every seeded agent landed in the primary checkout on
`main` instead of in a worktree. So the following remain untested against
reality: the plan commit, `gh issue create`, the spawn chaining off it, and the
"return to what you were doing" instruction.

### Found during verification

- **FORK has no branch-first rule, and PR does.** ~~The parent spec gives the PR
  verb "branches first when on the default branch". FORK inherits nothing of the
  sort, so pressing it while on `main` commits the plan straight to `main`. This
  is a real gap, found by watching seeded agents land there. It should either
  adopt PR's rule or refuse on the default branch.~~ **Resolved:** FORK's step 2
  now adopts PR's rule, worded as COMMIT and PUSH word it.

  Enforcement is **prompt-level, and `bin/fleet-spawn` was deliberately left
  alone.** The obvious alternative — have the sink refuse when the branch it is
  forking from is the default branch — cannot work, because `fleet-spawn` runs
  at step 4, *after* the plan is committed at step 2 and the issue is filed at
  step 3. A refusal there cannot undo the commit; it would leave a plan commit
  on `main`, a filed issue, and no agent working it — precisely the half-forked
  state `fork.md` names as worse than a fork that plainly did not happen.
  Enforcement has to precede the commit, and the only thing running before the
  commit is the prompt. That is also why COMMIT, PUSH and PR carry the rule in
  their prompts rather than in `fleet-press` or `fleet-send`.

  Branching the worktree *from* the default branch remains allowed: the fork
  point was never the problem, the commit was. Once the agent has branched, the
  plan lands on the new branch and `fleet-spawn` branches the worktree from
  there. The finding is kept rather than deleted because the reasoning above is
  the record of why the sink was not touched.
- **A spawned worktree's Row 1 label reads `issue-<n>`, not the repo name.** The
  label derives from the directory name and `fleet-spawn` names the directory
  after the issue, so a forked agent does not show which repo it belongs to.
  Cosmetic, and it compounds the branch-label point already in *Open decisions*.
- **The confirm arm's session key earned itself.** During testing the operator's
  own Row 1 press changed the selection between arming FORK and confirming it.
  Because Row 2 keys the arm by verb *and* target session, the confirm did not
  fire at the newly-selected agent — it re-armed. Without that key, FORK would
  have filed an issue from a session nobody had chosen.

## Risks

### A plan written by an agent that misread the conversation

FORK's whole value is that the plan carries real context; its whole risk is that
the plan is confidently wrong, and decision 3 means an agent starts executing it
immediately.

Three things bound this, in order of how much they buy:

1. **The refusal clause.** The most common bad fork is one where there was
   nothing to fork. A prompt that explicitly permits doing nothing removes it.
2. **The plan is a commit on your branch.** It is reviewable, and revertible,
   at the moment you next look at the branch — unlike a prompt typed into a
   window that scrolls away.
3. **The spawned agent's stop condition.** It is told to halt if the plan does
   not match the repository, rather than to improvise.

What does *not* bound it: `confirm: true`, which guards against pressing the key
by accident and not at all against the agent being wrong. Those are different
failures and only one of them has a mitigation on the key.

### The origin branch moving out from under the fork

The plan is committed at a SHA the issue records. The origin branch then
advances, or is rebased, or is deleted. The fork's branch keeps its own copy of
the plan file, so the plan itself never dangles — but the SHA in the issue can
become unreachable after a rebase, and the "branched from" claim becomes
historical.

Accepted rather than solved. The plan travels *in* the worktree by decision 2,
which is what makes it robust; the SHA is provenance, not a dependency.

### Row 1 filling with slots nobody chose

Each fork adds a working slot. Row 1 has eight, with an overflow count beyond
that. Enough forks and the deck stops being an annunciator for work you are
doing and becomes a list of work you started. No mitigation proposed — this is
worth watching in use before designing against it, and it is bounded by the fact
that pressing FORK is a deliberate act.

## Open decisions

- **The deck label for a spawned branch.** `issue-7-splash-on-lock` shortens to
  `issue-lock` through `fleetlib.shorten`. Identifiable, not lovely. A different
  branch template — putting the slug first, or dropping `issue-` — would read
  better on the key at the cost of the number being less obvious in `git branch`.
- **`bin/fleet-fail --explain`.** Already deferred work in the parent plan.
  `fleet-spawn` shipping with `--explain` while `fleet-fail` lacks it is a small
  inconsistency, left alone deliberately rather than fixed in passing.
- **Whether the plan commit should be separable.** Right now FORK's commit lands
  on the origin branch mixed into whatever you were doing. Committing it to the
  fork's branch only would keep your branch clean, but then the plan is not
  reachable at the moment `git worktree add` runs. Worth revisiting if the
  side effect proves annoying in use.
