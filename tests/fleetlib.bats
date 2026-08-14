#!/usr/bin/env bats
# Direct unit coverage for the bin/fleetlib.py primitives every later task
# depends on: write_json_atomic, read_json, append_jsonl, and git(). These
# are exercised through small python3 one-liners that import fleetlib
# directly -- the same style tests/config.bats and tests/labels.bats already
# use via bin/fleet-config -- rather than adding a new CLI surface.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
}

pyrun() {
  PYTHONPATH="$BIN" python3 -c "$1"
}

@test "write_json_atomic writes valid JSON readable by read_json (round-trip)" {
  run pyrun "
import fleetlib
p = '$BATS_TEST_TMPDIR/roundtrip/out.json'
obj = {'a': 1, 'b': [1, 2, 3], 'c': {'d': 'e'}}
fleetlib.write_json_atomic(p, obj)
got = fleetlib.read_json(p)
assert got == obj, got
print('OK')
"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "write_json_atomic leaves no leftover temp files in the destination directory" {
  dir="$BATS_TEST_TMPDIR/notemp"
  mkdir -p "$dir"
  run pyrun "
import fleetlib
fleetlib.write_json_atomic('$dir/out.json', {'x': 1})
"
  [ "$status" -eq 0 ]
  shopt -s dotglob nullglob
  leftovers=()
  for f in "$dir"/*; do
    base="$(basename "$f")"
    [ "$base" = "out.json" ] || leftovers+=("$f")
  done
  [ "${#leftovers[@]}" -eq 0 ]
}

@test "write_json_atomic stages its temp file in the destination directory (not /tmp) and auto-creates nested parents" {
  run pyrun "
import os, tempfile
import fleetlib
captured = {}
orig_mkstemp = tempfile.mkstemp
def spy(*a, **kw):
    captured['dir'] = kw.get('dir')
    return orig_mkstemp(*a, **kw)
tempfile.mkstemp = spy
p = '$BATS_TEST_TMPDIR/nested/sub/dir/out.json'
fleetlib.write_json_atomic(p, {'x': 1})
assert captured['dir'] == os.path.dirname(p), captured
assert os.path.isfile(p)
print('OK')
"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "read_json returns the default for a missing file" {
  run pyrun "
import fleetlib
got = fleetlib.read_json('$BATS_TEST_TMPDIR/does-not-exist.json', default='DEFAULT')
assert got == 'DEFAULT', got
print('OK')
"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "read_json returns the default for a truncated/malformed file" {
  printf '{ this is not json' >"$BATS_TEST_TMPDIR/bad.json"
  run pyrun "
import fleetlib
got = fleetlib.read_json('$BATS_TEST_TMPDIR/bad.json', default='DEFAULT')
assert got == 'DEFAULT', got
print('OK')
"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "read_json parses valid JSON of an unexpected type verbatim; type-checking is the caller's job" {
  # fleetlib.read_json only guards against exceptions (missing file, bad
  # syntax, etc) -- it does not know or enforce an expected type. Callers
  # that need a specific type (e.g. load_config) apply their own
  # isinstance() check afterwards. This test documents and locks in that
  # division of responsibility rather than asserting behaviour read_json
  # does not implement.
  printf '[1, 2, 3]' >"$BATS_TEST_TMPDIR/list.json"
  run pyrun "
import fleetlib
got = fleetlib.read_json('$BATS_TEST_TMPDIR/list.json', default={})
assert got == [1, 2, 3], got
print('OK')
"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "append_jsonl appends one line per call and preserves earlier lines across invocations" {
  run pyrun "
import json
import fleetlib
p = '$BATS_TEST_TMPDIR/events.jsonl'
fleetlib.append_jsonl(p, {'n': 1})
fleetlib.append_jsonl(p, {'n': 2})
fleetlib.append_jsonl(p, {'n': 3})
lines = open(p, encoding='utf-8').read().splitlines()
assert len(lines) == 3, lines
assert [json.loads(l)['n'] for l in lines] == [1, 2, 3], lines
print('OK')
"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "git() returns non-zero and empty output for a non-git directory" {
  dir="$BATS_TEST_TMPDIR/notgit"
  mkdir -p "$dir"
  run pyrun "
import fleetlib
rc, out = fleetlib.git(['rev-parse', '--is-inside-work-tree'], '$dir')
assert rc != 0, (rc, out)
assert out == '', (rc, out)
print('OK')
"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "git() returns 0 with expected output inside a real git repo" {
  dir="$BATS_TEST_TMPDIR/realrepo"
  mkdir -p "$dir"
  git -C "$dir" init -q
  run pyrun "
import fleetlib
rc, out = fleetlib.git(['rev-parse', '--is-inside-work-tree'], '$dir')
assert rc == 0, (rc, out)
assert out == 'true', out
print('OK')
"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "git() handles a repository path containing a space correctly" {
  dir="$BATS_TEST_TMPDIR/repo with space"
  mkdir -p "$dir"
  git -C "$dir" init -q
  run pyrun "
import fleetlib
rc, out = fleetlib.git(['rev-parse', '--is-inside-work-tree'], '$dir')
assert rc == 0, (rc, out)
assert out == 'true', out
print('OK')
"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}
