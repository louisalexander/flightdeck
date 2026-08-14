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
  # A tracked .gitignore, present from the seed commit onward, so every
  # worktree created below inherits it -- needed for the ignored-file
  # guard test, which relies on a pattern that is already in effect
  # without the test itself having to commit anything into the worktree.
  printf '*.local\n' >"$MAIN/.gitignore"
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
  [[ "$output" != *"WOULD REMOVE"* ]]
}

@test "REFUSES when the recorded directory no longer exists" {
  mksession GONE "$BATS_TEST_TMPDIR/repos/deleted-since"
  run "$BIN/fleet-kill" GONE
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" != *"WOULD REMOVE"* ]]
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

@test "REFUSES when a gitignored file is present, even though status --porcelain is spotless" {
  # git status --porcelain never reports ignored files, and
  # `git worktree remove` deletes them without needing --force. This is
  # the work-destruction path the guard must specifically close: a
  # worktree that looks completely clean by the ordinary check still
  # holds a real file (an .env, local notes, scratch work) that would be
  # gone forever.
  mkwt ignored
  echo secret >"$BATS_TEST_TMPDIR/repos/ignored/leftover.local"
  # Confirm the fixture actually is clean by the plain porcelain check --
  # otherwise this test would pass for the wrong reason.
  [ -z "$(git -C "$BATS_TEST_TMPDIR/repos/ignored" status --porcelain)" ]
  mksession IGNORED "$BATS_TEST_TMPDIR/repos/ignored"
  run "$BIN/fleet-kill" IGNORED
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" == *"ignored"* ]]
  [[ "$output" != *"WOULD REMOVE"* ]]
}

@test "REFUSES a submodule working directory, not just a primary tree" {
  # .git is a FILE for a submodule checkout too (it points into
  # <superproject>/.git/modules/<name>), so a bare ".git is a file" test
  # would wrongly treat it as a linked worktree eligible for removal.
  # git-dir vs git-common-dir tells them apart: for a submodule the two
  # are the SAME path (it doesn't participate in worktree machinery),
  # exactly like a primary tree, unlike a genuine linked worktree.
  subrepo="$BATS_TEST_TMPDIR/repos/subrepo-origin"
  git init -q "$subrepo"
  git -C "$subrepo" config user.email t@t
  git -C "$subrepo" config user.name t
  echo s >"$subrepo/s.txt"
  git -C "$subrepo" add .
  git -C "$subrepo" commit -qm s

  git -C "$MAIN" -c protocol.file.allow=always submodule add -q "$subrepo" embedded
  git -C "$MAIN" commit -qm "add submodule" >/dev/null

  mksession SUBMOD "$MAIN/embedded"
  run "$BIN/fleet-kill" SUBMOD
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" != *"WOULD REMOVE"* ]]
}

@test "REFUSES a primary working tree using --separate-git-dir, not just the ordinary layout" {
  # `git init --separate-git-dir=...` also makes .git a FILE for what is
  # still a single, primary working tree (there is no worktree admin
  # split here) -- another case a bare ".git is a file" test would get
  # wrong. git-dir and git-common-dir are equal here too.
  sepwork="$BATS_TEST_TMPDIR/repos/sepwork"
  git init -q --separate-git-dir="$BATS_TEST_TMPDIR/repos/sepwork.gitdir" "$sepwork"
  mksession SEPGITDIR "$sepwork"
  run "$BIN/fleet-kill" SEPGITDIR
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" != *"WOULD REMOVE"* ]]
}

@test "FLEET_DRY_RUN=true is honored as dry-run, not just the exact string 1" {
  # Matching only the literal string "1" is a footgun pointed at exactly
  # the person trying to be careful: FLEET_DRY_RUN=true must not silently
  # fall through to a REAL removal. Any non-empty value other than
  # "0"/"false" must mean dry-run.
  export FLEET_DRY_RUN=true
  mkwt truthy; mksession TRUTHY "$BATS_TEST_TMPDIR/repos/truthy"
  run "$BIN/fleet-kill" TRUTHY
  [ "$status" -eq 0 ]
  [[ "$output" == *"WOULD REMOVE"* ]]
  [ -d "$BATS_TEST_TMPDIR/repos/truthy" ]
}

@test "a boolean pid (JSON true) is never mistaken for pid 1 when deciding whether to signal" {
  # bool is a subclass of int in Python, so "pid": true would otherwise be
  # treated as a real, signalable pid 1 by a bare isinstance(pid, int)
  # check. Confirm the dry-run report never claims it would kill anything
  # for a boolean pid.
  mkwt boolpid
  python3 - "$FLEET_HOME/sessions/BOOLPID.json" "$BATS_TEST_TMPDIR/repos/boolpid" <<'PY'
import json, sys
p, cwd = sys.argv[1:3]
json.dump({"session_id": "BOOLPID", "state": "idle", "repo": "r", "branch": "b",
           "title": "", "cwd": cwd, "host": "iterm2", "iterm_session": "U",
           "pid": True, "ts": 1}, open(p, "w"))
PY
  run "$BIN/fleet-kill" BOOLPID
  [ "$status" -eq 0 ]
  [[ "$output" != *"WOULD KILL"* ]]
  [[ "$output" == *"WOULD REMOVE"* ]]
}

@test "a real (non-dry-run) removal deletes the worktree and session file, but keeps the branch ref" {
  # Branch survival is a stated invariant (worktree removal is reversible
  # via `git worktree add`; branch deletion is not) with no coverage
  # anywhere else in this suite -- every other test runs under
  # FLEET_DRY_RUN and never actually executes the removal path.
  unset FLEET_DRY_RUN
  mkwt keepbranch
  mksession KEEPBRANCH "$BATS_TEST_TMPDIR/repos/keepbranch"
  run "$BIN/fleet-kill" KEEPBRANCH
  [ "$status" -eq 0 ]
  [ ! -d "$BATS_TEST_TMPDIR/repos/keepbranch" ]
  [ ! -f "$FLEET_HOME/sessions/KEEPBRANCH.json" ]
  run git -C "$MAIN" rev-parse --verify --quiet refs/heads/keepbranch
  [ "$status" -eq 0 ]
}
