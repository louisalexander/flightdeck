#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  export FLEET_SKIP_RECONCILE=1
  mkdir -p "$FLEET_HOME/sessions"
  PAYLOAD='{"session_id":"S1","cwd":"/tmp"}'
}

emit() { printf '%s' "${2:-$PAYLOAD}" | "$BIN/fleet-emit" "$1"; }
field() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" \
            "$FLEET_HOME/sessions/S1.json" "$1"; }

@test "SessionStart maps to idle" { emit SessionStart; [ "$(field state)" = "idle" ]; }
@test "UserPromptSubmit maps to working" { emit UserPromptSubmit; [ "$(field state)" = "working" ]; }
@test "Notification maps to blocked" { emit Notification; [ "$(field state)" = "blocked" ]; }
@test "Stop maps to done" { emit Stop; [ "$(field state)" = "done" ]; }

# --- Stop with background work in flight -----------------------------------
#
# Stop means "the assistant turn ended", not "the agent is awaiting the
# operator". A turn that ends with a backgrounded subagent (or shell, workflow,
# monitor) still in flight wakes itself back up with no operator action, so it
# is `working` -- painting it green would claim a completion that has not
# happened and invite the operator to give an instruction to a busy agent.
#
# Claude Code hands us exactly this distinction: the Stop payload's
# background_tasks array, documented as letting hooks "distinguish 'session is
# done' from 'session is paused waiting for background work to wake it'".
#
# The field is `.optional()` in Claude Code's schema, so an absent one means "no
# information" and must keep the historical done mapping -- older Claude Code
# omits it entirely, and the bare "Stop maps to done" test above covers that.
stop_bg() { emit Stop "{\"session_id\":\"S1\",\"cwd\":\"/tmp\",\"background_tasks\":$1}"; }

@test "Stop with a running subagent maps to working" {
  stop_bg '[{"id":"a91","type":"subagent","status":"running","description":"d","agent_type":"general-purpose"}]'
  [ "$(field state)" = "working" ]
}

@test "Stop with a backgrounded shell maps to working" {
  stop_bg '[{"id":"b3l","type":"shell","status":"running","description":"sleep 45","command":"sleep 45"}]'
  [ "$(field state)" = "working" ]
}

@test "Stop with an empty background_tasks array maps to done" {
  stop_bg '[]'
  [ "$(field state)" = "done" ]
}

@test "Stop with a malformed background_tasks maps to done" {
  stop_bg '"not a list"'
  [ "$(field state)" = "done" ]
}

@test "Stop with background work still clears a blocked marker" {
  emit Notification
  [ -e "$(marker)" ]
  stop_bg '[{"id":"a91","type":"subagent","status":"running","description":"d"}]'
  [ "$(field state)" = "working" ]
  [ ! -e "$(marker)" ]
}

# --- blocked-marker lifecycle (the PreToolUse Resumed guard) ---------------
#
# Notification creates a marker at $FLEET_HOME/blocked/<session_id> so the
# guarded PreToolUse shell hook knows to pay for a python process and emit
# Resumed. Every event that proves the agent is no longer waiting on the
# operator -- UserPromptSubmit, Stop, SessionEnd, and Resumed itself -- must
# clear that marker, so it can never be left orphaned (an orphaned marker
# would make every future tool call in that session pay the python cost
# forever).

marker() { printf '%s' "$FLEET_HOME/blocked/S1"; }

@test "Notification creates the blocked marker" {
  emit Notification
  [ -e "$(marker)" ]
}

@test "Resumed clears a blocked session to working and removes the marker" {
  emit Notification
  [ "$(field state)" = "blocked" ]
  [ -e "$(marker)" ]

  emit Resumed
  [ "$(field state)" = "working" ]
  [ ! -e "$(marker)" ]
}

@test "UserPromptSubmit removes a stale marker" {
  emit Notification
  [ -e "$(marker)" ]
  emit UserPromptSubmit
  [ ! -e "$(marker)" ]
}

