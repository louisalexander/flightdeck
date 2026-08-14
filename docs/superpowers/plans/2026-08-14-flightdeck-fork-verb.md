# Flightdeck FORK Verb — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Press FORK on a session that is mid-conversation and get a written plan committed to the current branch, a GitHub issue pointing at it, and a fresh agent working that issue in its own worktree in a new iTerm2 tab — while the originating agent carries on with what it was doing.

**Architecture:** The focused agent writes a plan via `superpowers:writing-plans`, commits it, files an issue naming it, and calls `bin/fleet-spawn <n>`. The sink validates the number, branches a worktree from the *current* branch so the plan is present in it, and opens an iTerm2 tab running `claude` with a fixed literal prompt. Nothing model-authored crosses a shell or AppleScript boundary: the issue number is an integer, the worktree path is built from that integer alone, and the title-derived slug reaches `git` only through an argument list.

**Tech Stack:** Python 3 (stdlib only) for `bin/`, bats for CLI and integration tests, `python3 tests/test_fleetlib.py` for pure functions, AppleScript via `osascript` for the tab, `gh` for GitHub.

**Spec:** `docs/superpowers/specs/2026-08-14-flightdeck-fork-verb-design.md`

## Global Constraints

- **Python 3 stdlib only.** No third-party imports anywhere in `bin/`. Python 3.9 compatible, per `fleetlib.py`'s module docstring.
- **`bin/fleet-spawn` is not a hook and MUST be allowed to exit non-zero.** A fork that did not happen must be visible. This is the same exemption `bin/fleet-send` has, and the opposite of `bin/fleet-emit`'s "MUST ALWAYS EXIT 0" contract.
- **All state writes are atomic** via `fleetlib.write_json_atomic`.
- **`FLEET_HOME` overrides `~/.fleet`** everywhere; tests rely on this.
- **Subprocesses take an argument LIST, never a shell string.** `fleetlib.git()` carries this rule in its docstring — it is what makes a repo path containing a space safe.
- **Every value interpolated into AppleScript is validated where it enters the program, not where it is used.** `bin/fleet-focus` sets the precedent, including anchoring with `\Z` rather than `$` so a trailing newline cannot slip past.
- **No model-authored text in any shell or AppleScript string.** Spec decision 4. There is an executable test for this in Task 5; it is not a style preference.
- **Stub binaries, never real ones, in tests.** `FLEET_GH` and `FLEET_OSASCRIPT` override `gh` and `osascript`. A test that reaches the network or opens a terminal is a broken test.
- **Test commands.** Whole suite: `tests/run.sh`. Pure functions: `python3 tests/test_fleetlib.py -v`. One bats file: `bats tests/<file>.bats`.

---

## Preconditions — satisfied

This plan was blocked on Row 2's first slice. **Row 2 landed on `main`**, and the gate was run before execution began:

```
bin/fleet-verbs  bin/fleet-send  bin/fleet-fail  config/verbs/test.md  tests/verbs.bats   ✓ all present
```

Two things changed while this plan waited, and both are absorbed below rather than papered over:

- **`{{FLIGHTDECK_REPO}}` shipped upstream.** Row 2's implementation hit the relative-sink-path bug independently, verified it live, and fixed it in `bin/fleet-verbs`. **Task 1 is superseded and must not be implemented** — see the note in its place.
- **`confirm` enforcement shipped.** `bin/fleet-send` arms and fires on a second press within `verbArmSecs` (10s), keyed by verb *and* target session. Confirm verbs may also queue against a busy target with a `confirmQueueSecs` (300s) expiry, superseding the "confirm verbs never queue" rule the spec was written against. FORK's `confirm: true` is therefore live on arrival, not inert.

---

### Task 1: SUPERSEDED — do not implement

This task added a `{FLEET_BIN}` placeholder to `bin/fleet-verbs` and fixed `config/verbs/test.md`, which named `bin/fleet-fail` by a path that is only correct inside the flightdeck repo.

**Row 2's implementation found and fixed the same bug first.** `bin/fleet-verbs` ships `REPO_TOKEN = "{{FLIGHTDECK_REPO}}"`, substituted by `parse_verb` on every `show`, plus a `resolved-path` subcommand that materialises a token-substituted copy to `$FLEET_HOME/verbs-resolved/<id>.md` — needed because `fleet-send`'s wake path points an idle agent at a *file*, which would otherwise contain the raw token. `config/verbs/test.md` already uses it. The comment in `fleet-verbs` records that the bug was **verified live**.

Implementing this task would introduce a second placeholder for a solved problem. **Skip it.** Task 6 uses `{{FLIGHTDECK_REPO}}/bin/fleet-spawn` instead.

The one thing worth carrying forward is the test intent: Task 6 asserts that `fleet-verbs show fork` emits an absolute path, which is what this task existed to guarantee.

---

### Task 2: `fleetlib.slugify` and the spawn record path

Two pure additions, in the file that already owns this kind of helper — `shorten` lives here and is unit-tested in `tests/test_fleetlib.py`, so `slugify` belongs beside it rather than inside a hyphenated script that cannot be imported.

