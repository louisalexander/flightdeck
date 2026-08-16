#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  export FLEET_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  mkdir -p "$FLEET_HOME/sessions" "$FLEET_CONFIG_DIR"
  cp "$ROOT/config/fleet.json" "$FLEET_CONFIG_DIR/fleet.json"
}

# id state repo branch [title]
mksession() {
  python3 - "$FLEET_HOME/sessions/$1.json" "$1" "$2" "$3" "$4" "${5:-}" <<'PY'
import json,sys
p,sid,st,repo,br,title = sys.argv[1:7]
json.dump({"session_id":sid,"state":st,"repo":repo,"branch":br,"title":title,
           "cwd":"/tmp","host":"iterm2","iterm_session":"U-"+sid,"pid":1,"ts":1},
          open(p,"w"))
PY
}

sf() {
  python3 -c "import json,sys;d=json.load(open('$FLEET_HOME/slots.json'));\
print([s for s in d['slots'] if s['index']==$1][0]['$2'])"
}
# json.dumps (not a bare print) so a dict/bool/null value round-trips
# exactly, quotes and all -- callers that pattern-match on the rendered
# JSON (e.g. the verdict tests below) depend on that. .get() rather than
# [$1] so a genuinely absent key reads as the string "null", not a
# KeyError, matching what a caller comparing against "null" expects.
top() { python3 -c "import json;d=json.load(open('$FLEET_HOME/slots.json'));print(json.dumps(d.get('$1')))"; }

@test "sessions claim the lowest free slot and the file always has 8 entries" {
  mksession A working flightdeck main
  mksession B blocked sisko feat/login
  run "$BIN/fleet-reconcile"
  [ "$status" -eq 0 ]
  [ "$(sf 0 session_id)" = "A" ]
  [ "$(sf 1 session_id)" = "B" ]
  [ "$(python3 -c "import json;print(len(json.load(open('$FLEET_HOME/slots.json'))['slots']))")" = "8" ]
  [ "$(sf 7 state)" = "empty" ]
}

@test "STICKINESS: a freed slot does not shift its neighbours, and is reused" {
  mksession A working flightdeck main
  mksession B blocked sisko feat/login
  "$BIN/fleet-reconcile"

  rm -f "$FLEET_HOME/sessions/A.json"
  "$BIN/fleet-reconcile"
  [ "$(sf 0 state)" = "empty" ]
  [ "$(sf 1 session_id)" = "B" ]

  mksession C idle homeassistant main
  "$BIN/fleet-reconcile"
  [ "$(sf 0 session_id)" = "C" ]
  [ "$(sf 1 session_id)" = "B" ]
}

@test "labels put repo on top and shorten the branch" {
  mksession B blocked sisko feat/login
  "$BIN/fleet-reconcile"
  [ "$(sf 0 label_top)" = "sisko" ]
  [ "$(sf 0 label_bottom)" = "login" ]
}

# --- the worktree- prefix -----------------------------------------------
#
# These read the shipped config/fleet.json (setup copies it), so they assert
# the prefix list the operator's deck actually uses, not a fixture.

@test "WTPREFIX: the worktree- prefix is stripped before the branch is shortened" {
  mksession B blocked flightdeck worktree-vague-row-1-title
  "$BIN/fleet-reconcile"
  [ "$(sf 0 label_bottom)" = "vague-title" ]
}

@test "WTPREFIX: sibling worktrees of one repo stay distinguishable" {
  # The point of the fix. Both keys used to read "workt-..." with the
  # discriminating tokens trimmed off to make room for a shared prefix.
  mksession A working flightdeck worktree-green-when-should-be-blue
  mksession B working flightdeck worktree-rows-3-4
  "$BIN/fleet-reconcile"
  [ "$(sf 0 label_bottom)" = "green-blue" ]
  [ "$(sf 1 label_bottom)" = "rows-3-4" ]
  [ "$(sf 0 label_bottom)" != "$(sf 1 label_bottom)" ]
}

@test "task title beats branch for the bottom label" {
  mksession B blocked sisko feat/login break-state
  "$BIN/fleet-reconcile"
  [ "$(sf 0 label_bottom)" = "break-state" ]
}

