# Stream Deck XL as an Agent Fleet Console — Design

**Date:** 2026-08-13
**Status:** Approved design, ready for implementation planning
**Repo:** https://github.com/louisalexander/flightdeck

## Problem

Running 2–4 Claude Code agents in parallel today (growing to 2–3 repos × multiple
worktrees at work) means constant tab-hunting. The expensive failure is an agent
sitting blocked on a permission prompt while attention is elsewhere: the work is
done, the unblock is one keystroke, and the only thing missing is *knowing*.

A Stream Deck XL (8×4, 32 keys, everything visible without folders) can make fleet
state ambient — readable with peripheral vision, actionable with one thumb.

## Scope

**v1 is Row 1 only: fleet awareness.** Eight keys, one per live agent. Background
colour is state, label is repo + branch, press focuses that session, long-press
tears it down under guard.

Rows 2–4 from the originating concept (acts-on-focused-session, spawn & capture,
destinations) are explicitly **out of scope for v1** but the architecture is built
so they attach without redesign. Section "Deferred" records what they assume.

## Approach

Three options were considered:

- **A — Full custom Stream Deck plugin.** All logic in TypeScript. Truest to the
  concept, but every behavioural tweak costs a rebuild, reinstall, and plugin
  lifecycle debug cycle.
- **B — No plugin, built-in actions plus shell scripts.** Rejected: Elgato's
  built-in actions cannot have colour and label driven from outside the app, so
  this cannot deliver fleet awareness at all.
- **C — Thin plugin as a dumb renderer, shell scripts as the brain. CHOSEN.**

Under C the plugin ships exactly one action type, `Fleet Slot`, parameterised by a
slot index 0–7. It watches one JSON file, paints colour and label, and on press
shells out to `bin/fleet-press <slot> <verb>`. Every rule that will change —
what counts as blocked, how slots are assigned, what teardown means, how a host is
focused — lives in shell scripts that are edited and run directly from a terminal.

The TypeScript surface is small and stops changing after week one. The
work-machine port is `git clone` plus one plugin install.

## Architecture

```
┌─ Claude Code agent in an iTerm2 session ─┐
│  hooks fire on every state change        │
└───────────────┬──────────────────────────┘
                │  bin/fleet-emit <event>
                ▼
   ~/.fleet/sessions/<claude-session-id>.json     ← one file per live agent
                │
                │  (same script continues)
                ▼
   bin/fleet-reconcile  ───────►  ~/.fleet/slots.json
                ▲                  slot 0-7 → session, sticky assignment
                │
        launchd agent, 15s tick — reaps dead PIDs, frees slots
                │
                ▼
   Stream Deck plugin  — fs.watch(slots.json) → repaint 8 keys
                │  keyDown / keyUp
                ▼
   bin/fleet-press <slot> <short|long>
                ├─ iterm2 host:     osascript → select window+tab+session
                └─ pinned-app host: open -a "ChatGPT"
```

**Load-bearing principle: the plugin does no thinking.** It reads one small JSON
file and shells out one command. This is what keeps ~90% of the system testable
from a terminal with no hardware attached.

**Why `slots.json` is separate from `sessions/`:** stickiness. If the plugin
derived slots by listing the directory, a finishing agent would reshuffle every
other key and muscle memory would be worthless. `fleet-reconcile` owns assignment;
the plugin reads the answer.

**Writes are event-driven, cleanup is polled.** Hooks fire on real transitions, so
a key turns amber the instant an agent blocks — no polling latency. The 15s
launchd tick exists only to catch crashed sessions whose `SessionEnd` never ran.

### Verified environment assumptions

Confirmed on this machine during design:

- `ITERM_SESSION_ID` is exported into every iTerm2 session as `w1t4p0:<UUID>`.
- iTerm2 AppleScript can enumerate every session UUID across all windows and tabs.
  Direct `session id "<uuid>"` addressing **fails** (error -1728); iterate-and-match
  is required. Focus therefore works, including into split panes.
- `CLAUDE_CODE_SESSION_ID` is exported into the session, giving each agent a stable
  identity to key state on.
- Obsidian vault present at `/Users/pk/Documents/Obsidian Vaults/Vault 101`.
- `claude-cli://` is registered and functional. LaunchServices reports
  `claimed schemes: claude-cli:` bound to `com.anthropic.claude-code-url-handler`.
  The handler at `~/Applications/Claude Code URL Handler.app` is background-only
  and its `Contents/MacOS/claude` is a symlink to the real CLI. Requires Claude
  Code ≥ 2.1.91; this machine runs 2.1.231. See "Deep links" below.
