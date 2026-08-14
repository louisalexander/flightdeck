---
id: pr
label: PR
interrupt: false
confirm: true
---
Commit, push, and open a pull request.

Everything PUSH does first — stage by name, never `git add -A` or
`git commit -a`, branch first if you are on the default branch, and write a
message that carries the reasoning rather than restating the diff. Then push,
setting upstream.

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

If the repository has no GitHub remote, or `gh` is not authenticated, say so
and print the PR body you would have filed rather than failing quietly.
