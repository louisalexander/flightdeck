---
id: review
label: REVIEW
interrupt: false
confirm: false
---
Review your own work in this tree, the way a reviewer who did not write it
would.

Read the actual diff — staged, unstaged, and untracked. Do not review from
memory of what you intended to write; review what is on disk.

Look hardest at the things a fresh reviewer catches and an author does not:

- **Where the code does not match what was asked.** Not what you decided to
  do instead, but the gap between the request and the result.
- **Debris.** Debug output, commented-out attempts, a scratch file, a
  temporary constant that became permanent, an unused import.
- **Paths you never exercised.** Which branches has nothing actually run?
  An error handler you wrote and never triggered is untested code, and saying
  so is more useful than asserting it works.
- **Things that only work here.** A hardcoded path, an assumption about the
  machine, an ordering that happens to hold today.
- **Tests that would pass if the feature were deleted.** If a test cannot
  fail, it is documentation with a runner attached.

Report findings worst-first, at most five, each with the file and line and
about two lines on what is wrong and why it matters here. Say plainly which
ones you think are worth fixing and which you would leave. If you found more
than five, the five you chose *are* the review — a sixth I never scroll far
enough to reach is worth less than the five I read, and choosing them is
part of what I am asking you to do.

If the work is genuinely clean, say so in a sentence and stop.

Do not fix anything. Report first; wait to be told. You are done when I could
hand this tree to someone else knowing what they will find in it.
