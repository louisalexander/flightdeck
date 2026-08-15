# Flightdeck Rows 3 and 4 — Verdict and Governance

**Date:** 2026-08-15
**Status:** Approved design, ready for implementation planning
**Follows:** `2026-08-13-streamdeck-fleet-design.md` (Row 1), `2026-08-14-flightdeck-row2-commands-design.md` (Row 2)

## What changes

Row 1 made the deck an annunciator: it reads fleet state and paints it. Row 2 made it an
actuator: it sends work to a chosen agent. Rows 3 and 4 make it an **authority** — it answers
the question an agent is blocked on, and it sets what the fleet is allowed to do at all.

The two rows are designed together because they share machinery. Both ride the permission
system, both consume the same risk classification, and Row 4's halt is the far end of the same
axis Row 3's per-request denial sits on. Splitting them would have meant writing the risk table
twice.

## Empirical basis

Everything structural here was verified against Claude Code v2.1.233 on 2026-08-14 rather than
assumed. The full contract, with payloads, is in `docs/hook-contract.md` under
"Permission-decision events". The five results this design rests on:

1. **`PermissionRequest` fires only when a human would actually be asked.** It never fires in
   headless mode, where permission is silently declined. There is no spam to filter.
2. **Its payload carries `tool_name`, the full `tool_input`, and `permission_suggestions`** —
   Claude Code's own proposal for a scoped rule that would stop the prompt recurring.
3. **The hook may block, and the session waits.** A hook that slept six seconds and returned
   `allow` caused the tool to execute with no human input.
4. **Exceeding the hook's `timeout` falls through to the human dialog.** The hook process is
   killed, nothing is printed, and the ordinary prompt stays answerable.
5. **`PreToolUse` gates every tool call in every permission mode**, including
   `bypassPermissions` and `--dangerously-skip-permissions`. Claude Code says so in its own
   strings and it was confirmed live, twice.

The output schema is **not** the documented `PreToolUse` one — `permissionDecision` is silently
ignored on this event. Two probes were lost to that before the real shape was read out of the
bundle:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest",
  "decision":{"behavior":"allow","updatedInput":{},"updatedPermissions":[]}}}

{"hookSpecificOutput":{"hookEventName":"PermissionRequest",
  "decision":{"behavior":"deny","message":"...","interrupt":true}}}
