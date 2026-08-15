#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/fleet"
  export FLEET_DECIDE_POLL_SECS=0.02
  export FLEET_DECIDE_TIMEOUT_SECS=1
  export FLEET_SKIP_RECONCILE=1
  mkdir -p "$FLEET_HOME"
  # prompt_id "P1" is recorded in the pending record purely as a debugging
  # field. It is NOT the request identity: prompt_id is unique per TURN
  # (docs/hook-contract.md), and one turn can raise several PermissionRequests
  # for several tool calls sharing the same prompt_id -- round-2 review (N2)
  # reproduced a decision meant for an earlier call in the same turn being
  # accepted as the answer to a later, unrelated one. fleet-decide instead
  # mints request_id fresh with uuid4() at staging time, so no fixture here
  # can predict it in advance -- see request_id()/answer() below.
  PAYLOAD='{"session_id":"S1","cwd":"/tmp","prompt_id":"P1","tool_name":"Bash","tool_input":{"command":"rm -rf ./build"},"permission_suggestions":[{"type":"addRules","destination":"localSettings","rules":[{"toolName":"Bash","ruleContent":"rm:*"}],"behavior":"allow"}]}'
}

decide() { printf '%s' "${1:-$PAYLOAD}" | "$BIN/fleet-decide"; }
pending() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" \
              "$FLEET_HOME/pending/S1.json" "$1"; }
request_id() { pending request_id; }

# Writes decisions/S1.json as <decision-json> merged with the request_id
# fleet-decide actually minted for the pending record currently on disk --
# the same round-trip fleet-verdict performs for real. Must be called after
# fleet-decide has staged its pending record (await it first, below).
answer() {
  mkdir -p "$FLEET_HOME/decisions"
  python3 -c "
import json, sys
d = json.loads(sys.argv[1])
d['request_id'] = json.load(open(sys.argv[2]))['request_id']
json.dump(d, open(sys.argv[3], 'w'))
" "$1" "$FLEET_HOME/pending/S1.json" "$FLEET_HOME/decisions/S1.json"
}

# Bounded poll on an arbitrary shell condition, instead of a fixed sleep
# (round-3 review, promoted #3): a fixed `sleep 0.2` before reading a file
# fleet-decide is writing in the background is an intermittent failure
# waiting to happen on a loaded box, not a guarantee. Polls every 20ms for
# up to 1s; the condition itself still runs afterward as the real
# assertion, so a genuine timeout still fails loud rather than silently.
await() {  # await '<shell condition as a string>'
  for _ in $(seq 1 50); do
    eval "$1" && return 0
    sleep 0.02
  done
  return 1
}
await_pending() { await '[ -f "$FLEET_HOME/pending/S1.json" ]'; }

@test "a waiting decision is emitted as allow and the tool proceeds" {
  OUT="$BATS_TEST_TMPDIR/out.txt"
  decide > "$OUT" &
  pid=$!
  await_pending
  answer '{"behavior":"allow"}'
  wait "$pid"
  output="$(cat "$OUT")"
  [[ "$output" == *'"hookEventName":"PermissionRequest"'* ]] || return 1
  [[ "$output" == *'"behavior":"allow"'* ]] || return 1
  # permissionDecision is the documented PreToolUse field and is silently
  # ignored on PermissionRequest -- its presence here would be an invisible
  # failure, since Claude Code would just discard the whole verdict.
  [[ "$output" != *'permissionDecision'* ]] || return 1
}

@test "a deny decision carries its message and interrupt flag" {
  OUT="$BATS_TEST_TMPDIR/out.txt"
  decide > "$OUT" &
  pid=$!
  await_pending
  answer '{"behavior":"deny","message":"no","interrupt":true}'
  wait "$pid"
  output="$(cat "$OUT")"
  [[ "$output" == *'"behavior":"deny"'* ]] || return 1
  [[ "$output" == *'"interrupt":true'* ]] || return 1
  [[ "$output" != *'permissionDecision'* ]] || return 1
}

@test "a deny decision with a non-string message and non-boolean interrupt normalises to a bare deny" {
  OUT="$BATS_TEST_TMPDIR/out.txt"
  decide > "$OUT" &
  pid=$!
  await_pending
  answer '{"behavior":"deny","message":123,"interrupt":"yes"}'
  wait "$pid"
  output="$(cat "$OUT")"
  [[ "$output" == *'"behavior":"deny"'* ]] || return 1
  [[ "$output" != *'"message"'* ]] || return 1
  [[ "$output" != *'"interrupt"'* ]] || return 1
}