**Files:**
- Modify: `bin/fleetlib.py` (add `slugify` after `shorten`; add `spawns_dir` and `spawn_record_path` after `armed_path`)
- Test: `tests/test_fleetlib.py` (append two test classes)

**Interfaces:**
- Consumes: `fleetlib.fleet_home()`
- Produces: `fleetlib.slugify(text, max_chars=32) -> str` returning only `[a-z0-9-]`; `fleetlib.spawns_dir() -> Path`; `fleetlib.spawn_record_path(worktree_path) -> Path`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_fleetlib.py`, immediately before the `if __name__ == "__main__":` block:

```python
class SlugifyTests(unittest.TestCase):
    """A branch-name slug built from an issue title.

    The title is model-authored text. These tests are the executable form
    of the spec's decision 4: whatever goes in, only [a-z0-9-] comes out.
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
        long_title = "a" * 200
        self.assertLessEqual(len(fleetlib.slugify(long_title)), 32)

    def test_truncation_drops_a_partial_trailing_token(self):
        # Cutting mid-word leaves a fragment that reads like a typo in
        # `git branch`. Prefer a whole token, even a shorter slug.
        self.assertEqual(
            fleetlib.slugify("alpha beta gamma delta epsilon zeta eta"),
            "alpha-beta-gamma-delta-epsilon")

    def test_shell_metacharacters_cannot_survive(self):
        hostile = "$(rm -rf /); `whoami`; \"quoted\"; 'single'; a\\b; x\ny"
        result = fleetlib.slugify(hostile)
        self.assertRegex(result, r"\A[a-z0-9-]*\Z")

    def test_non_ascii_is_dropped_not_transliterated(self):
        # Dropping is honest and safe; transliteration would need a table
        # and would still not be reversible.
        self.assertRegex(fleetlib.slugify("Ünïcödé bug"), r"\A[a-z0-9-]*\Z")


class SpawnRecordTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.environ["FLEET_HOME"] = self.tmp

    def tearDown(self):
        os.environ.pop("FLEET_HOME", None)

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 tests/test_fleetlib.py -v`
Expected: FAIL with `AttributeError: module 'fleetlib' has no attribute 'slugify'`.

- [ ] **Step 3: Add `slugify` to `bin/fleetlib.py`**

Add immediately after `shorten`:

```python
SLUG_MAX_CHARS = 32

def slugify(text, max_chars=SLUG_MAX_CHARS):
    """Reduces arbitrary text to [a-z0-9-], for use in a branch name.

    Sanitising, not escaping. The input is an issue title -- model-authored
    text -- and the output is interpolated into a branch name. Escaping
    would mean reasoning about which of git, the shell and AppleScript each
    metacharacter is dangerous to; reducing to a charset with no
    metacharacters in it at all means there is nothing left to reason
    about. `shorten` above solves a different problem (fitting a label on a
    96px key) and deliberately keeps the original characters.

    Truncation prefers a whole trailing token: cutting mid-word leaves a
    fragment that reads like a typo in `git branch`.
    """
    cleaned = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")
    if len(cleaned) <= max_chars:
        return cleaned
    cut = cleaned[:max_chars]
    if "-" in cut:
        cut = cut.rsplit("-", 1)[0]
    return cut.strip("-")
```

- [ ] **Step 4: Add the spawn record helpers**

Add `import hashlib` to the imports at the top of `bin/fleetlib.py`, keeping alphabetical order (before `import json`).

Add immediately after `armed_path`:

```python
def spawns_dir():
    return fleet_home() / "spawns"


def spawn_record_path(worktree_path):
    """Where the iTerm2 session id for a spawned worktree is remembered.

    Keyed by a hash of the absolute worktree path rather than by issue
    number: issue #7 exists in every repository, and keying on the number
    would make one repo's FORK focus another repo's tab. Hashing rather
    than sanitising because a path may contain anything a filesystem
    allows, and this filename is never read by a human.
    """
    digest = hashlib.sha256(str(worktree_path).encode("utf-8")).hexdigest()[:16]
    return spawns_dir() / "{}.json".format(digest)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `python3 tests/test_fleetlib.py -v`
Expected: all PASS, including the 13 cases added here.

- [ ] **Step 6: Run the whole suite**

Run: `tests/run.sh`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add bin/fleetlib.py tests/test_fleetlib.py
git commit -m "feat: add slugify and the spawn record path to fleetlib"
```

---

### Task 3: `bin/fleet-spawn` — validation, `--explain`, and every refusal

No worktree and no tab yet. This task builds the script's refusal surface first, because refusals are what make a fork that did not happen visible, and they are the cheapest thing to get wrong silently.

**Files:**
- Create: `bin/fleet-spawn`
- Test: `tests/spawn.bats` (create)

**Interfaces:**
- Consumes: `fleetlib.log()`, `fleetlib.git()`
- Produces: `bin/fleet-spawn <n>` exits 0 on success, 1 on any refusal. `bin/fleet-spawn --explain` prints the agent-readable explanation and exits 0. Module-level: `ISSUE_RE`, `explain() -> str`, `resolve_repo(cwd) -> (Path|None, str)`, `issue_title(number, cwd) -> str|None`.

- [ ] **Step 1: Write the failing test**

Create `tests/spawn.bats`:

```bash
#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$ROOT/bin"
  export FLEET_HOME="$BATS_TEST_TMPDIR/state"
  mkdir -p "$FLEET_HOME"

  # A real git repo to run inside. fleet-spawn learns the repo and the
  # origin branch from its working directory, never from an argument.
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q "$REPO"
  git -C "$REPO" config user.email t@t
  git -C "$REPO" config user.name t
  echo seed > "$REPO/f.txt"
  git -C "$REPO" add .
  git -C "$REPO" commit -qm seed
  git -C "$REPO" checkout -q -b feat/origin-branch

  # Never let a test reach the network or open a terminal.
  stub_gh "Show the splash on screen lock"
  export FLEET_OSASCRIPT=/usr/bin/true
}

# A stub `gh` that returns a fixed issue title as JSON.
stub_gh() {
  cat > "$BATS_TEST_TMPDIR/gh" <<SH
#!/usr/bin/env bash
printf '{"title":"%s"}' "$1"
SH
  chmod +x "$BATS_TEST_TMPDIR/gh"
  export FLEET_GH="$BATS_TEST_TMPDIR/gh"
}

# A stub `gh` that fails, standing in for a missing issue.
stub_gh_missing() {
  cat > "$BATS_TEST_TMPDIR/gh" <<'SH'
#!/usr/bin/env bash
printf 'could not resolve to an Issue\n' >&2
exit 1
SH
  chmod +x "$BATS_TEST_TMPDIR/gh"
  export FLEET_GH="$BATS_TEST_TMPDIR/gh"
}

spawn() { (cd "$REPO" && "$BIN/fleet-spawn" "$@"); }

@test "--explain prints guidance and exits 0" {
  run spawn --explain
  [ "$status" -eq 0 ]
  # It exists so an agent can learn the calling convention without being
  # told it in the verb prompt. Idempotency is the part it must convey.
  [[ "$output" == *"issue number"* ]]
  [[ "$output" == *"safe to re-run"* ]]
}

@test "no argument refuses" {
  run spawn
  [ "$status" -eq 1 ]
}

@test "a non-numeric issue reference refuses" {
  run spawn "7; rm -rf /"
  [ "$status" -eq 1 ]
}

@test "a hash-prefixed issue reference refuses rather than being cleaned up" {
  # Guessing what the caller meant is how an unvalidated value gets in.
  run spawn "#7"
  [ "$status" -eq 1 ]
}

@test "a plain issue number is accepted" {
  run spawn 7
  [ "$status" -eq 0 ]
}

@test "a negative number refuses" {
  run spawn -- -7
  [ "$status" -eq 1 ]
}

@test "running outside a git repository refuses" {
  mkdir -p "$BATS_TEST_TMPDIR/nowhere"
  run bash -c "cd '$BATS_TEST_TMPDIR/nowhere' && '$BIN/fleet-spawn' 7"
  [ "$status" -eq 1 ]
}

@test "a detached HEAD refuses, because there is no origin branch to fork" {
  git -C "$REPO" checkout -q --detach
  run spawn 7
  [ "$status" -eq 1 ]
}

@test "an issue that does not exist refuses" {
  stub_gh_missing
  run spawn 7
  [ "$status" -eq 1 ]
}
```

Note: at this task the success path does nothing observable beyond exiting 0 — the worktree arrives in Task 4 and the tab in Task 5. Asserting it here anyway keeps the refusal cases honest, since a script that refused *everything* would pass all eight of the others.

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/spawn.bats`
Expected: FAIL — `bin/fleet-spawn` does not exist.

- [ ] **Step 3: Write the script**

Create `bin/fleet-spawn`:

```python
#!/usr/bin/env python3
"""Spawns a fresh agent on a GitHub issue, in a worktree of its own.

