<p align="center">
  <img src="assets/brand/flightdeck-lockup.svg" alt="flightdeck" width="420">
</p>

Running two to four Claude Code agents in parallel means constant tab-hunting.
The expensive failure isn't lost time — it's an agent sitting blocked on a
permission prompt while your attention is somewhere else. The work is done,
the unblock is one keystroke, and the only thing missing is *knowing*.

flightdeck turns Row 1 of a Stream Deck XL into an annunciator panel for a
fleet of Claude Code agents. Eight keys, one per live session. Background
colour is lifecycle state, read in peripheral vision before it's read as
text. A press focuses that session's iTerm2 window. A long-press, guarded,
tears it down.

This is v1: Rows 1 through 3 are built and running on real hardware —
annunciator, commands, and verdicts. Row 4 (GATE, SPEND, DISPATCH) is not; see
*Out of scope for v1*.

## The state table

| State | Colour | Glyph | Meaning | Set by |
|---|---|---|---|---|
| `blocked` | `#F5A623` amber | ▲ | Waiting on the operator | `Notification` hook |
| `working` | `#1256A3` dark blue | ▶ | Prompt submitted, tools or reasoning active | `UserPromptSubmit` hook, or `Stop` with background work still in flight |
| `done` | `#238636` green | ✓ | Turn complete, awaiting next instruction | `Stop` hook, with nothing in flight |
| `idle` | `#25282D` near-black grey | · | Session alive, nothing in flight | `SessionStart` hook |
| `failed` | `#B42318` red | ✕ | Observed failure, sticky until cleared | abnormal `SessionEnd`, or `fleet-fail` |
| `empty` | `#000000` black | *(none)* | No session in this slot | `fleet-reconcile` |

Colours and glyph names live in [`config/fleet.json`](config/fleet.json).

**Attention hierarchy.** Amber pulls attention — it's the whole point of the
project. Green reports completion. Red reports a problem needing
investigation. `working` is a deliberately *dark* blue so an agent doing its
job recedes rather than competing with one that needs you. Grey is
ignorable. Black is absence — an empty slot renders fully black, with no
content, because absence should look absent.

**Green means finished, not merely stopped.** Claude Code's `Stop` hook fires
when an assistant *turn* ends, which is not the same as the agent awaiting
you. A turn that ends with a backgrounded subagent, shell or workflow still
running wakes itself back up with no input from you, so those sessions stay
blue — `Stop` carries a `background_tasks` array for exactly this purpose, and
flightdeck paints green only when it is empty. A long-lived background task —
a dev server, say — therefore holds a key blue while its agent sits idle. That
is the deliberate direction to err: a false blue merely recedes, and amber
still overrides it, whereas a false green hides a busy agent behind a colour
that says *your turn*.

Colour carries the message; the glyph is redundancy. Amber and red are
adjacent hues, and red/green is the most common colourblind failure, so
every state stays legible without relying on colour alone. Glyphs are drawn
as SVG geometry — `<polygon>`, `<path>`, `<circle>`, `<line>` — never as
`<text>`. `▲` and `▶` (U+25B2, U+25B6) aren't in Helvetica, so a text glyph
would silently fall back to some other font with different metrics: wrong
position at best, a blank key at worst. Geometry means the redundant channel
cannot fail to render.

## Architecture

```
Claude Code hooks (SessionStart, UserPromptSubmit, Notification, Stop, SessionEnd)
        │
        │  bin/fleet-emit <event>
        ▼
~/.fleet/sessions/<session-id>.json      one file per live agent
        │
        │  bin/fleet-reconcile  (also run by the 15s launchd reaper)
        ▼
~/.fleet/slots.json                      sticky slot 0-7 -> session
        │
        │  fs.watch
        ▼
Stream Deck plugin  (paints 8 keys, dispatches key presses)
        │
        │  bin/fleet-press <slot> <short|long>
        ▼
osascript (iTerm2) / open -a (pinned app)
```