@test "labels never exceed maxChars" {
  mksession D working averyverylongreponame some/very-long-branch-name
  "$BIN/fleet-reconcile"
  t="$(sf 0 label_top)"; b="$(sf 0 label_bottom)"
  [ "${#t}" -le 11 ]
  [ "${#b}" -le 11 ]
}

@test "OVERFLOW: only 8 are slotted and the remainder is counted, not shuffled in" {
  i=1; while [ $i -le 9 ]; do mksession "S$i" working "repo$i" main; i=$((i+1)); done
  "$BIN/fleet-reconcile"
  [ "$(python3 -c "import json;d=json.load(open('$FLEET_HOME/slots.json'));\
print(len([s for s in d['slots'] if s['state']!='empty']))")" = "8" ]
  [ "$(top overflow)" = "1" ]
}

@test "a pinned slot is never auto-assigned and reduces capacity" {
  cat >"$FLEET_CONFIG_DIR/fleet.local.json" <<'EOF'
{"pins":{"7":{"host":"pinned-app","app":"ChatGPT","label_top":"ask","label_bottom":"ChatGPT"}}}
EOF
  i=1; while [ $i -le 8 ]; do mksession "P$i" working "repo$i" main; i=$((i+1)); done
  "$BIN/fleet-reconcile"
  [ "$(sf 7 host)"  = "pinned-app" ]
  [ "$(sf 7 app)"   = "ChatGPT" ]
  [ "$(sf 7 state)" = "idle" ]
  [ "$(top overflow)" = "1" ]
}

@test "a corrupt session file is skipped rather than failing the whole reconcile" {
  mksession OK working flightdeck main
  printf 'garbage{' >"$FLEET_HOME/sessions/BAD.json"
  run "$BIN/fleet-reconcile"
  [ "$status" -eq 0 ]
  [ "$(sf 0 session_id)" = "OK" ]
}

@test "no sessions at all still produces a valid 8-slot file" {
  run "$BIN/fleet-reconcile"
  [ "$status" -eq 0 ]
  [ "$(top overflow)" = "0" ]
  [ "$(sf 3 state)" = "empty" ]
}

# --- renderers ------------------------------------------------------------

# Rewrites the test config with a "renderers" list.
set_renderers() {
  python3 - "$FLEET_CONFIG_DIR/fleet.json" "$@" <<'PY'
import json, sys
path, renderers = sys.argv[1], sys.argv[2:]
cfg = json.load(open(path))
cfg["renderers"] = renderers
json.dump(cfg, open(path, "w"))
PY
}

@test "RENDERER SEAM: a renderer receives the fleet snapshot on stdin" {
  cat > "$BATS_TEST_TMPDIR/capture" <<EOF
#!/bin/sh
cat > "$BATS_TEST_TMPDIR/got.json"
EOF
  chmod +x "$BATS_TEST_TMPDIR/capture"
  set_renderers "$BATS_TEST_TMPDIR/capture"
  mksession A working flightdeck main
  mksession B blocked sisko feat/login

  run "$BIN/fleet-reconcile"
  [ "$status" -eq 0 ]

  run python3 -c "
import json
d = json.load(open('$BATS_TEST_TMPDIR/got.json'))
states = {s['session_id']: s['state'] for s in d['sessions']}
assert states == {'A': 'working', 'B': 'blocked'}, states
assert d['states']['working']['color'] == '#1256A3', d['states']
assert isinstance(d['ts'], int)
print('OK')
"
  [ "$output" = "OK" ]
}

@test "RENDERER SEAM: no renderers configured behaves exactly as before" {
  mksession A working flightdeck main
  run "$BIN/fleet-reconcile"
  [ "$status" -eq 0 ]
  [ "$(sf 0 session_id)" = "A" ]
}

@test "RENDERER SEAM: a missing renderer never fails reconcile" {
  set_renderers "$BATS_TEST_TMPDIR/does-not-exist"
  mksession A working flightdeck main
  run "$BIN/fleet-reconcile"
  [ "$status" -eq 0 ]
  [ "$(sf 0 session_id)" = "A" ]
}