Called by the FORK verb after the focused agent has written a plan,
committed it, and filed an issue naming it. Takes one issue number and
nothing else: the repository and the branch to fork from are read from the
working directory, because an argument is a channel and the whole security
argument for this script is that there is exactly one.

Not a hook: unlike bin/fleet-emit this may exit non-zero. A fork that did
not happen must be visible rather than silently dropped.
"""

import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fleetlib  # noqa: E402

# \Z rather than $, which matches before a trailing newline and would let
# "7\n" through. bin/fleet-focus records the same reasoning for its UUID.
ISSUE_RE = re.compile(r"\A[0-9]+\Z")

GH_TIMEOUT_SECS = 20

EXPLAIN = """\
fleet-spawn -- hand a GitHub issue to a fresh agent in its own worktree.

Usage:  fleet-spawn <issue-number>

Takes one issue number and nothing else. The repository and the branch to
fork from are read from the current working directory, so run it from
inside the repo the issue belongs to, on the branch the work came from.

What it expects of the issue: the body must name a plan file that has
already been committed to the current branch. fleet-spawn does not read
the body -- the agent it spawns does. If you have not committed the plan
yet, commit it before calling this, or the new worktree will not contain
it.

What it does: creates a worktree at .claude/worktrees/issue-<n>, branched
from the current branch so the plan is present in it, then opens an iTerm2
tab running an agent that reads the issue and executes the plan.

