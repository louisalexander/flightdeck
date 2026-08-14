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

Report findings worst-first, each with the file and line, and say plainly
which ones you think are worth fixing versus which you would leave.

If the work is genuinely clean, say so in a sentence and stop. Do not pad the
list to look thorough — an invented finding costs me more time than it saves.

Do not fix anything. Report first; wait to be told.
