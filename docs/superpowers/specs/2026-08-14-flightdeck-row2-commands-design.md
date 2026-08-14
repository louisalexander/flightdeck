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

**On `failed`:** this is not a cost. Flightdeck learns the result because the
verb's prompt tells the agent to report it — see *The failed signal*. That is
the prior spec's intent word for word: "failure becomes something verification
actions *report*, never something the deck guesses."

Nor is reporting a weaker link than the rest of the chain. Under this decision
everything is agent-mediated: the tests run at all only because the prompt asked.
Treating "run the tests" as reliable while treating "report the result" as
best-effort would be incoherent — it is one instruction, in one prompt, to one
agent.

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

### 3. Delivery is a staged queue, drained by the hook flightdeck already owns

A press does not type a prompt. It **stages** the verb in
`~/.fleet/queue/<session_id>.json` with an atomic write. What happens next
depends on the session's state — which flightdeck already tracks, and which is
the one thing it has been doing since Row 1:

- **Working** — nothing else happens. When the turn ends, flightdeck's existing
  `Stop` hook drains the queue and returns
  `{"decision": "block", "reason": "<verb prompt>"}`. The agent continues into
  the verb. No keystrokes, no race, and the right semantics: the command runs
  after the current work finishes instead of colliding with it.
- **Idle** — no `Stop` will ever fire, so something must wake the session, and
  input is the only wake. AppleScript types a **single short line pointing at
  the queue file**. The verb's actual prompt never travels through AppleScript.

**Why not the messaging socket:** `/tmp/cc-socks/<pid>.sock`, the transport
behind Claude Code's session-to-session messages, was probed during design. It
exists and accepts connections but returned nothing to any of four probe shapes
— HTTP/1.1, bare newline, newline-delimited JSON, and a plain connect. It is an
opaque framed protocol that would have to be reverse-engineered out of a
minified bundle, with no stability guarantee across updates. There is also no
supported CLI path: `claude agents` manages `--bg` background agents, not
running interactive sessions.

**Why not type the prompt directly:** that was the previous form of this
decision, and staging is better in four ways. The fragile channel shrinks from
several paragraphs to roughly fifty characters. Its failure mode becomes benign
— a draft concatenating with a pointer produces something the agent queries or
ignores, rather than a mangled instruction it half-follows. Verbs pressed at an
awkward moment queue instead of being dropped. And the queue file becomes the
interface, so most of the path is testable without driving a real iTerm2.

**Verified, not assumed:** the `Stop` hook's `decision: "block"` with a `reason`
field is real — there are explicit code paths and operator-visible strings for
it ("Stop hook denied continuation", "Stop hook block discarded"), and the hook
payload carries `stop_hook_active` specifically to keep a blocking hook from
looping. Prompt injection via a `UserPromptSubmit` `additionalContext` field was
*considered and rejected*: the strings that appeared to support it belong to the
bundled AWS SDK, not to Claude Code's hook system. Nothing here depends on it.

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

A thin white border, inset, around the focused Row 1 key. Whatever agent you
most recently focused is the one a Row 2 press acts on, and that must be
unmistakable at a glance — you are about to send work to it.

**This reverses the v1 spec deliberately**, which called for "a small white
bottom marker or underline — not a full white border, which would compete with
the lifecycle background." That concern is real: the saturated fill carries
state, and selection must not read as a state change. It is answered by
restraint rather than by choosing a weaker affordance — the border stays thin
and inset so the lifecycle colour remains the dominant element of the key. An
underline is easy to miss on a glanced-at panel, and being wrong about which
agent you just sent a command to is expensive.

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
  reuses the atomic arm-claim *technique* `fleet-press` relies on for
  destructive teardown — the `os.replace` ownership rename — so two
  near-simultaneous presses cannot both fire.

  **On a separate file, not `armed.json`.** An earlier draft of this spec said
  to reuse that file directly. It must not: `armed.json` carries exactly one
  meaning, "slot N is armed for destructive teardown", and `fleet-press` fires
  `fleet-kill` off it. Sharing one file would let a verb arm and a teardown arm
  consume each other, and any convergence of their shapes would turn a Row 2
  press into a session teardown. Verb arms live in `armed-verb.json`.

  The arm is keyed by verb **and by target**. Arming ISSUE against one agent,
  changing the selection, then confirming would otherwise fire at whoever is
  selected now — a different repository than the operator was looking at when
  they decided.

  A confirm verb **may queue against a busy target, but only briefly.** The
  first form of this rule refused outright whenever the target was `working`
  or `blocked`. In use that refused at exactly the moment the verb was most
  wanted — while watching an agent hit the problem worth filing. The fear was
  never "at the end of this turn, while you are still sitting here"; it was
  "twenty minutes later, forgotten". So the entry is staged carrying an
  `expires_at` (`timings.confirmQueueSecs`, default 300s) and the `Stop` drain
  discards it if it has expired, which bounds that fear directly rather than
  by refusing.

  A busy target still does not skip the arm: the first press arms, and only
  the second stages. And a `blocked` session is staged but never woken, so a
  permission dialog is never typed into.

  Plain verbs carry no expiry. They are not outward-facing, so a late delivery
  costs nothing and waiting indefinitely is friendlier; a general TTL for every
  verb remains an open decision.

  `fleet-send` therefore reports three outcomes, not two: `0` delivered, `1`
  refused, `2` armed. The deck needs the distinction — painting an armed key
  as refused would tell the operator the press failed at the moment it is
  waiting on them to confirm.