It is safe to re-run. A second call for the same issue focuses the tab
that already exists rather than creating a second worktree or a second
agent working the same issue.

Exit status is 0 only if the agent was actually spawned or an existing one
was focused. Any refusal exits 1 and logs the reason to the fleet log.
"""


def explain():
    return EXPLAIN


def resolve_repo(cwd):
    """(repo root, current branch) for `cwd`, or (None, "") if unusable.

    A detached HEAD reports the literal "HEAD", which is not a branch and
    cannot be forked from -- refuse rather than invent one.
    """
    code, top = fleetlib.git(["rev-parse", "--show-toplevel"], cwd)
    if code != 0 or not top:
        return None, ""
    code, branch = fleetlib.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd)
    if code != 0 or not branch or branch == "HEAD":
        return None, ""
    return Path(top), branch


def issue_title(number, cwd):
    """The issue's title, or None if it cannot be read.

    Also serves as the existence check: `gh` exits non-zero for an issue
    that is not there, which is the refusal we want before any worktree is
    created.
    """
    gh = os.environ.get("FLEET_GH") or "gh"
    try:
        proc = subprocess.run(
            [gh, "issue", "view", number, "--json", "title"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            cwd=str(cwd), timeout=GH_TIMEOUT_SECS)
    except Exception as err:
        fleetlib.log("spawn: gh failed for issue {}: {}".format(number, err))
        return None
    if proc.returncode != 0:
        fleetlib.log("spawn: no such issue: {}".format(number))
        return None
    try:
        data = json.loads(proc.stdout.decode("utf-8", "replace"))
    except Exception:
        fleetlib.log("spawn: unreadable gh output for issue {}".format(number))
        return None
    title = data.get("title") if isinstance(data, dict) else None
    return title if isinstance(title, str) else None


def main(argv):
    args = argv[1:]
    if args and args[0] == "--":
        args = args[1:]
    if not args:
        sys.stderr.write("fleet-spawn: an issue number is required\n")
        return 1
    if args[0] == "--explain":
        sys.stdout.write(explain())
        return 0

    number = args[0]
    if not ISSUE_RE.match(number):
        fleetlib.log("spawn: refusing non-numeric issue ref {!r}".format(number))
        sys.stderr.write("fleet-spawn: issue must be a number\n")
        return 1

    cwd = Path.cwd()
    repo_root, origin_branch = resolve_repo(cwd)
    if repo_root is None:
        fleetlib.log("spawn: {} is not a repo on a named branch".format(cwd))
        sys.stderr.write("fleet-spawn: not in a git repo on a named branch\n")
        return 1

    if issue_title(number, cwd) is None:
        sys.stderr.write("fleet-spawn: cannot read issue {}\n".format(number))
        return 1

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as err:
        fleetlib.log("spawn: unhandled error: {}".format(err))
        sys.exit(1)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `chmod +x bin/fleet-spawn && bats tests/spawn.bats`
Expected: 9 tests, all PASS.

- [ ] **Step 5: Run the whole suite**

Run: `tests/run.sh`
Expected: all PASS. `compileall` covers the new file's syntax.

- [ ] **Step 6: Commit**

```bash
git add bin/fleet-spawn tests/spawn.bats
git commit -m "feat: add fleet-spawn's validation, refusals and --explain"
```

---

### Task 4: Worktree creation, branched from the current branch

**Files:**
- Modify: `bin/fleet-spawn` (add `worktree_path`, `create_worktree`; call from `main`)
- Modify: `.gitignore` — verify `.claude/worktrees/` is present (added when the spec was written; confirm rather than duplicate)
- Test: `tests/spawn.bats` (append)

**Interfaces:**
- Consumes: `fleetlib.slugify()` (Task 2), `fleetlib.git()`
- Produces: `worktree_path(repo_root, number) -> Path`; `create_worktree(repo_root, path, branch, origin_branch) -> bool`

- [ ] **Step 1: Write the failing test**

Append to `tests/spawn.bats`:

```bash
# --- worktree creation --------------------------------------------------

wt() { printf '%s' "$REPO/.claude/worktrees/issue-7"; }

@test "WT: a worktree is created at a path built from the issue number" {
  run spawn 7
  [ "$status" -eq 0 ]
  [ -d "$(wt)" ]
}

@test "WT: the branch carries the number and the slugified title" {
  spawn 7
  run git -C "$(wt)" rev-parse --abbrev-ref HEAD
  [ "$output" = "issue-7-show-the-splash-on-screen-lock" ]
}

@test "WT: the worktree is branched from the branch we were on" {
  # The plan the fresh agent must execute was committed on this branch.
  # Branching from anywhere else hands it a plan describing code its
  # worktree does not contain.
  echo plan > "$REPO/PLAN.md"
  git -C "$REPO" add PLAN.md
  git -C "$REPO" commit -qm "add plan"
  spawn 7
  [ -f "$(wt)/PLAN.md" ]
}

@test "WT: the path contains no text from the issue title" {
  # Spec decision 4: the slug goes in the branch name, which reaches git
  # through an argv list, and deliberately NOT in the path, which is
  # interpolated into a shell command and an AppleScript literal.
  stub_gh 'Fix the widget'
  spawn 7
  [ -d "$(wt)" ]
  [ ! -d "$REPO/.claude/worktrees/issue-7-fix-the-widget" ]
}

@test "WT: a title of pure punctuation still yields a usable branch" {
  stub_gh '!!! ???'
  run spawn 7
  [ "$status" -eq 0 ]
  run git -C "$(wt)" rev-parse --abbrev-ref HEAD
  [ "$output" = "issue-7" ]
}

@test "WT: a second call creates no second worktree" {
  spawn 7
  run spawn 7
  [ "$status" -eq 0 ]
  run bash -c "ls '$REPO/.claude/worktrees' | wc -l | tr -d ' '"
  [ "$output" = "1" ]
}

@test "WT: nothing is created when the issue does not exist" {
  stub_gh_missing
  run spawn 7
  [ "$status" -eq 1 ]
  [ ! -d "$REPO/.claude/worktrees" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/spawn.bats -f WT`
Expected: FAIL on "a worktree is created at a path built from the issue number" — nothing creates it.

- [ ] **Step 3: Confirm the gitignore entry**

Run: `grep -n 'worktrees' .gitignore`
Expected: `.claude/worktrees/` is listed. It was added alongside the design doc. If it is absent, add it — a worktree created inside the repo otherwise leaves the origin branch's `git status` permanently dirty, and FORK is the verb that also commits a plan to that branch.

- [ ] **Step 4: Implement worktree creation**

Add to `bin/fleet-spawn`, after `issue_title`:

```python
def worktree_path(repo_root, number):
    """Where issue <n>'s worktree lives.

    Built from the issue number alone. A path including the slug would
    read better in `ls` and would mean interpolating model-authored text
    into a shell command and an AppleScript string literal -- the exact
    thing the v1 spec's hard rule forbids. The slug goes in the branch
    name instead, which git receives as an argv element.
    """
    return Path(repo_root) / ".claude" / "worktrees" / "issue-{}".format(number)


def create_worktree(repo_root, path, branch, origin_branch):
    """Adds the worktree. False on any failure, having logged why."""
    code, out = fleetlib.git(
        ["worktree", "add", "-b", branch, str(path), origin_branch],
        repo_root, timeout=60)
    if code != 0:
        fleetlib.log("spawn: worktree add failed for {}: {}".format(path, out))
        return False
    return True
```

In `main`, replace `return 0` with:

```python
    path = worktree_path(repo_root, number)
    if path.exists():
        # Idempotent by contract -- see --explain. Two agents in two
        # worktrees on one issue is the failure this prevents.
        fleetlib.log("spawn: issue {} already has a worktree".format(number))
        return 0

    slug = fleetlib.slugify(title)
    branch = "issue-{}-{}".format(number, slug) if slug else "issue-{}".format(number)
    if not create_worktree(repo_root, path, branch, origin_branch):
        sys.stderr.write("fleet-spawn: could not create the worktree\n")
        return 1
    return 0
```

And capture the title in `main` — replace the existence check:

```python
    title = issue_title(number, cwd)
    if title is None:
        sys.stderr.write("fleet-spawn: cannot read issue {}\n".format(number))
        return 1
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/spawn.bats`
Expected: 16 tests, all PASS.

- [ ] **Step 6: Run the whole suite**

Run: `tests/run.sh`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add bin/fleet-spawn tests/spawn.bats
git commit -m "feat: branch a worktree for the issue from the current branch"
```

---

### Task 5: The iTerm2 tab, and the executable form of the security rule

**Files:**
- Modify: `bin/fleet-spawn` (add `LAUNCH_PROMPT`, `TAB_SCRIPT`, `launch_tab`, `focus_existing`; call from `main`)
- Test: `tests/spawn.bats` (append)

**Interfaces:**
- Consumes: `fleetlib.spawn_record_path()` (Task 2), `fleetlib.write_json_atomic()`, `fleetlib.read_json()`
- Produces: `launch_tab(path, number) -> str | None` returning the new iTerm2 session id; `focus_existing(path) -> bool`

- [ ] **Step 1: Write the failing test**

Append to `tests/spawn.bats`:

```bash
# --- the iTerm2 tab -----------------------------------------------------

# A recording stub for osascript. It logs the script it was handed and
# prints a plausible session id, which is what the real one returns.
stub_osascript() {
  cat > "$BATS_TEST_TMPDIR/osa" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OSA_LOG"
printf '11111111-2222-3333-4444-555555555555\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/osa"
  export FLEET_OSASCRIPT="$BATS_TEST_TMPDIR/osa"
  export OSA_LOG="$BATS_TEST_TMPDIR/osa.log"
}

@test "TAB: a tab is opened for a successful spawn" {
  stub_osascript
  spawn 7
  [ -e "$OSA_LOG" ]
}

@test "TAB: the launch command cds to the worktree and starts claude" {
  stub_osascript
  spawn 7
  run cat "$OSA_LOG"
  [[ "$output" == *"$REPO/.claude/worktrees/issue-7"* ]]
  [[ "$output" == *"claude"* ]]
}

@test "TAB: the launch command names the issue number" {
  stub_osascript
  spawn 7
  run cat "$OSA_LOG"
  [[ "$output" == *"gh issue view 7"* ]]
}

@test "TAB: NO text from the issue title reaches the launch command" {
  # This is spec decision 4 as an assertion rather than a principle. The
  # title is chosen to be catastrophic if it were ever interpolated.
  stub_osascript
  stub_gh 'pwned $(touch /tmp/fleet-pwned) `id` "quoted"'
  spawn 7
  run cat "$OSA_LOG"
  [[ "$output" != *"pwned"* ]]
  [[ "$output" != *"touch"* ]]
  [ ! -e /tmp/fleet-pwned ]
}

@test "TAB: the spawned session id is recorded" {
  stub_osascript
  spawn 7
  run bash -c "cat '$FLEET_HOME'/spawns/*.json"
  [[ "$output" == *"11111111-2222-3333-4444-555555555555"* ]]
}

@test "TAB: a second call focuses the recorded session instead of spawning" {
  stub_osascript
  spawn 7
  : > "$OSA_LOG"
  export FLEET_FOCUS_CMD="$BATS_TEST_TMPDIR/osa"
  run spawn 7
  [ "$status" -eq 0 ]
  # No second tab was created.
  run grep -c 'create tab' "$OSA_LOG"
  [ "$output" = "0" ]
}

@test "TAB: no tab is opened when the worktree could not be created" {
  stub_osascript
  # An existing branch of the same name makes `git worktree add -b` fail.
  git -C "$REPO" branch issue-7-show-the-splash-on-screen-lock
  run spawn 7
  [ "$status" -eq 1 ]
  [ ! -e "$OSA_LOG" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/spawn.bats -f TAB`
Expected: FAIL on "a tab is opened for a successful spawn" — nothing invokes osascript.

- [ ] **Step 3: Add the launch prompt and the AppleScript**

Add to `bin/fleet-spawn`, after `EXPLAIN`:

```python
OSASCRIPT_TIMEOUT_SECS = 20

# A literal. The issue number -- validated as an integer -- is the only
# substitution, which is what lets this string cross a shell and an
# AppleScript boundary safely. Deliberately free of double quotes,
# backslashes and backticks so neither layer needs escaping rules applied
# to it. The last sentence is the guard against the worktree having been
# branched from the wrong place: stop rather than execute a plan that does
# not describe the code in front of you.
LAUNCH_PROMPT = (
    "Read GitHub issue #{n} in this repository by running: gh issue view {n} "
    "-- it names a plan file that is present in this worktree. Execute that "
    "plan with the superpowers:executing-plans skill, task by task. If the "
    "plan file is missing, or does not describe this repository, stop and "
    "report that rather than guessing."
)

# `create window with default profile` already yields a session, so the
# empty case must not also create a tab -- doing both opens two. Handling
# it at all matters because a verb that needs a window already open fails
# in exactly the situation where forking is most useful.
TAB_SCRIPT = '''
tell application "iTerm2"
  activate
  if (count of windows) is 0 then
    set newWindow to (create window with default profile)
    set newSession to (current session of newWindow)
  else
    tell current window
      set newTab to (create tab with default profile)
    end tell
    set newSession to (current session of newTab)
  end if
  tell newSession
    write text "{command}"
  end tell
  return id of newSession
end tell
'''
```

- [ ] **Step 4: Implement the launch and the focus path**

Add after `create_worktree`:

```python
def launch_tab(path, number):
    """Opens an iTerm2 tab running an agent in `path`. Session id or None.

    Every value reaching the shell and the AppleScript here is derived
    from the validated issue number: `path` is built from it, and the
    prompt is a literal with the number substituted. Nothing model-authored
    is in scope, which is why shlex.quote is sufficient rather than
    load-bearing.
    """
    command = "cd {} && claude {}".format(
        shlex.quote(str(path)),
        shlex.quote(LAUNCH_PROMPT.format(n=number)))
    # Defensive even though the literal contains neither character: if the
    # prompt is ever edited, this keeps the AppleScript string intact.
    escaped = command.replace("\\", "\\\\").replace('"', '\\"')
    osa = os.environ.get("FLEET_OSASCRIPT") or "osascript"
    try:
        proc = subprocess.run(
            [osa, "-e", TAB_SCRIPT.format(command=escaped)],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=OSASCRIPT_TIMEOUT_SECS)
    except Exception as err:
        fleetlib.log("spawn: could not open a tab for issue {}: {}".format(
            number, err))
        return None
    if proc.returncode != 0:
        fleetlib.log("spawn: osascript refused for issue {}".format(number))
        return None
    return proc.stdout.decode("utf-8", "replace").strip() or None


def focus_existing(path):
    """Brings an already-spawned agent's tab forward. False if unknown."""
    record = fleetlib.read_json(fleetlib.spawn_record_path(path))
    session_id = record.get("iterm_session") if isinstance(record, dict) else None
    if not session_id:
        fleetlib.log("spawn: {} exists but its tab was never recorded".format(path))
        return False
    focus = os.environ.get("FLEET_FOCUS_CMD") or str(HERE / "fleet-focus")
    try:
        proc = subprocess.run([focus, "iterm2", session_id],
                              stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=10)
    except Exception as err:
        fleetlib.log("spawn: focus failed for {}: {}".format(path, err))
        return False
    return proc.returncode == 0
