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
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
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

    # --- the worktree- prefix ---------------------------------------------
    #
    # Every branch fleet-spawn creates is worktree-<slug>, so the prefix is
    # shared by every worktree key on the deck and carries no information.
    # Unstripped it is the FIRST token, which is exactly the one shorten
    # protects -- so it survives while the distinguishing tokens are trimmed
    # away, and five keys all read "workt-...".

    def test_strips_the_worktree_prefix_every_spawned_branch_shares(self):
        self.assertEqual(
            fleetlib.shorten("worktree-vague-row-1-title"), "vague-title")

    def test_a_short_branch_becomes_the_slug_alone(self):
        self.assertEqual(fleetlib.shorten("worktree-note"), "note")

    def test_a_branch_that_is_all_prefix_once_shortened_is_rescued(self):
        # worktree-rows-3-4 shortened to "worktree-4": the label was the
        # prefix plus one character, and said nothing at all.
        self.assertEqual(fleetlib.shorten("worktree-rows-3-4"), "rows-3-4")

    def test_the_prefix_is_anchored_and_does_not_match_mid_token(self):
        # "worktreeish" merely starts with the letters; it is not the prefix.
        self.assertEqual(fleetlib.shorten("worktreeish-plan"), "worktr-plan")


class CleanTitleTests(unittest.TestCase):
    """iTerm2 session name -> task title.

    Shapes observed on a live probe and recorded in the design spec
    (2026-08-13-streamdeck-fleet-design.md:107-109).
    """

    def test_strips_a_busy_glyph_and_the_trailing_process_name(self):
        self.assertEqual(
            fleetlib.clean_title("◑ Set up Stream Deck XL as AI agent (node)"),
            "Set up Stream Deck XL as AI agent")

    def test_strips_a_ready_glyph(self):
        self.assertEqual(
            fleetlib.clean_title("✳ break-state-exit-handling (node)"),
            "break-state-exit-handling")

    def test_an_unknown_glyph_is_stripped_by_class_not_by_lookup(self):
        # The spec calls the glyph vocabulary unversioned and liable to
        # change without notice, so a glyph nobody has seen must still go.
        self.assertEqual(fleetlib.clean_title("⚄ rebuild the index (node)"),
                         "rebuild the index")

    def test_a_name_with_no_glyph_survives_intact(self):
        self.assertEqual(fleetlib.clean_title("plain session name"),
                         "plain session name")

    def test_a_name_with_no_trailing_process_survives(self):
        self.assertEqual(fleetlib.clean_title("◑ mid-flight"), "mid-flight")

    def test_a_leading_digit_is_not_mistaken_for_a_glyph(self):
        self.assertEqual(fleetlib.clean_title("3-way merge (node)"), "3-way merge")

    def test_a_name_that_is_only_a_glyph_yields_empty(self):
        self.assertEqual(fleetlib.clean_title("◑"), "")

    def test_empty_and_none_yield_empty(self):
        self.assertEqual(fleetlib.clean_title(""), "")
        self.assertEqual(fleetlib.clean_title(None), "")

    def test_only_a_trailing_node_marker_is_stripped_not_any_parenthetical(self):
        # "(node)" is iTerm2 reporting the foreground process. A parenthetical
        # the user actually typed is part of the title.
        self.assertEqual(fleetlib.clean_title("◑ fix the parser (again) (node)"),
                         "fix the parser (again)")