- **A deep link opens a new iTerm2 session**, not Terminal.app — verified by
  session-count delta on a live probe. Spawned agents therefore receive an
  `ITERM_SESSION_ID`, fire the normal hooks, and appear in Row 1 automatically
  with no additional host adapter.
- **iTerm2 session names already carry Claude Code state and task titles**, e.g.
  `◑ Set up Stream Deck XL as AI agent (node)` and `✳ break-state-exit-handling
  (node)`. Enumerable over AppleScript. See "Titles as a second signal" below.

**Unverified, must be checked first in implementation:** the exact Claude Code hook
event names and their stdin payload shapes. The `claude` binary is compiled and
could not be inspected. Everything below assumes the five hooks named; confirm
before building on them.

## State model

| State | Colour | Glyph | Meaning | Set by |
|---|---|---|---|---|
| `blocked` | bright amber | ▲ | Waiting on you — permission prompt or question | `Notification` |
| `working` | deep blue | ● | Prompt submitted, tools running | `UserPromptSubmit` |
| `done` | green | ✓ | Turn complete, awaiting next instruction | `Stop` |
| `idle` | dim grey | · | Session alive, nothing in flight | `SessionStart` |
| `failed` | deep red | ✕ | Something broke. Sticky until cleared | see below |
| `empty` | off / black | — | No session in this slot | `fleet-reconcile` |

**Colour carries the message; the glyph is redundancy.** Row 1 is read with
peripheral vision, so hue separation matters more than text. Amber and red are
adjacent hues and red/green is the common colourblind failure, so a one-character
glyph makes every state legible without relying on colour alone.

**No animation in v1.** All states render solid.

### Hook set — exactly five, all low-frequency

`SessionStart`, `UserPromptSubmit`, `Notification`, `Stop`, `SessionEnd`.

`PreToolUse` and `PostToolUse` are deliberately **not** used. They fire on every
tool call, so a hook there would add shell-out latency to every action of every
agent in the fleet. The fleet must stay invisible to the thing it is watching.

### On `failed`

No Claude Code hook means "your agent screwed up." Inferring it from non-zero Bash
exits would be noise — many commands exit non-zero by design.

In v1, red is set by exactly two things: an abnormal `SessionEnd`, and a manual
`bin/fleet-fail <slot>`.

The real signal arrives with Row 2: when the user presses "run tests" and they
fail, that slot goes red and stays red until cleared. Failure becomes something
verification actions *report*, never something the deck guesses.

### Titles as a second signal

iTerm2 session names already carry Claude Code's own status glyph and a task title,
enumerable over AppleScript with no hook involvement:

```
◑ Set up Stream Deck XL as AI agent (node)     ← busy
✳ break-state-exit-handling (node)             ← ready
```

This is a **fallback state source, not the primary one.** Hooks stay primary: they
are event-driven, so a key turns amber the instant an agent blocks, whereas titles
must be polled. But the glyph is a genuine second signal that depends on nothing
this project builds, which materially de-risks Open Risk 2 — if `Notification`
turns out not to fire on permission prompts, the amber key has another way to work.

Implementation note: treat the glyph vocabulary as **unversioned and liable to
change without notice**. Parse defensively, map unknown glyphs to `idle`, and never
let a parse failure propagate.

### Labels

Two lines: repo short name on top, and below it the **task title** taken from the
iTerm2 session name, falling back to branch when no title is available.

The originating concept assumed branch names, but the live data argues otherwise:
`break-state-exit-handling` is more informative than `feat/break-state` at 96px,
and enormously more informative than `main` when three repos all have one. Branch
remains the fallback because pinned and non-CLI slots have no session title.

At 96px roughly 8–10 characters fit per line, so `fleet-reconcile` shortens before
the label reaches the key: strip the status glyph and the trailing `(node)`, strip
known branch prefixes (`feat/`, `<repo>-wt-`), then truncate.

### Slot assignment

- A session claims the **lowest free non-pinned slot** on first sight and holds it
  until it dies.
- On death the slot goes `empty` and **nothing else moves**. No compaction, no
  reshuffling. Slot 3 stays slot 3 all afternoon.
- Pinned slots declared in local config are never auto-assigned.
- **Overflow past 8: stickiness wins.** The first eight to appear keep their slots;
  later sessions are unslotted and logged with a count. Accepted trade-off: a
  blocked ninth agent is invisible until a slot frees. Chosen because keys that
  move under the thumb destroy the entire value of the row.

## Press semantics

### Short press — focus, dispatched on host

Each session file carries a `host` field. `fleet-press` is a case statement over it:

- **`iterm2`** — enumerate windows → tabs → sessions, match the UUID, then `select`
  the window, the tab and the session, and `activate` iTerm2.