```

In `main`, replace the `if path.exists():` block:

```python
    path = worktree_path(repo_root, number)
    if path.exists():
        # Idempotent by contract -- see --explain. Two agents in two
        # worktrees on one issue is the failure this prevents. Focusing
        # rather than refusing, because the operator pressing FORK twice
        # most likely wants to see the agent they already started.
        fleetlib.log("spawn: issue {} already spawned; focusing".format(number))
        focus_existing(path)
        return 0
```

And replace the tail of `main`:

```python
    if not create_worktree(repo_root, path, branch, origin_branch):
        sys.stderr.write("fleet-spawn: could not create the worktree\n")
        return 1

    session_id = launch_tab(path, number)
    if session_id is None:
        # The worktree is left in place deliberately: it holds the plan,
        # and `claude` can be started in it by hand. Removing it would
        # discard work to tidy up after a failure that did not touch it.
        sys.stderr.write("fleet-spawn: worktree created at {} but the tab "
                         "could not be opened\n".format(path))
        return 1

    fleetlib.write_json_atomic(fleetlib.spawn_record_path(path), {
        "issue": int(number),
        "branch": branch,
        "worktree": str(path),
        "iterm_session": session_id,
    })
    return 0
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/spawn.bats`
Expected: 23 tests, all PASS. Confirm `/tmp/fleet-pwned` does not exist afterwards.

- [ ] **Step 6: Run the whole suite**

Run: `tests/run.sh`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add bin/fleet-spawn tests/spawn.bats
git commit -m "feat: open an iTerm2 tab running an agent on the spawned worktree"
```

