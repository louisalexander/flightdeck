# Worktree Repo Label Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A session running in a linked worktree shows its **repository** on Row 1's top line, not the worktree's directory name.

**Architecture:** `bin/fleet-emit` derives the repo label from `git rev-parse --show-toplevel`, which in a linked worktree is the *worktree* path. Switch to the common git directory's parent, which is the primary checkout for both worktree kinds.

**Tech Stack:** Python 3 (stdlib only), bats.

**Spec:** `docs/superpowers/specs/2026-08-14-flightdeck-fork-verb-design.md` — recorded under *Live verification → Found during verification*.

## The problem

`bin/fleet-emit:151-152`:

```python
code, top = fleetlib.git(["rev-parse", "--show-toplevel"], cwd)
if code == 0 and top:
    repo = Path(top).name
```

`--show-toplevel` returns the working tree's own root. In a linked worktree that is the worktree directory, so `repo` becomes the directory name rather than the repository name.

This is a defect against stated intent, not a preference. The v1 spec, line 20: *"colour is state, **label is repo + branch**, press focuses that session."*

**Observed:** FORK spawns worktrees named after the issue, so a forked agent appears on Row 1 labelled `issue-13`. The operator cannot tell which repository it belongs to — and FORK's whole premise is that you are running several agents at once and need the deck to tell them apart. It is not FORK-specific: every worktree session has always shown its directory name, including `new-worktree-from-issue` and `green-when-should-be-blue`.

## The decision this has to settle

Fixing it makes every worktree of one repository share a top line. Five flightdeck worktrees all read `flightdeck`, distinguished only by the bottom line — the branch, which `fleetlib.shorten` compresses to 11 characters.

**Take the fix anyway.** Two reasons:

1. **The bottom line is the discriminator by design.** `shorten` exists precisely to make sibling branch names distinguishable — its docstring calls out `break-state-exit-handling` vs `break-state-entry-handling` and keeps first and last tokens for exactly this. The current behaviour puts a second discriminator on the top line and loses the repo entirely; that is a worse trade, because branch is recoverable from the bottom line and repo is recoverable from nowhere.
2. **Cross-repo is the case that breaks.** With worktrees of one repo, the labels are merely repetitive. With agents in *different* repos — the normal case on this deck — a directory-derived top line is actively misleading: `issue-13` and `flightdeck` look like two repositories when they are one.

If the repetition proves annoying in use, the answer is a better bottom line, not a top line that lies. Do not solve it here.

## Global Constraints

- **Python 3 stdlib only**, Python 3.9 compatible.
- **Hook scripts MUST ALWAYS EXIT 0.** `fleet-emit` carries this in its module docstring; a git failure here must degrade to an empty label, never raise.
- **Subprocesses take an argument LIST** via `fleetlib.git()`, never a shell string.
- **`--path-format=absolute` needs git ≥ 2.31.** Older git prints a path relative to `cwd` for `--git-common-dir`, so the implementation resolves it against `cwd` rather than assuming absolute. Do not skip that.
- **Test command.** `bats tests/emit.bats`, whole suite `tests/run.sh`.

---

### Task 1: Derive the repo label from the common git directory

**Files:**
- Modify: `bin/fleet-emit:150-153`
- Test: `tests/emit.bats` (append)

**Interfaces:**
- Consumes: `fleetlib.git()`
- Produces: `repo` in `~/.fleet/sessions/<id>.json` is the primary checkout's directory name for both primary and linked worktrees

- [ ] **Step 1: Write the failing test**

Append to `tests/emit.bats`:

