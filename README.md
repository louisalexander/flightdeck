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

This is v1: Row 1 only. It is installed and running on real hardware.

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

The plugin is deliberately dumb: it watches one JSON file, paints colour and
label, and on press shells out to a script. It ships exactly one action
type, `Fleet Slot`, parameterised by a slot index. Every rule that's likely
to change — what counts as blocked, how slots get assigned, what teardown
means, how a host gets focused — lives in Python scripts under `bin/` that
you edit and run directly from a terminal. Nothing there requires rebuilding
or reinstalling the plugin.

Writes are event-driven, cleanup is polled: a hook fires on a real state
transition, so a key turns amber the instant an agent blocks, with no
polling latency. The 15-second launchd tick (`bin/fleet-reap`) exists only
to catch crashed sessions whose `SessionEnd` never ran.

## Quickstart

```
./install.sh
./bin/fleet-doctor
```

`install.sh` pins the Python interpreter, merges the five hooks into
`~/.claude/settings.json`, loads the launchd reaper, and builds and links
the plugin into Stream Deck. `fleet-doctor` then verifies every moving part
— interpreter, hooks, reaper, plugin, Stream Deck running, and iTerm2
automation permission, the classic silent killer macOS denies with no
dialog.

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

## Row 3: deep links

`claude-cli://` is a custom URL scheme Claude Code registers with the OS.
Opening one launches a new terminal session with a prompt sitting inert in
the input box — nothing executes until it's read and Enter is pressed.
Because a spawned session gets a normal `ITERM_SESSION_ID`, it fires the
usual hooks and shows up in Row 1 automatically, with no integration code.

All of Row 3 is just this URL wired to Stream Deck's built-in *Website*
action — no plugin code needed, since a static-image row is configuration,
not software. GitHub strips the `claude-cli:` scheme from rendered
Markdown, so the format is fenced here rather than shown as a live link:

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

A pinned slot is declared in local config and is **never auto-assigned** —
so each pin permanently reduces fleet capacity by one agent.

### Verbs

A Row 2 key stages a verb against the selected agent. A verb is a markdown
file — frontmatter for the flags the dispatcher needs, body for the prompt
the agent receives — resolved by [`bin/fleet-verbs`](bin/fleet-verbs).
`$FLEET_HOME/verbs/<id>.md` wins over the shipped
[`config/verbs/<id>.md`](config/verbs) **per verb**, so overriding one
doesn't mean maintaining copies of the rest.

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
with none of the latency a poll loop would add. `PreToolUse` and
`PostToolUse` are deliberately unused — they fire on every tool call, and
the fleet must stay invisible to the thing it's watching.

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
and the bats suite. Currently 97 bats tests, all passing — covering hook
emission, slot reconciliation (stickiness, reaping, overflow, pinned-slot
exclusion), press dispatch and the arm/confirm state machine, the settings
merge, and the teardown guard against fixture worktrees (dirty, unpushed,
clean — asserting only the clean one is ever removed).

`fleet-focus` requires a live iTerm2 and is verified by hand; it's isolated
in its own script for exactly that reason.

## Out of scope for v1

Rows 2 (per-session commands), and 4 (system) are not built. Row 3 needs no
plugin code, as above, and is configured by hand in the Elgato app once Row
1 works.
