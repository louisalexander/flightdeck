---
id: test
label: TEST
interrupt: false
confirm: false
---
Run this project's test suite and report what fails.

Report the outcome so the deck can show it:

- If the suite fails, run `{{FLIGHTDECK_REPO}}/bin/fleet-fail` -- this
  script lives in the flightdeck repo, not in the repo you are working in,
  so it must be run by its absolute path rather than a relative one.
- If you are unsure what that does or how flightdeck expects it to be
  called, run `{{FLIGHTDECK_REPO}}/bin/fleet-fail --explain` and follow
  what it tells you.

Do not fix anything yet. Report first; wait to be told to fix.
