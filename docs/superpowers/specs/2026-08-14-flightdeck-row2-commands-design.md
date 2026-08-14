# Flightdeck Row 2 — Commands

Design doc. Follows `2026-08-13-streamdeck-fleet-design.md`, which shipped Row 1
(fleet awareness) and deferred Row 2 with a one-line sketch. This settles what
Row 2 actually is.

## What changes

Row 1 made the deck an annunciator: it reads agent state and paints it. Row 2
makes the deck an actuator — eight keys that send work to a chosen agent.

That is a larger step than adding a row. It introduces three things Row 1 never
needed: a notion of *which* agent a press targets, a way to deliver text into a
running session, and a place for prompts to live that is neither code nor a
release.

## Decisions taken

Each of these was a real fork. Recorded with the reasoning, because the
alternatives are all defensible and a later reader will wonder.

### 1. A verb is a prompt to the agent, not a command flightdeck runs

Pressing TEST types "run the test suite" into the focused agent. Flightdeck does
not run `npm test` itself.

**Why:** the agent has the context. It knows what the test command is for this
repo, it can read the failure, and it can fix it. Flightdeck running the command
directly would need per-repo configuration of every command, and would leave the
agent unaware that anything happened.

**Cost, accepted:** flightdeck sees hook events, not exit codes, so it cannot
observe pass or fail. The prior spec's claim that "Row 2 is where `failed` gets
its real signal" does not survive this choice as written. See *The failed
signal* below for how it is recovered.

### 2. Focus is declared, not derived

The target is the slot whose Row 1 key you pressed most recently. It persists
until you press another one. It is not "whatever iTerm2 window is frontmost".

**Why:** the deck must be able to tell you where a command will land. A declared
target is always displayable — the Row 1 marker shows it even when you have
switched to a browser and no Claude session is frontmost at all. A derived
target is undefined in exactly that case, and would need polling to keep the
marker honest.

**Cost, accepted:** the selection can go stale relative to what you are looking
at. You can switch sessions by hand and the target will not follow.

### 3. Delivery is hardened iTerm2 automation, not the messaging socket

Text reaches the session through AppleScript, using the same UUID tree-walk
`bin/fleet-focus` already performs.

**Why:** the alternative was `/tmp/cc-socks/<pid>.sock`, the transport behind
Claude Code's session-to-session messages. It was probed during design. The
socket exists and accepts connections, but returned nothing to any of four probe
shapes — HTTP/1.1, bare newline, newline-delimited JSON, and a plain connect.
It is an opaque framed protocol that would have to be reverse-engineered out of
a minified bundle and would carry no stability guarantee across Claude Code
updates. There is also no supported CLI path: `claude agents` manages `--bg`
background agents, not running interactive sessions.

**Cost, accepted:** AppleScript delivery is fragile in specific, known ways. It
is made safe by guards rather than by hope — see *The sender*.

### 4. Verbs are markdown files, not code and not config strings

`config/verbs/<id>.md`, frontmatter plus prose.

**Why:** a good verb prompt is several paragraphs. Held in a JSON string it needs
`\n` escaping, which makes the most-tweaked thing in the system the most annoying
to edit. As markdown it diffs line-by-line and reads as what it is. Retuning a
verb, or adding one, is then editing a file — not a release.

## Non-goals

- Flightdeck does not parse agent output. It sends and it observes hook state.
- No text input from the deck. A verb's prompt is fixed at press time.
- Rows 3 and 4 remain out of scope.

## Architecture

### Selection state

Selection is operator state, not derived state, so it does not belong in
`slots.json` — `fleet-reconcile` regenerates that from `sessions/` and would
erase it.

- `~/.fleet/focus.json` holds the selected `session_id`.
- `bin/fleet-press` writes it on a Row 1 press, alongside the focus it already
  performs. One press both raises the terminal and declares the command target.
