#!/usr/bin/env bash
# Walks the free keys of Row 1 through every lifecycle state so you can watch
# the deck react.
#
# Two things this is careful about:
#   1. It never touches your real agents. Slot assignment is sticky, so live
#      sessions and pinned slots keep their keys; the demo only drives slots
#      that are genuinely empty when it starts.
#   2. It narrates the ACTUAL row read back from slots.json after each step,
#      rather than announcing slots it assumed it owned. An earlier version
#      claimed "slot 1 working" while its session had landed somewhere else
#      entirely, which made a working demo look broken.
#
# Demo sessions use pid 0 so the reaper never touches them, and are removed
# on exit even if you interrupt.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PY="$(cat "$HOME/.fleet/interpreter" 2>/dev/null || command -v python3)"
SESSIONS="$HOME/.fleet/sessions"
SLOTS="$HOME/.fleet/slots.json"

cleanup() {
  find "$SESSIONS" -name 'FDDEMO*.json' -delete 2>/dev/null
  "$REPO/bin/fleet-reconcile" 2>/dev/null
}
trap cleanup EXIT INT TERM

# Slots with no session and no pin — the only ones we may drive.
free_slots() {
  "$PY" - "$SLOTS" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print(" ".join(str(s["index"]) for s in d.get("slots", []) if s.get("state") == "empty"))
PY
}

# Writes a demo session. Ties itself to a slot by claiming it while free.
mk() { # id state repo branch
  "$PY" - "$SESSIONS" "$@" <<'PY'
import json, os, sys, time
sessions, sid, state, repo, branch = sys.argv[1:6]
json.dump({"session_id": sid, "state": state, "repo": repo, "branch": branch,
           "title": "", "cwd": "/tmp", "host": "iterm2", "iterm_session": "",
           "pid": 0, "ts": int(time.time())},
          open(os.path.join(sessions, sid + ".json"), "w"))
PY
}

show() { # narration
  "$REPO/bin/fleet-reconcile"
  printf '\n  %s\n' "$1"
  "$PY" - "$SLOTS" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
glyph = {"blocked": "▲", "working": "▶", "done": "✓", "idle": "·",
         "failed": "✕", "empty": " "}
cells = []
for s in d.get("slots", []):
    g = glyph.get(s.get("state", "empty"), "?")
    label = (s.get("label_bottom") or s.get("label_top") or "")[:7]
    cells.append("%s %-7s" % (g, label))
print("    " + " | ".join(cells))
PY
  sleep "${2:-2}"
}

FREE="$(free_slots)"
COUNT="$(printf '%s' "$FREE" | wc -w | tr -d ' ')"

printf '\nflightdeck demo — watch Row 1\n'
printf '  your live agents keep their keys; only free slots are driven\n'
printf '  free slots: %s\n' "${FREE:-none}"

if [ "${COUNT:-0}" -lt 1 ]; then
  printf '\n  Row 1 is fully occupied by real sessions — nothing free to demo.\n'
  printf '  Close an agent, or just watch the real fleet.\n\n'
  exit 0
fi

set -- $FREE
S1="${1:-}"; S2="${2:-$S1}"; S3="${3:-$S1}"; S4="${4:-$S2}"; S5="${5:-$S3}"

mk "FDDEMO$S1" idle    alpha   main
[ -n "$S2" ] && mk "FDDEMO$S2" idle bravo   main
[ -n "$S3" ] && mk "FDDEMO$S3" idle charlie main
[ -n "$S4" ] && mk "FDDEMO$S4" idle delta   main
[ -n "$S5" ] && mk "FDDEMO$S5" idle echo    main
show "all demo keys idle — dim grey, deliberately ignorable" 3

mk "FDDEMO$S1" working alpha feat/parser
show "one starts working — dark blue, recedes into the background" 3

mk "FDDEMO$S2" working bravo fix/timeout
show "a second one working — busy agents don't compete for attention" 3

mk "FDDEMO$S3" blocked charlie feat/auth-refactor
show "BLOCKED — bright amber. this is the key that should pull your eye" 4

mk "FDDEMO$S4" "done" delta chore/deps
show "another finished — green means a turn completed, awaiting you" 3

mk "FDDEMO$S5" failed echo feat/migration
show "FAILED — deep red, sticky until you clear it" 3

show "compare: amber needs you · red broke · blue is busy · grey is quiet" 6

printf '\n  clearing demo sessions...\n'
cleanup
printf '  done — your real fleet has the row back.\n\n'
