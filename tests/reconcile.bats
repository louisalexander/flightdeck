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
top() { python3 -c "import json;d=json.load(open('$FLEET_HOME/slots.json'));print(d['$1'])"; }

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
