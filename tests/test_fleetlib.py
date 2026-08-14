#!/usr/bin/env python3
"""Direct unit coverage for bin/fleetlib.py's pure functions.

bats was chosen back when bin/ was going to be bash. bin/ is Python, and
roughly 20 bats tests in the old tests/fleetlib.bats and tests/labels.bats
worked around that mismatch by shelling out to python3 -c one-liners (and
one CLI flag, fleet-config --shorten, invented for no reason other than
letting bats reach fleetlib.shorten()). stdlib unittest can import
fleetlib directly, so those cases live here now, and --shorten is gone.

CLI-contract tests -- e.g. that `fleet-config` with no args prints the
merged config JSON on stdout -- stay in tests/config.bats, since that is
testing the actual command surface, not a pure function.

Run directly:  python3 tests/test_fleetlib.py -v
Or via tests/run.sh, which wires this in alongside bats.
"""

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

BIN = str(Path(__file__).resolve().parent.parent / "bin")
if BIN not in sys.path:
    sys.path.insert(0, BIN)

import fleetlib  # noqa: E402


class ShortenTests(unittest.TestCase):
    """Ported from tests/labels.bats (all 8 cases)."""

    def test_already_short_label_is_unchanged(self):
        self.assertEqual(fleetlib.shorten("flightdeck"), "flightdeck")

    def test_single_long_token_is_truncated(self):
        self.assertEqual(fleetlib.shorten("averyverylongsingletoken"), "averyverylo")

    def test_keeps_first_and_last_token_trimming_the_longer_one(self):
        self.assertEqual(fleetlib.shorten("break-state-exit-handling"), "break-handl")

    def test_protects_last_token_when_first_already_fits(self):
        self.assertEqual(fleetlib.shorten("agent-hook-notification"), "agent-notif")

    def test_strips_known_branch_prefixes_before_shortening(self):
        self.assertEqual(fleetlib.shorten("feat/stream-deck-renderer"), "strea-rende")

    def test_splits_on_underscores_and_slashes_as_well_as_hyphens(self):
        self.assertEqual(fleetlib.shorten("my_module/deep_nested_thing"), "my-thing")

    def test_empty_input_yields_empty_output(self):
        self.assertEqual(fleetlib.shorten(""), "")

    def test_output_never_exceeds_the_maximum(self):
        result = fleetlib.shorten("some-extremely-long-branch-name-here", 11)
        self.assertLessEqual(len(result), 11)


class DeepMergeTests(unittest.TestCase):
    """New direct coverage: config.bats exercises deep_merge only
    indirectly, through the fleet-config CLI. These call the function.
    """

    def test_nested_merge_overrides_leaf_values(self):
        base = {"timings": {"armMs": 3000}, "slots": {"count": 8}}
        over = {"timings": {"armMs": 5000}}
        merged = fleetlib.deep_merge(base, over)
        self.assertEqual(merged["timings"]["armMs"], 5000)

    def test_sibling_keys_at_every_level_survive_the_merge(self):
        base = {"slots": {"count": 8}, "states": {"idle": {"color": "#25282D"}}}
        over = {"timings": {"armMs": 5000}, "pins": {"7": {"host": "pinned-app"}}}
        merged = fleetlib.deep_merge(base, over)
        self.assertEqual(merged["slots"]["count"], 8)
        self.assertEqual(merged["states"]["idle"]["color"], "#25282D")
        self.assertEqual(merged["timings"]["armMs"], 5000)
        self.assertEqual(merged["pins"]["7"]["host"], "pinned-app")

    def test_neither_input_dict_is_mutated(self):
        base = {"a": {"b": 1}}
        over = {"a": {"c": 2}}
        base_snapshot = json.loads(json.dumps(base))
        over_snapshot = json.loads(json.dumps(over))
        fleetlib.deep_merge(base, over)
        self.assertEqual(base, base_snapshot)
        self.assertEqual(over, over_snapshot)


