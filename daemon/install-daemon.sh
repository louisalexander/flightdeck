#!/usr/bin/env bash
set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON_DIR="$REPO_ROOT/daemon"
NODE_BIN="$(command -v node)"
if [ -z "$NODE_BIN" ]; then
  echo "error: node not found on PATH" >&2
  exit 1
fi

echo "==> checking native dependencies"
if ! node -e "require('sharp')" 2>/dev/null; then
  echo "error: sharp did not load. Run 'npm install' inside daemon/ and check for a" >&2
  echo "       prebuilt-binary download failure before continuing." >&2
  exit 1
fi
if ! node -e "require('@elgato-stream-deck/node')" 2>/dev/null; then
  echo "error: @elgato-stream-deck/node did not load. Run 'npm install' inside daemon/." >&2
  exit 1
fi

echo "==> checking HID device access"
if ! node -e "
  const { listStreamDecks } = require('@elgato-stream-deck/node');
  listStreamDecks().then((devices) => {
    if (devices.length === 0) {
      console.error('no Stream Deck found — plug it in and retry');
      process.exit(1);
    }
    console.log('found', devices.length, 'device(s)');
  }).catch((err) => { console.error('HID open failed:', err); process.exit(1); });
"; then
  echo "error: could not enumerate HID devices. On macOS this can be a permission" >&2
  echo "       prompt hidden behind another window rather than a real absence — check" >&2
  echo "       System Settings > Privacy & Security before assuming the device is gone." >&2
  exit 1
fi

echo "==> building daemon"
(cd "$DAEMON_DIR" && npm install --silent && npm run build --silent)

echo "==> installing launchd job"
mkdir -p "$HOME/.fleet"
PLIST_SRC="$DAEMON_DIR/launchd/com.louisalexander.flightdeck.daemon.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.louisalexander.flightdeck.daemon.plist"
sed -e "s|__NODE__|$NODE_BIN|g" -e "s|__REPO__|$REPO_ROOT|g" -e "s|__HOME__|$HOME|g" \
  "$PLIST_SRC" > "$PLIST_DST"

launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"

echo "==> done. Tail $HOME/.fleet/daemon.out.log and daemon.err.log to confirm it's running."
