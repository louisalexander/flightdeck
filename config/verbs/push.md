---
id: push
label: PUSH
interrupt: false
confirm: true
---
Commit the work in progress, then push it.

Before committing:

- Review what is actually staged and unstaged, and stage the files this
  change needs **by name**. Never `git add -A` or `git commit -a` here —
  repositories in this fleet carry untracked scratch that must not enter
  history.
- If you are on the default branch, create a branch first and say so.

Write the message the way this repository writes them: what changed and why
it is right, in prose. The reasoning is the payload — a reader six months
from now needs the argument, not a restatement of the diff.

Then push, setting upstream if the branch has none.

Stop there. Do not open a pull request — that is what PR is for. If the push
is rejected because the remote has moved, do not force: fetch, report what
diverged, and wait to be told how to reconcile it.