class ReadJsonTests(unittest.TestCase):
    """Ported from tests/fleetlib.bats."""

    def test_returns_default_for_missing_file(self):
        with tempfile.TemporaryDirectory() as d:
            got = fleetlib.read_json(os.path.join(d, "does-not-exist.json"), default="DEFAULT")
            self.assertEqual(got, "DEFAULT")

    def test_returns_default_for_truncated_or_malformed_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "bad.json")
            Path(p).write_text("{ this is not json", encoding="utf-8")
            got = fleetlib.read_json(p, default="DEFAULT")
            self.assertEqual(got, "DEFAULT")

    def test_parses_valid_json_of_unexpected_type_verbatim_type_checking_is_load_configs_job(self):
        # read_json only guards against exceptions (missing file, bad
        # syntax, etc) -- it does not know or enforce an expected type.
        # load_config, one layer up, applies its own isinstance() check
        # after calling read_json. This locks in that division of
        # responsibility rather than asserting behaviour read_json does
        # not implement.
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "list.json")
            Path(p).write_text("[1, 2, 3]", encoding="utf-8")
            got = fleetlib.read_json(p, default={})
            self.assertEqual(got, [1, 2, 3])


class WriteJsonAtomicTests(unittest.TestCase):
    """Ported from tests/fleetlib.bats, plus new coverage for `indent`."""

    def test_round_trip_readable_by_read_json(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "roundtrip", "out.json")
            obj = {"a": 1, "b": [1, 2, 3], "c": {"d": "e"}}
            fleetlib.write_json_atomic(p, obj)
            self.assertEqual(fleetlib.read_json(p), obj)

    def test_no_leftover_temp_files_in_destination_directory(self):
        with tempfile.TemporaryDirectory() as d:
            fleetlib.write_json_atomic(os.path.join(d, "out.json"), {"x": 1})
            self.assertEqual(os.listdir(d), ["out.json"])

    def test_temp_file_staged_in_destination_directory_and_parents_auto_created(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "nested", "sub", "dir", "out.json")
            captured = {}
            orig_mkstemp = tempfile.mkstemp

            def spy(*args, **kwargs):
                captured["dir"] = kwargs.get("dir")
                return orig_mkstemp(*args, **kwargs)

            tempfile.mkstemp = spy
            try:
                fleetlib.write_json_atomic(p, {"x": 1})
            finally:
                tempfile.mkstemp = orig_mkstemp
            self.assertEqual(captured["dir"], os.path.dirname(p))
            self.assertTrue(os.path.isfile(p))

    def test_indent_parameter_produces_pretty_multiline_output_default_stays_compact(self):
        with tempfile.TemporaryDirectory() as d:
            obj = {"a": 1, "b": {"c": 2}}

            pretty = os.path.join(d, "pretty.json")
            fleetlib.write_json_atomic(pretty, obj, indent=2)
            pretty_text = Path(pretty).read_text(encoding="utf-8")
            self.assertGreater(pretty_text.count("\n"), 1)
            self.assertEqual(json.loads(pretty_text), obj)

            compact = os.path.join(d, "compact.json")
            fleetlib.write_json_atomic(compact, obj)
            compact_text = Path(compact).read_text(encoding="utf-8")
            self.assertEqual(compact_text.count("\n"), 0)
            self.assertEqual(json.loads(compact_text), obj)


