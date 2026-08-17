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

One press, one issue. If two separate things surfaced, file the one that
would be lost first and name the other in a line at the end — I will press
the key again if I want it.

If the repository has no GitHub remote, or `gh` is not authenticated, say so
and print the issue body you would have filed instead of failing silently —
losing the capture is the only outcome that matters here.

The body is the work; what you say here is a receipt. End with the issue
number and its URL, one line, and leave it there. Do not repeat the body
into the terminal: I can open the link, and reading it twice spends the
glance this key was meant to save. Done is an issue that someone who was
not here could pick up cold.