The plugin is deliberately dumb: each action type watches the fleet's state
under `~/.fleet`, paints colour and label, and — for the three you press —
shells out to a script. It ships four action types, each parameterised by
whatever its row needs rather than by one fixed shape: a slot index for Row
1, a verb for Row 2, a verdict (plus, for STEER, a verb) for Row 3. Every
rule that's likely to change — what counts as blocked, how slots get
assigned, what teardown means, how a host gets focused — lives in Python
scripts under `bin/` that you edit and run directly from a terminal.
Nothing there requires rebuilding or reinstalling the plugin.

Writes are event-driven, cleanup is polled: a hook fires on a real state
transition, so a key turns amber the instant an agent blocks, with no
polling latency. The 15-second launchd tick (`bin/fleet-reap`) exists only
to catch crashed sessions whose `SessionEnd` never ran.

## Quickstart

```
./install.sh
./bin/fleet-doctor
```

`install.sh` pins the Python interpreter, merges the seven hooks into
`~/.claude/settings.json`, loads the launchd reaper, and builds and links
the plugin into Stream Deck. `fleet-doctor` then verifies every moving part
— interpreter, hooks (including the `PermissionRequest` one Row 3 depends
on, and the halt clause's ordering), whether the fleet is currently
halted, reaper, plugin, Stream Deck running, and iTerm2 automation
permission, the classic silent killer macOS denies with no dialog.

Once it's installed, drag the `Fleet Slot` action onto Row 1 in the Elgato
app. Each key defaults to its own **column**, so dragging the action across
all eight keys of Row 1 needs no per-key configuration.

## Safety

**A thumb on a Stream Deck must never be able to destroy uncommitted work.**

Long-press **arms** a teardown; it does not perform one. Holding a key for
800ms flips it to an armed presentation that lives for 3 seconds. A second
press inside that window confirms and runs the teardown. A timeout, or
pressing any other key, disarms — the key returns to its previous lifecycle
state, not to a neutral one.

The armed key renders near-black with an amber warning triangle, deliberately
**not** red. Red is reserved for an observed failure, and an operator merely
considering teardown hasn't experienced one — reusing red would make "this
agent broke" and "you are one press from destroying a worktree" visually
identical at exactly the moment the distinction matters most. Red appears
only after a teardown is *refused*, because a refusal genuinely is a problem.

A confirmed teardown ([`bin/fleet-kill`](bin/fleet-kill)) kills the agent
process, then inspects the worktree. It removes it only if **every** one of
these holds:

- it is a **linked worktree** (its `git rev-parse --git-dir` differs from
  its `--git-common-dir` — a primary checkout or a submodule is refused);
- `git status --porcelain` is clean;
- it has an **upstream** configured;
- it has **no unpushed commits** against that upstream;
- and it has **no gitignored-but-present files**.

That last check exists because `git worktree remove` deletes ignored files
without needing `--force`. `git status --porcelain` never reports them, so a
worktree holding a gitignored `.env` or scratch notes would look perfectly
clean by every other check while the removal silently destroyed it. Anything
the checks can't prove — a `git` call that fails, times out, or returns
something unexpected — resolves to **refuse**, never to "assume safe."

The branch ref itself is never deleted, only the worktree. Removal is
reversible with `git worktree add`; branch deletion isn't. Force-removal
exists only as a script run deliberately in a terminal where its output is
readable — never reachable from a key.

## Row 3: verdict keys

Row 3 answers the permission prompt Claude Code is already showing, from
the deck, without a context switch to the terminal. `bin/fleet-decide` sits
on the `PermissionRequest` hook and blocks — up to `timings.decideTimeoutSecs`
(120s) — until a decision is written or its own timeout notices first. It's
the one hook in flightdeck allowed to do that; see *Why the deciding hook
may block* below for why that's safe.

The row is auto-targeted: it answers for **the selected session if it has a
pending decision, otherwise the oldest pending decision** — no separate
targeting press for the common case of one amber key. Disambiguating between
several pending requests is a Row 1 press, which you'd have to make anyway to
know which agent is which.

| Key | Action | Sends |
|---|---|---|
| 1 | DETAIL | nothing — focuses and selects the session, exactly like a Row 1 press |
| 2 | APPROVE | allow — arms first when the tier is `high` |
| 3 | REMEMBER | allow + Claude Code's own suggested rule — always arms |
| 4 | DENY | deny, with a stock message |
| 5 | STEER — JUSTIFY | deny: explain what this does and why, then wait |
| 6 | INTERRUPT | deny + `interrupt: true` — stop, don't retry |
| 7 | STEER — OTHER WAY | deny: reach the goal without that command |
| 8 | *(unbound — `dryrun` ships in `config/verbs/`, bind it if wanted)* | |

**Getting the row onto the deck is per-key, unlike Row 1.** Drag the
`Verdict` action across Row 3's eight keys, then set each key's verdict in
its property inspector — it defaults to `(none)`, which does nothing when
pressed. Keys 5 and 7 (STEER) also need their verb dropdown set to
`justify` or `otherway`; key 8 is left unbound above but can take `dryrun`
the same way.

Risk tier comes from [`config/risk.json`](config/risk.json) — a rule table,
not a model, so a `high` classification (`rm -rf`, `git push --force`,
`git reset --hard`, `sudo`, `dd if=`, a pipe into `sh`, …) is predictable and
testable against fixtures. A tier only ever adds friction on top of a prompt
the operator is already being shown; it never removes one and never grants
anything, so a pattern missing from the table degrades to today's behaviour,
never to an unguarded action.

**DETAIL never shows the request.** No key renders tool input — at 96px
`rm -rf ./build` and `rm -rf ./ build` truncate identically, so a truncated
command reads as information while being ambiguous exactly where it
matters. DETAIL carries only a classification (agent, tool, tier, repeat
count); the complete request is one press away, already drawn in full by
Claude Code in the terminal it's blocked in.

### The worktree trap under REMEMBER

`updatedPermissions` — the rule REMEMBER writes — persists to the
**canonical repo root's** `.claude/settings.local.json`, never to the
worktree the agent is actually running in. Verified empirically: a probe
run with `cwd` inside a linked worktree created no `.claude/` there at
all.

That makes REMEMBER's blast radius bigger than the session that pressed
it: **one press widens permissions for every agent in every worktree of
that repository, including ones that do not exist yet.** No tier says
that — a `low`-tier REMEMBER is exactly as far-reaching as a `high`-tier
one — so REMEMBER always arms, regardless of tier, and its armed face
names the repository and the rule rather than the agent:

```
flightdeck
Bash(git push:*)
CONFIRM?
```

The agent is the one thing this press is not scoped to, so it's the one
thing that must not appear on the confirmation. There is no undo on the
deck; removing a remembered rule is a text edit to that file.

### Why the deciding hook may block

`fleet-decide` is the one hook in this project allowed to sit — every
other hook must exit in milliseconds because it runs on a live agent's
critical path, and this is the exception because it only ever fires once
the agent is already stopped, waiting on a human either way.

**Every way it can fail degrades to Claude Code's own dialog, still
answerable.** An unplugged deck, a crashed plugin, a bug in `fleet-decide`
throwing partway through, an operator who simply walked away — none of
them block the agent any further than not having flightdeck installed at
all would have, because `fleet-decide` emits *nothing* on timeout rather
than a denial. The ordinary permission dialog stays exactly where it would
have been. The dialog and the deck race for the same answer and whichever
responds first wins; answering in the terminal while the deck is still
waiting is a normal outcome of that race, not a failure of either path.

## HALT

`bin/fleet-halt` is the emergency brake. Today it's a script, run from a
terminal — `bin/fleet-halt --off` clears it. A dedicated Stream Deck key
for it arrives with Row 4; the design called for one calling this script
directly, needing no custom plugin action. **Do not improvise a binding
for it now.** Stream Deck's built-in *Open* action shells out to macOS
`open`, and `bin/fleet-halt` is a shebang'd Python file with no
`.command` extension — `open` on it launches a text editor instead of
running it, which is the worst failure this feature can have: an operator
reaches for the brake mid-incident and gets TextEdit.

**HALT's exact guarantee: no NEW tool call reaches your machine while the
latch is set. It does not guarantee the agent stops.** The latch is a
file, read by pure shell spliced onto the front of the `PreToolUse` hook —
no Python, no config parsing, nothing flightdeck's own tooling could break
— so every *new* tool call is denied before it runs, even under
`bypassPermissions` or `--dangerously-skip-permissions` (checked by hand,
twice). But a denial is something the model *receives and reasons about*:
it is free to retry the identical call or try to route around the
refusal, and work already in flight when the latch lands keeps running
unless the accompanying ESC actually lands on it. HALT stops the hands
going forward. It does not stop a hand already moving, and it does not
stop the head.

The second half of HALT is that ESC: sent only to sessions Row 1 already
knows are `working`, and only over a real iTerm2 host with a well-formed
session id. It is never sent to a `blocked` session — there, ESC selects
"No, and tell Claude what to do differently" and opens a text box, which
is not an interrupt and not a state the operator asked for. The latch
already covers those sessions by denying whatever they try next.

### Deep links

`claude-cli://` is a custom URL scheme Claude Code registers with the OS.
Opening one launches a new terminal session with a prompt sitting inert in
the input box — nothing executes until it's read and Enter is pressed.
Because a spawned session gets a normal `ITERM_SESSION_ID`, it fires the
usual hooks and shows up in Row 1 automatically, with no integration code.

Wired to Stream Deck's built-in *Website* action — no plugin code needed,
since a static-image key is configuration, not software. Not bound to a
particular row today: a future DISPATCH key (Row 4, not built) would
generate these programmatically from an issue queue, but a hand-configured
one is a standalone, general-purpose capability. GitHub strips the
`claude-cli:` scheme from rendered Markdown, so the format is fenced here
rather than shown as a live link:

```
claude-cli://open?q=<url-encoded-prompt>&cwd=/absolute/path
```

`cwd` must be an absolute path. **Never build one of these from untrusted
input.** A patched RCE once smuggled a `--settings` flag through `q`,
carrying a hook that achieved arbitrary command execution. Deep links in
this project are hand-authored literals in `fleet.local.json` — never
templated from issue titles, CI output, branch names, or model output.

## Configuration

- [`config/fleet.json`](config/fleet.json) — committed, machine-agnostic:
  state colours and glyphs, label-shortening rules, timings.
- `config/fleet.local.json` — gitignored, machine-specific: pinned slots,
  the Obsidian vault path, and renderers. Copied from
  [`config/fleet.local.example.json`](config/fleet.local.example.json) by
  `install.sh` if it doesn't already exist.
- [`config/risk.json`](config/risk.json) — committed: the Row 3 tier rules.
  `config/risk.local.json`, gitignored, layers machine-specific rules on
  top, same pattern as `fleet.local.json`.

A pinned slot is declared in local config and is **never auto-assigned** —
so each pin permanently reduces fleet capacity by one agent.

### Verbs

A Row 2 key stages a verb against the selected agent. A verb is a markdown
file — frontmatter for the flags the dispatcher needs, body for the prompt
the agent receives — resolved by [`bin/fleet-verbs`](bin/fleet-verbs).
`$FLEET_HOME/verbs/<id>.md` wins over the shipped
[`config/verbs/<id>.md`](config/verbs) **per verb**, so overriding one
doesn't mean maintaining copies of the rest.

Getting it onto the deck is per-key, the same as Row 3: drag the `Command`
action onto each Row 2 key and pick its verb in the property inspector —
it also defaults to `(none)`.

Everything shipped in `config/verbs` is dependency-free: it assumes a shell,
a git checkout, and nothing else. Prompts that depend on a particular
machine's setup live in [`config/verb-overrides`](config/verb-overrides) —
git-tracked so they don't rot, but installed by hand because they can't be
right by default.

### NOTE and Obsidian

NOTE summarises the session and journals it. The shipped verb writes the
summary wherever it can and says so plainly when it can't journal at all —
losing the only copy is the one outcome worth designing against.

The recommended setup is a **dedicated flightdeck vault** reached over an
Obsidian MCP server. The reason is scoping, not taste: an MCP server pointed
at a general-purpose vault hands every agent in the fleet write access to
whatever else lives there. A vault that holds only flightdeck material makes
broad access to it unremarkable.

```sh
claude mcp add --scope user obsidian -- \
  npx -y obsidian-mcp serve --vault "flightdeck=/absolute/path/to/vault"
cp config/verb-overrides/note-obsidian.md ~/.fleet/verbs/note.md
```

User scope, because fleet agents run in whatever repo they were started in,
not in this one. The override names the vault by **id**, never by path — the
server holds the path, and `journal.vault` in local config records which
vault that is so the two can't drift apart unnoticed.

With no Obsidian server configured, the override refuses rather than
improvising a path on disk, and the shipped verb prints the summary to the
terminal instead. Neither one guesses at a vault.

### Renderers

`renderers` in local config lists absolute paths to executables. Each
receives the current fleet snapshot as JSON on stdin every time
`fleet-reconcile` runs, and each is bounded at a 1-second timeout — kept
under the 1.5-second budget all `SessionEnd` hooks share, since a renderer
sits on that path. A renderer that's missing, crashes, hangs, or times out
is logged and stepped over; none of them can break reconcile or delay the
deck. A renderer needing real work should dispatch it detached and return
immediately.

## Design decisions

**Hooks, not polling.** A key turns amber the instant `Notification` fires,
with none of the latency a poll loop would add. `PostToolUse` is
deliberately unused — it fires on every tool call, and the fleet must stay
invisible to the thing it's watching. `PreToolUse` *is* used — it's what
carries the halt clause and the `Resumed` guard, see *HALT* above — but
only through a pure-shell `test -e` per clause, paying for an interpreter
only on a real transition (a resume) or never at all (a latched halt
denies from shell alone). That is what keeps "stay invisible" true on this
hook rather than abandoning it.

**`bin/` is Python, not bash.** launchd's `PATH` is unset and resolves to
`/usr/bin:/bin:/usr/sbin:/sbin`, a different interpreter than an interactive
shell resolves — so `install.sh` pins an absolute interpreter path into
every shebang and the launchd plist. Separately, `subprocess.run(["git",
"-C", cwd, ...])` cannot word-split a path the way `git -C $CWD` can in
bash when `cwd` contains a space, which matters most in exactly the
highest-stakes script, `fleet-kill`.

**Slot assignment is sticky.** A session claims the lowest free non-pinned
slot on first sight and holds it until it dies; on death the slot goes
empty and nothing else moves. A key that shifts under your thumb is useless
even when the underlying data is perfectly correct.

## Testing

```
./tests/run.sh
```

Runs shellcheck over the shell bootstrap, a Python syntax gate over `bin/`,
and the bats suite — `./tests/run.sh` reports the current total and every
result. Coverage includes hook emission, slot reconciliation (stickiness,
reaping, overflow, pinned-slot exclusion), press dispatch and the
arm/confirm state machine, the settings merge, the teardown guard against
fixture worktrees (dirty, unpushed, clean — asserting only the clean one
is ever removed), `fleet-decide`'s pending/decision lifecycle, and the
halt guard.

`fleet-focus` requires a live iTerm2 and is verified by hand; it's isolated
in its own script for exactly that reason.

## Out of scope for v1

Row 4 (GATE, SPEND, DISPATCH) is not built. HALT — its fourth key in the
original design — ships today as a script (`bin/fleet-halt`, see above)
rather than a dedicated Stream Deck action: run it from a terminal until
Row 4's key exists. Rows 1 through 3 are built and running on real
hardware.