- **`pinned-app`** — `open -a "<AppName>"`.
- **`conductor`** and any future host — one additional case, nothing else changes.

That case statement is the entire host-portability story.

### Long press — arm, then confirm

Long press is destructive, so **it does not fire on the hold**:

1. Hold ≥800ms **arms** the key: it flips red, reads `CONFIRM?`, and lives 3 seconds.
2. A second press inside that window executes.
3. Timeout, or any other key, disarms.

The arm state lives in a marker file carrying an expiry timestamp, not in the
plugin. The plugin's existing `fs.watch` repaints on arm; a single 3s timer
repaints on expiry. The plugin still knows nothing.

### Teardown safety — hard rule

**A thumb on a Stream Deck must never be able to destroy uncommitted work.**

Confirmed long-press performs:

1. Kill the Claude process in that session.
2. Inspect the worktree. If there are uncommitted changes, **or** commits not
   pushed anywhere: **stop**. Leave the worktree exactly as it is, flip the slot to
   red, and log the reason.
3. Only if the tree is genuinely clean and merged: remove the worktree and prune
   the branch.

Force-removal exists as a script run deliberately in a terminal where its output is
readable. Never on a key. The deck makes the safe path fast; it does not make the
dangerous path reachable by accident.

## Repository layout

```
stream-deck/
├── bin/           fleet-emit · reconcile · press · focus · kill · fail · doctor
├── plugin/        @elgato/streamdeck TS plugin (the dumb renderer)
├── hooks/         settings snippet to merge into ~/.claude/settings.json
├── launchd/       15s reaper agent
├── config/        fleet.json (committed) + fleet.local.json (gitignored)
└── install.sh
```

### Configuration — layered for two machines

- **`config/fleet.json`** — committed, machine-agnostic: colours, glyphs,
  label-shortening rules, timings (arm duration, reaper interval).
- **`config/fleet.local.json`** — gitignored, machine-specific: pinned slot
  definitions and the Obsidian vault path. Two keys. No merge conflicts between
  home and work.

Resolution order: built-in defaults ← `fleet.json` ← `fleet.local.json`.

**No repo-root list is needed.** `fleet-reconcile` derives repo and branch from the
session's own `cwd` via `git rev-parse`. Nothing to configure, and it works in
repos not yet thought of.

### State directory

`~/.fleet/` — identical path on both machines.

```
~/.fleet/
├── sessions/<claude-session-id>.json   one per live agent
├── slots.json                          sticky slot → session map
├── armed.json                          long-press arm markers with expiry
├── events.jsonl                        append-only, never pruned
└── fleet.log                           hook errors
```

## Error handling

Hooks run inside live agents, so they follow two absolute rules:

1. **Always `exit 0`**, regardless of what happened. A bug in this system can never
   break actual work. Worst case the deck goes stale and the reason lands in
   `~/.fleet/fleet.log`.
2. **Write atomically** — temp file plus rename. The plugin can never read a
   half-written file and paint garbage.

Additional handling:

- Stale detection via `kill -0 <pid>`; the reaper frees slots for dead sessions.
- Missing or corrupt `slots.json`: the plugin renders all keys `empty` with a `?`
  rather than crashing.
- Focus target no longer exists (tab closed, hook never fired): mark stale, key
  goes dark, log it.

### `fleet-doctor`

One command that makes the work-machine port survivable. Checks:

- `~/.fleet/` exists and is writable
- the five hooks are present in `~/.claude/settings.json`
- the launchd reaper is loaded
- the Stream Deck plugin is installed
- the Stream Deck application is running
- **iTerm2 automation permission is actually granted**

The last is the classic silent killer: macOS denies AppleScript automation with no
visible error. A command that says so out loud saves an evening.

## Testing

Because the plugin is dumb, nearly everything is a pure function over the
filesystem and needs no hardware and no running agents:

- **`fleet-emit`** — pipe hook JSON on stdin, assert the resulting session file.
- **`fleet-reconcile`** — point at a fixture `sessions/` directory, assert
  `slots.json`. Covers stickiness, reaping, overflow, pinned-slot exclusion.
- **`fleet-press`** — assert host dispatch and the arm/confirm state machine with
  the focus adapter stubbed.
- **Teardown guard** — fixture worktrees (dirty, unpushed, clean) asserting that
  only the clean one is ever removed. Highest-value test in the suite.
- **Plugin** — colour and label mapping tested as a pure function.

`fleet-focus` genuinely requires a live iTerm2 and is verified by hand. It is
isolated in its own script precisely so it is the only such thing.

## Memory substrate — reserved, not built