---

### Task 6: `config/verbs/fork.md`

The sink works and is drivable by hand at this point. Only now does the verb file exist to point an agent at it — the same ordering Row 2 used, where the keypress is the last thing that has to work rather than the first.

**Files:**
- Create: `config/verbs/fork.md`
- Test: `tests/verbs.bats` (append)

**Interfaces:**
- Consumes: `bin/fleet-verbs` `{FLEET_BIN}` substitution (Task 1); `bin/fleet-spawn` (Tasks 3–5)
- Produces: `fleet-verbs show fork` resolves; `fleet-verbs flags fork` reports `interrupt=false confirm=true`

- [ ] **Step 1: Write the failing test**

Append to `tests/verbs.bats`:

```bash
# --- the FORK verb ------------------------------------------------------

@test "FORK resolves and names fleet-spawn by an absolute path" {
  run "$BIN/fleet-verbs" show fork
  [ "$status" -eq 0 ]
  [[ "$output" == *"$ROOT/bin/fleet-spawn"* ]]
}

@test "FORK is a confirm verb" {
  # It files a public issue and starts an unsupervised agent. COMMIT,
  # PUSH and PR carry confirm for less.
  run "$BIN/fleet-verbs" flags fork
  [ "$output" = "interrupt=false confirm=true" ]
}

@test "FORK tells the agent about --explain" {
  run "$BIN/fleet-verbs" show fork
  [[ "$output" == *"--explain"* ]]
}

@test "FORK permits doing nothing" {
  # The most common bad fork is one where there was nothing to fork.
  run "$BIN/fleet-verbs" show fork
  [[ "$output" == *"do nothing"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/verbs.bats -f FORK`