@test "Stop removes a stale marker" {
  emit Notification
  [ -e "$(marker)" ]
  emit Stop
  [ ! -e "$(marker)" ]
}

@test "SessionEnd removes a stale marker" {
  emit Notification
  [ -e "$(marker)" ]
  emit SessionEnd
  [ ! -e "$(marker)" ]
}

@test "Resumed on a session that is NOT blocked changes nothing" {
  emit SessionStart
  [ "$(field state)" = "idle" ]
  emit Resumed
  [ "$(field state)" = "idle" ]
}

@test "Resumed for an unknown session is a silent no-op" {
  run bash -c "printf '%s' '$PAYLOAD' | '$BIN/fleet-emit' Resumed"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$FLEET_HOME/sessions")" ]
}

@test "SessionEnd removes the session file" {
  emit SessionStart
  [ -f "$FLEET_HOME/sessions/S1.json" ]
  emit SessionEnd
  [ ! -f "$FLEET_HOME/sessions/S1.json" ]
}

# FIX 5 (fix wave, 2026-08-14): the spec requires SessionEnd to clear any
# queue entry for that session, alongside the focus/marker clearing it
# already did. A resumed Claude Code session keeps its session id, so a
# leftover entry would otherwise be delivered by the first Stop after
# resume -- a verb staged before the session ended firing into whatever
# comes back under the same id.
@test "SessionEnd clears any queued verb for that session" {
  emit SessionStart
  mkdir -p "$FLEET_HOME/queue"
  python3 -c "
import json
json.dump({'verb':'test','prompt':'X','verb_path':'','queued_at':1},
          open('$FLEET_HOME/queue/S1.json','w'))"
  [ -e "$FLEET_HOME/queue/S1.json" ]
  emit SessionEnd
  [ ! -e "$FLEET_HOME/queue/S1.json" ]
}

@test "every event appends one line to the journal spine, removals included" {
  emit SessionStart; emit UserPromptSubmit; emit Stop; emit SessionEnd
  [ "$(wc -l <"$FLEET_HOME/events.jsonl" | tr -d ' ')" = "4" ]
  [ "$(tail -1 "$FLEET_HOME/events.jsonl" | python3 -c 'import json,sys;print(json.load(sys.stdin)["event"])')" = "SessionEnd" ]
}

@test "iTerm session uuid is captured with its w/t/p prefix stripped" {
  ITERM_SESSION_ID="w1t2p0:ABC-123" emit SessionStart
  [ "$(field iterm_session)" = "ABC-123" ]
  [ "$(field host)" = "iterm2" ]
}

@test "host is unknown when not running under iTerm" {
  ITERM_SESSION_ID="" emit SessionStart
  [ "$(field host)" = "unknown" ]
}

@test "repo and branch are derived from the session cwd" {
  R="$BATS_TEST_TMPDIR/somerepo"
  mkdir -p "$R" && git init -q "$R" && git -C "$R" checkout -q -b my-branch 2>/dev/null || true
  emit SessionStart "{\"session_id\":\"S1\",\"cwd\":\"$R\"}"
  [ "$(field repo)" = "somerepo" ]
}

@test "garbage stdin exits 0 and creates no session file" {
  run bash -c "printf 'not json at all' | '$BIN/fleet-emit' Stop"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$FLEET_HOME/sessions")" ]
}

@test "unknown event name is ignored safely" {
  run bash -c "printf '%s' '$PAYLOAD' | '$BIN/fleet-emit' TotallyUnknownEvent"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$FLEET_HOME/sessions")" ]
}

@test "an unwritable state directory still exits 0" {
  run env FLEET_HOME=/nonexistent/unwritable bash -c "printf '{}' | '$BIN/fleet-emit' Stop"
  [ "$status" -eq 0 ]
}

