#!/usr/bin/env bash
# Dumps a hook's stdin payload for contract discovery. Never fails. Throwaway.
set -u
OUT="${HOME}/.fleet-probe"
mkdir -p "$OUT" 2>/dev/null
EVENT="${1:-unknown}"
{
  printf '=== %s @ %s ===\n' "$EVENT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'ITERM_SESSION_ID=%s\n' "${ITERM_SESSION_ID:-<unset>}"
  printf 'CLAUDE_CODE_SESSION_ID=%s\n' "${CLAUDE_CODE_SESSION_ID:-<unset>}"
  printf 'PWD=%s PPID=%s\n' "$PWD" "$PPID"
  printf -- '--- stdin ---\n'
  cat
  printf '\n'
} >> "$OUT/probe.log" 2>/dev/null
exit 0
