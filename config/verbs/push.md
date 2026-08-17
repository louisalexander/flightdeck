---
id: push
label: PUSH
interrupt: false
confirm: true
common: git
---
Commit the work in progress, then push it.

Push once the commit is made, setting upstream if the branch has none.

Stop there. Do not open a pull request — that is what PR is for. If the push
is rejected because the remote has moved, do not force: fetch, report what
diverged, and wait to be told how to reconcile it.