@test "a missing session id exits 0 without writing" {
  run bash -c "printf '{\"cwd\":\"/tmp\"}' | env CLAUDE_CODE_SESSION_ID= '$BIN/fleet-emit' Stop"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$FLEET_HOME/sessions")" ]
}

# --- find_agent_pid: macOS comm can be a full path containing spaces -------
#
# A first draft parsed `ps -o comm= -o ppid= -p <pid>` with a single
# whitespace split, taking parts[0] as comm. On macOS `comm` is the full
# executable path (e.g. "/Applications/Private Internet Access.app/.../
# pia-daemon"), which contains spaces -- confirmed against a real running
# process (PIA's daemon, pid 299 at the time) where that approach yielded
# `comm == "/Applications/Pr"` instead of the real path. fleet-emit's
# find_agent_pid instead issues two single-field `ps` calls (see _ps_field),
# each read whole with no split needed. This test spawns a real process
# whose own executable path contains a space and asserts _ps_field returns
# the untruncated path so the basename match against "claude"/"node" still
# works.
@test "_ps_field reads a comm value containing spaces without truncating it" {
  # A copied/renamed binary gets SIGKILLed on launch by macOS's code-signing
  # enforcement, so a symlink is used instead: the kernel resolves it and
  # execs the real /bin/sleep, but `ps -o comm=` reports it by the path it
  # was invoked through -- the spaced symlink path -- which is exactly the
  # shape a real "*.app/Contents/MacOS/<binary>" comm takes.
  DIR="$BATS_TEST_TMPDIR/Program With Space"
  mkdir -p "$DIR"
  ln -s /bin/sleep "$DIR/claude"
  "$DIR/claude" 30 &
  CPID=$!
  sleep 0.2

  run python3 -c "
import importlib.machinery
import importlib.util
loader = importlib.machinery.SourceFileLoader('fleet_emit_under_test', '$BIN/fleet-emit')
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
comm = mod._ps_field($CPID, 'comm')
assert ' ' in comm, comm
assert comm.rsplit('/', 1)[-1] == 'claude', comm
print('OK')
"
  kill "$CPID" 2>/dev/null || true
  wait "$CPID" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# --- bounded subprocess timeouts --------------------------------------------
#
# fleet-emit shells out twice: to `ps` (inside find_agent_pid) and to
# fleet-reconcile. Both calls now carry a timeout= so a wedged child process
# cannot hang the hook -- this matters more once Task 4 lands a real
# fleet-reconcile that globs a directory and reads N files. Both tests below
# genuinely exercise the timeout branch (a stub that sleeps past the bound)
# rather than asserting the timeout value by inspection, and time the whole
# invocation to prove it returns promptly rather than only checking status.

@test "a wedged ps does not hang fleet-emit; it still exits 0 promptly" {
  FAKEBIN="$BATS_TEST_TMPDIR/fakepsbin"
  mkdir -p "$FAKEBIN"
  cat > "$FAKEBIN/ps" <<'SH'
#!/bin/sh
sleep 30
SH
  chmod +x "$FAKEBIN/ps"

  start=$(date +%s)
  run env PATH="$FAKEBIN:$PATH" bash -c "printf '%s' '$PAYLOAD' | '$BIN/fleet-emit' SessionStart"
  end=$(date +%s)
  elapsed=$((end - start))

  [ "$status" -eq 0 ]
  [ "$elapsed" -lt 10 ]
  [ "$(field pid)" = "0" ]
}

@test "a wedged fleet-reconcile does not hang fleet-emit; it still exits 0 within the bound" {
  # fleet-emit resolves fleet-reconcile relative to its own directory, so a
  # full copy of fleet-emit (plus a symlink to the real fleetlib.py) is
  # staged in a scratch bin alongside a stub fleet-reconcile that sleeps
  # well past the 10s timeout.
  FAKEBIN="$BATS_TEST_TMPDIR/fakereconcilebin"
  mkdir -p "$FAKEBIN"
  cp "$BIN/fleet-emit" "$FAKEBIN/fleet-emit"
  chmod +x "$FAKEBIN/fleet-emit"
  ln -s "$BIN/fleetlib.py" "$FAKEBIN/fleetlib.py"
  cat > "$FAKEBIN/fleet-reconcile" <<'PY'
#!/usr/bin/env python3
import time
time.sleep(30)
PY
  chmod +x "$FAKEBIN/fleet-reconcile"

  unset FLEET_SKIP_RECONCILE
  start=$(date +%s)
  run bash -c "printf '%s' '$PAYLOAD' | '$FAKEBIN/fleet-emit' Stop"
  end=$(date +%s)
  elapsed=$((end - start))

  [ "$status" -eq 0 ]
  [ "$elapsed" -lt 15 ]
}

# --- Notification classification by notification_type ----------------------
#
# Claude Code fires Notification for two unrelated situations and hands us a
# notification_type to tell them apart. Only the types that genuinely need an
# operator decision may paint a slot amber; the informational ones (chiefly
# idle_prompt, the ~60s nudge after a finished turn) must leave the slot
# exactly as they found it, or `done` decays into `blocked` and green stops
# meaning anything. A missing or unrecognised type keeps the old behaviour:
# a false amber is visible and self-clearing via the Resumed guard, whereas a
# missed real block leaves a stuck agent looking green.

notif() { emit Notification "{\"session_id\":\"S1\",\"cwd\":\"/tmp\",\"notification_type\":\"$1\"}"; }

@test "a permission_prompt notification still blocks and marks" {
  notif permission_prompt
  [ "$(field state)" = "blocked" ]
  [ -e "$(marker)" ]
}

@test "a worker_permission_prompt notification blocks" {
  notif worker_permission_prompt
  [ "$(field state)" = "blocked" ]
}

@test "an agent_needs_input notification blocks" {
  notif agent_needs_input
  [ "$(field state)" = "blocked" ]
}

@test "an elicitation_dialog notification blocks" {
  notif elicitation_dialog
  [ "$(field state)" = "blocked" ]
}

@test "an elicitation_url_dialog notification blocks" {
  notif elicitation_url_dialog
  [ "$(field state)" = "blocked" ]
}

@test "IDLE: an idle_prompt after Stop leaves the session file byte-identical" {
  emit Stop
  before="$(cat "$FLEET_HOME/sessions/S1.json")"
  notif idle_prompt
  [ "$(cat "$FLEET_HOME/sessions/S1.json")" = "$before" ]
  [ "$(field state)" = "done" ]
}

@test "IDLE: an idle_prompt writes no blocked marker" {
  emit Stop
  notif idle_prompt
  [ ! -e "$(marker)" ]
}

@test "IDLE: an idle_prompt mid-turn does not disturb a working session" {
  emit UserPromptSubmit
  notif idle_prompt
  [ "$(field state)" = "working" ]
  [ ! -e "$(marker)" ]
}

@test "IDLE: an idle_prompt never clears an existing marker" {
  notif permission_prompt
  [ -e "$(marker)" ]
  notif idle_prompt
  [ -e "$(marker)" ]
  [ "$(field state)" = "blocked" ]
}

@test "an agent_completed notification leaves the state alone" {
  emit Stop
  notif agent_completed
  [ "$(field state)" = "done" ]
  [ ! -e "$(marker)" ]
}

@test "an auth_success notification leaves the state alone" {
  emit Stop
  notif auth_success
  [ "$(field state)" = "done" ]
}

@test "a push_notification leaves the state alone" {
  emit Stop
  notif push_notification
  [ "$(field state)" = "done" ]
}

@test "computer_use_enter leaves the state alone" {
  emit Stop
  notif computer_use_enter
  [ "$(field state)" = "done" ]
}

@test "BACK-COMPAT: a notification with no notification_type still blocks" {
  emit Notification
  [ "$(field state)" = "blocked" ]
  [ -e "$(marker)" ]
}

@test "FAIL-SAFE: an unrecognised notification_type still blocks" {
  notif some_future_type
  [ "$(field state)" = "blocked" ]
  [ -e "$(marker)" ]
}

@test "an ignored notification is still journalled, with its type" {
  emit Stop
  notif idle_prompt
  run python3 -c "
import json
rows=[json.loads(l) for l in open('$FLEET_HOME/events.jsonl')]
n=[r for r in rows if r['event']=='Notification']
assert len(n)==1, n
print(n[0].get('notification_type'))
"
  [ "$status" -eq 0 ]
  [ "$output" = "idle_prompt" ]
}

@test "a blocking notification records its type in the journal too" {
  notif permission_prompt
  run python3 -c "
import json
rows=[json.loads(l) for l in open('$FLEET_HOME/events.jsonl')]
print([r.get('notification_type') for r in rows if r['event']=='Notification'][0])
"
  [ "$output" = "permission_prompt" ]
}

# --- repo label in a linked worktree ------------------------------------
#
# Row 1's top line is meant to be the repository (v1 spec line 20). A linked
# worktree's --show-toplevel is the worktree, so the label used to read the
# worktree's directory name -- and a FORK-spawned agent showed "issue-13"
# with no indication of which repo it belonged to.

@test "REPOLABEL: a linked worktree reports the repository, not its own dir" {
  R="$BATS_TEST_TMPDIR/myrepo"
  git init -q "$R"
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  echo x > "$R/f.txt"
  git -C "$R" add .
  git -C "$R" commit -qm seed
  git -C "$R" worktree add -q -b wt "$BATS_TEST_TMPDIR/issue-99"

  printf '{"session_id":"WT1","cwd":"%s"}' "$BATS_TEST_TMPDIR/issue-99" \
    | "$BIN/fleet-emit" UserPromptSubmit
  run python3 -c "import json;print(json.load(open('$FLEET_HOME/sessions/WT1.json'))['repo'])"
  [ "$output" = "myrepo" ]
}

@test "REPOLABEL: a primary checkout is unaffected" {
  R="$BATS_TEST_TMPDIR/plainrepo"
  git init -q "$R"
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  echo x > "$R/f.txt"
  git -C "$R" add .
  git -C "$R" commit -qm seed

  printf '{"session_id":"P1","cwd":"%s"}' "$R" | "$BIN/fleet-emit" UserPromptSubmit
  run python3 -c "import json;print(json.load(open('$FLEET_HOME/sessions/P1.json'))['repo'])"
  [ "$output" = "plainrepo" ]
}

@test "REPOLABEL: a non-repo cwd still yields an empty label, not a crash" {
  mkdir -p "$BATS_TEST_TMPDIR/notarepo"
  printf '{"session_id":"N1","cwd":"%s"}' "$BATS_TEST_TMPDIR/notarepo" \
    | "$BIN/fleet-emit" UserPromptSubmit
  run python3 -c "import json;print(repr(json.load(open('$FLEET_HOME/sessions/N1.json'))['repo']))"
  [ "$output" = "''" ]
}

@test "REPOLABEL: the branch still comes from the worktree, not the primary" {
  # Only the repo half moves. Branch must stay per-worktree or every
  # worktree of a repo would report the primary checkout's branch.
  R="$BATS_TEST_TMPDIR/br"
  git init -q "$R"
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  echo x > "$R/f.txt"
  git -C "$R" add .
  git -C "$R" commit -qm seed
  git -C "$R" worktree add -q -b feature/thing "$BATS_TEST_TMPDIR/wt2"

  printf '{"session_id":"B1","cwd":"%s"}' "$BATS_TEST_TMPDIR/wt2" \
    | "$BIN/fleet-emit" UserPromptSubmit
  run python3 -c "import json;print(json.load(open('$FLEET_HOME/sessions/B1.json'))['branch'])"
  [ "$output" = "feature/thing" ]
}
