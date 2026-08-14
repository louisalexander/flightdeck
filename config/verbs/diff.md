---
id: diff
label: DIFF
interrupt: false
confirm: false
---
Summarise what has changed in this working tree, and why.

Not a raw diff — the terminal can already show me that, and it tells me
nothing I cannot read for myself. What I want is the part a diff does not
carry:

- What changed, grouped by intent rather than by file. One line each.
- Why each group changed — the decision behind it, not a restatement of
  the code.
- Anything in there I would be surprised by: a change I did not ask for, a
  workaround you left in, a decision you made that could reasonably have
  gone the other way.
- Anything unfinished or deliberately deferred, so it does not get
  committed as though it were complete.

Include unstaged and untracked work, not just what is staged — the point
is to see the whole state of the tree.

Keep it short enough to read at a glance. If it does not fit in a screen,
you are summarising too finely.