```

## Decisions taken

### 1. The deciding hook blocks, and that is allowed exactly here

`bin/fleet-decide` sits on `PermissionRequest` and does not return until the deck answers or
the hook times out. Every other flightdeck hook must exit in milliseconds; this one may sit
for two minutes.

**Why this does not contradict "the fleet must stay invisible to the thing it is watching":**
the rule that matters is about *added* latency, and this hook only ever runs when the agent is
already waiting on a human. It adds nothing to a session that is by definition stopped. Stated
as a rule for the next reader: **the only hook that may block is one that fires when the agent
is already blocked.**

Three properties make it safe to build on, all of them measured rather than hoped for:

- **Every failure degrades to today's behaviour.** Deck unplugged, plugin crashed,
  `fleet-decide` throwing, operator walking away — all of them end in the hook emitting
  nothing, and the ordinary permission dialog is still on screen and still answerable. The
  feature cannot make things worse than not having it.
- **The dialog races the hook, and whoever answers first wins.** The prompt is on screen the
  whole time the hook deliberates. Answering in the terminal while the deck is still waiting is
  fine: Claude Code discards the hook's late decision through its own orphaned-permission path.
  The deck is therefore strictly an *additional* input channel. There is no state in which
  using flightdeck takes your own terminal away from you.
- **Hooks tighten and never loosen.** A hook `allow` remains subject to deny rules.

Because timeout is a safe fall-through, it can be generous: `timings.decideTimeoutSecs`,
default 120. The only cost of a long one is a sleeping Python process per blocked agent.

**Rejected — the deck types into the dialog.** This would have reused Row 2's AppleScript wake
path and required no blocking. It is wrong on evidence: the observed dialog read
`1. Yes / 2. Yes, and don't ask again for example.com / 3. No, and tell Claude what to do
differently`, and option 2 exists only for tools that support a scoped rule. **The option
numbering shifts with the tool**, so sending `2` would approve-and-remember on one call and
decline on another. It also throws away `updatedPermissions`, which is the whole value of the
REMEMBER key.

**Rejected — a socket or FIFO.** Lower latency than polling, at the price of a daemon in a
project whose only background process is a fifteen-second launchd tick. The latency saved is
invisible next to a human thumb.

### 2. Targeting is automatic, with selection as the override

The target is **the selected session if it has a pending decision, otherwise the oldest pending
decision.** Nothing else.

**Why not a triage queue head with a cycle key**, as the originating sketch had it: that spends
two of eight keys on targeting, and it gives key 1 a meaning that changes as the queue changes
— which is the exact failure Row 1's design forbids ("a key that shifts under your thumb is
useless even when the underlying data is correct"). It also introduces a second selection
channel alongside `focus.json`, which Rows 2 already depends on.

**Why not selection alone**, matching Row 2 exactly: every approval would need a Row 1 press
first, and a Row 1 press focuses the terminal — the context switch the row exists to avoid.

Automatic targeting resolves the common case, one amber key, with no targeting press at all.
Disambiguation, when several are amber, is a Row 1 press, which you were going to have to make
anyway to know which is which.

**Accepted cost:** a stale selection pointing at a blocked agent will win over an older pending
request. This is deliberate. Predictability beats correctness-by-recency on a device read
peripherally, and a selection pointing at a blocked agent is not a wrong answer — that agent
does genuinely need deciding.

### 3. Risk tier comes from a rule table, not a model

`config/risk.json` maps patterns to `low`, `normal` and `high`; unmatched is `normal`. It is
edited the way verbs are, diffs line by line, and is unit-testable against fixtures.

**What makes this safe despite being incomplete:** a tier can only ever *add* friction on top
of a prompt the human is already being shown. It never removes a prompt and never grants
anything. A pattern you have not written down degrades to today's behaviour, not to an
unguarded action.

**Rejected — an LLM `prompt` hook.** Claude Code supports `type: "prompt"` and `type: "agent"`
hooks on this event, so a classifier could have been written with no code at all, and the
latency would have been free because the session is already blocked. Rejected because the tier
gates the arm/confirm guard: a non-deterministic classifier means the same command sometimes
arms and sometimes does not, and a guard you cannot predict is a guard you stop trusting. It
also cannot be tested against fixtures, which is where the rest of this repo's confidence comes
from.

### 4. HALT denies everywhere, and interrupts only where interrupting means interrupting

The latch is fleet-wide and un-bypassable. The interrupt is sent **only to sessions Row 1
already knows are `working`**.

**Why not interrupt everything:** ESC into a session showing a permission prompt is not an
interrupt. It selects "No, and tell Claude what to do differently" and opens a text box. A
blanket ESC would leave sessions in a state the operator did not choose and is not looking at.
Blocked sessions need no interrupt anyway — the deny already covers them.

This is the first design decision to consume Row 1's state model as an input rather than
produce it, and it is worth noticing: the lifecycle state exists, so the safe version costs one
condition.

**A deny is not a pause, and the claim must not overreach.** The model receives a denial and
reasons about it; it is free to retry or route around. Both probe runs did produce stop-and-wait
behaviour from the wording used, but that is a model complying with a sentence. What HALT
guarantees is that nothing an agent does can reach the machine. What it does not guarantee is
that the agent stops thinking, or stops spending. Anything written on a key, in a README, or on
a landing page must say the first and not imply the second.

### 5. Dispatch is `fleet-spawn`-backed, not a deep link

`bin/fleet-dispatch <template-id>` resolves the selected session to its `cwd`, reads the
template's issue filter from local config, asks `gh` for the oldest matching open issue, and
calls `bin/fleet-spawn <number>` with that working directory.

**Why not `claude-cli://` deep links,** which the v1 spec established need no code at all: a
deep link can only point at a directory that already exists, so it cannot create a worktree.
It is not idempotent — press twice, get two agents on the same job — and it cannot decline to
create a ninth session that the deck has no room to display. Its prompt also lands inert and
needs an Enter keystroke in a window that has just appeared, so it is not really one press.