@test "RENDERER SEAM: a crashing renderer never fails reconcile" {
  cat > "$BATS_TEST_TMPDIR/boom" <<'EOF'
#!/bin/sh
exit 3
EOF
  chmod +x "$BATS_TEST_TMPDIR/boom"
  set_renderers "$BATS_TEST_TMPDIR/boom"
  mksession A working flightdeck main
  run "$BIN/fleet-reconcile"
  [ "$status" -eq 0 ]
}

@test "RENDERER SEAM: a hanging renderer is timed out, not waited on forever" {
  cat > "$BATS_TEST_TMPDIR/hang" <<'EOF'
#!/bin/sh
sleep 30
EOF
  chmod +x "$BATS_TEST_TMPDIR/hang"
  set_renderers "$BATS_TEST_TMPDIR/hang"
  mksession A working flightdeck main
  start=$(date +%s)
  run "$BIN/fleet-reconcile"
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 0 ]
  [ "$elapsed" -lt 5 ]
}

@test "RENDERER SEAM: slots.json is written before renderers run, so a bad one cannot delay the deck" {
  cat > "$BATS_TEST_TMPDIR/checkslots" <<EOF
#!/bin/sh
cp "$FLEET_HOME/slots.json" "$BATS_TEST_TMPDIR/slots-at-render.json"
EOF
  chmod +x "$BATS_TEST_TMPDIR/checkslots"
  set_renderers "$BATS_TEST_TMPDIR/checkslots"
  mksession A working flightdeck main
  run "$BIN/fleet-reconcile"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/slots-at-render.json" ]
  run python3 -c "
import json
d = json.load(open('$BATS_TEST_TMPDIR/slots-at-render.json'))
print([s for s in d['slots'] if s['index']==0][0]['session_id'])
"
  [ "$output" = "A" ]
}

@test "RENDERER SEAM: every configured renderer runs, even if an earlier one fails" {
  cat > "$BATS_TEST_TMPDIR/boom" <<'EOF'
#!/bin/sh
exit 3
EOF
  cat > "$BATS_TEST_TMPDIR/second" <<EOF
#!/bin/sh
touch "$BATS_TEST_TMPDIR/second-ran"
EOF
  chmod +x "$BATS_TEST_TMPDIR/boom" "$BATS_TEST_TMPDIR/second"
  set_renderers "$BATS_TEST_TMPDIR/boom" "$BATS_TEST_TMPDIR/second"
  mksession A working flightdeck main
  run "$BIN/fleet-reconcile"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/second-ran" ]
}

# --- live iTerm2 task titles ---------------------------------------------
#
# The bottom line is meant to be the task title from the iTerm2 session name,
# with the branch only as a fallback (design spec lines 205-211). mksession
# writes iterm_session as "U-<id>", so these tests stub osascript to return a
# real-shaped UUID and set the field to match.

UUID_A="11111111-2222-3333-4444-555555555555"

stub_titles() {
  # $1 = raw session name to report for UUID_A
  cat >"$BATS_TEST_TMPDIR/osa" <<EOF
#!/bin/sh
printf '%s\t%s\n' "$UUID_A" "$1"
EOF
  chmod +x "$BATS_TEST_TMPDIR/osa"
  export FLEET_OSASCRIPT="$BATS_TEST_TMPDIR/osa"
}

# id state repo branch iterm_session
mksession_iterm() {
  python3 - "$FLEET_HOME/sessions/$1.json" "$1" "$2" "$3" "$4" "$5" <<'PY'
import json,sys
p,sid,st,repo,br,iterm = sys.argv[1:7]
json.dump({"session_id":sid,"state":st,"repo":repo,"branch":br,"title":"",
           "cwd":"/tmp","host":"iterm2","iterm_session":iterm,"pid":1,"ts":1},
          open(p,"w"))
PY
}

@test "TITLE: the live iTerm2 task title becomes the bottom label" {
  stub_titles "◑ break-state-exit-handling (node)"
  mksession_iterm B working flightdeck worktree-vague-row-1-title "$UUID_A"
  "$BIN/fleet-reconcile"
  [ "$(sf 0 label_bottom)" = "break-handl" ]
}