Expected: FAIL — `fleet-verbs: no such verb: fork`.

- [ ] **Step 3: Write the verb file**

Create `config/verbs/fork.md`:

```markdown
---
id: fork
label: FORK
interrupt: false
confirm: true
---
Something separate from the current task has come up in this conversation.
Park it properly and hand it to a fresh agent, then carry on with what you
were doing.

First decide whether there is anything to fork. If no distinct piece of
work has surfaced — one that is genuinely separate from the task in hand,
not the next step of it — say so plainly and stop. Do not invent an issue
to justify this. Doing nothing is the correct outcome more often than not.

If there is, then:

1. Write it up as a plan using the superpowers:writing-plans skill, saved
   to `docs/superpowers/plans/YYYY-MM-DD-<slug>.md`. Assume the agent that
   executes it has no memory of this conversation and cannot ask you
   anything. Carry the context that makes it executable: what the problem
   is, why it matters, what you already know that is not obvious from the
   code, the constraints that apply, and what "done" looks like. This
   document is the entire handover — a thin plan produces a lost agent.

2. Commit the plan to the branch you are on. It must be committed before
   step 4, because the new worktree is branched from this branch and will
   only contain what is committed here.

3. File the issue with `gh issue create`. The body must name the plan's
   path, the branch it was committed on, and the commit SHA. Keep the body
   short — it is a pointer to the plan, not a copy of it.

4. Run `{FLEET_BIN}/fleet-spawn <issue-number>` with the number `gh` just
   reported. If you are unsure what that does or how flightdeck expects it
   to be called, run `{FLEET_BIN}/fleet-spawn --explain` and follow what it
   tells you.

5. Return to what you were doing before this interruption, and say in one
   line what you forked and where it went. Do not start executing the plan
   you just wrote — another agent now has it.

If any step fails, stop at that step and report it rather than working
around it. A half-forked task, where the issue exists but no agent is
working it, is worse than one that plainly did not happen.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/verbs.bats`
Expected: all PASS, including the 4 FORK cases.

