---
id: test
label: TEST
interrupt: false
confirm: false
---
Run this project's test suite and report what fails.

I am deciding whether to keep going here, and I would rather decide against
the suite than against your account of it. Run the whole thing, the way the
project runs it — not the one file you have been iterating on, which is the
one place a break is least likely to be hiding.

If anything failed, mark it on the deck: run
`{{FLIGHTDECK_REPO}}/bin/fleet-fail` with no arguments. That script lives in
the flightdeck repo rather than the one you are working in, so it needs its
absolute path. Give it nothing else — it works out which slot is yours by
itself, and a slot number you guessed would turn someone else's session red.
It exits non-zero if it could not mark anything; if that happens, say so,
because then the deck is still green and your reply is the only place the
failure exists. Run it with `--explain` if you want its full contract before
using it, and with `--clear`, again with no other arguments, once the thing
that failed passes again.

What that leaves behind outlasts this turn. The red survives the end of your
own reply and stays lit until it is cleared or I give you a fresh
instruction — that is the point of pressing this key rather than asking you
in words. It is there so I see it when I look up, not only while I am
already looking.

Report the failing test names and one line each on why. Not the runner's
output: I can scroll that myself, and a thousand lines of it buries the four
names I actually needed. If the suite is green, the count and one line
saying so is the whole answer. You are done when I know whether to keep
going, and — if not — which test to look at first.

Do not fix anything yet. Report first; wait to be told to fix.
