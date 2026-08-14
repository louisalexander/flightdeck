#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/state"
  mkdir -p "$FLEET_HOME"

  # A real git repo to run inside. fleet-spawn learns the repo and the
  # origin branch from its working directory, never from an argument.
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q "$REPO"
  git -C "$REPO" config user.email t@t
  git -C "$REPO" config user.name t
  echo seed > "$REPO/f.txt"
  git -C "$REPO" add .
  git -C "$REPO" commit -qm seed
  git -C "$REPO" checkout -q -b feat/origin-branch

  # Never let a test reach the network or open a terminal.
  stub_gh "Show the splash on screen lock"
  export FLEET_OSASCRIPT=/usr/bin/true
}

# A stub `gh` that returns a fixed issue title as JSON.
stub_gh() {
  cat > "$BATS_TEST_TMPDIR/gh" <<SH
#!/usr/bin/env bash
printf '{"title":"%s"}' "$1"
SH
  chmod +x "$BATS_TEST_TMPDIR/gh"
  export FLEET_GH="$BATS_TEST_TMPDIR/gh"
}

# A stub `gh` that fails, standing in for an issue that is not there.
stub_gh_missing() {
  cat > "$BATS_TEST_TMPDIR/gh" <<'SH'
#!/usr/bin/env bash
printf 'could not resolve to an Issue\n' >&2
exit 1
SH
  chmod +x "$BATS_TEST_TMPDIR/gh"
  export FLEET_GH="$BATS_TEST_TMPDIR/gh"
}

spawn() { (cd "$REPO" && "$BIN/fleet-spawn" "$@"); }

@test "--explain prints guidance and exits 0" {
  run spawn --explain
  [ "$status" -eq 0 ]
  # It exists so an agent can learn the calling convention without being
  # told it in the verb prompt. Idempotency is the part it must convey.
  [[ "$output" == *"issue number"* ]]
  [[ "$output" == *"safe to re-run"* ]]
}

@test "no argument refuses" {
  run spawn
  [ "$status" -eq 1 ]
}

@test "a plain issue number is accepted" {
  run spawn 7
  [ "$status" -eq 0 ]
}

@test "a non-numeric issue reference refuses" {
  run spawn "7; rm -rf /"
  [ "$status" -eq 1 ]
}

@test "a hash-prefixed issue reference refuses rather than being cleaned up" {
  # Guessing what the caller meant is how an unvalidated value gets in.
  run spawn "#7"
  [ "$status" -eq 1 ]
}

@test "a negative number refuses" {
  run spawn -- -7
  [ "$status" -eq 1 ]
}

@test "running outside a git repository refuses" {
  mkdir -p "$BATS_TEST_TMPDIR/nowhere"
  run bash -c "cd '$BATS_TEST_TMPDIR/nowhere' && '$BIN/fleet-spawn' 7"
  [ "$status" -eq 1 ]
}

@test "a detached HEAD refuses, because there is no origin branch to fork" {
  git -C "$REPO" checkout -q --detach
  run spawn 7
  [ "$status" -eq 1 ]
}

@test "an issue that does not exist refuses" {
  stub_gh_missing
  run spawn 7
  [ "$status" -eq 1 ]
}