- `fleet-reconcile` reads it and stamps `focused: true` on the matching slot.
- The reaper clears it when the selected session dies, so a marker cannot
  outlive its session.

### Focus marker

A small white underline at the bottom of the focused Row 1 key. Explicitly not a
full border: the lifecycle colour owns the background because state is the
information, and selection must not compete with it. Selection is its own
visual channel.

### Row 2 keys

A second action type, `com.louisalexander.flightdeck.command`, carrying a `verb`
setting. Deep charcoal, white label, no saturation.

A press invokes `bin/fleet-send <verb>`, mirroring how a Row 1 press invokes
`bin/fleet-press`. The plugin stays a renderer and a dispatcher; it holds no
knowledge of what a verb means.

### Verb files

```markdown
---
id: doubt
label: DOUBT
interrupt: false
confirm: false
---
Stop and challenge the current approach before continuing.

Argue the strongest case *against* what we are doing right now:
- What assumption are we treating as settled that isn't?
- What's the simpler approach we dismissed too early?
- What breaks first when this meets reality?

If the approach survives, say so plainly and continue.
Don't manufacture objections to seem rigorous.
```

Shipped in `config/verbs/`, overridable per-verb in `~/.fleet/verbs/`, matching
the base-plus-local precedence `fleet.json`/`fleet.local.json` already uses.

- `interrupt: true` — not a prompt; an interrupt (STOP sends ESC).
- `confirm: true` — the verb arms on first press and fires only on a second
  press inside the arm window. Enforcement lives in `bin/fleet-send`, which
  reuses `fleetlib`'s existing atomic arm-claim (the `os.replace` on
  `armed.json` that `fleet-press` already relies on for destructive teardown),
  so two near-simultaneous presses cannot both fire. The arm is keyed by verb,
  not by slot.

### The sender: `bin/fleet-send <verb>`

Resolves selection to a session, then to its `iterm_session` UUID, then sends.
Three guards, each earned by an observed failure during design rather than
imagined:

1. **Address by UUID via tree-walk, never `window 1`.** A send addressed by
   window index was observed delivering into the wrong window. `fleet-focus`
   already has the correct script and the malformed-UUID rejection; reuse both.
2. **Refuse when the prompt box holds a draft.** Observed: injected text
   concatenates onto whatever the operator has half-typed. This is a
   correctness failure, not flakiness. Read the pane first; abort rather than
   corrupt.
3. **Confirm submission.** Observed: `write text` delivered the text but did not
   submit it; a separate Return was required. Verify the prompt actually
   cleared, and report failure rather than assuming success.

Unlike the hook scripts, `fleet-send` is not required to exit 0 — a press that
could not be delivered must say so.

### Feedback

A press resolves to sent, refused, or no-target, and the key flashes
accordingly. This matters more here than elsewhere: guard 2 means a press can
legitimately decline to act, and a key that silently does nothing is
indistinguishable from a broken one.

### The capability seam

A verb prompt may end by directing the agent to use a capability it already has.
Two kinds, one mechanism:

- **Sink scripts** — `bin/send-ntfy`, `bin/send-slack-message`, `bin/fleet-fail`.
- **MCP tools** — an Obsidian server, or anything else the session can reach.

Adding either needs no plugin change, no new action type, and no release: a
script (or a configured server) and a line in a verb file. This is the
extensibility path for Row 2 and should be treated as the intended way to grow
it.

Two properties follow from the prompt-to-agent model and must be designed for:

- **A prompt is a request, not a guarantee.** The agent may decline, or call the
  script twice. Sinks must be idempotent and safe to re-run.
- **Outward-facing sinks trip permission prompts**, turning the slot amber
  mid-verb. That is correct behaviour, not a bug, but it means pressing PUSH can
  leave an amber key waiting on approval.

## The verb set