@test "the decision file is consumed, not left behind" {
  decide >/dev/null &
  pid=$!
  await_pending
  answer '{"behavior":"allow"}'
  wait "$pid"
  [ ! -f "$FLEET_HOME/decisions/S1.json" ]
}

@test "the pending record is cleared once decided" {
  decide >/dev/null &
  pid=$!
  await_pending
  answer '{"behavior":"allow"}'
  wait "$pid"
  [ ! -f "$FLEET_HOME/pending/S1.json" ]
}

# THE safety property: walking away must not become an automatic denial.
@test "a timeout emits absolutely nothing" {
  run decide
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # bats' `run` strips trailing newlines from $output, so a regression that
  # prints a bare newline (or any whitespace) would slip past the assertion
  # above. Counting raw bytes closes that gap.
  [ "$(printf '%s' "$PAYLOAD" | "$BIN/fleet-decide" | wc -c)" -eq 0 ]
}

@test "a timeout clears its pending record" {
  decide >/dev/null
  [ ! -f "$FLEET_HOME/pending/S1.json" ]
}

@test "a second identical request increments repeats rather than duplicating" {
  export FLEET_DECIDE_TIMEOUT_SECS=1
  decide >/dev/null &
  await_pending
  [ "$(pending repeats)" = "1" ]
  printf '%s' "$PAYLOAD" | "$BIN/fleet-decide" >/dev/null &
  await '[ "$(pending repeats)" = "2" ]'
  [ "$(pending repeats)" = "2" ]
  wait
}

@test "a high-risk command scores high" {
  decide >/dev/null &
  await_pending
  [ "$(pending tier)" = "high" ]
  wait
}

@test "the session is marked blocked immediately" {
  decide >/dev/null &
  await '[ -f "$FLEET_HOME/blocked/S1" ]'
  [ -f "$FLEET_HOME/blocked/S1" ]
  wait
}

@test "a real payload's permission suggestion is captured in the pending record" {
  # REMEMBER (a later verb) depends entirely on this field; it is otherwise
  # covered nowhere, since every other test's payload omits the suggestion
  # or never inspects it.
  decide >/dev/null &
  await_pending
  python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
sugg = data['suggestion']
assert sugg['type'] == 'addRules', sugg
assert sugg['destination'] == 'localSettings', sugg
assert sugg['rules'][0]['toolName'] == 'Bash', sugg
assert sugg['rules'][0]['ruleContent'] == 'rm:*', sugg
" "$FLEET_HOME/pending/S1.json"
  wait
}

# The pending record's `repo` is what REMEMBER's armed face names, and a
# remembered rule lands in the CANONICAL repo root -- it widens every agent
# in every worktree of that repository. --show-toplevel would record the
# worktree ("wt" below), naming the one scope the press is NOT limited to
# and making the mitigation actively misleading. Real git, real linked
# worktree, because the point is what git actually reports.
@test "the pending record names the canonical repository, not the worktree" {
  local repo="$BATS_TEST_TMPDIR/canonrepo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name t
  : > "$repo/f.txt"
  git -C "$repo" add f.txt
  git -C "$repo" commit -qm init
  local wt="$repo/.claude/worktrees/wt"
  git -C "$repo" worktree add -q -b wt "$wt"

  local payload
  payload="$(python3 -c "
import json, sys
p = json.loads(sys.argv[1]); p['cwd'] = sys.argv[2]
print(json.dumps(p))" "$PAYLOAD" "$wt")"
  decide "$payload" >/dev/null &
  await_pending
  [ "$(pending repo)" = "canonrepo" ]
  wait
}

