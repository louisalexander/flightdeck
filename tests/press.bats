#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR"
  export FLEET_CONFIG_DIR="$BATS_TEST_TMPDIR/config"
  mkdir -p "$FLEET_CONFIG_DIR"
  cp "$ROOT/config/fleet.json" "$FLEET_CONFIG_DIR/fleet.json"

  printf '#!/usr/bin/env bash\nprintf "focus %%s\\n" "$*" >>"%s/calls.log"\n' \
    "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/focus-stub"
  printf '#!/usr/bin/env bash\nprintf "kill %%s\\n" "$*" >>"%s/calls.log"\n' \
    "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/kill-stub"
  chmod +x "$BATS_TEST_TMPDIR/focus-stub" "$BATS_TEST_TMPDIR/kill-stub"
  export FLEET_FOCUS_CMD="$BATS_TEST_TMPDIR/focus-stub"
  export FLEET_KILL_CMD="$BATS_TEST_TMPDIR/kill-stub"

  cat >"$BATS_TEST_TMPDIR/slots.json" <<'EOF'
{"ts":1,"overflow":0,"slots":[
 {"index":0,"state":"working","label_top":"r","label_bottom":"b","session_id":"S1","host":"iterm2","iterm_session":"U-1","cwd":"/tmp","app":""},
 {"index":1,"state":"empty","label_top":"","label_bottom":"","session_id":"","host":"","iterm_session":"","cwd":"","app":""},
 {"index":2,"state":"idle","label_top":"ask","label_bottom":"ChatGPT","session_id":"","host":"pinned-app","iterm_session":"","cwd":"","app":"ChatGPT"}
]}
EOF
}

calls() { cat "$BATS_TEST_TMPDIR/calls.log" 2>/dev/null; }
armed_exists() { [ -f "$BATS_TEST_TMPDIR/armed.json" ]; }
armfield() { python3 -c "import json;print(json.load(open('$BATS_TEST_TMPDIR/armed.json'))['$1'])"; }

@test "short press focuses the iTerm session behind that slot" {
  FLEET_NOW=1000 "$BIN/fleet-press" 0 short
  [ "$(calls)" = "focus iterm2 U-1" ]
}

@test "short press on a pinned slot activates the app" {
  FLEET_NOW=1000 "$BIN/fleet-press" 2 short
  [ "$(calls)" = "focus pinned-app ChatGPT" ]
}

@test "pressing an empty slot does nothing at all" {
  FLEET_NOW=1000 "$BIN/fleet-press" 1 short
  [ -z "$(calls)" ]
}

@test "long press ARMS and must not kill anything on the hold" {
  FLEET_NOW=1000 "$BIN/fleet-press" 0 long
  [ -z "$(calls)" ]
  armed_exists
  [ "$(armfield index)" = "0" ]
  [ "$(armfield expires)" = "1003" ]
}

@test "a second press inside the window confirms the teardown" {
  FLEET_NOW=1000 "$BIN/fleet-press" 0 long
  FLEET_NOW=1002 "$BIN/fleet-press" 0 short
  [ "$(calls)" = "kill S1" ]
  ! armed_exists
}

@test "a press after expiry focuses and never kills" {
  FLEET_NOW=1000 "$BIN/fleet-press" 0 long
  FLEET_NOW=1099 "$BIN/fleet-press" 0 short
  [ "$(calls)" = "focus iterm2 U-1" ]
  ! armed_exists
}

@test "pressing a different key while armed disarms without killing" {
  FLEET_NOW=1000 "$BIN/fleet-press" 0 long
  FLEET_NOW=1001 "$BIN/fleet-press" 2 short
  [ "$(calls)" = "focus pinned-app ChatGPT" ]
  ! armed_exists
}

@test "a pinned slot cannot be armed for teardown" {
  FLEET_NOW=1000 "$BIN/fleet-press" 2 long
  ! armed_exists
  [ -z "$(calls)" ]
}

@test "an empty slot cannot be armed for teardown" {
  FLEET_NOW=1000 "$BIN/fleet-press" 1 long
  ! armed_exists
}

@test "an out-of-range slot index is harmless" {
  run env FLEET_NOW=1000 "$BIN/fleet-press" 99 short
  [ "$status" -eq 0 ]
  [ -z "$(calls)" ]
}

