This key writes to a git repository. Three rules hold every time:

- **Stage by name.** Review what is actually staged and unstaged, and add
  the files this change needs by name. Never `git add -A` or `git commit -a`
  — repositories in this fleet carry untracked scratch that must not enter
  history.
- **Branch first.** If you are on the default branch, create a branch before
  committing, and say which one.
- **The message carries the reasoning.** What changed and why it is right,
  in prose. A reader six months from now needs the argument, not a
  restatement of the diff they can already see.
