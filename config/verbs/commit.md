---
id: commit
label: COMMIT
interrupt: false
confirm: true
---
Commit the work in progress.

Not on the panel by default — the eight keys are TEST, DIFF, NOTE, ISSUE,
PUSH, PR, DOUBT, STOP. This verb exists so it can be swapped in without
writing anything new; PUSH already commits before pushing, so the deck is
not missing the ability to commit, only the ability to commit *without*
pushing.

Before committing:

- Review what is actually staged and unstaged. Stage the files this change
  needs by name. Never `git add -A` or `git commit -a` in this repository:
  it has untracked scratch directories that must not enter history.
- If the working tree is on the default branch, create a branch first.

Write the message the way this repository writes them: what changed and
*why it is right*, in prose. The reasoning is the payload — a reader six
months from now needs the argument, not a restatement of the diff they can
already see.

Do not push. That is what PUSH is for.