Deep links remain the right tool for "open a terminal here with a prompt already typed" and are
configured by hand on the built-in Website action. They are simply not what Row 4's back half
should be.

**`fleet-spawn` is not modified.** Its argument surface stays at exactly one — *"an argument is
a channel and the whole security argument for this script is that there is exactly one"* — and
it still reads repo and base branch from its working directory. `fleet-dispatch` sets that
directory and passes an integer that `gh` produced. Nothing templated from an issue title,
branch name, or model output ever reaches it.

## Architecture

```
PermissionRequest ──► bin/fleet-decide ──► ~/.fleet/pending/<session>.json
                            │                        │
                            │ poll 150ms             │ fs.watch
                            ▼                        ▼
                  ~/.fleet/decisions/<session>.json   Row 3 renders DETAIL
                            ▲
                            │  bin/fleet-verdict <action>
                            │
PreToolUse ──► shell guard ─┴─► $FLEET_HOME/halt   ──► bin/fleet-halt
                                $FLEET_HOME/posture
```

### `bin/fleet-decide` — the deciding hook

On each firing:

1. read `tool_name`, `tool_input` and `permission_suggestions` from the payload;
2. score the tier against `config/risk.json`;
3. hash `(session_id, tool_name, tool_input)`. If a pending record already carries that hash,
   **increment its `repeats` and reuse it** rather than creating a second record;
4. otherwise write `~/.fleet/pending/<session_id>.json` atomically;
5. flip the slot to `blocked` immediately;
6. poll `~/.fleet/decisions/<session_id>.json` every 150ms;
7. on a decision, claim it with `os.replace`, emit the JSON, clear the pending record;
8. on timeout, emit nothing and clear the pending record.

Step 5 is a latency improvement to the shipped product, not only to this feature.
`PermissionRequest` fires at t≈0 where `Notification/permission_prompt` is debounced to t≈6.0s
— measured at 6.01, 6.02 and 6.03 seconds across three runs. Amber currently arrives about six
seconds later than the information is available. `PermissionRequest` is *narrower* than
`Notification`, being tool-permission-only, so this is an addition to the blocked signal and
never a replacement for it.

Step 3 exists because **a denied agent is free to retry immediately.** It re-issues the call, a
new request fires, and one press produces another prompt indefinitely. Steer prose should
forbid retrying, but that is model compliance and must not be the only defence. Counting
repeats turns a silent loop into `×3` on the DETAIL key — the same argument the Row 2 spec made
for making a stale queued verb visible rather than trying to prevent it.

The pending record:

```json
{ "session_id": "...", "tool": "Bash", "input_digest": "sha256:...",
  "input_summary": "git push --force origin main", "tier": "high",
  "suggestion": { "type": "addRules", "destination": "localSettings",
                  "rules": [{"toolName": "Bash", "ruleContent": "git push:*"}],
                  "behavior": "allow" },
  "repo": "flightdeck", "repeats": 1, "requested_at": 1786700000 }
```

`input_summary` is held for the terminal and the log, never rendered whole on a key. See
*Rendering*.

### `bin/fleet-verdict <action>` — the sender

Mirrors `fleet-send`'s contract exactly, including its three-way exit status: `0` delivered,
`1` refused, `2` armed. The deck needs the third, because painting an armed key as refused
would report failure at the moment the system is waiting on the operator.

It refuses when no pending record exists, which is also how a timed-out request reports itself,
since `fleet-decide` clears pending on the way out. A decision written into the gap between
that check and the write is harmless: a stale decision file with no waiter, which the reaper
clears alongside its existing work.

Arming reuses `fleet-send`'s `os.replace` ownership rename and its `armed-verb.json`
convention — **not** `armed.json`, which carries exactly one meaning, "slot N is armed for
destructive teardown", and which `fleet-press` fires `fleet-kill` off. The Row 2 spec records
why that separation is load-bearing; the same reasoning applies unchanged here.

### Row 3 — the verdict row