| Key | id | Behaviour | Flags |
|---|---|---|---|
| TEST | `test` | Run the suite; report what fails. Ends by calling `bin/fleet-fail` on failure. | |
| DIFF | `diff` | Summarise what changed and why — not a raw diff dump, which the terminal already shows. | |
| LOG | `log` | Summarise the session so far and journal it. See *Obsidian*. | |
| COMMIT | `commit` | Commit. | `confirm` |
| PUSH | `push` | Commit and push. | `confirm` |
| PR | `pr` | Commit, push, open the PR. Branches first when on the default branch. | `confirm` |
| DOUBT | `doubt` | Challenge the current approach before continuing. | |
| STOP | `stop` | Interrupt the agent. | `interrupt` |

COMMIT / PUSH / PR are a deliberate ladder of increasing commitment, each a
superset of the last. The PR verb branches first when on the default branch,
matching the repo's own convention.

## The failed signal, recovered

Decision 1 means flightdeck cannot observe pass or fail. The capability seam
recovers it without code: the TEST verb's prompt ends by instructing the agent
to run `bin/fleet-fail <slot>` when the suite fails.

Failure therefore becomes something a verb *reports* — which is what the
original spec always wanted — and it is configuration rather than a release.
The honest caveat from the seam applies: this is a request to the agent, so
`failed` is best-effort, not guaranteed. `bin/fleet-fail` remains available
manually.

## Obsidian: recommended, not required

LOG journals the session. The prior spec's LOG almost certainly meant `git log`,
paired with DIFF; under the prompt-to-agent model that is a weak key, because
the terminal already shows it and it tells the operator nothing new.

**Recommended practice: a dedicated flightdeck vault, reached over MCP.**

The reason is scoping, not taste. A dedicated vault means the agent's MCP access
covers only flightdeck material. Pointing it at a general-purpose vault would
grant an agent write access to whatever else lives there — on the design
machine, the Journal folder's siblings included Recovery, Money, and Job Search.
A separate vault makes broad access to it unremarkable.

This is a convention, not a requirement:

- Shipped `config/verbs/log.md` stays dependency-free.
- The MCP flavour is a documented **override** at `~/.fleet/verbs/log.md`.
- With no Obsidian MCP server configured, LOG degrades to saying it cannot
  journal, rather than failing obscurely.

## Open decisions

- **DOUBT's label length** at 96px. `DOUBT` was chosen over `CHALLENGE` on fit.
  Confirm against the real renderer before the verb set is frozen.
- **STOP's mechanism.** ESC via AppleScript is assumed but unverified; confirm
  it interrupts a running turn rather than dismissing something else.
- **Flash vocabulary.** Sent / refused / no-target need three distinguishable
  brief states that do not read as lifecycle colour.

## Risks

- **Draft detection is inherently racy.** The operator can type between the read
  and the send. Mitigation is read, send, verify — and report on mismatch rather
  than assume. It narrows the window; it does not close it.
- **Sending to a busy agent.** A verb pressed mid-turn queues rather than
  interrupting. This is probably desirable but should be confirmed, and it is
  the reason STOP exists as a separate mechanism.
- **AppleScript automation permission** is already required by Row 1's focus
  verb, so no new consent surface — but a revoked permission now breaks sending
  as well as focusing, and the failure must be legible on the key.

## Testing

- **Pure functions** — verb file parsing, verb-to-prompt resolution, selection
  resolution, marker geometry — unit tested, following the existing split
  between bats and the node tests in `plugin/src/render.test.mjs`.
- **The guards** are the point of this feature and get the most coverage. The
  osascript layer is injected as a command runner so each guard is testable
  against fakes, following the stub-bin pattern already used in `tests/emit.bats`.
- **What cannot be faked** — that a real iTerm2 actually submits — gets a live
  check on real sessions, the way the hook chain was verified.

## First slice

Selection state, the focus marker, `fleet-send` with all three guards, feedback,
and one verb end-to-end: TEST. That exercises every part of the path. The
remaining seven verbs are then genuinely configuration.