class AppendJsonlTests(unittest.TestCase):
    """Ported from tests/fleetlib.bats."""

    def test_appends_one_line_per_call_preserving_earlier_lines(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "events.jsonl")
            fleetlib.append_jsonl(p, {"n": 1})
            fleetlib.append_jsonl(p, {"n": 2})
            fleetlib.append_jsonl(p, {"n": 3})
            lines = Path(p).read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(lines), 3)
            self.assertEqual([json.loads(l)["n"] for l in lines], [1, 2, 3])

    def test_concurrent_appends_from_multiple_processes_produce_intact_parseable_lines(self):
        # Multiple agents' hooks can fire and append to events.jsonl at the
        # same moment. append_jsonl opens O_APPEND and writes the fully
        # encoded line (payload + trailing newline) in a single os.write()
        # call, which POSIX guarantees does not interleave with other
        # writers on a local filesystem. Use real OS processes -- the
        # failure mode this guards against lives at the write-syscall
        # level, below what threads inside one interpreter would exercise
        # -- and pad each record so a naive buffered write (the pre-fix
        # implementation used a text-mode handle.write()) would have a
        # realistic chance of splitting mid-record if it were going to
        # misbehave.
        workers, lines_per_worker = 8, 40
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "concurrent.jsonl")
            env = dict(os.environ, PYTHONPATH=BIN)
            script = (
                "import fleetlib\n"
                "for i in range({lines}):\n"
                "    fleetlib.append_jsonl({path!r}, "
                "{{'worker': {worker}, 'i': i, 'pad': 'x' * 300}})\n"
            )
            procs = [
                subprocess.Popen(
                    [
                        sys.executable,
                        "-c",
                        script.format(lines=lines_per_worker, path=path, worker=w),
                    ],
                    env=env,
                )
                for w in range(1, workers + 1)
            ]
            for proc in procs:
                self.assertEqual(proc.wait(), 0)

            lines = Path(path).read_text(encoding="utf-8").splitlines()
            expected = workers * lines_per_worker
            self.assertEqual(len(lines), expected)
            seen = set()
            for line in lines:
                obj = json.loads(line)  # raises on a partial or merged line
                self.assertEqual(set(obj.keys()), {"worker", "i", "pad"})
                seen.add((obj["worker"], obj["i"]))
            self.assertEqual(len(seen), expected)


class GitTests(unittest.TestCase):
    """Ported from tests/fleetlib.bats."""

    def test_non_git_directory_returns_nonzero_and_empty_output(self):
        with tempfile.TemporaryDirectory() as d:
            rc, out = fleetlib.git(["rev-parse", "--is-inside-work-tree"], d)
            self.assertNotEqual(rc, 0)
            self.assertEqual(out, "")

    def test_real_git_repo_returns_zero_with_expected_output(self):
        with tempfile.TemporaryDirectory() as d:
            subprocess.run(["git", "-C", d, "init", "-q"], check=True)
            rc, out = fleetlib.git(["rev-parse", "--is-inside-work-tree"], d)
            self.assertEqual(rc, 0)
            self.assertEqual(out, "true")

    def test_repo_path_containing_a_space_is_handled_correctly(self):
        # fleetlib.git() runs git with an argument LIST, never a shell
        # string -- that is what makes a repo path with a space in it
        # safe. This is exactly the word-splitting class of bug that
        # motivated choosing Python over bash for bin/; keep this case.
        with tempfile.TemporaryDirectory() as d:
            repo = os.path.join(d, "repo with space")
            os.makedirs(repo)
            subprocess.run(["git", "-C", repo, "init", "-q"], check=True)
            rc, out = fleetlib.git(["rev-parse", "--is-inside-work-tree"], repo)
            self.assertEqual(rc, 0)
            self.assertEqual(out, "true")

    def test_bounded_by_timeout_and_reads_as_failure_not_success_when_git_hangs(self):
        # A wedged git (e.g. blocked on .git/index.lock, or a stuck
        # filesystem) must not hang fleet-kill forever, and must not be
        # mistaken for success. Shadow the real `git` with a fake binary
        # that never returns, then confirm fleetlib.git() comes back
        # quickly with the SAME failure shape (non-zero code, empty
        # output) used for every other error -- which is what makes a
        # timed-out safety check read as "could not determine" and
        # therefore REFUSE in bin/fleet-kill.
        with tempfile.TemporaryDirectory() as d:
            fakebin = os.path.join(d, "fakebin")
            os.makedirs(fakebin)
            fake_git = os.path.join(fakebin, "git")
            Path(fake_git).write_text("#!/usr/bin/env bash\nsleep 30\n", encoding="utf-8")
            os.chmod(fake_git, 0o755)

            repo = os.path.join(d, "timeoutrepo")
            os.makedirs(repo)

            old_path = os.environ.get("PATH", "")
            os.environ["PATH"] = fakebin + os.pathsep + old_path
            try:
                start = time.time()
                rc, out = fleetlib.git(["status", "--porcelain"], repo, timeout=1)
                elapsed = time.time() - start
            finally:
                os.environ["PATH"] = old_path

            self.assertNotEqual(rc, 0)
            self.assertEqual(out, "")
            self.assertLess(elapsed, 10)


if __name__ == "__main__":
    unittest.main()
