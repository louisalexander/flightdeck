---
id: issue
label: ISSUE
interrupt: false
confirm: true
---
Capture what we are currently up against as a GitHub issue, so it survives
this session.

The subject is whatever is live right now: the problem we just hit, the
approach we are arguing about, the tangent we noticed and deliberately did
not chase, or the thing we worked around instead of fixing. Prefer the
thing that would be lost if this session ended in the next minute.

Write it for someone who was not here:

- What is actually wrong, or actually undecided. Not a title restating the
  symptom.
- The evidence. Paste the real output, the real path, the real line — what
  you observed, not what you concluded.
- What has already been tried and ruled out, so nobody repeats it.
- What a fix would need to decide. If there is a real design choice, name
  the options and their costs rather than picking one silently.

Then create it with `gh issue create`, in the repository the current
working directory belongs to. Include enough of the above in the body that
the issue stands alone.

If the repository has no GitHub remote, or `gh` is not authenticated, say so
and print the issue body you would have filed instead of failing silently —
losing the capture is the only outcome that matters here.

Do not fix the thing you are filing. Filing it is the whole job.
