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

### 5. Verb prompts address sink scripts through `{FLEET_BIN}`

`config/verbs/test.md` as planned says "run `bin/fleet-fail` from the repository
root." That is true only when the focused agent happens to be working in the
flightdeck repo. Row 2 sends verbs to agents in **any** repo, where `bin/` holds
something else entirely or nothing.

This is a latent bug in the shipped TEST verb, not a new problem FORK
introduces, but FORK cannot work around it: it depends on a sink script by
definition.

**Fix:** `bin/fleet-verbs` substitutes a `{FLEET_BIN}` placeholder for the
absolute path to flightdeck's `bin/` when it resolves a verb. One `str.replace`
in the resolver. Verb files stay portable and readable, prompts name a path that
exists from wherever the agent is standing, and `test.md` is corrected on the way
past.

### 6. `confirm: true`, accepted as inert at first

FORK files a public issue and starts an unsupervised agent. COMMIT, PUSH and PR
carry `confirm` for less.

The parent spec's plan defers `confirm` enforcement out of the first slice, so
the flag will be read and ignored for a while: the verb is live and unguarded on
the day it lands, and becomes double-press-guarded for free when enforcement
arrives. Shipping the flag anyway records the intent in the place that will be
consulted, rather than in a follow-up nobody reads.

It also inherits the parent spec's rule that `confirm` verbs never queue — an
idle target or a refusal. That is correct here for the same reason it is correct
for PUSH: a fork firing twenty minutes later, from a queue the operator has
forgotten, produces an agent working on something nobody is watching.

## Non-goals

- **No text input from the deck.** The verb prompt is fixed at press time; what
  gets forked is whatever the conversation makes obvious. If that is ambiguous,
  the correct behaviour is to refuse, not to guess.
- **FORK does not manage the forked work.** No tracking, no follow-up, no
  reporting back to the originating session. The new agent appears in Row 1 and
  is thereafter an ordinary slot.
- **Not on a key by default.** Row 2's eight are spoken for. FORK is a ninth
  verb in the inventory, assigned to a key by the operator when wanted.

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
5. Run `{FLEET_BIN}/fleet-spawn <n>`, falling back to
   `{FLEET_BIN}/fleet-spawn --explain` if unsure how it is called.
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

**Verified and unresolved:** `.claude/` is neither tracked nor ignored in this
repo, and there is no global excludes file. A worktree created there therefore
leaves the origin branch's `git status` showing an untracked `.claude/`. That is
already true of the two worktrees living there today, so FORK inherits the
condition rather than creating it — but a verb that commits a plan to the origin
branch should not also be quietly dirtying it. See *Open decisions*.

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
  opens in the worktree. Verified on a real session, the way the hook chain was.

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

### An untracked directory on the branch FORK just committed to

See *Worktree location*. The failure is small and cosmetic on its own, but it
compounds: `fleet-kill` refuses to remove a worktree with uncommitted changes,
and a verb that both commits to a branch and dirties it is muddling two things
the operator reads as one signal.

### Row 1 filling with slots nobody chose

Each fork adds a working slot. Row 1 has eight, with an overflow count beyond
that. Enough forks and the deck stops being an annunciator for work you are
doing and becomes a list of work you started. No mitigation proposed — this is
worth watching in use before designing against it, and it is bounded by the fact
that pressing FORK is a deliberate act.

## Open decisions

- **The untracked `.claude/`.** Whether to add `.claude/worktrees/` to
  `.gitignore`, put spawned worktrees somewhere outside the repository instead,
  or leave the condition as it already is. It predates this verb; FORK just
  makes it more visible.
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
