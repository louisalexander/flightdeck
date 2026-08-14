#!/usr/bin/env bats
# Exercises bin/fleet-merge-hooks against a FIXTURE settings.json --
# never against a real ~/.claude/settings.json. The fixture reproduces
# the dangerous case: a third-party plugin already owns a hook entry on
# an event flightdeck also manages (Stop, SessionStart). A naive
# dict-merge would replace the whole array and silently delete it.

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
  # count_ours <event>
  python3 -c "
import json
d = json.load(open('$TARGET'))
entries = d['hooks'].get('$1', [])
print(sum(1 for e in entries for h in e.get('hooks', [])
          if '$REPO/bin/fleet-emit' in h.get('command', '')))
"
}

@test "MERGE: third-party hooks on Stop and SessionStart survive untouched, ours are added" {
  run "$BIN/fleet-merge-hooks" "$TARGET" "$SNIPPET" "$BACKUP" "$REPO"
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
  run "$BIN/fleet-merge-hooks" "$TARGET" "$SNIPPET" "$BACKUP" "$REPO"
  [ "$status" -eq 0 ]

  # install.sh takes a fresh backup on every invocation -- reproduce
  # that: the second run's backup is a copy of the already-merged file.
  cp "$TARGET" "$BACKUP"
  run "$BIN/fleet-merge-hooks" "$TARGET" "$SNIPPET" "$BACKUP" "$REPO"
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
  run "$BIN/fleet-merge-hooks" "$TARGET" "$SNIPPET" "$BACKUP" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"restored"* ]]
  after_sha="$(shasum "$TARGET")"
  [ "$before_sha" = "$after_sha" ]
}