@test "TITLE: a session with no matching iTerm2 title falls back to its branch" {
  stub_titles "◑ irrelevant (node)"
  mksession_iterm B working flightdeck worktree-vague-row-1-title "U-nomatch"
  "$BIN/fleet-reconcile"
  [ "$(sf 0 label_bottom)" = "vague-title" ]
}

@test "TITLE: a failing osascript falls back to branches, and reconcile still succeeds" {
  printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/osa"
  chmod +x "$BATS_TEST_TMPDIR/osa"
  export FLEET_OSASCRIPT="$BATS_TEST_TMPDIR/osa"
  mksession_iterm B working flightdeck worktree-vague-row-1-title "$UUID_A"
  run "$BIN/fleet-reconcile"
  [ "$status" -eq 0 ]
  [ "$(sf 0 label_bottom)" = "vague-title" ]
}

@test "TITLE: a hanging osascript is timed out and reconcile still writes slots" {
  printf '#!/bin/sh\nsleep 30\n' >"$BATS_TEST_TMPDIR/osa"
  chmod +x "$BATS_TEST_TMPDIR/osa"
  export FLEET_OSASCRIPT="$BATS_TEST_TMPDIR/osa"
  mksession_iterm B working flightdeck worktree-vague-row-1-title "$UUID_A"
  # Times the whole invocation rather than shelling out to `timeout`, which
  # is GNU coreutils and not on a stock macOS. Same approach as the wedged
  # osascript test in tests/focus.bats.
  start=$(date +%s)
  run "$BIN/fleet-reconcile"
  end=$(date +%s)
  [ "$status" -eq 0 ]
  [ "$((end - start))" -lt 10 ]
  [ "$(sf 0 label_bottom)" = "vague-title" ]
}