### The sender: `bin/fleet-send <verb>`

Resolves selection to a session, resolves the verb to its prompt, and stages it:

```json
{ "verb": "test", "prompt": "...", "queued_at": 1786700000 }
```

Written atomically to `~/.fleet/queue/<session_id>.json`, the same
write-temp-then-`os.replace` pattern the rest of the repo uses. Then it acts on
the session's state:

- **Working** — done. The `Stop` drain will pick it up.
- **Idle** — wake the session (see below).
- **No selection, or the selected session is gone** — refuse and report.

Unlike the hook scripts, `fleet-send` is not required to exit 0. A press that
could not be staged must say so.

### The `Stop` drain

Flightdeck's `Stop` hook gains one responsibility: if a queued verb exists for
this session, remove it and return
`{"decision": "block", "reason": "<verb prompt>"}`.

Two properties are load-bearing:

- **Drain before returning.** Delete the queue entry *first*, then emit the
  block. Returning the block while the entry still exists re-fires the same verb
  on the next `Stop`, forever. `stop_hook_active` in the payload is a backstop
  against runaway loops, but correctness must not lean on it.
- **The empty case must be nearly free.** This now sits on the latency path of
  every turn end, for every session. It gets the same treatment as the
  `PreToolUse` guard: a file-existence check that costs nothing when there is no
  queued verb, and pays for a full interpreter only on a real transition.

### Waking an idle session

The only case that touches AppleScript. It types one short line pointing at the
queue file — never the verb prompt itself. Two guards, each earned by a failure
observed during design rather than imagined:

1. **Address by UUID via tree-walk, never `window 1`.** A send addressed by
   window index was observed delivering into the wrong window. `fleet-focus`
   already has the correct script and the malformed-UUID rejection; reuse both.
2. **Confirm submission.** Observed: `write text` delivered text but did not
   submit it; a separate Return was required. Verify the prompt actually
   cleared, and report failure rather than assuming success.

The draft guard from the previous design is no longer a correctness
requirement, because staging removed what made a draft dangerous: concatenating
a pointer onto half-typed text yields something the agent will question or
ignore, not a corrupted instruction it partially obeys. Refusing on a visible
draft is still worth doing — typing over someone's half-written thought is rude
— but it is now politeness, not safety, and it must not block the verb.

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

- **Sinks must be idempotent.** Not because the agent is unreliable, but because
  a verb can be pressed twice, a turn can be retried, and an agent may
  reasonably call a script again after an error. Safe to re-run is the contract.
- **Sinks should explain themselves.** A `--explain` mode lets a verb prompt
  point at the convention instead of restating it, which keeps prompts short and
  keeps them working when the convention changes.
- **Outward-facing sinks trip permission prompts**, turning the slot amber
  mid-verb. That is correct behaviour, not a bug, but it means pressing PUSH can
  leave an amber key waiting on approval.

## The verb set

| Key | id | Behaviour | Flags |
|---|---|---|---|
| TEST | `test` | Run the suite; report what fails. Ends by calling `bin/fleet-fail` on failure. | |
| DIFF | `diff` | Summarise what changed and why — not a raw diff dump, which the terminal already shows. | |
| NOTE | `note` | Summarise the session so far and journal it. See *Obsidian*. | |
| ISSUE | `issue` | File the live problem, open question, or noticed-and-not-chased tangent as a GitHub issue, so it survives the session. | `confirm` |
| PUSH | `push` | Commit and push. | `confirm` |
| PR | `pr` | Commit, push, open the PR. Branches first when on the default branch. | `confirm` |
| DOUBT | `doubt` | Challenge the current approach before continuing. | |
| STOP | `stop` | Interrupt the agent. | `interrupt` |

PUSH / PR are a ladder of increasing commitment, each a superset of the last.
The PR verb branches first when on the default branch, matching the repo's own
convention.

