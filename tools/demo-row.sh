#!/usr/bin/env bash
# Drives all 8 slots through every lifecycle state so you can watch the row.
# Uses a SEPARATE FLEET_HOME? No -- it must write the real one the plugin watches.
# It only creates fake sessions with pid 0 (never reaped) and removes them at the end.
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
PY="$(cat "$HOME/.fleet/interpreter" 2>/dev/null || command -v python3)"
S="$HOME/.fleet/sessions"
mk() { "$PY" -c "
import json,sys
json.dump({'session_id':sys.argv[1],'state':sys.argv[2],'repo':sys.argv[3],'branch':sys.argv[4],
'title':'','cwd':'/tmp','host':'iterm2','iterm_session':'','pid':0,'ts':int(sys.argv[5])},
open('$S/'+sys.argv[1]+'.json','w'))" "$@"; }
step() { printf '  %s\n' "$1"; "$R/bin/fleet-reconcile"; sleep "${2:-2}"; }

printf '\nflightdeck demo — watch row 1\n\n'
i=1; while [ $i -le 6 ]; do mk "DEMO$i" idle "demo$i" "main" "$((100+i))"; i=$((i+1)); done
step "all idle — dim grey, quiet" 2
mk DEMO1 working flightdeck main 101;      step "slot 1 working — dark blue, plays in the background" 2
mk DEMO2 working sisko feat/login 102;     step "slot 2 working" 2
mk DEMO3 blocked beacon feat/beacon-v1 103; step "slot 3 BLOCKED — bright amber, this is the one that pulls your eye" 3
mk DEMO4 "done" homeassistant deck-render 104; step "slot 4 done — green, turn complete" 2
mk DEMO5 failed yardmap hook-notif 105;     step "slot 5 FAILED — deep red, sticky until cleared" 3
step "hold here — compare amber (needs you) vs red (broke) vs blue (busy)" 4
i=1; while [ $i -le 6 ]; do rm -f "$S/DEMO$i.json"; i=$((i+1)); done
step "demo cleared — back to your real fleet" 1
printf '\ndone. your live agents are back on the row.\n\n'
