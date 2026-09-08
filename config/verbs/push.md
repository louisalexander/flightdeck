---
id: push
label: PUSH
interrupt: false
confirm: true
common: git
---
Commit the work in progress, then push it.

I want this off the machine — somewhere I can reach it from another
window, and somewhere it survives this laptop — without it becoming a
pull request yet.

Push once the commit is made, setting upstream if the branch has none.

Stop there. Do not open a pull request — that is what PR is for. If the push
is rejected because the remote has moved, do not force: fetch, report what
diverged, and wait to be told how to reconcile it.

One line back: which branch, and where it went. Not the commit message, not
the file list — the branch name and the remote are what tell me whether to
go and look. If the push did not happen, that same line says so and names
what stopped it. Done is a branch on the remote that I can open, or a plain
statement of why there is not one.