class ItermSessionTitlesTests(unittest.TestCase):
    """The osascript seam. Stubbed via FLEET_OSASCRIPT, the same seam
    tests/spawn.bats:185 and tests/send.bats:92 use.
    """

    UUID_A = "11111111-2222-3333-4444-555555555555"
    UUID_B = "66666666-7777-8888-9999-000000000000"

    def _stub(self, body):
        """Write an executable stub and point FLEET_OSASCRIPT at it."""
        d = tempfile.mkdtemp()
        p = os.path.join(d, "osa")
        with open(p, "w") as fh:
            fh.write("#!/bin/sh\n" + body + "\n")
        os.chmod(p, 0o755)
        self.addCleanup(shutil.rmtree, d, True)
        old = os.environ.get("FLEET_OSASCRIPT")
        os.environ["FLEET_OSASCRIPT"] = p
        if old is None:
            self.addCleanup(os.environ.pop, "FLEET_OSASCRIPT", None)
        else:
            self.addCleanup(os.environ.__setitem__, "FLEET_OSASCRIPT", old)

    def test_parses_tab_separated_uuid_and_name(self):
        self._stub("printf '%s\\t%s\\n' '{a}' '◑ alpha (node)'".format(a=self.UUID_A))
        self.assertEqual(fleetlib.iterm_session_titles(),
                         {self.UUID_A: "◑ alpha (node)"})

    def test_parses_several_sessions(self):
        self._stub("printf '%s\\t%s\\n%s\\t%s\\n' '{a}' 'alpha' '{b}' 'beta'"
                   .format(a=self.UUID_A, b=self.UUID_B))
        self.assertEqual(fleetlib.iterm_session_titles(),
                         {self.UUID_A: "alpha", self.UUID_B: "beta"})

    def test_a_name_containing_a_tab_keeps_everything_after_the_first(self):
        self._stub("printf '%s\\talpha\\tbeta\\n' '{a}'".format(a=self.UUID_A))
        self.assertEqual(fleetlib.iterm_session_titles(),
                         {self.UUID_A: "alpha\tbeta"})

    def test_a_nonzero_exit_yields_an_empty_map(self):
        self._stub("exit 1")
        self.assertEqual(fleetlib.iterm_session_titles(), {})

    def test_a_missing_osascript_yields_an_empty_map_not_a_raise(self):
        os.environ["FLEET_OSASCRIPT"] = "/nonexistent/osascript"
        self.addCleanup(os.environ.pop, "FLEET_OSASCRIPT", None)
        self.assertEqual(fleetlib.iterm_session_titles(), {})

    def test_a_hanging_osascript_is_timed_out_and_yields_an_empty_map(self):
        self._stub("sleep 30")
        start = time.time()
        self.assertEqual(fleetlib.iterm_session_titles(timeout=1), {})
        self.assertLess(time.time() - start, 10)

    def test_lines_that_are_not_uuid_tab_name_are_skipped(self):
        self._stub("printf 'garbage\\nnot-a-uuid\\tname\\n%s\\tgood\\n' '{a}'"
                   .format(a=self.UUID_A))
        self.assertEqual(fleetlib.iterm_session_titles(), {self.UUID_A: "good"})

    def test_empty_output_yields_an_empty_map(self):
        self._stub("true")
        self.assertEqual(fleetlib.iterm_session_titles(), {})

    def test_the_separator_is_not_the_bare_applescript_tab_keyword(self):
        # Every test above stubs osascript, so none of them can see what the
        # real script emits. Inside `tell application "iTerm2"` the bare word
        # `tab` resolves to iTerm2's tab class, not the tab character, and
        # stringifies as the literal word "tab" -- so every line fails the
        # UUID<TAB>name parse and the map comes back empty on a real Mac
        # while the whole suite stays green. Caught once; guarded here.
        script = fleetlib.ITERM_TITLES_SCRIPT
        self.assertIn("ASCII character 9", script)
        self.assertNotIn("& tab &", script)


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


