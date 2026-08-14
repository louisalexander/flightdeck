#!/usr/bin/env bash
# Single entry point: lint shell bootstrap, compile-check Python, run bats.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rc=0

printf '== shellcheck (bootstrap shell only) ==\n'
targets=""
for f in "$ROOT"/install.sh "$ROOT"/tools/*.sh; do
  [ -f "$f" ] && targets="$targets $f"
done
if [ -z "$targets" ]; then
  printf 'nothing to lint yet\n'
# shellcheck disable=SC2086  # $targets is intentionally a word list of paths
elif shellcheck -s bash -S warning $targets; then
  printf 'clean\n'
else
  rc=1
fi

printf '\n== python syntax ==\n'
if python3 -m compileall -q "$ROOT/bin" >/dev/null 2>&1; then
  printf 'clean\n'
else
  python3 -m compileall -q "$ROOT/bin"
  rc=1
fi

printf '\n== python unittest (fleetlib pure functions) ==\n'
if /usr/bin/python3 "$ROOT/tests/test_fleetlib.py" -v; then
  printf 'unittest: OK\n'
else
  printf 'unittest: FAILED\n'
  rc=1
fi

printf '\n== bats ==\n'
bats "$ROOT/tests" || rc=1

exit "$rc"