```bash
# --- repo label in a linked worktree ------------------------------------
#
# Row 1's top line is meant to be the repository (v1 spec line 20). A linked
# worktree's --show-toplevel is the worktree, so the label used to read the
# worktree's directory name -- and a FORK-spawned agent showed "issue-13"
# with no indication of which repo it belonged to.

@test "REPOLABEL: a linked worktree reports the repository, not its own dir" {
  R="$BATS_TEST_TMPDIR/myrepo"
  git init -q "$R"
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  echo x > "$R/f.txt"
  git -C "$R" add .
  git -C "$R" commit -qm seed
  git -C "$R" worktree add -q -b wt "$BATS_TEST_TMPDIR/issue-99"

  printf '{"session_id":"WT1","cwd":"%s"}' "$BATS_TEST_TMPDIR/issue-99" \
    | "$BIN/fleet-emit" UserPromptSubmit
  run python3 -c "import json;print(json.load(open('$FLEET_HOME/sessions/WT1.json'))['repo'])"
  [ "$output" = "myrepo" ]
}

@test "REPOLABEL: a primary checkout is unaffected" {
  R="$BATS_TEST_TMPDIR/plainrepo"
  git init -q "$R"
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  echo x > "$R/f.txt"
  git -C "$R" add .
  git -C "$R" commit -qm seed

  printf '{"session_id":"P1","cwd":"%s"}' "$R" | "$BIN/fleet-emit" UserPromptSubmit
  run python3 -c "import json;print(json.load(open('$FLEET_HOME/sessions/P1.json'))['repo'])"
  [ "$output" = "plainrepo" ]
}

@test "REPOLABEL: a non-repo cwd still yields an empty label, not a crash" {
  mkdir -p "$BATS_TEST_TMPDIR/notarepo"
  printf '{"session_id":"N1","cwd":"%s"}' "$BATS_TEST_TMPDIR/notarepo" \
    | "$BIN/fleet-emit" UserPromptSubmit
  run python3 -c "import json;print(repr(json.load(open('$FLEET_HOME/sessions/N1.json'))['repo']))"
  [ "$output" = "''" ]
}

@test "REPOLABEL: the branch still comes from the worktree, not the primary" {
  # Only the repo half moves. Branch must stay per-worktree or every
  # worktree of a repo would report the primary checkout's branch.
  R="$BATS_TEST_TMPDIR/br"
  git init -q "$R"
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  echo x > "$R/f.txt"
  git -C "$R" add .
  git -C "$R" commit -qm seed
  git -C "$R" worktree add -q -b feature/thing "$BATS_TEST_TMPDIR/wt2"

  printf '{"session_id":"B1","cwd":"%s"}' "$BATS_TEST_TMPDIR/wt2" \
    | "$BIN/fleet-emit" UserPromptSubmit
  run python3 -c "import json;print(json.load(open('$FLEET_HOME/sessions/B1.json'))['branch'])"
  [ "$output" = "feature/thing" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/emit.bats -f REPOLABEL`
Expected: FAIL on the first case — `repo` is `issue-99`, not `myrepo`. The other three should already pass; they are regression guards, and a failure there means something beyond this change is wrong.

- [ ] **Step 3: Implement**

In `bin/fleet-emit`, replace lines 150-153:

```python
    repo = branch = ""
    # The REPOSITORY, not this working tree. --show-toplevel returns the
    # worktree's own root, so a linked worktree reported its directory name
    # -- a FORK-spawned agent showed "issue-13" and nothing about which repo
    # it belonged to. The common git dir is shared by the primary checkout
    # and every linked worktree, so its parent is the repository for both.
    #
    # Resolved against cwd rather than assumed absolute: --path-format is
    # git >= 2.31, and older git prints --git-common-dir relative to cwd.
    code, common = fleetlib.git(["rev-parse", "--git-common-dir"], cwd)
    if code == 0 and common:
        repo = (Path(cwd) / common).resolve().parent.name
        # Branch stays per-worktree. Only the repo half moves -- taking the
        # branch from the primary checkout would report one branch for
        # every worktree of a repo, which is the opposite of useful.
        _, branch = fleetlib.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/emit.bats`
Expected: all PASS, including the four added here.

- [ ] **Step 5: Run the whole suite**

Run: `tests/run.sh`
Expected: all PASS. `tests/reconcile.bats` and `tests/emit.bats` both assert session shape and are the likely places for a regression.

- [ ] **Step 6: Verify against the live fleet**

The unit tests use synthetic repos; this one is about what the operator actually sees.

```bash
python3 -c "
import json,glob,os
for p in glob.glob(os.path.expanduser('~/.fleet/sessions/*.json')):
    d=json.load(open(p))
    print(d['repo'].ljust(20), d['branch'].ljust(34), d['cwd'])
"
```

Expected: every flightdeck worktree reports `flightdeck`, not `issue-13` / `new-worktree-from-issue` / `green-when-should-be-blue`. Sessions must re-emit before this shows — send a prompt in one, or wait for the next hook.

- [ ] **Step 7: Commit**

```bash
git add bin/fleet-emit tests/emit.bats
git commit -m "fix: label a worktree session with its repo, not its directory"
```

---

## Done looks like

- A session in a linked worktree reports the repository on Row 1's top line.
- Branch still comes from the worktree.
- A non-repo cwd still degrades to an empty label rather than raising, preserving `fleet-emit`'s exit-0 contract.
- Full suite green.

## Out of scope

- **The branch label's legibility** when several worktrees of one repo are on the deck at once. Named in *The decision this has to settle* and deliberately not solved here; the answer, if one is needed, is a better bottom line.
- **`fleet-spawn`'s directory naming.** `.claude/worktrees/issue-<n>` is deliberate — the path is built from the issue number alone so that no model-authored text crosses a shell or AppleScript boundary (FORK spec, decision 4). Do not "fix" the label by renaming the directory.