| Key | Action | Emits | Arms |
|---|---|---|---|
| 1 | DETAIL | — (press focuses the session) | — |
| 2 | APPROVE | `{"behavior":"allow"}` | when tier is `high` |
| 3 | REMEMBER | allow + `updatedPermissions` | always |
| 4 | DENY | `{"behavior":"deny","message":…}` | — |
| 5 | STEER — `justify` | deny, message from the verb | — |
| 6 | INTERRUPT | deny + `"interrupt":true` | — |
| 7 | STEER — `otherway` | deny, message from the verb | — |
| 8 | *(unbound)* | | |

One action type, `com.louisalexander.flightdeck.verdict`, carrying a `verdict` setting and — for
steers — a `verb` setting, mirroring how Row 2's command action carries a verb. The plugin
stays a renderer and a dispatcher and holds no knowledge of what a verdict means.

**DETAIL's press is the anti-blind-approval escape hatch.** The deck tells you tool and tier;
when that is not enough, one press puts the full text in front of you. That is what makes it
honest to keep the input off the key face.

**REMEMBER always arms, and never invents a rule.** It emits `permission_suggestions` verbatim.
If the payload carries none, the key refuses rather than synthesising one. It arms regardless
of tier because of what the probe found about where the rule lands — see *The worktree trap*.

**STEER and INTERRUPT are the same mechanism one flag apart.** `interrupt: true` is "stop", its
absence is "keep going, differently". Recorded because it makes the row coherent rather than a
list of eight unrelated things.

### The worktree trap

`updatedPermissions` persists — but a session running in a linked worktree writes
`localSettings` to the **canonical repo root**, not the worktree. A probe with `cwd` inside
`.claude/worktrees/rows-3-4` created no `.claude/` there at all; the rule landed in
`<repo-root>/.claude/settings.local.json`. Claude Code does this deliberately, reasoning that a
per-worktree copy "would become a stale, revocation-resurrecting legacy overlay".

For a worktree-based fleet the consequence is a safety property, not a detail: **remembering a
permission for one agent widens permissions for every agent in every worktree of that
repository, including ones that do not exist yet.**

Therefore the armed face of REMEMBER names **the repository and the rule**, not the agent:

```
flightdeck
Bash(git push:*)
CONFIRM?
```

The agent is the one thing this press is not scoped to, so it is the one thing that must not
appear on the confirmation.

### Steer verbs

Steers reuse `config/verbs/` for the editing story, with a new `steer: true` frontmatter flag
alongside `interrupt` and `confirm`. `fleet-verbs` refuses a non-steer verb on a steer key.

**Why a flag rather than reusing any verb:** verb bodies are written as instructions to an
agent picking up a task; a deny message is read as the reason a tool call was refused. Binding
PUSH to a steer key would deny a call with "Commit and push" as its justification, which is
nonsense. The existing "REACHABLE: every shipped verb appears in the property inspector" test
was written to catch this class of mistake.

Three ship; two are bound:

| id | Says |
|---|---|
| `justify` | Don't do this yet. Explain what it does and why you need it, and wait. |
| `otherway` | Achieve this without that command. |
| `dryrun` | Do the read-only version first and show me the result. |

`dryrun` ships unbound, the same call the Row 2 spec made for COMMIT — available by editing one
setting rather than shipping a change.

**`deny.message` is the only synchronous prompt channel in the product.** Row 2's staged queue,
`Stop` drain and AppleScript wake all exist because there was no way to get text into a running
agent. This one arrives inside the tool call, at the moment the agent is asking, attached to the
specific call it is about — no queue, no waiting for a turn to end, no keystrokes.

### Row 4 — the governance row

| Key | Action |
|---|---|
| 1 | HALT — fleet-wide deny latch, plus ESC to `working` sessions |
| 2 | SPEND — fleet total; press overlays Row 1 for three seconds |
| 3 | POSTURE — NORMAL / STRICT |
| 4–8 | DISPATCH — `fleet-dispatch <template-id>` |

#### HALT

The latch is `$FLEET_HOME/halt`, and the gate folds into the `PreToolUse` entry that already
exists — the one carrying the `Resumed` shell guard. It costs one additional `stat` per tool
call, on a hook already paying for one.

