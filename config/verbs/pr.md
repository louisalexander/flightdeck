---
id: pr
label: PR
interrupt: false
confirm: true
common: git
---
Commit, push, and open a pull request.

Everything PUSH does first: commit, then push, setting upstream.

Then open the PR with `gh pr create`, against the default branch unless the
work clearly belongs on top of another open branch.

The PR body is the part worth spending time on. It should let a reviewer
decide without re-deriving the work:

- What this changes, and why it is the right change rather than a change
  that happens to pass.
- Anything you had to decide on the way, and what you decided against.
- What you verified, and — honestly — what you did not. A reviewer trusts an
  explicit "not tested on real hardware" far more than silence.
- Anything deliberately left out, so it does not read as an oversight.

Open it and stop. Do not merge it, do not enable auto-merge, and do not go
back to editing the branch it is built on — a reviewer looking at a moving
PR cannot review it.

If the repository has no GitHub remote, or `gh` is not authenticated, say so
and print the PR body you would have filed rather than failing quietly.

The body is the work; what you say here is a receipt. End with the PR's URL,
one line, and do not paste the body back into the terminal — it is already
on the page I am about to open. Done is a pull request a reviewer could act
on without asking you a question first.