@test "an unparseable payload exits 0 and emits nothing" {
  run bash -c "printf 'not json' | '$BIN/fleet-decide'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a payload with no session id exits 0 and emits nothing" {
  run bash -c "printf '{}' | '$BIN/fleet-decide'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a decision with an unrecognised behavior is discarded, nothing emitted" {
  # Must be a genuinely MATCHING decision, not a stale/mismatched one -- a
  # mismatched fixture would be discarded for the wrong reason (identity,
  # not _normalise rejecting "maybe") and prove nothing about this path.
  OUT="$BATS_TEST_TMPDIR/out.txt"
  decide > "$OUT" &
  pid=$!
  await_pending
  answer '{"behavior":"maybe"}'
  wait "$pid"
  [ -z "$(cat "$OUT")" ]
}

@test "a decision file that is valid JSON but not an object is discarded, nothing emitted" {
  mkdir -p "$FLEET_HOME/decisions"
  printf '%s' '"just a string"' > "$FLEET_HOME/decisions/S1.json"
  run decide
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a decision file containing unparseable bytes is discarded, nothing emitted" {
  mkdir -p "$FLEET_HOME/decisions"
  printf 'not json' > "$FLEET_HOME/decisions/S1.json"
  run decide
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- C1: request identity, not just session identity ------------------------
#
# fleetlib.resolve_target() and this hook are both keyed by session_id, but a
# session can have more than one PermissionRequest across its lifetime, and a
# decision file is only a valid answer to the request that is CURRENTLY
# staged. Without checking request_id, a leftover decision -- from a crashed
# fleet-decide (see C2 below) or a double press landing in the claim/unlink
# window -- would auto-answer a brand-new, unrelated request with no human
# ever having pressed anything.

@test "a stale decision predating this request is discarded, not consumed" {
  mkdir -p "$FLEET_HOME/decisions"
  printf '%s' '{"behavior":"allow"}' > "$FLEET_HOME/decisions/S1.json"
  run decide
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$FLEET_HOME/decisions/S1.json" ]
}

@test "a decision landing during staging is still honoured end-to-end, not dropped" {
  # Round-2 review (N1) reproduced this at the black-box level: the pending
  # record is on disk (and so resolve_target() already resolves to this
  # session) before create_blocked_marker, _touch_session_blocked and
  # _reconcile() run, so a Row 3 press landing anywhere in that window can
  # produce a correctly request_id-stamped decision before the wait loop
  # ever starts polling -- and the old unconditional purge threw that
  # answer away with nothing but a log line to show for it.
  #
  # This test races to answer as soon as the pending record exists, but it
  # CANNOT tell -- and round-3 review confirmed it never actually does --
  # which of fleet-decide's two internal call sites claims the decision:
  # with FLEET_SKIP_RECONCILE=1 the staging-to-purge window collapses to
  # microseconds, so in practice the wait loop's first poll always wins the
  # race here, not the pre-wait purge. That is not a gap: both call sites
  # now share one primitive, fleetlib.claim_matching_decision (round-3
  # review, N1), so they cannot disagree about what counts as a match --
  # and that primitive's own honour/discard behaviour is unit-tested
  # directly, decision-file-already-planted, in
  # tests/test_fleetlib.py::PendingTests (test_claim_matching_decision_*).
  # This test's remaining job is narrower and still real: prove the
  # end-to-end path does not lose a decision that arrives early.
  OUT="$BATS_TEST_TMPDIR/out.txt"
  decide > "$OUT" &
  pid=$!
  await_pending
  answer '{"behavior":"allow"}'
  wait "$pid"
  output="$(cat "$OUT")"
  [[ "$output" == *'"behavior":"allow"'* ]] || return 1
}

@test "a decision with a mismatched request_id is rejected, not consumed" {
  export FLEET_DECIDE_TIMEOUT_SECS=1
  OUT="$BATS_TEST_TMPDIR/out.txt"
  : > "$OUT"
  ( decide > "$OUT" ) &
  pid=$!
  await_pending
  mkdir -p "$FLEET_HOME/decisions"
  printf '%s' '{"behavior":"allow","request_id":"WRONG"}' > "$FLEET_HOME/decisions/S1.json"
  wait "$pid"
  [ ! -s "$OUT" ]
}

# --- C2: the pending record must never leak, even on a kill ----------------
#
# fleetlib.resolve_target() always hands Row 3 the OLDEST pending record, so
# a leaked one is oldest forever and permanently hijacks every future press
# away from whatever agent is actually blocked.

@test "the pending record is cleared when the process is signalled" {
  export FLEET_DECIDE_TIMEOUT_SECS=5
  # Deliberately not the `decide` helper: `decide >/dev/null &` backgrounds
  # a shell FUNCTION containing a pipeline, so `$!` captures the wrapping
  # subshell's pid, not fleet-decide's -- killing it never reaches the
  # python process at all. Redirecting stdin from a file backgrounds
  # fleet-decide itself as the one and only forked process, so `$!` is its
  # actual pid and the signal lands where the test means it to.
  IN="$BATS_TEST_TMPDIR/payload.json"
  printf '%s' "$PAYLOAD" > "$IN"
  "$BIN/fleet-decide" < "$IN" >/dev/null &
  pid=$!
  await_pending
  [ -f "$FLEET_HOME/pending/S1.json" ]
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  [ ! -f "$FLEET_HOME/pending/S1.json" ]
}