class CanonicalRepoNameTests(unittest.TestCase):
    """The repository REMEMBER's armed face names.

    A remembered permission rule lands in the CANONICAL repo root's
    .claude/settings.local.json -- never in the worktree the agent is
    running in -- so it widens permissions for every agent in every
    worktree of that repository. Naming the worktree on the confirmation
    would name the one scope the press is not limited to, which makes the
    mitigation actively misleading rather than merely incomplete. Real git
    repositories here, including a real linked worktree, because the whole
    point is what git actually reports.
    """

    def _repo(self, parent, name):
        repo = os.path.join(parent, name)
        os.makedirs(repo)
        subprocess.run(["git", "-C", repo, "init", "-q"], check=True)
        subprocess.run(["git", "-C", repo, "config", "user.email", "t@example.com"], check=True)
        subprocess.run(["git", "-C", repo, "config", "user.name", "t"], check=True)
        Path(repo, "f.txt").write_text("x", encoding="utf-8")
        subprocess.run(["git", "-C", repo, "add", "f.txt"], check=True)
        subprocess.run(["git", "-C", repo, "commit", "-qm", "init"], check=True)
        return repo

    def test_names_the_repository_at_its_top_level(self):
        with tempfile.TemporaryDirectory() as d:
            repo = self._repo(d, "flightdeck")
            self.assertEqual(fleetlib.canonical_repo_name(repo), "flightdeck")

    def test_names_the_repository_from_a_subdirectory(self):
        # git prints --git-common-dir RELATIVE to cwd ("../.git" here), so
        # this covers the resolution step, not just the happy absolute path.
        with tempfile.TemporaryDirectory() as d:
            repo = self._repo(d, "flightdeck")
            sub = os.path.join(repo, "bin")
            os.makedirs(sub)
            self.assertEqual(fleetlib.canonical_repo_name(sub), "flightdeck")

    def test_names_the_CANONICAL_repository_from_inside_a_worktree(self):
        # The one that matters. --show-toplevel would answer "rows-3-4"
        # here, which is the wrong name for a trap whose entire point is
        # that the rule lands in the canonical repo root and widens every
        # worktree of it, including this one's siblings.
        with tempfile.TemporaryDirectory() as d:
            repo = self._repo(d, "flightdeck")
            worktree = os.path.join(repo, ".claude", "worktrees", "rows-3-4")
            subprocess.run(["git", "-C", repo, "worktree", "add", "-q", "-b", "wt", worktree],
                           check=True)
            self.assertEqual(fleetlib.canonical_repo_name(worktree), "flightdeck")
            # And from a subdirectory of the worktree, which is where an
            # agent's cwd usually is.
            sub = os.path.join(worktree, "bin")
            os.makedirs(sub)
            self.assertEqual(fleetlib.canonical_repo_name(sub), "flightdeck")

    def test_a_non_git_directory_is_unknown_rather_than_guessed_from_the_path(self):
        # A wrong repository name on that key is worse than none: the whole
        # value of the line is that it is the true blast radius.
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(fleetlib.canonical_repo_name(d), "")

    def test_an_empty_cwd_is_unknown(self):
        self.assertEqual(fleetlib.canonical_repo_name(""), "")


class ClaimQueueTests(unittest.TestCase):
    """Direct coverage for fleetlib.claim_queue's ownership guarantee.

    tests/send.bats has a "CLAIM: exactly one claimant wins" test, but it
    calls claim_queue() twice sequentially in one process -- that proves
    the already-claimed case (a second call finds the source gone), not an
    actual race between simultaneous claimants. The real guarantee rests
    on os.replace() being atomic at the OS level, which is exactly the
    kind of thing that "works" under a sequential test and still has a
    race in it. Use a ThreadPoolExecutor so multiple threads genuinely
    call os.replace() against the same source path at once (the GIL does
    not serialize the underlying syscall), repeated across several rounds
    to make a false pass from lucky scheduling unlikely, while staying
    fast enough not to slow the suite.
    """

    def test_concurrent_claimants_exactly_one_wins_across_many_rounds(self):
        workers, rounds = 8, 25
        with tempfile.TemporaryDirectory() as d:
            old_home = os.environ.get("FLEET_HOME")
            os.environ["FLEET_HOME"] = d
            try:
                for round_num in range(rounds):
                    session_id = "S{}".format(round_num)
                    fleetlib.write_json_atomic(
                        fleetlib.queue_path(session_id),
                        {"verb": "test", "prompt": "p", "verb_path": "",
                         "queued_at": 1})

                    with ThreadPoolExecutor(max_workers=workers) as pool:
                        results = list(pool.map(
                            lambda _: fleetlib.claim_queue(session_id),
                            range(workers)))

                    winners = [r for r in results if r is not None]
                    self.assertEqual(
                        len(winners), 1,
                        "round {}: expected exactly one winner, got {}".format(
                            round_num, len(winners)))
                    self.assertFalse(fleetlib.queue_path(session_id).exists())
            finally:
                if old_home is None:
                    os.environ.pop("FLEET_HOME", None)
                else:
                    os.environ["FLEET_HOME"] = old_home


