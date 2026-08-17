---
id: commit
label: COMMIT
interrupt: false
confirm: true
common: git
---
Commit the work in progress.

The work has reached a point worth recording and I want it recorded now,
while I can still see what it was for. Nothing leaves this machine.

Not on the panel by default — the eight keys are TEST, DIFF, NOTE, ISSUE,
PUSH, PR, DOUBT, STOP. This verb exists so it can be swapped in without
writing anything new; PUSH already commits before pushing, so the deck is
not missing the ability to commit, only the ability to commit *without*
pushing.

Do not push, and do not open a pull request. Those are PUSH and PR. If
there is nothing here worth recording — an empty tree, or only scratch that
should never enter history — say so and commit nothing. A commit made so
that there is something to report is worse than no commit.

Answer in one line: what you committed, and on which branch. Not the message
read back to me, not a list of files — `git show` holds both, and I will
look if the line makes me want to. You are done when there is a commit that
did not exist a minute ago and nothing went into it that you did not choose
to put there.
