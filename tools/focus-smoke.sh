#!/usr/bin/env bash
# Manual check: focuses this very session, then reports on a bogus target.
set -u
BIN="$(cd "$(dirname "$0")/../bin" && pwd)"
UUID="${ITERM_SESSION_ID#*:}"
[ -n "$UUID" ] || { echo "not running inside iTerm2"; exit 1; }

echo "focusing this session ($UUID) ..."
if "$BIN/fleet-focus" iterm2 "$UUID"; then echo "  ok"; else echo "  FAILED ($?)"; fi

echo "focusing a bogus session ..."
if "$BIN/fleet-focus" iterm2 "00000000-0000-0000-0000-000000000000"; then
  echo "  FAILED - should have exited non-zero"
else
  echo "  ok (non-zero as expected)"
fi
