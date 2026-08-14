#!/usr/bin/env bash
# Sets up flightdeck on this machine. Safe to re-run.
set -eu
REPO="$(cd "$(dirname "$0")" && pwd)"
FLEET_HOME="${FLEET_HOME:-$HOME/.fleet}"

printf 'installing flightdeck from %s\n' "$REPO"
mkdir -p "$FLEET_HOME/sessions"

# 0. Pin the interpreter. This machine has several python3 installs and
#    launchd resolves a different one than an interactive shell, so every
#    automated caller gets an absolute path.
PY="$(command -v python3 || true)"
[ -n "$PY" ] || { printf 'ERROR: no python3 on PATH\n' >&2; exit 1; }
PY="$("$PY" -c 'import sys; print(sys.executable)')"
"$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3,9) else 1)' || {
  printf 'ERROR: %s is older than python 3.9\n' "$PY" >&2; exit 1; }
printf '%s' "$PY" >"$FLEET_HOME/interpreter"
printf '  interpreter pinned: %s\n' "$PY"

# 1. Local config from the example, if absent.
if [ ! -f "$REPO/config/fleet.local.json" ]; then
  cp "$REPO/config/fleet.local.example.json" "$REPO/config/fleet.local.json"
  printf '  created config/fleet.local.json - edit pins and vault path\n'
fi

# 2. Merge hooks into ~/.claude/settings.json, preserving everything else.
#
#    This file governs every other Claude Code session running on this
#    machine, so the merge is deliberately paranoid: back up first and
#    verify the backup is readable JSON *before* writing anything, then
#    after writing re-read the result and confirm every pre-existing
#    top-level key survived byte-identical. Any failure at either gate
#    restores the backup immediately rather than leaving a damaged file.
S="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -f "$S" ] || printf '{}' >"$S"

BACKUP="$S.flightdeck-backup.$(date +%s)"
cp "$S" "$BACKUP"
if ! "$PY" -c 'import json, sys; json.load(open(sys.argv[1]))' "$BACKUP"; then
  printf 'ERROR: backup %s is not valid JSON -- aborting before any write\n' "$BACKUP" >&2
  printf '       %s may already be corrupt; not touching it\n' "$S" >&2
  exit 1
fi
printf '  backup written and verified: %s\n' "$BACKUP"

sed -e "s|__PYTHON__|$PY|g" -e "s|__REPO__|$REPO|g" \
  "$REPO/hooks/settings.snippet.json" >"$FLEET_HOME/.snippet.json"

if "$PY" - "$S" "$FLEET_HOME/.snippet.json" "$BACKUP" <<'PY'
import json, sys

target, snippet_path, backup_path = sys.argv[1], sys.argv[2], sys.argv[3]


def merge(a, b):
    out = dict(a)
    for k, v in b.items():
        out[k] = merge(out[k], v) if k in out and isinstance(out[k], dict) and isinstance(v, dict) else v
    return out


with open(backup_path, encoding="utf-8") as f:
    original = json.load(f)
with open(snippet_path, encoding="utf-8") as f:
    snippet = json.load(f)

merged = merge(original, snippet)

with open(target, "w", encoding="utf-8") as f:
    json.dump(merged, f, indent=2)
    f.write("\n")

# Verify before declaring success: re-read what was actually written, and
# require every pre-existing top-level key to be present and unchanged.
try:
    with open(target, encoding="utf-8") as f:
        written = json.load(f)
except Exception as err:
    print("ERROR: written settings.json failed to parse: {}".format(err), file=sys.stderr)
    sys.exit(1)

for key, value in original.items():
    if key not in written or written[key] != value:
        print("ERROR: pre-existing key {!r} changed or missing after merge".format(key),
              file=sys.stderr)
        sys.exit(1)

print("  verified: {} pre-existing top-level key(s) intact".format(len(original)))
PY
then
  printf '  hooks merged into %s (backup at %s)\n' "$S" "$BACKUP"
else
  printf 'ERROR: settings merge failed verification -- restoring backup\n' >&2
  cp "$BACKUP" "$S"
  rm -f "$FLEET_HOME/.snippet.json"
  exit 1
fi
rm -f "$FLEET_HOME/.snippet.json"

# 3. launchd reaper.
LA="$HOME/Library/LaunchAgents"
mkdir -p "$LA"
PLIST="$LA/com.louisalexander.flightdeck.reaper.plist"
sed -e "s|__PYTHON__|$PY|g" -e "s|__REPO__|$REPO|g" -e "s|__HOME__|$HOME|g" \
  "$REPO/launchd/com.louisalexander.flightdeck.reaper.plist" >"$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
printf '  launchd reaper loaded\n'

# 4. Build and link the plugin.
( cd "$REPO/plugin" && npm install --silent && npm run build --silent )
DEST="$HOME/Library/Application Support/com.elgato.StreamDeck/Plugins"
mkdir -p "$DEST"
ln -sfn "$REPO/plugin/com.louisalexander.flightdeck.sdPlugin" \
        "$DEST/com.louisalexander.flightdeck.sdPlugin"
printf '  plugin linked\n'

# 5. Restart Stream Deck so it picks up the plugin.
osascript -e 'quit app "Elgato Stream Deck"' 2>/dev/null || true
open -a "Elgato Stream Deck" 2>/dev/null || true

printf '\nrunning doctor...\n\n'
"$REPO/bin/fleet-doctor" || true
printf '\nNext: drag "Fleet Slot" onto Row 1 keys and set Slot 0-7.\n'