@test "a non-numeric slot index is harmless" {
  run env FLEET_NOW=1000 "$BIN/fleet-press" "; rm -rf /" short
  [ "$status" -eq 0 ]
  [ -z "$(calls)" ]
}

# --- bounded subprocess timeout on the kill/focus adapter calls ------------
#
# fleet-press shells out to fleet-kill (on confirm) and fleet-focus (on a
# plain press). Both calls now carry a timeout= so a wedged adapter cannot
# hang a physical key press -- the same defect pattern already fixed once
# in fleet-emit and once in fleet-focus. This genuinely exercises the
# timeout branch (a stub that sleeps well past the bound) and times the
# whole invocation, rather than asserting the timeout value by inspection.

@test "a wedged fleet-kill does not hang fleet-press; it returns promptly" {
  # fleet-kill's own outer bound is 30s (KILL_TIMEOUT_SECS in fleet-press),
  # raised from an earlier 10s so a real fleet-kill has room to finish its
  # own bounded git work rather than being cut off mid `worktree remove`.
  # The stub here sleeps well past that 30s bound so this still genuinely
  # exercises the timeout branch rather than the stub simply finishing.
  cat >"$BATS_TEST_TMPDIR/wedged-kill" <<'SH'
#!/usr/bin/env bash
sleep 60
SH
  chmod +x "$BATS_TEST_TMPDIR/wedged-kill"
  export FLEET_KILL_CMD="$BATS_TEST_TMPDIR/wedged-kill"

  FLEET_NOW=1000 "$BIN/fleet-press" 0 long

  start=$(date +%s)
  run env FLEET_NOW=1002 "$BIN/fleet-press" 0 short
  end=$(date +%s)
  elapsed=$((end - start))

  [ "$status" -eq 0 ]
  [ "$elapsed" -lt 40 ]
  ! armed_exists
}

# --- atomic claim of the arm marker -----------------------------------------
#
# The arm marker used to be cleared with a plain read-then-unlink, which is
# racy: two near-simultaneous presses on the same slot could both read the
# same live arm before either unlinked it, and both invoke the kill command.
# claim_arm() now renames armed.json to a unique armed.claim.<pid>.json with
# os.replace() -- an atomic operation -- and treats a successful rename as
# sole ownership. Exactly one process can win that rename; the loser's
# os.replace() finds the source already gone (FileNotFoundError) and must
# behave as if no arm existed at all.

@test "arm-then-confirm fires the kill exactly once; a repeat confirm attempt does not fire again" {
  FLEET_NOW=1000 "$BIN/fleet-press" 0 long
  FLEET_NOW=1002 "$BIN/fleet-press" 0 short
  FLEET_NOW=1002 "$BIN/fleet-press" 0 short
  [ "$(calls | grep -c '^kill ')" -eq 1 ]
  ! armed_exists
}

@test "a stale armed.claim.*.json left behind by a crashed process does not cause a later press to fire" {
  # Simulates a process that won a claim (renamed armed.json to its own
  # claim file) and then crashed before firing or cleaning up, leaving
  # only the claim file on disk -- no armed.json. A later press must never
  # consult stray claim files; with no live armed.json it is simply unarmed.
  cat >"$BATS_TEST_TMPDIR/armed.claim.99999.json" <<'JSON'
{"index":0,"expires":9999999999}
JSON
  FLEET_NOW=1000 "$BIN/fleet-press" 0 short
  [ "$(calls)" = "focus iterm2 U-1" ]
  [ "$(calls | grep -c '^kill ')" -eq 0 ]
  [ -e "$BATS_TEST_TMPDIR/armed.claim.99999.json" ]
}

@test "a losing claim (arm already taken by a concurrent presser) never fires" {
  FLEET_NOW=1000 "$BIN/fleet-press" 0 long
  armed_exists

  # Simulate a second, concurrent presser winning the race first: it
  # atomically renames armed.json to its own claim file exactly as
  # claim_arm() does, before our press gets there. Our press's own
  # os.replace() then finds the source already gone -- the same
  # FileNotFoundError a true race loser would see -- and must fall back to
  # ordinary short-press behaviour rather than firing the kill.
  mv "$BATS_TEST_TMPDIR/armed.json" "$BATS_TEST_TMPDIR/armed.claim.424242.json"

  FLEET_NOW=1002 "$BIN/fleet-press" 0 short
  [ "$(calls)" = "focus iterm2 U-1" ]
  [ "$(calls | grep -c '^kill ')" -eq 0 ]
}