**COMMIT exists but is not on the panel.** It ships as `config/verbs/commit.md`
so it can be swapped in without writing anything new. Its slot went to ISSUE,
which earns the key better: PUSH already commits before pushing, so the deck
does not lose the ability to commit — only the ability to commit *without*
pushing. That is a real loss and a deliberate one, and swapping COMMIT back in
is editing one setting, not shipping a change.

**ISSUE is `confirm: true`** for the same reason PUSH and PR are: it writes to a
shared repository where other people will see it. Filing a stray issue is
cheaper to undo than a stray push, but it is still an outward-facing action and
should fire while the operator is watching.

ISSUE pairs with DOUBT rather than duplicating it. DOUBT questions the approach
in the session; ISSUE takes the thing that came out of it — the tangent nobody
is going to chase today, the design question with no answer yet — and puts it
somewhere that outlives the session. A fleet of agents generates exactly this
kind of debris, and the operator's usual choice is between derailing to chase it
and losing it entirely.

## The failed signal

This is where `failed` gets its real signal, exactly as the v1 spec promised.
The TEST verb's prompt ends by instructing the agent to run `bin/fleet-fail`
when the suite fails. Failure is something a verb *reports*, never something the
deck guesses — and it is configuration rather than a release.

A verb prompt is not limited to naming a script. It can carry its own fallbacks
and teach the convention it depends on:

> If the tests fail, run `bin/fleet-fail`.
> If you are unsure what that does or how flightdeck expects it to be called,
> run `bin/fleet-fail --explain` and follow what it tells you.

This matters more than it first appears. A prompt that assumes the agent already
knows a local convention is brittle across repos and across model versions; one
that points at a script which explains the convention is self-repairing. Sink
scripts should therefore ship with a `--explain` mode, and verb prompts should
use it rather than embedding assumptions about what the agent knows.

`bin/fleet-fail` remains available manually, as it is today.

## Obsidian: recommended, not required

NOTE journals the session. The prior spec called this key LOG, which almost
certainly meant `git log`, paired with DIFF; under the prompt-to-agent model
that is a weak key, because the terminal already shows it and it tells the
operator nothing new.

**Renamed LOG to NOTE deliberately.** Keeping the old label while changing the
meaning would have left the panel with a key that reads as `git log` and does
something else entirely — the worst of both, and a mistake an operator makes
once per press. The name now says what the key does.

**Recommended practice: a dedicated flightdeck vault, reached over MCP.**

The reason is scoping, not taste. A dedicated vault means the agent's MCP access
covers only flightdeck material. Pointing it at a general-purpose vault would
grant an agent write access to whatever else lives there — on the design
machine, the Journal folder's siblings included Recovery, Money, and Job Search.
A separate vault makes broad access to it unremarkable.

This is a convention, not a requirement:

- Shipped `config/verbs/note.md` stays dependency-free.
- The MCP flavour is a documented **override** at `~/.fleet/verbs/note.md`.
- With no Obsidian MCP server configured, NOTE degrades to saying it cannot
  journal, rather than failing obscurely.

## Open decisions

- **DOUBT's label length** at 96px. `DOUBT` was chosen over `CHALLENGE` on fit.
  Confirm against the real renderer before the verb set is frozen.
- **STOP's mechanism.** ESC via AppleScript is assumed but unverified; confirm
  it interrupts a running turn rather than dismissing something else.
- **Flash vocabulary.** Queued / delivered / refused / no-target need
  distinguishable brief states that do not read as lifecycle colour. Note that
  *queued* and *delivered* are now genuinely different moments — a verb staged
  against a working session may not run for minutes — and the deck should
  probably say so rather than claim success at press time.
- **Queue depth.** Whether a second press of the same verb replaces the queued
  entry, queues behind it, or is refused. Replacing is probably right for TEST
  and clearly wrong for DOUBT.
- **Stale queue policy.** How old a queued verb may get before it is dropped,
  and what the operator sees when that happens.

## Risks

### A verb queued against a session that never stops again

The operator walks away mid-turn, or the agent blocks on a permission prompt
nobody answers. The entry sits until the turn eventually ends — possibly the
next morning — and then fires. Four layers, in order of how much they buy:

1. **`confirm: true` verbs never queue.** COMMIT, PUSH and PR require an idle
   session or refuse outright. An outward-facing action must fire while the
   operator is watching, not twenty minutes later from a queue they have
   forgotten. This removes the harmful half of the risk rather than managing it.
2. **Pending is visible.** The Row 2 key and the target Row 1 slot both show
   that a verb is waiting. Invisibility is what makes staleness dangerous, not
   duration — a verb you can see waiting is a verb you can cancel.