@test "TITLE: a live title beats a stored one" {
  stub_titles "◑ live-title-wins (node)"
  python3 - "$FLEET_HOME/sessions/B.json" <<PY
import json,sys
json.dump({"session_id":"B","state":"working","repo":"flightdeck",
           "branch":"main","title":"stored-title","cwd":"/tmp","host":"iterm2",
           "iterm_session":"$UUID_A","pid":1,"ts":1}, open(sys.argv[1],"w"))
PY
  "$BIN/fleet-reconcile"
  [ "$(sf 0 label_bottom)" = "live-wins" ]
# --- halt, verdict and permission_mode publishing --------------------------
#
# The plugin watches slots.json and nothing else -- one file, one watch. So
# the halt latch, the currently-targeted permission request, and each slot's
# permission mode all travel there rather than teaching the plugin a second
# source to poll.
#
# Uses the single `top()` helper defined near the top of this file
# (extended, not duplicated, so the pre-existing `top overflow` callers
# below cannot silently start reading a shadowed definition -- see the
# 2026-08-15 fix-round-1 report entry).

@test "halted is false when no latch exists" {
  "$BIN/fleet-reconcile"
  [ "$(top halted)" = "false" ]
}

@test "halted is true when the latch exists" {
  touch "$FLEET_HOME/halt"
  "$BIN/fleet-reconcile"
  [ "$(top halted)" = "true" ]
}

@test "verdict is null when nothing is pending" {
  "$BIN/fleet-reconcile"
  [ "$(top verdict)" = "null" ]
}

@test "verdict names the targeted session, tool and tier" {
  mkdir -p "$FLEET_HOME/pending"
  python3 -c "
import json
json.dump({'session_id':'S1','tool':'Bash','input_digest':'d','input_summary':'x',
           'tier':'high','suggestion':None,'repo':'flightdeck','cwd':'/tmp',
           'repeats':3,'requested_at':int(__import__('time').time())}, open('$FLEET_HOME/pending/S1.json','w'))"
  "$BIN/fleet-reconcile"
  [[ "$(top verdict)" == *'"tool": "Bash"'* ]] || return 1
  [[ "$(top verdict)" == *'"tier": "high"'* ]] || return 1
  [[ "$(top verdict)" == *'"repeats": 3'* ]] || return 1
}

# REMEMBER's armed face names the repository and the rule -- the stated
# mitigation for the worktree trap, and undeliverable until slots.json
# carried the rule at all. `repo` is the CANONICAL repository (fleet-decide
# derives it from --git-common-dir); the AGENT is deliberately absent from
# that face, since it is the one scope the press is not limited to.
@test "verdict publishes the repository and the rule the armed REMEMBER face needs" {
  mkdir -p "$FLEET_HOME/pending"
  python3 -c "
import json
json.dump({'session_id':'S1','tool':'Bash','input_digest':'d','input_summary':'x',
           'tier':'high','repo':'flightdeck','cwd':'/tmp','repeats':1,
           'suggestion':{'type':'addRules','destination':'localSettings','behavior':'allow',
                         'rules':[{'toolName':'Bash','ruleContent':'git push:*'}]},
           'requested_at':int(__import__('time').time())}, open('$FLEET_HOME/pending/S1.json','w'))"
  "$BIN/fleet-reconcile"
  [[ "$(top verdict)" == *'"repo": "flightdeck"'* ]] || return 1
  [[ "$(top verdict)" == *'"rule": "Bash(git push:*)"'* ]] || return 1
}

# DETAIL's identity line must read the same as the Row 1 key for the same
# agent. The pending record's repo is the CANONICAL repository (for
# REMEMBER's armed face); Row 1's label is the session's own repo, which for
# a worktree session is the worktree. They differ for exactly the sessions
# this fleet runs, so the two channels are read from their own sources.
@test "verdict's agent line matches Row 1, while repo names the canonical repository" {
  mksession S1 blocked rows-3-4 wt
  mkdir -p "$FLEET_HOME/pending"
  python3 -c "
import json
json.dump({'session_id':'S1','tool':'Bash','input_digest':'d','input_summary':'x',
           'tier':'high','suggestion':None,'repo':'flightdeck','cwd':'/tmp','repeats':1,
           'requested_at':int(__import__('time').time())}, open('$FLEET_HOME/pending/S1.json','w'))"
  "$BIN/fleet-reconcile"
  [ "$(sf 0 label_top)" = "rows-3-4" ]
  [[ "$(top verdict)" == *'"agent": "rows-3-4"'* ]] || return 1
  [[ "$(top verdict)" == *'"repo": "flightdeck"'* ]] || return 1
}

@test "verdict publishes an empty rule when Claude Code offered no suggestion" {
  mkdir -p "$FLEET_HOME/pending"
  python3 -c "
import json
json.dump({'session_id':'S1','tool':'Bash','input_digest':'d','input_summary':'x',
           'tier':'high','suggestion':None,'repo':'flightdeck','cwd':'/tmp','repeats':1,
           'requested_at':int(__import__('time').time())}, open('$FLEET_HOME/pending/S1.json','w'))"
  "$BIN/fleet-reconcile"
  [[ "$(top verdict)" == *'"rule": ""'* ]] || return 1
}

@test "verdict never carries input_summary onto slots.json" {
  mkdir -p "$FLEET_HOME/pending"
  python3 -c "
import json
json.dump({'session_id':'S1','tool':'Bash','input_digest':'d','input_summary':'rm -rf /secret',
           'tier':'high','suggestion':None,'repo':'flightdeck','cwd':'/tmp',
           'repeats':1,'requested_at':int(__import__('time').time())}, open('$FLEET_HOME/pending/S1.json','w'))"
  "$BIN/fleet-reconcile"
  [[ "$(top verdict)" != *'input_summary'* ]] || return 1
  [[ "$(top verdict)" != *'rm -rf'* ]] || return 1
}

@test "a slot carries its session's permission_mode" {
  mksession A working flightdeck main
  python3 -c "
import json
p='$FLEET_HOME/sessions/A.json'
d=json.load(open(p)); d['permission_mode']='bypassPermissions'; json.dump(d, open(p,'w'))"
  "$BIN/fleet-reconcile"
  [ "$(sf 0 permission_mode)" = "bypassPermissions" ]
}

@test "a slot with no known permission_mode defaults to empty" {
  mksession A working flightdeck main
  "$BIN/fleet-reconcile"
  [ "$(sf 0 permission_mode)" = "" ]
}