**The halt path emits its deny from pure shell and never execs Python.** The payload is a fixed
string, so the guard is `test -e "$FLEET_HOME/halt" && { cat >/dev/null; printf '%s' '<deny
json>'; exit 0; }`, placed before the existing `Resumed` clause so it wins. The emergency brake
therefore has no dependency on flightdeck's pinned interpreter, its config parsing, or any of
its own code. That is the right property for the one control whose entire job is working when
things have gone wrong.

The key itself calls `bin/fleet-halt`, which writes the latch, then walks `slots.json` and
sends ESC to every session in state `working` through the keystroke path Row 2's STOP verb
already uses. Unlike the gate, this script is ordinary Python — it runs on a press, not on the
tool-call hot path, and it may exit non-zero, because a halt that did not happen must be
visible.

**Halting is a single press; un-halting arms.** An emergency brake that needs confirming is not
one. Resuming a halted fleet deserves the beat.

**Row 1 must show the halt.** "The fleet is stopped" is a fact about every agent, and if Row 1
keeps painting blue and green there is no way to know nothing can run. `slots.json` gains
`halted: true` and the plugin hatches every slot; the existing `fs.watch` already repaints on
it.

**Coverage is what the deck can see.** A session started before install fires no hooks, so it
has no session file, no slot, and no gate — it is invisible to the whole product. This cuts
cleanly: every slot on the panel *is* enrolled, by construction, so there is no partial-coverage
badge to render. The gap is off-panel agents. `fleet-reconcile` compares tracked sessions
against running `claude` processes and publishes `untracked: N`; `fleet-doctor` says so out
loud and the HALT key carries a small `+N` when it is non-zero. That is the difference between
"un-bypassable" being true and being a demo that fails once, in front of someone.

#### POSTURE

Two positions, held in `$FLEET_HOME/posture` as a single word. `NORMAL` adds nothing — the
file's absence means normal. `STRICT` denies `high`-tier calls fleet-wide, through the same
`PreToolUse` gate, before they ever raise a prompt — the "I am away from the desk" mode.

Unlike HALT, STRICT cannot be answered from shell: deciding whether *this* call is `high`
requires reading the tool input and scoring it against `config/risk.json`. So the guard stays
`test -e` cheap on the common path and execs the interpreter only when the posture file exists.
That is the same shape as the `Resumed` guard, and the reason HALT and POSTURE are separate
mechanisms rather than one dial with three positions.

**"Trusted" is not on the dial because it is unreachable.** Hooks tighten and never loosen, and
Claude Code enforces this in both directions. Offering a position that cannot do what its name
says would be worse than not offering it.

HALT is the far end of this same axis and is kept as its own key only because cycling to an
emergency stop is wrong.

**Posture does not set a default for dispatched sessions.** An earlier draft gave it that second
meaning. It is dropped: two meanings on one key contradicts "one semantic channel per property",
and whether a deep link can carry a permission mode is unverified.

#### SPEND

Per-session usage comes from `transcript_path`, which every hook payload already carries.

**Transcripts carry `usage` token counts and a model id, but no `costUSD`** — verified against a
real transcript. So the unit is a weighted token figure, with the weights in `fleet.json`:
`cache_read ×0.1`, `cache_creation ×1.25`, `input ×1`, `output ×5`. Ratios are far more stable
than prices, and the comparator the overlay needs is a ratio. An optional per-model rate in
local config converts to currency for anyone on metered billing; on a subscription a dollar
figure is notional and tokens are the resource that actually runs out.

**Rejected — OTel.** `claude_code.cost.usage` is real, is in USD, and is emitted by Claude Code
itself. Consuming it means enabling an exporter and running a collector: a metrics pipeline and
a daemon, in a repo whose discipline is stdlib Python with no third-party packages. It remains
the right answer for a multi-machine or team deployment and is deliberately left as the upgrade
path.