An Obsidian vault as one memory substrate shared across tools is intended DNA.
It is not built in v1, but the architecture reserves it now because it is the same
`Stop` hook already being wired — journaling is a second consumer of an event
already emitted, not a new integration.

Two provisions in v1:

1. **`fleet-emit` appends every event to `~/.fleet/events.jsonl`** — append-only,
   never pruned: repo, branch, session, event, cwd, git SHA, timestamp. Today a
   debugging aid; later the spine the Obsidian exporter reads. Cost: ~3 lines.
2. **`config/fleet.local.json` carries `journal.vault`** pointing at
   `/Users/pk/Documents/Obsidian Vaults/Vault 101`. Unused in v1.

**Decided policy for when it is built: mechanical always, LLM on demand.**

A shell hook cannot produce "decision, open question" — that requires summarising a
transcript. Every turn gets its mechanical spine for free (repo, branch, files
touched, diff stat). Expensive summarisation fires only on a deliberate Row 3
keypress. This is also a better NotebookLM source than auto-summarising everything:
a vault full of summaries of trivial turns buries the decisions worth searching for.

## Deep links (`claude-cli://`) — Row 3 needs no code

Claude Code registers a custom URL scheme with the OS, the same way `mailto:` opens
a mail client. Requires ≥ 2.1.91.

```
claude-cli://open?q=<prompt>&cwd=<abs-path>&repo=<owner/repo>
```

Opening one hands the URL to the OS, which launches Claude Code in a new terminal
window, in the given directory, with the prompt **already in the input box but not
sent**. A deep link never executes anything on its own: the prompt sits inert, with
a "Prompt from an external link" warning below the input, until it is read and Enter
is pressed.

**Architectural consequence.** Stream Deck's built-in *Website* action opens a URL.
So all of Row 3 — spawn a worktree with the spec-first template, the bugfix
template, the review-critic template — is three deep links configured in Elgato's
app in about five minutes. No plugin code, no AppleScript, no terminal automation.

This sharpens the scope boundary rather than widening it: **the custom plugin is
needed only for Row 1, because Row 1 is the only row whose key images change.**
Static-image rows are configuration, not software.

Verified: a deep link opens a new **iTerm2** session, so a spawned agent flows into
the state bus and appears in Row 1 automatically — pressing a Row 3 key makes a new
Row 1 key light up, with no integration code between them.

### Constraints

- **`cwd` must be an absolute path.** `repo` only resolves to clones Claude Code has
  already seen, so prefer `cwd`, or run `claude` once in each worktree first.
- **GitHub-rendered Markdown strips the scheme** in READMEs, issues and wikis. Any
  deep link in this repo's docs must sit inside a code block so it can be copied.

### Security rule — hard

**Never generate a deep link from untrusted input.** A patched RCE allowed a crafted
`q` parameter to smuggle a `--settings` flag carrying a `SessionStart` hook,
achieving arbitrary command execution.

Hand-authored templates in local config are fine, and that is the entire v1 use.
The rule exists because the memory-substrate and journal work later in this
roadmap is exactly the kind of feature that starts templating links from captured
text. Links are built only from literals in `fleet.local.json` — never from issue
titles, CI output, branch names, or model output.

## Deferred

**Conductor.** Not adopted. It would be a *host*, not a replacement — it runs real
Claude Code, so hooks fire and the state bus fills for free. But it breaks the
focus verb (no `ITERM_SESSION_ID`; press-to-focus degrades to "activate Conductor"
unless per-workspace deep links exist, which is unverified), and it overlaps both
Row 1 and Row 3. Adopting it now would fork the design before the design exists.
Later cost: one focus adapter case. Revisit when worktree pain is actually felt.

**Row 3.** Out of scope as *engineering*, but effectively free once v1 ships: three
`claude-cli://` deep links on built-in Website actions, configured in Elgato's app.
Worth doing by hand the same day Row 1 works. Nothing in v1 blocks it and it needs
no code from this repo beyond the template strings living in `fleet.local.json`.

**Rows 2 and 4.** Out of scope. Row 2 additionally requires knowing which session is
*currently focused* — a thin white border on the active slot — which is deferred
with it. Row 2 is also where `failed` gets its real signal.

**Animation, dials, folders.** Not in v1.

## Open risks

1. **Hook names and payload shapes are unverified.** First implementation step.
2. **`Notification` may not fire exactly on permission prompts.** The amber key is
   the highest-value element of the design. **Downgraded from critical:** iTerm2
   session-title glyphs are a verified independent fallback (see "Titles as a second
   signal"), so failure here costs polling latency rather than sinking the design.
   Still worth resolving early, because event-driven beats polled.
3. **macOS automation permissions** must be granted for iTerm2 control, on both
   machines. `fleet-doctor` surfaces this.