- [ ] **Step 5: Verify the label fits the key**

Run: `python3 -c "print(len('FORK'))"`
Expected: `4`. `DOUBT` at 5 characters was the fit budget at 96px, so `FORK` is inside it with room to spare.

- [ ] **Step 6: Run the whole suite**

Run: `tests/run.sh`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add config/verbs/fork.md tests/verbs.bats
git commit -m "feat: add the FORK verb, which hands parked work to a new agent"
```

---

### Task 7: Live verification

Stubs prove the guards. They cannot prove that a real iTerm2 opens a tab, or that `claude` with a positional prompt *submits* rather than leaving it in the input box — which is the single unverified assumption this whole design rests on. The v1 spec observed that the `claude-cli://` deep link deliberately does not submit; this plan assumes the CLI's positional argument does. That has to be checked on a real machine before FORK is trusted.

**Files:**
- Modify: `docs/superpowers/specs/2026-08-14-flightdeck-fork-verb-design.md` (record the result)

**Interfaces:**
- Consumes: everything from Tasks 1–6

- [ ] **Step 1: Verify the submit assumption in isolation**

In any scratch repo, run:

```bash
claude 'Reply with exactly: SUBMIT CHECK OK'
```

Expected: the agent answers without you pressing Return.

**If the prompt sits unsent in the input box, stop.** The design's decision 3 — that the spawned agent starts work on arrival — is not achievable this way, and the plan needs revisiting before Task 7 continues. Record what actually happened; do not paper over it by having the operator press Return, which silently converts FORK into the bookmark decision 3 rejected.

- [ ] **Step 2: Verify the tab opens with no iTerm2 window present**

Quit iTerm2 entirely, then from a repo with an open issue:

```bash
bin/fleet-spawn <n>
```

Expected: iTerm2 launches, one window with one tab (not two), sitting in the new worktree with an agent running.

- [ ] **Step 3: Verify the ordinary path**

With an iTerm2 window already open, run `bin/fleet-spawn <n>` for a second issue.
Expected: a new **tab** in the existing window, agent running, and a new Row 1 slot appears — the spawned session reaches the state bus through the ordinary hook chain, with no integration code.

- [ ] **Step 4: Verify idempotency against a real tab**

Run `bin/fleet-spawn <n>` again for an issue already spawned.
Expected: the existing tab is focused. No second worktree, no second agent.

Confirm with: `git worktree list` — exactly one worktree per issue.

- [ ] **Step 5: Verify the whole verb end to end**

Start a real `claude` in the flightdeck repo, select it with a Row 1 press, and run `bin/fleet-send fork` while it is idle.

Expected: the agent writes a plan, commits it, files an issue, spawns a tab, and **returns to what it was doing** rather than executing the plan itself. That last behaviour is step 5 of the verb prompt and is the one most likely to be ignored — check it specifically.

- [ ] **Step 6: Record the results in the spec**

Update the *Testing* section of the design doc: replace "still unverified" for the submit assumption with what was observed. If anything behaved differently from the design, record the divergence rather than adjusting the description to match.

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/specs/2026-08-14-flightdeck-fork-verb-design.md
git commit -m "docs: record FORK's live verification results"
```

---

## Deferred

Recorded so they are not mistaken for oversights. Each is in the spec.

- **`bin/fleet-fail --explain`.** Already deferred in the Row 2 plan. `fleet-spawn` ships with `--explain` while `fleet-fail` lacks it; left alone deliberately rather than fixed in passing.
- **`confirm: true` enforcement.** Deferred out of Row 2's first slice. FORK ships with the flag set and inert, so it is live and unguarded until that lands.
- **The deck label for a spawned branch.** `issue-7-show-the-splash` shortens to roughly `issue-splas` through `fleetlib.shorten`. Identifiable, not lovely.
- **Whether the plan commit should be separable** from whatever else is on the origin branch.
- **A TTL or cleanup for `~/.fleet/spawns/`.** Records accumulate one per spawn and are never pruned. Small and harmless until it isn't.
- **Row 1 filling with slots nobody chose.** Worth watching in use before designing against it.