**Display is a time-share, not a ninth channel.** Row 1's channels are spoken for: background is
lifecycle state, glyph is its redundancy, inset border is selection, brightness is reserved for
seen-versus-unseen, and the two text lines are identity. Adding a gauge to eight keys would tax
the amber signal those keys exist to deliver. Instead, pressing SPEND writes `overlay.json`
with an `expires_at`; Row 1 renders consumption for three seconds and reverts. During the
overlay the row is not showing lifecycle state at all, so background is free to carry magnitude
with nothing to collide with. The mechanism is the arm-marker pattern the plugin already
watches and already expires.

**The cap warns and never acts.** At threshold the SPEND key goes amber. Auto-quarantine is
rejected: nothing destructive in this project fires without a thumb, and a cap that halts a
fleet mid-PR is exactly the accident the safety doctrine forbids.

#### DISPATCH

A template is `(label, issue filter)`. The repository comes from the current selection, so the
row follows you between repos instead of hard-coding five of them, and keys 4–8 differ by which
queue they pull from.

```json
{ "dispatch": [
  { "id": "ready", "label": "READY", "filter": "--label ready --state open" },
  { "id": "bug",   "label": "BUG",   "filter": "--label bug --state open" }
] }
```

`fleet-dispatch` refuses, before creating anything, when there is no selection, no matching
issue, or no free slot. The slot check matters: the v1 spec accepts that a ninth session is
invisible, and a dispatch key that cannot count would cheerfully create it. `fleet-spawn` is
already idempotent per issue, so a double press focuses the existing tab.

## Rendering

Rows 3 and 4 are **monochrome deep charcoal**, as Row 2 established, because Row 1 owns
saturated backgrounds and state is the information.

**Tier is not a colour.** A `high` tier shows the amber warning triangle — the glyph the armed
teardown already owns, which already means *you are one press from something serious*. Reusing
an established meaning on a different row beats inventing a fourth colour language, and it
cannot collide with lifecycle amber because Row 1 does not draw it.

**The input never appears whole on a key.** At 96px roughly eleven characters fit per line, and
`rm -rf ./build` and `rm -rf ./ build` truncate identically. DETAIL therefore carries agent
identity, tool name, tier and the repeat count — a classification, never a quotation. The full
text lives one press away, in the terminal.

**Armed presentation is the existing one**: near-black, large amber triangle, high-contrast
`CONFIRM?`. Not red — red is an observed failure, and an operator considering an approval has
not had one.

The verb-arm window is `timings.verbArmSecs` (10s), not `armMs` (3s). The Row 2 spec records
why: 3s was observed to be too tight to read `CONFIRM?` and decide within, and a re-arm is
visually identical to a first arm, so the operator cannot tell "too slow" from "not registered".

## Non-goals

- Flightdeck does not read the tool input to decide anything except a tier. It classifies; it
  does not interpret.
- No text input from the deck. A steer's prose is fixed at press time.
- No auto-approval. Nothing on these rows ever answers a permission request without a press.
- Spend is observed and displayed, never enforced.

## Risks

### A blocking hook holds a process per blocked agent

Eight blocked agents means eight sleeping Python processes for up to two minutes each. This is
acceptable — they sleep rather than spin, and the polling interval is 150ms — but it is new,
and it is the first time flightdeck holds long-lived processes at all. If it proves a problem
the fix is the rejected FIFO, not a shorter timeout: a shorter timeout trades a real capability
for a resource cost that has not yet been shown to matter.

### A steer loop

Covered by the repeat counter, which makes it visible rather than preventing it. Visibility is
the right treatment: the operator can see `×4` and reach for INTERRUPT. A mechanical cap on
retries would be a second policy engine, and would sometimes be wrong.

### REMEMBER's blast radius outlives the session

Mitigated by always arming and by naming the repository on the armed face, but not eliminated.
The rule persists in `<repo-root>/.claude/settings.local.json`, where it applies to every future
agent in that repository. There is no undo on the deck; removing a rule is a text edit. This is
the single most consequential press in the design and it is worth saying so in the README.

### HALT's claim can be overstated

Addressed in *Decisions taken 4*, and repeated here because it is the sentence most likely to
end up in marketing copy detached from its qualification. HALT guarantees that nothing an agent
does reaches the machine. It does not guarantee the agent stops.

### `PreToolUse` on the hot path