3. **Pressing a queued verb again cancels it.** The cheapest possible escape
   hatch, and it composes with the queue-depth decision below.
4. **A TTL, with visible expiry.** `queued_at` is already in the entry; the
   drain discards anything older than a configurable window. The default should
   be generous, because long agent turns are legitimate and a verb dropped for
   being patient is worse than one delivered late. Expiry must surface on the
   key — silent eviction is the failure this is meant to prevent, arriving by a
   different route.

`SessionEnd` clears any queue for that session, alongside the focus and marker
clearing it already does.

### The claim race between waking and draining

`fleet-send` judges the session idle and wakes it with a pointer; the session
was in fact just finishing, `Stop` fires, and the drain delivers the same verb.
Or the reverse: the drain wins, and the pointer then names a file that no longer
exists, leaving the agent to puzzle over a missing path.

**Claim before acting, never act then claim.** Both paths take the entry with
the same atomic `os.replace()` to a per-pid sibling that `fleet-press`'s
`claim_arm()` already uses for arming — a successful rename is sole ownership,
and the loser gets `FileNotFoundError` and must behave as though there were
nothing to deliver. For the wake path this means claiming *first* and then
typing a pointer to the claimed path, so a pointer is only ever typed for an
entry that is already owned. Exactly one delivery, and no dangling pointer.

Sink idempotency is the backstop underneath, not the mechanism.

### `Stop` hook latency — smaller than it first appears

This risk was overstated when first recorded. `fleet-emit Stop` **already runs
on every turn end** — `Stop` maps to `done` in `EVENT_STATES`, so the
interpreter is already being paid for on that path. The drain is a
file-existence check inside a process that runs regardless. It needs no new hook
entry and no `PreToolUse`-style shell guard.

The real constraint is output discipline, not cost. The hook must print nothing
at all on the ordinary path, and emit JSON only when it genuinely blocks —
stray output on a hook that runs for every turn of every session is a much
better way to break Claude Code than a few milliseconds of CPU. Blocking is
expressed in stdout JSON with exit 0, which preserves `fleet-emit`'s existing
"MUST ALWAYS EXIT 0" contract.
### Smaller risks

- **AppleScript automation permission** is already required by Row 1's focus
  verb, so no new consent surface — but a revoked permission breaks waking an
  idle session, and the failure must be legible on the key rather than silent.
- **Blocking a `Stop` makes an agent continue on its own.** To an operator
  watching the terminal this looks like the agent deciding to keep working. The
  verb prompt should make its origin obvious in the first line.

## Testing

The staged queue is what makes this testable: the file is the interface, so
almost everything can be exercised without driving a real terminal.

- **Pure functions** — verb file parsing, verb-to-prompt resolution, selection
  resolution, marker geometry — unit tested, following the existing split
  between bats and the node tests in `plugin/src/render.test.mjs`.
- **Staging and draining** are plain file operations and get the bulk of the
  coverage: a queued verb blocks the `Stop` with the right reason; the entry is
  removed before the block is emitted; a second `Stop` does not re-fire it; no
  queued verb produces no block and no interpreter startup; two claimants get
  exactly one delivery.
- **The wake path** keeps its guards, with the osascript layer injected as a
  command runner so each is testable against fakes, following the stub-bin
  pattern already used in `tests/emit.bats`.
- **What cannot be faked** — that a real iTerm2 submits, and that a real agent
  continues from a blocked `Stop` — gets a live check on real sessions, the way
  the hook chain was verified.

## First slice

The queue is the core, so it goes first and the terminal automation goes last:

1. **Selection state and the focus marker** — `~/.fleet/focus.json`, written on
   a Row 1 press, rendered as the inset border. Independently useful: it makes
   the deck show which agent you are working on, before any verb exists.
2. **Verb files and resolution** — parse `config/verbs/*.md`, apply the
   `~/.fleet/verbs/` override, resolve a verb to its prompt. Pure, fully tested.
3. **Stage and drain** — `bin/fleet-send` writes the queue entry; the `Stop`
   hook claims and drains it into a block. This is the whole mechanism, and it
   is testable end-to-end without a terminal or a Stream Deck.
4. **The Row 2 key and feedback** — the action type, monochrome render, flash.
5. **Waking an idle session** — the AppleScript pointer and its two guards. Last
   because it is the only part that needs a real iTerm2, and by this point
   everything it delivers has already been proven.

One verb end-to-end: TEST. The remaining seven are then genuinely configuration.

Steps 1–3 are worth landing before the deck can press anything, because a
queued verb can be staged by hand — `bin/fleet-send test` from a terminal — and
observed to arrive. The keypress is the last thing that needs to work, not the
first.
