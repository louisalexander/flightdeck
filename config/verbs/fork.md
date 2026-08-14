---
id: fork
label: FORK
interrupt: false
confirm: true
---
Something separate from the current task has come up in this conversation.
Park it properly and hand it to a fresh agent, then carry on with what you
were doing.

First decide whether there is anything to fork. If no distinct piece of
work has surfaced — one that is genuinely separate from the task in hand,
not the next step of it — say so plainly and do nothing. Do not invent an
issue to justify this. Doing nothing is the correct outcome more often
than not.

If there is, then:

1. Write it up as a plan using the superpowers:writing-plans skill, saved
   to `docs/superpowers/plans/YYYY-MM-DD-<slug>.md`. Assume the agent that
   executes it has no memory of this conversation and cannot ask you
   anything. Carry the context that makes it executable: what the problem
   is, why it matters, what you already know that is not obvious from the
   code, the constraints that apply, and what "done" looks like. This
   document is the entire handover — a thin plan produces a lost agent.

2. Commit the plan to the branch you are on. It must be committed before
   step 4: the new worktree is branched from this branch and will contain
   only what is committed here.

3. File the issue with `gh issue create`. The body must name the plan's
   path, the branch it was committed on, and the commit SHA. Keep the body
   short — it is a pointer to the plan, not a copy of it. This is the one
   way FORK differs from the ISSUE verb, which puts the depth in the issue
   body because its reader is a human scanning a backlog later. Yours is
   an agent that must execute immediately.

4. Run `{{FLIGHTDECK_REPO}}/bin/fleet-spawn <issue-number>` with the number
   `gh` just reported — this script lives in the flightdeck repo, not in
   the repo you are working in, so it must be run by its absolute path. If
   you are unsure what it does or how flightdeck expects it to be called,
   run `{{FLIGHTDECK_REPO}}/bin/fleet-spawn --explain` and follow what it
   tells you.

5. Return to what you were doing before this interruption, and say in one
   line what you forked and where it went. Do not start executing the plan
   you just wrote — another agent now has it.

If any step fails, stop at that step and report it rather than working
around it. A half-forked task, where the issue exists but no agent is
working it, is worse than one that plainly did not happen.
