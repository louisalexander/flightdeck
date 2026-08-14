#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/state"
  export FLEET_DRY_RUN=1
  export FLEET_SKIP_RECONCILE=1
  mkdir -p "$FLEET_HOME/sessions" "$BATS_TEST_TMPDIR/repos"

  ORIGIN="$BATS_TEST_TMPDIR/repos/origin.git"
  MAIN="$BATS_TEST_TMPDIR/repos/main"
  git init -q --bare "$ORIGIN"
  git init -q "$MAIN"
  git -C "$MAIN" config user.email t@t
  git -C "$MAIN" config user.name t
  git -C "$MAIN" remote add origin "$ORIGIN"
  echo seed >"$MAIN/f.txt"
  git -C "$MAIN" add .
  git -C "$MAIN" commit -qm seed
  git -C "$MAIN" push -q -u origin HEAD:refs/heads/main
}

mkwt() {
  git -C "$MAIN" worktree add -q -b "$1" "$BATS_TEST_TMPDIR/repos/$1"
  git -C "$MAIN" push -q origin "$1:refs/heads/$1"
  git -C "$BATS_TEST_TMPDIR/repos/$1" branch --set-upstream-to="origin/$1" >/dev/null 2>&1
  git -C "$BATS_TEST_TMPDIR/repos/$1" config user.email t@t
  git -C "$BATS_TEST_TMPDIR/repos/$1" config user.name t
}

mksession() {
  python3 - "$FLEET_HOME/sessions/$1.json" "$1" "$2" <<'PY'
import json,sys
p,sid,cwd = sys.argv[1:4]
json.dump({"session_id":sid,"state":"idle","repo":"r","branch":"b","title":"",
           "cwd":cwd,"host":"iterm2","iterm_session":"U","pid":0,"ts":1},
          open(p,"w"))
PY
}

@test "a clean, pushed, linked worktree is eligible for removal" {
  mkwt clean; mksession CLEAN "$BATS_TEST_TMPDIR/repos/clean"
  run "$BIN/fleet-kill" CLEAN
  [ "$status" -eq 0 ]
  [[ "$output" == *"WOULD REMOVE"* ]]
}

@test "REFUSES when tracked files are modified" {
  mkwt dirty; echo change >>"$BATS_TEST_TMPDIR/repos/dirty/f.txt"
  mksession DIRTY "$BATS_TEST_TMPDIR/repos/dirty"
  run "$BIN/fleet-kill" DIRTY
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" == *"uncommitted"* ]]
  [[ "$output" != *"WOULD REMOVE"* ]]
}

@test "REFUSES when an untracked file is present" {
  mkwt untracked; echo new >"$BATS_TEST_TMPDIR/repos/untracked/brand-new.txt"
  mksession UNTRACKED "$BATS_TEST_TMPDIR/repos/untracked"
  run "$BIN/fleet-kill" UNTRACKED
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" != *"WOULD REMOVE"* ]]
}

@test "REFUSES when commits exist only locally" {
  mkwt unpushed
  echo more >>"$BATS_TEST_TMPDIR/repos/unpushed/f.txt"
  git -C "$BATS_TEST_TMPDIR/repos/unpushed" add .
  git -C "$BATS_TEST_TMPDIR/repos/unpushed" commit -qm "local only"
  mksession UNPUSHED "$BATS_TEST_TMPDIR/repos/unpushed"
  run "$BIN/fleet-kill" UNPUSHED
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" == *"unpushed"* ]]
  [[ "$output" != *"WOULD REMOVE"* ]]
}

@test "REFUSES when there is no upstream to prove the work is safe" {
  git -C "$MAIN" worktree add -q -b noups "$BATS_TEST_TMPDIR/repos/noups"
  mksession NOUPS "$BATS_TEST_TMPDIR/repos/noups"
  run "$BIN/fleet-kill" NOUPS
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" != *"WOULD REMOVE"* ]]
}

@test "REFUSES to remove a primary working tree, even a spotless one" {
  mksession MAINWT "$MAIN"
  run "$BIN/fleet-kill" MAINWT
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" != *"WOULD REMOVE"* ]]
}

@test "REFUSES a directory that is not a git repository" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  mksession PLAIN "$BATS_TEST_TMPDIR/plain"
  run "$BIN/fleet-kill" PLAIN
  [[ "$output" == *"REFUSING"* ]]
}

@test "REFUSES when the recorded directory no longer exists" {
  mksession GONE "$BATS_TEST_TMPDIR/repos/deleted-since"
  run "$BIN/fleet-kill" GONE
  [[ "$output" == *"REFUSING"* ]]
}

@test "a path containing spaces is handled as one argument" {
  git -C "$MAIN" worktree add -q -b spaced "$BATS_TEST_TMPDIR/repos/has space here"
  git -C "$MAIN" push -q origin "spaced:refs/heads/spaced"
  git -C "$BATS_TEST_TMPDIR/repos/has space here" branch --set-upstream-to=origin/spaced >/dev/null 2>&1
  mksession SPACED "$BATS_TEST_TMPDIR/repos/has space here"
  run "$BIN/fleet-kill" SPACED
  [[ "$output" == *"WOULD REMOVE"* ]]
}

@test "an unknown session id is harmless" {
  run "$BIN/fleet-kill" NOSUCHSESSION
  [ "$status" -eq 0 ]
}

@test "a refusal marks the session failed rather than silently doing nothing" {
  unset FLEET_DRY_RUN
  mkwt dirty2; echo change >>"$BATS_TEST_TMPDIR/repos/dirty2/f.txt"
  mksession DIRTY2 "$BATS_TEST_TMPDIR/repos/dirty2"
  run "$BIN/fleet-kill" DIRTY2
  [ "$(python3 -c "import json;print(json.load(open('$FLEET_HOME/sessions/DIRTY2.json'))['state'])")" = "failed" ]
  [ -d "$BATS_TEST_TMPDIR/repos/dirty2" ]
}