class ClaimDecisionTests(unittest.TestCase):
    """Direct coverage for fleetlib.claim_decision's ownership guarantee.

    PendingTests.test_claim_decision_yields_exactly_one_winner calls
    claim_decision() twice sequentially in one process -- that proves the
    already-claimed case (a second call finds the source gone), not an
    actual race between simultaneous claimants, and would pass just as
    happily against a naive read-then-delete implementation. The stakes
    here are higher than for claim_queue: a double-claim on a decision
    would let one operator keypress answer two permission requests. Same
    ThreadPoolExecutor technique as ClaimQueueTests, for the same reason.
    """

    def test_concurrent_claimants_exactly_one_wins_across_many_rounds(self):
        workers, rounds = 8, 25
        with tempfile.TemporaryDirectory() as d:
            old_home = os.environ.get("FLEET_HOME")
            os.environ["FLEET_HOME"] = d
            try:
                for round_num in range(rounds):
                    session_id = "S{}".format(round_num)
                    fleetlib.write_json_atomic(
                        fleetlib.decision_path(session_id),
                        {"behavior": "allow"})

                    with ThreadPoolExecutor(max_workers=workers) as pool:
                        results = list(pool.map(
                            lambda _: fleetlib.claim_decision(session_id),
                            range(workers)))

                    winners = [r for r in results if r is not None]
                    self.assertEqual(
                        len(winners), 1,
                        "round {}: expected exactly one winner, got {}".format(
                            round_num, len(winners)))
                    self.assertFalse(fleetlib.decision_path(session_id).exists())
            finally:
                if old_home is None:
                    os.environ.pop("FLEET_HOME", None)
                else:
                    os.environ["FLEET_HOME"] = old_home


class SlugifyTests(unittest.TestCase):
    """A branch-name slug built from an issue title.

    The title is model-authored text. These tests are the executable form
    of the FORK spec's decision 4: whatever goes in, only [a-z0-9-] comes
    out.
    """

    def test_ordinary_title_becomes_a_hyphenated_slug(self):
        self.assertEqual(
            fleetlib.slugify("Show the splash on screen lock"),
            "show-the-splash-on-screen-lock")

    def test_punctuation_collapses_to_single_hyphens(self):
        self.assertEqual(fleetlib.slugify("Fix: the  thing -- badly!"),
                         "fix-the-thing-badly")

    def test_leading_and_trailing_separators_are_stripped(self):
        self.assertEqual(fleetlib.slugify("  --hello--  "), "hello")

    def test_a_title_of_only_punctuation_yields_empty(self):
        self.assertEqual(fleetlib.slugify("!!! ??? ***"), "")

    def test_empty_and_none_yield_empty(self):
        self.assertEqual(fleetlib.slugify(""), "")
        self.assertEqual(fleetlib.slugify(None), "")

    def test_output_never_exceeds_the_cap(self):
        self.assertLessEqual(len(fleetlib.slugify("a" * 200)), 32)

    def test_truncation_drops_a_partial_trailing_token(self):
        # Cutting mid-word leaves a fragment that reads like a typo in
        # `git branch`. Prefer a whole token, even a shorter slug.
        self.assertEqual(
            fleetlib.slugify("alpha beta gamma delta epsilon zeta eta"),
            "alpha-beta-gamma-delta-epsilon")

    def test_shell_metacharacters_cannot_survive(self):
        hostile = "$(rm -rf /); `whoami`; \"quoted\"; 'single'; a\\b; x\ny"
        self.assertRegex(fleetlib.slugify(hostile), r"\A[a-z0-9-]*\Z")

    def test_non_ascii_is_dropped_not_transliterated(self):
        # Dropping is honest and safe; transliteration would need a table
        # and would still not be reversible.
        self.assertRegex(fleetlib.slugify("Ünïcödé bug"), r"\A[a-z0-9-]*\Z")


