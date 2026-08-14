#!/usr/bin/env bats
# Exercises bin/fleet-merge-hooks against a FIXTURE settings.json --
# never against a real ~/.claude/settings.json. The fixtures reproduce
# two dangerous cases: (1) a third-party plugin already owns a hook
# entry on an event flightdeck also manages (Stop, SessionStart) -- a
# naive dict-merge would replace the whole array and silently delete
# it; (2) an entry left behind by a flightdeck checkout at a DIFFERENT
# path (a relocated repo, or a second machine) -- ownership must be
# recognised regardless of path, or the old entry piles up forever
# instead of being replaced.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  REPO="/fake/repo/flightdeck"
  PY="/fake/python3"
  TARGET="$BATS_TEST_TMPDIR/settings.json"
  SNIPPET="$BATS_TEST_TMPDIR/snippet.json"
  BACKUP="$BATS_TEST_TMPDIR/settings.json.backup"

  cat >"$TARGET" <<'EOF'
{
  "permissions": { "allow": ["Bash(ssh root@host *)"] },
  "enabledPlugins": { "some-plugin@marketplace": true },
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "/opt/other-plugin/notify.sh SessionStart" }] }],
    "Stop":         [{ "hooks": [{ "type": "command", "command": "/opt/other-plugin/notify.sh Stop" }] }]
  }
}
EOF
  cp "$TARGET" "$BACKUP"

  sed -e "s|__PYTHON__|$PY|g" -e "s|__REPO__|$REPO|g" \
    "$ROOT/hooks/settings.snippet.json" >"$SNIPPET"
}

count_ours() {
  # count_ours <event> -- "ours" is matched path-independently, on
  # "/bin/fleet-emit", exactly as bin/fleet-merge-hooks does.
  python3 -c "
import json
d = json.load(open('$TARGET'))
entries = d['hooks'].get('$1', [])
print(sum(1 for e in entries for h in e.get('hooks', [])
          if '/bin/fleet-emit' in h.get('command', '')))
"
}

@test "MERGE: third-party hooks on Stop and SessionStart survive untouched, ours are added" {
  run "$BIN/fleet-merge-hooks" "$TARGET" "$SNIPPET" "$BACKUP"
  [ "$status" -eq 0 ]

  py() { python3 -c "import json; d=json.load(open('$TARGET')); print($1)"; }

  # unrelated top-level keys are untouched
  [ "$(py 'd["permissions"]["allow"][0]')" = "Bash(ssh root@host *)" ]
  [ "$(py 'd["enabledPlugins"]["some-plugin@marketplace"]')" = "True" ]

  # the third party's entries are still there, verbatim
  [ "$(py 'd["hooks"]["SessionStart"][0]["hooks"][0]["command"]')" = "/opt/other-plugin/notify.sh SessionStart" ]
  [ "$(py 'd["hooks"]["Stop"][0]["hooks"][0]["command"]')" = "/opt/other-plugin/notify.sh Stop" ]

  # ours was added exactly once, on all five events (not just the two contested ones)
  for event in SessionStart UserPromptSubmit Notification Stop SessionEnd; do
    [ "$(count_ours "$event")" -eq 1 ]
  done

  # SessionStart and Stop each carry BOTH entries -- the array was
  # extended, not replaced
  [ "$(py 'len(d["hooks"]["SessionStart"])')" -eq 2 ]
  [ "$(py 'len(d["hooks"]["Stop"])')" -eq 2 ]
}

@test "MERGE: a second run neither duplicates our entry nor disturbs the third party's" {
  run "$BIN/fleet-merge-hooks" "$TARGET" "$SNIPPET" "$BACKUP"
  [ "$status" -eq 0 ]

  # install.sh takes a fresh backup on every invocation -- reproduce
  # that: the second run's backup is a copy of the already-merged file.
  cp "$TARGET" "$BACKUP"
  run "$BIN/fleet-merge-hooks" "$TARGET" "$SNIPPET" "$BACKUP"
  [ "$status" -eq 0 ]

  py() { python3 -c "import json; d=json.load(open('$TARGET')); print($1)"; }

  # still exactly one flightdeck entry per event -- no duplication
  for event in SessionStart UserPromptSubmit Notification Stop SessionEnd; do
    [ "$(count_ours "$event")" -eq 1 ]
  done

  # the third party's entries are still exactly there, still exactly one each
  [ "$(py 'd["hooks"]["SessionStart"][0]["hooks"][0]["command"]')" = "/opt/other-plugin/notify.sh SessionStart" ]
  [ "$(py 'd["hooks"]["Stop"][0]["hooks"][0]["command"]')" = "/opt/other-plugin/notify.sh Stop" ]

  # no unbounded growth: two contested events still hold exactly 2
  # entries (theirs + ours), the other three hold exactly 1 (ours only)
  [ "$(py 'len(d["hooks"]["SessionStart"])')" -eq 2 ]
  [ "$(py 'len(d["hooks"]["Stop"])')" -eq 2 ]
  [ "$(py 'len(d["hooks"]["UserPromptSubmit"])')" -eq 1 ]
  [ "$(py 'len(d["hooks"]["Notification"])')" -eq 1 ]
  [ "$(py 'len(d["hooks"]["SessionEnd"])')" -eq 1 ]
}