The v1 spec deliberately avoided `PreToolUse` because it fires on every tool call. That
position has already been amended once — the `Resumed` guard is on it today — and the mitigation
is the same and is proven: a shell `test -e` that costs nothing and pays for an interpreter only
on a real transition. HALT adds a second `stat`, and in the halted case emits its deny from
shell without an interpreter at all.

## Testing

The pending record and the decision file are the interfaces, so most of this is testable with
no hardware, no Stream Deck, and no live agent — the property that made Row 2 tractable.

- **Pure functions** — risk scoring against fixture tool inputs, target resolution against
  fixture pending sets, steer-verb resolution and the non-steer refusal, weighted token
  arithmetic against fixture transcripts.
- **`fleet-decide`** — pipe a `PermissionRequest` payload on stdin with a decision file already
  present and assert the emitted JSON; assert the pending record's shape; assert that a second
  identical payload increments `repeats` rather than creating a record; assert that a timeout
  emits *nothing at all*, which is the safety property and deserves its own test.
- **The claim race** — two claimants, exactly one delivery, the loser behaving as though there
  were nothing to deliver.
- **The halt guard** — the highest-value test on Row 4. Assert the shell clause emits valid deny
  JSON with no interpreter available on `PATH` at all, which is the property that makes it an
  emergency brake rather than another feature.
- **`fleet-dispatch`** — refusal on no selection, no matching issue, and a full fleet, with `gh`
  and `fleet-spawn` stubbed by the stub-bin pattern `tests/emit.bats` already uses.
- **Plugin** — verdict key rendering as a pure function, including the armed REMEMBER face
  showing repository rather than agent.

**What cannot be faked** gets a live check on real sessions, the way the hook chain was
verified: that a real blocked agent proceeds on an `allow`, and that ESC into a `working`
session interrupts it.

## First slice

The decision channel is the whole mechanism, so it goes first and the deck goes last.

1. **`fleet-decide` and the pending record** — the hook, risk scoring, the pending write, the
   poll, the timeout fall-through. Testable end to end by writing a decision file by hand.
2. **`fleet-verdict`** — APPROVE and DENY only. At this point the system works from a terminal:
   `bin/fleet-verdict approve` unblocks a real agent, with no key involved.
3. **Row 3's action type and rendering** — DETAIL, APPROVE, DENY, and the flash vocabulary.
4. **REMEMBER and the steers** — the arming path, the repository-named armed face, the
   `steer: true` flag and the three verb files.
5. **HALT** — the shell guard, the latch, the `working`-only interrupt, the Row 1 halted paint.
6. **POSTURE, SPEND, DISPATCH** — in that order, each independently useful and none blocking
   the others.

Steps 1 and 2 are worth landing before the deck can press anything, for the same reason Row 2's
first slice was: a verdict can be issued by hand and observed to arrive, and the keypress is the
last thing that needs to work rather than the first.

## Open decisions

- **`decideTimeoutSecs` default.** 120s is a guess. It should be tuned against how long it
  actually takes to notice an amber key and reach the deck, which is the number the Days 1–30
  experiment already measures.
- **Whether DETAIL should page** when several requests are pending on the same session. Today
  the repeat counter covers the identical-request case; distinct concurrent requests on one
  session are unhandled.
- **Steer labels at 96px.** `JUSTIFY`, `OTHER WAY` and `DRY RUN` fit the eleven-character
  budget, but the Row 2 spec's open question about `DOUBT` applies: confirm against the real
  renderer before the set is frozen.
- **Whether `PermissionRequest` should replace `Notification` as the amber trigger** for
  tool-permission blocks specifically, given the measured six-second debounce. This is a change
  to shipped Row 1 behaviour and should be decided on its own, not smuggled in with this row.
- **The free-versus-paid boundary.** Recorded because it changes nothing here technically and
  everything about what ships together. If Rows 3–4 are the paid tier, the emergency brake is
  behind the paywall. HALT is one key and one `stat`, costs nothing to give away, and "the stop
  button is free, forever" is a stronger line than any feature list — while the compounding
  value, REMEMBER and the interruption-rate number, stays firmly on the paid side.
