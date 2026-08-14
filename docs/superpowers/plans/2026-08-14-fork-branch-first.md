# FORK Branch-First Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pressing FORK while on the default branch must not commit the plan file to the default branch.

**Architecture:** The fix goes in `config/verbs/fork.md`, matching where COMMIT, PUSH and PR already carry the same rule. Not in `bin/fleet-spawn` — see *Why not the sink* below, which is the one real decision here and the reason this needs a plan rather than a one-line edit.

**Tech Stack:** Markdown verb file, bats.

**Spec:** `docs/superpowers/specs/2026-08-14-flightdeck-fork-verb-design.md` — the gap is recorded under *Live verification → Found during verification*.

## The problem

FORK step 2 says "Commit the plan to the branch you are on." On the default branch, that is a plan commit landing directly on `main`.

Every other committing verb already guards this, in its prompt:

| Verb | Wording |
|---|---|
| `commit.md:20` | "If the working tree is on the default branch, create a branch first." |
| `push.md:15` | "If you are on the default branch, create a branch first and say so." |
| `pr.md:10` | "branch first if you are on the default branch" |
| `fork.md` | **nothing** |

FORK is the only one missing it, and it is the one that commits *without the operator having asked for a commit* — the plan file is a side effect of parking work, not the thing the operator pressed the key for. That makes the missing rule worse here than it would be on COMMIT.

**How this was found:** during FORK's live verification, seeded agents kept landing in the primary checkout on `main` (a new iTerm2 tab inherits the frontmost session's directory). Firing FORK at one would have written a plan commit onto `main`. The verification was abandoned rather than run, and the gap recorded instead.

## Why not the sink

The obvious alternative is to make `bin/fleet-spawn` refuse when the branch it is about to fork from is the default branch. That is wrong, and the reasoning should survive into the code comment:

`fleet-spawn` runs at **step 4**, after the plan has been committed at step 2 and the issue filed at step 3. A refusal there cannot undo the commit. It would leave a plan commit on `main`, a filed issue, and no agent working it — which `fork.md` itself calls out as the worst available outcome: *"A half-forked task, where the issue exists but no agent is working it, is worse than one that plainly did not happen."*

Enforcement has to happen before the commit, and the only thing running before the commit is the prompt. So the prompt is where it goes — which is also why the other three verbs put it there, rather than in `fleet-press` or `fleet-send`.

**Branching the worktree from the default branch is fine and must stay allowed.** The problem is never the fork point; it is the commit. Once the agent has branched, the plan is committed to the new branch and `fleet-spawn` branches the worktree from that — consistent, and no change to the sink at all.

## Global Constraints

- **Verb files are markdown, frontmatter plus prose.** No code changes in this plan.
- **`{{FLIGHTDECK_REPO}}`** is the token for flightdeck's own path; do not introduce another.
- **Match the existing wording.** Three verbs already phrase this rule; a fourth phrasing is a maintenance cost for no gain.
- **Test command.** `bats tests/verbs.bats`, or the whole suite with `tests/run.sh`.

---

### Task 1: FORK branches first on the default branch

**Files:**
- Modify: `config/verbs/fork.md` (step 2 of the numbered list)
- Test: `tests/verbs.bats` (append to the FORK block)

**Interfaces:**
- Consumes: nothing
- Produces: `fleet-verbs show fork` includes the branch-first instruction

- [ ] **Step 1: Write the failing test**

Append to the `# --- the FORK verb ---` block in `tests/verbs.bats`:

```bash
@test "FORK branches first when on the default branch" {
  # The plan file is a side effect of parking work, not a commit the
  # operator asked for -- so landing it on main is worse here than it
  # would be for COMMIT, which at least says "commit" on the key.
  run "$BIN/fleet-verbs" show fork
  [[ "$output" == *"default branch"* ]]
  [[ "$output" == *"branch first"* ]]
}

@test "FORK's branch-first rule sits with the commit step, not at the end" {
  # A rule stated after step 4 is a rule the agent reads after it has
  # already committed.
  run "$BIN/fleet-verbs" show fork
  before=$(printf '%s' "$output" | grep -n "branch first" | head -1 | cut -d: -f1)
  after=$(printf '%s' "$output" | grep -n "fleet-spawn" | head -1 | cut -d: -f1)
  [ -n "$before" ]
  [ -n "$after" ]
  [ "$before" -lt "$after" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/verbs.bats -f "branches first"`
Expected: FAIL — `fork.md` says nothing about the default branch.

- [ ] **Step 3: Add the rule to step 2 of `config/verbs/fork.md`**

Replace step 2 of the numbered list:

```markdown
2. Commit the plan to the branch you are on. If you are on the default
   branch, create a branch first and say so — the plan file is a side
   effect of parking work, not a commit that was asked for, and it must
   not land on the default branch. It must be committed before step 4:
   the new worktree is branched from this branch and will contain only
   what is committed here.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/verbs.bats`
Expected: all PASS, including the two added here.

- [ ] **Step 5: Run the whole suite**

Run: `tests/run.sh`
Expected: all PASS.

- [ ] **Step 6: Record the resolution in the spec**

In `docs/superpowers/specs/2026-08-14-flightdeck-fork-verb-design.md`, under *Found during verification*, mark the branch-first bullet resolved and state that enforcement is prompt-level for the reason in *Why not the sink* above. Do not delete the finding — the reasoning is why the sink was left alone.

- [ ] **Step 7: Commit**

```bash
git add config/verbs/fork.md tests/verbs.bats \
        docs/superpowers/specs/2026-08-14-flightdeck-fork-verb-design.md
git commit -m "fix: FORK branches first on the default branch, as COMMIT/PUSH/PR do"
```

---

## Done looks like

- `fleet-verbs show fork` carries the branch-first rule, worded as the other three verbs word it, positioned with the commit step rather than after the spawn step.
- `bin/fleet-spawn` is unchanged, and the spec records why.
- Full suite green.

## Out of scope

Recorded so they are not mistaken for oversights. Both were found in the same verification pass and are separately tracked.

- **A spawned worktree's Row 1 label reads `issue-<n>` rather than the repo name**, because the label derives from the directory name and `fleet-spawn` names the directory after the issue.
- **FORK's happy path is still unverified end to end** — the plan commit, `gh issue create`, the chained spawn, and the "return to what you were doing" instruction. That is verification work, not a fix, and it is blocked on having an agent in a repo with a GitHub remote, off the default branch, holding a real forkable tangent.