class SpawnRecordTests(unittest.TestCase):
    """Where a spawned worktree's iTerm2 session id is remembered."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.old_home = os.environ.get("FLEET_HOME")
        os.environ["FLEET_HOME"] = self.tmp

    def tearDown(self):
        if self.old_home is None:
            os.environ.pop("FLEET_HOME", None)
        else:
            os.environ["FLEET_HOME"] = self.old_home

    def test_record_lives_under_fleet_home(self):
        path = fleetlib.spawn_record_path("/repo/.claude/worktrees/issue-7")
        self.assertEqual(path.parent, Path(self.tmp) / "spawns")

    def test_same_worktree_maps_to_the_same_record(self):
        a = fleetlib.spawn_record_path("/repo/.claude/worktrees/issue-7")
        b = fleetlib.spawn_record_path("/repo/.claude/worktrees/issue-7")
        self.assertEqual(a, b)

    def test_same_issue_number_in_two_repos_does_not_collide(self):
        # Issue #7 exists in every repo. Keying on the number alone would
        # make one repo's fork focus another repo's tab.
        a = fleetlib.spawn_record_path("/one/.claude/worktrees/issue-7")
        b = fleetlib.spawn_record_path("/two/.claude/worktrees/issue-7")
        self.assertNotEqual(a, b)

    def test_record_filename_is_filesystem_safe(self):
        path = fleetlib.spawn_record_path("/a b/c'd/.claude/worktrees/issue-7")
        self.assertRegex(path.name, r"\A[a-f0-9]+\.json\Z")


RULES = {
    "high": [
        {"tool": "Bash", "match": r"rm\s+-[a-z]*[rf]"},
        {"tool": "Bash", "match": r"push\s+.*--force"},
        {"tool": "Bash", "match": r"curl.*\|\s*(ba)?sh"},
    ],
    "low": [{"tool": "Read"}, {"tool": "Grep"}, {"tool": "Glob"}],
}


class ScoreRiskTests(unittest.TestCase):
    def test_unmatched_tool_is_normal(self):
        self.assertEqual(fleetlib.score_risk("Write", {"file_path": "a"}, RULES), "normal")

    def test_tool_only_rule_matches(self):
        self.assertEqual(fleetlib.score_risk("Read", {"file_path": "a"}, RULES), "low")

    def test_pattern_rule_matches_command(self):
        self.assertEqual(fleetlib.score_risk("Bash", {"command": "rm -rf ./build"}, RULES), "high")

    def test_pattern_rule_requires_the_named_tool(self):
        # The same text under a different tool must not score high.
        self.assertEqual(fleetlib.score_risk("Write", {"content": "rm -rf ./build"}, RULES), "normal")

    def test_high_wins_over_low(self):
        rules = {"high": [{"tool": "Read"}], "low": [{"tool": "Read"}]}
        self.assertEqual(fleetlib.score_risk("Read", {}, rules), "high")

    def test_scans_every_string_value_in_the_input(self):
        self.assertEqual(fleetlib.score_risk("Bash", {"command": "git push --force"}, RULES), "high")

    def test_malformed_rules_degrade_to_normal(self):
        self.assertEqual(fleetlib.score_risk("Bash", {"command": "rm -rf /"}, {"high": "nope"}), "normal")

    def test_bad_regex_is_skipped_not_raised(self):
        rules = {"high": [{"tool": "Bash", "match": "([unclosed"}]}
        self.assertEqual(fleetlib.score_risk("Bash", {"command": "x"}, rules), "normal")


class PendingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.environ["FLEET_HOME"] = self.tmp

    def tearDown(self):
        os.environ.pop("FLEET_HOME", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _pending(self, sid, age_secs, tier="normal"):
        """`age_secs` is seconds-ago from now, not a raw epoch value.

        read_pending_all() now applies a staleness TTL floor (see C2 in the
        row-3-verdict-and-halt review), so a fixture timestamped near the
        unix epoch -- as the old raw-integer `at` values (100, 200) were --
        would be filtered out as impossibly stale before a test ever got to
        assert on it. Seconds-ago keeps every fixture realistic while still
        letting tests express clean relative ordering.
        """
        fleetlib.write_json_atomic(fleetlib.pending_path(sid), {
            "session_id": sid, "tool": "Bash", "input_digest": "sha256:abc",
            "input_summary": "x", "tier": tier, "suggestion": None,
            "repo": "r", "repeats": 1, "requested_at": int(time.time()) - age_secs,
        })

    def test_digest_is_stable_and_order_independent(self):
        a = fleetlib.input_digest("Bash", {"command": "ls", "timeout": 1})
        b = fleetlib.input_digest("Bash", {"timeout": 1, "command": "ls"})
        self.assertEqual(a, b)
        self.assertTrue(a.startswith("sha256:"))

    def test_digest_changes_with_the_tool(self):
        self.assertNotEqual(fleetlib.input_digest("Bash", {"c": 1}),
                            fleetlib.input_digest("Write", {"c": 1}))

    def test_read_pending_all_is_oldest_first(self):
        self._pending("B", 10)
        self._pending("A", 20)
        self.assertEqual([p["session_id"] for p in fleetlib.read_pending_all()], ["A", "B"])

    def test_read_pending_all_skips_unreadable_files(self):
        fleetlib.pending_dir().mkdir(parents=True, exist_ok=True)
        (fleetlib.pending_dir() / "junk.json").write_text("{not json")
        self._pending("A", 10)
        self.assertEqual([p["session_id"] for p in fleetlib.read_pending_all()], ["A"])

    def test_read_pending_all_skips_a_record_past_the_ttl_floor(self):
        # The backstop for SIGKILL: a leaked record older than the TTL is
        # proven dead, not merely slow, and must not be resolve_target()'s
        # "oldest" forever.
        self._pending("OLD", fleetlib.PENDING_TTL_DEFAULT_SECS + 5)
        self._pending("FRESH", 5)
        self.assertEqual([p["session_id"] for p in fleetlib.read_pending_all()], ["FRESH"])

    def test_read_pending_all_honours_a_configured_ttl(self):
        cfg_dir = tempfile.mkdtemp()
        try:
            os.environ["FLEET_CONFIG_DIR"] = cfg_dir
            with open(os.path.join(cfg_dir, "fleet.json"), "w", encoding="utf-8") as handle:
                # decideTimeoutSecs kept low so the decide-timeout coupling
                # floor exercised below (60s margin) does not itself swallow
                # this test's smaller pendingTtlSecs.
                json.dump({"timings": {"decideTimeoutSecs": 1, "pendingTtlSecs": 100}}, handle)
            self._pending("OLD", 150)
            self._pending("FRESH", 10)
            self.assertEqual([p["session_id"] for p in fleetlib.read_pending_all()], ["FRESH"])
        finally:
            os.environ.pop("FLEET_CONFIG_DIR", None)
            shutil.rmtree(cfg_dir, ignore_errors=True)

    def test_pending_ttl_floors_at_the_decide_timeout_plus_margin(self):
        # Round-2 review: timings.decideTimeoutSecs and timings.pendingTtlSecs
        # were two independent knobs with no relationship enforced -- setting
        # the former above the latter would make a live fleet-decide's own
        # pending record fall off resolve_target() while it is still
        # legitimately waiting on it.
        #
        # decideTimeoutSecs (110) is chosen just under
        # DECIDE_TIMEOUT_CEILING_SECS (120, see the B2 clamp test below) so
        # this test stays unclamped and keeps isolating the ttl/decide
        # COUPLING it was written for, independent of the ceiling itself.
        cfg_dir = tempfile.mkdtemp()
        try:
            os.environ["FLEET_CONFIG_DIR"] = cfg_dir
            with open(os.path.join(cfg_dir, "fleet.json"), "w", encoding="utf-8") as handle:
                # pendingTtlSecs (50) configured BELOW decideTimeoutSecs (110).
                json.dump({"timings": {"decideTimeoutSecs": 110, "pendingTtlSecs": 50}}, handle)
            # 90s old: past the configured pendingTtlSecs (50) but still
            # within decideTimeoutSecs + the 60s margin (170) -- a live
            # fleet-decide waiting that long must not have its own record
            # vanish out from under it mid-wait.
            self._pending("STILL_WAITING", 90)
            self.assertEqual(
                [p["session_id"] for p in fleetlib.read_pending_all()], ["STILL_WAITING"])
        finally:
            os.environ.pop("FLEET_CONFIG_DIR", None)
            shutil.rmtree(cfg_dir, ignore_errors=True)

    def test_decide_timeout_secs_honours_a_configured_value_under_the_ceiling(self):
        self.assertEqual(fleetlib._decide_timeout_secs({"timings": {"decideTimeoutSecs": 30}}),
                          30.0)

    def test_decide_timeout_secs_clamps_a_configured_value_above_the_ceiling(self):
        # B2: without this clamp, timings.decideTimeoutSecs = 9999 would make
        # a live fleet-decide wait 9999s while Claude Code kills the hook at
        # fleetlib.HOOK_TIMEOUT_SECS (130s) -- and a hook killed by SIGKILL
        # skips the `finally` that clears its pending record, the exact leak
        # this file has already been hardened against twice.
        self.assertEqual(
            fleetlib._decide_timeout_secs({"timings": {"decideTimeoutSecs": 9999}}),
            float(fleetlib.DECIDE_TIMEOUT_CEILING_SECS))

    def test_resolve_target_prefers_a_selection_that_is_pending(self):
        self._pending("A", 20)
        self._pending("B", 10)
        fleetlib.write_focus("B")
        self.assertEqual(fleetlib.resolve_target(), "B")

    def test_resolve_target_falls_back_when_the_selection_is_not_pending(self):
        self._pending("A", 10)
        fleetlib.write_focus("Z")
        self.assertEqual(fleetlib.resolve_target(), "A")

    def test_resolve_target_is_empty_when_nothing_is_pending(self):
        self.assertEqual(fleetlib.resolve_target(), "")

    def test_claim_decision_yields_exactly_one_winner(self):
        fleetlib.write_json_atomic(fleetlib.decision_path("A"), {"behavior": "allow"})
        first = fleetlib.claim_decision("A")
        second = fleetlib.claim_decision("A")
        self.assertEqual(first, {"behavior": "allow"})
        self.assertIsNone(second)

    # Round-3 review (N1): bin/fleet-decide's own bats coverage could not
    # prove the "honour a matching leftover" branch actually ran --
    # FLEET_SKIP_RECONCILE=1 collapses the staging-to-purge window to
    # microseconds in tests, so the decision always arrived late enough for
    # the wait loop's first poll to claim it instead, leaving the honour
    # branch provably unexercised. Testing the extracted primitive directly,
    # with the decision already planted before the call, removes the race
    # entirely: both fleet-decide call sites (the pre-wait purge and the
    # wait loop) now share this exact function, so proving it correct here
    # proves both call sites correct, regardless of which one wins the race
    # in production.
    def test_claim_matching_decision_returns_a_match_and_consumes_the_file(self):
        fleetlib.write_json_atomic(fleetlib.decision_path("A"),
                                    {"behavior": "allow", "request_id": "R1"})
        result = fleetlib.claim_matching_decision("A", "R1")
        self.assertEqual(result, {"behavior": "allow", "request_id": "R1"})
        self.assertFalse(fleetlib.decision_path("A").exists())

    def test_claim_matching_decision_discards_a_mismatch_but_still_consumes_the_file(self):
        fleetlib.write_json_atomic(fleetlib.decision_path("A"),
                                    {"behavior": "allow", "request_id": "OTHER"})
        result = fleetlib.claim_matching_decision("A", "R1")
        self.assertIsNone(result)
        self.assertFalse(fleetlib.decision_path("A").exists())

    def test_claim_matching_decision_discards_a_decision_with_no_request_id_at_all(self):
        fleetlib.write_json_atomic(fleetlib.decision_path("A"), {"behavior": "allow"})
        result = fleetlib.claim_matching_decision("A", "R1")
        self.assertIsNone(result)
        self.assertFalse(fleetlib.decision_path("A").exists())

    def test_claim_matching_decision_returns_none_when_nothing_is_present(self):
        self.assertIsNone(fleetlib.claim_matching_decision("A", "R1"))


if __name__ == "__main__":
    unittest.main()