@test "MERGE: a verification failure restores the target from backup and exits non-zero" {
  # A snippet whose own hooks value is not a dict (malformed) makes
  # merge_top's hooks branch fall through to a wholesale replace of the
  # top-level "hooks" key with something that is not a dict -- which
  # then fails the "hooks" round-trip implicitly by making every
  # subsequent event lookup empty, tripping the third-party-preserved
  # check. This proves the restore-on-failure path actually restores.
  cat >"$SNIPPET" <<EOF
{ "hooks": "not-a-dict-anymore" }
EOF
  before_sha="$(shasum "$TARGET")"
  run "$BIN/fleet-merge-hooks" "$TARGET" "$SNIPPET" "$BACKUP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"restored"* ]]
  after_sha="$(shasum "$TARGET")"
  [ "$before_sha" = "$after_sha" ]
}

@test "MERGE: a forced failure exactly at the write step restores the target byte-identical to the backup" {
  # Fault injection via FLEET_MERGE_HOOKS_FORCE_WRITE_FAILURE (see the
  # script's docstring): raises immediately before the atomic write, so
  # this proves ANY exception up to and including the write itself --
  # not just a post-write verification mismatch -- is caught and
  # restored, deterministically and without depending on triggering a
  # real disk/OS failure.
  before_backup_sha="$(shasum "$BACKUP")"
  export FLEET_MERGE_HOOKS_FORCE_WRITE_FAILURE=1
  run "$BIN/fleet-merge-hooks" "$TARGET" "$SNIPPET" "$BACKUP"
  unset FLEET_MERGE_HOOKS_FORCE_WRITE_FAILURE
  [ "$status" -eq 1 ]
  [[ "$output" == *"restored"* ]]
  after_target_sha="$(shasum "$TARGET" | awk '{print $1}')"
  after_backup_sha="$(shasum "$BACKUP" | awk '{print $1}')"
  [ "$after_backup_sha" = "${before_backup_sha%% *}" ]
  [ "$after_target_sha" = "$after_backup_sha" ]
}

@test "MERGE: a stale entry from a relocated (different-path) checkout is replaced, not duplicated" {
  OLD_REPO="/fake/old-checkout/flightdeck"
  cat >"$TARGET" <<EOF
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "/fake/python3 $OLD_REPO/bin/fleet-emit SessionStart" }] }]
  }
}
EOF
  cp "$TARGET" "$BACKUP"

  run "$BIN/fleet-merge-hooks" "$TARGET" "$SNIPPET" "$BACKUP"
  [ "$status" -eq 0 ]

  # exactly one flightdeck-shaped entry survives -- the stale one was
  # replaced, not kept alongside a second, growing the array forever
  [ "$(count_ours SessionStart)" -eq 1 ]

  surviving="$(python3 -c "import json; d=json.load(open('$TARGET')); print(d['hooks']['SessionStart'][0]['hooks'][0]['command'])")"
  [[ "$surviving" == *"$REPO/bin/fleet-emit"* ]]
  [[ "$surviving" != *"$OLD_REPO"* ]]
}

@test "MERGE: a genuinely foreign hook survives alongside a relocated-and-replaced flightdeck entry" {
  OLD_REPO="/fake/old-checkout/flightdeck"
  cat >"$TARGET" <<EOF
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "/opt/other-plugin/notify.sh Stop" }] },
      { "hooks": [{ "type": "command", "command": "/fake/python3 $OLD_REPO/bin/fleet-emit Stop" }] }
    ]
  }
}
EOF
  cp "$TARGET" "$BACKUP"

  run "$BIN/fleet-merge-hooks" "$TARGET" "$SNIPPET" "$BACKUP"
  [ "$status" -eq 0 ]

  py() { python3 -c "import json; d=json.load(open('$TARGET')); print($1)"; }

  # exactly 2 entries on Stop: the genuinely foreign one, plus our
  # (new-checkout) one -- the stale flightdeck entry was replaced, not
  # kept alongside a duplicate (which would make 3)
  [ "$(py 'len(d["hooks"]["Stop"])')" -eq 2 ]
  [ "$(count_ours Stop)" -eq 1 ]
  [ "$(py 'd["hooks"]["Stop"][0]["hooks"][0]["command"]')" = "/opt/other-plugin/notify.sh Stop" ]

  surviving="$(python3 -c "
import json
d = json.load(open('$TARGET'))
cmds = [h['command'] for e in d['hooks']['Stop'] for h in e['hooks'] if '/bin/fleet-emit' in h['command']]
print(cmds[0])
")"
  [[ "$surviving" == *"$REPO/bin/fleet-emit"* ]]
  [[ "$surviving" != *"$OLD_REPO"* ]]
}
