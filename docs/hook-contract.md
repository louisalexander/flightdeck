# Claude Code Hook Contract (empirically verified)

**Verified against:** Claude Code CLI `v2.1.232`, macOS (Darwin 24.6.0), on 2026-08-13/14.
Extended against `v2.1.233` on 2026-08-14 with `PermissionRequest`, `PreToolUse` under
bypassed permissions, and the second `Notification` type — see
"Permission-decision events" below.

**Method:** A project-scoped `.claude/settings.json` (this repo only — `~/.claude/settings.json`
was never touched) registered all five hook events, each pointing at
`tools/probe-hook.sh <EventName>`, which appends the raw stdin JSON to
`~/.fleet-probe/probe.log`. Because the human partner was unavailable to drive an
interactive session by hand, transitions were exercised in two ways:

1. **Headless** (`claude -p "<prompt>" --max-turns 3`), run from `/Users/pk/code/flightdeck`.
   This reliably fired `SessionStart`, `UserPromptSubmit`, `Stop`, `SessionEnd` on the very
   first invocation.
2. **Scripted-interactive**, for `Notification` only: an `expect` script spawned a real
   interactive `claude` process in a pty (still project-scoped, still only touching this
   repo's settings), typed a prompt that required tool-use approval, and captured the
   permission dialog. This was necessary because headless `-p` mode has no TTY to show a
   permission prompt — it either hard-blocks the tool call or silently declines it, and
   `Notification` never fires in that mode (see below).

No other running Claude Code sessions on this machine were touched: the settings file lived
only in `/Users/pk/code/flightdeck/.claude/settings.json`, which only applies to sessions
started with that directory as project root.

## Summary table

| Event | Fired? | How |
|---|---|---|
| `SessionStart` | YES | every launch (headless and interactive) |
| `UserPromptSubmit` | YES | every prompt submission (headless and interactive) |
| `Stop` | YES | every completed turn (headless and interactive) |
| `SessionEnd` | YES | every session teardown (headless `-p` exit and interactive `/exit`) |
| `Notification` | YES | two types: `permission_prompt` (interactive only) and `idle_prompt` |
| `PermissionRequest` | YES | interactive only — fires exactly when a permission dialog is raised |
| `PreToolUse` | YES | every tool call, **in every permission mode** |

All five event names in the brief (`SessionStart`, `UserPromptSubmit`, `Notification`,
`Stop`, `SessionEnd`) are correct — Claude Code did not reject any of them at startup.

## Per-event detail

### 1. `SessionStart` — FIRED

Fires once, immediately on process launch, before any prompt is processed.

Verbatim payload (headless run):
```json
{"session_id":"9c008bb0-9aa5-4d03-a36c-d5c225c89132","transcript_path":"/Users/pk/.claude/projects/-Users-pk-code-flightdeck/9c008bb0-9aa5-4d03-a36c-d5c225c89132.jsonl","cwd":"/Users/pk/code/flightdeck","hook_event_name":"SessionStart","source":"startup"}
```

Verbatim payload (interactive run — note the extra `model` field, absent headlessly):
```json
{"session_id":"27e4ec46-c3d2-4ffb-bfcf-bfce00148720","transcript_path":"/Users/pk/.claude/projects/-Users-pk-code-flightdeck/27e4ec46-c3d2-4ffb-bfcf-bfce00148720.jsonl","cwd":"/Users/pk/code/flightdeck","hook_event_name":"SessionStart","source":"startup","model":"claude-opus-5[1m]"}
```

Fields: `session_id` (string, uuid), `transcript_path` (string, absolute path),
`cwd` (string, absolute path — **this is the field Task 3 should read for the working
directory**), `hook_event_name` (literal `"SessionStart"`), `source` (observed value:
`"startup"` — the docs also mention `"resume"`/`"clear"` as other possible values, not
observed here), and optionally `model` (string, e.g. `"claude-opus-5[1m]"` — present in
some but not all launches; do not assume it is always there).

### 2. `UserPromptSubmit` — FIRED

Fires once per prompt submission, before the model processes it.

Verbatim payload:
```json
{"session_id":"9c008bb0-9aa5-4d03-a36c-d5c225c89132","transcript_path":"/Users/pk/.claude/projects/-Users-pk-code-flightdeck/9c008bb0-9aa5-4d03-a36c-d5c225c89132.jsonl","cwd":"/Users/pk/code/flightdeck","prompt_id":"4cb2eb04-bd13-41d1-8379-11e55d9085d7","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"list the files in this directory"}
```

Fields: `session_id`, `transcript_path`, `cwd` — same as above — plus `prompt_id` (string,
uuid, unique per turn), `permission_mode` (string, observed value `"default"`),
`hook_event_name` (literal `"UserPromptSubmit"`), `prompt` (string, the raw text the user
submitted).

### 3. `Notification` — FIRED (interactive only) — THE DECISIVE RESULT

**Did NOT fire in headless (`-p`) mode.** Two headless attempts to trigger a permission
request were made:
- `claude -p "run: rm -i /tmp/nonexistent-flightdeck-probe" --max-turns 3` — this was hard
  denied by a harness-level working-directory sandbox restriction before any permission
  system was consulted at all (Claude's own reply: *"The command was blocked by the harness
  before it ran... Claude Code may only remove files from the allowed working directories for
  this session"*). No prompt, no `Notification`.
- `claude -p "Fetch https://example.com and summarize it" --max-turns 3` — WebFetch requires
  permission under `permission_mode: "default"`, but with no TTY attached, headless mode
  silently declines the tool call instead of prompting (Claude's own reply: *"the WebFetch
  permission wasn't granted for this session, so the call was blocked before it ran"*). No
  prompt, no `Notification`.

**DID fire when a real permission dialog was shown in an interactive session.** An `expect`
script spawned `claude` in a pty (project-scoped to this repo), typed `Use the WebFetch tool
to fetch https://example.com and give me the title`, and captured the resulting "Do you want
to allow Claude to fetch this content?" dialog. At the moment that dialog rendered:

Verbatim payload:
```json
{"session_id":"27e4ec46-c3d2-4ffb-bfcf-bfce00148720","transcript_path":"/Users/pk/.claude/projects/-Users-pk-code-flightdeck/27e4ec46-c3d2-4ffb-bfcf-bfce00148720.jsonl","cwd":"/Users/pk/code/flightdeck","prompt_id":"22de5aae-9979-4930-b28f-534281641373","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}
```

Fields: `session_id`, `transcript_path`, `cwd`, `prompt_id` — same shapes as above — plus
`hook_event_name` (literal `"Notification"`), `message` (string, human-readable, observed
value `"Claude needs your permission"`), and **`notification_type`** (string, observed value
`"permission_prompt"`).

**Answer to the decisive question:** yes, `Notification` fired when the permission prompt
appeared, and its payload *does* distinguish the event type via `notification_type`. Only
`"permission_prompt"` was observed in this spike (an idle-nudge notification, which Claude
Code's docs describe as firing after ~60s of no response, was not exercised — see
"Requires interactive verification" below). Downstream code (e.g. Task 3) should branch on
`notification_type == "permission_prompt"` rather than trying to infer intent from `message`
text, since `message` is free-form.

An additional, unplanned data point surfaced along the way: a bare **"trust this folder"**
dialog appeared once (on a session's very first launch in that pty) and did *not* generate a
`Notification` event — it is a workspace-trust prompt handled entirely outside the hook
system, not a tool-permission prompt. Do not conflate the two.

**The second variant, `idle_prompt`, is now confirmed** (2026-08-14, v2.1.233). It fired ~70s
after a turn ended awaiting input:

```json
{"hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}
```

`fleet-emit` already lists it in `IGNORED_NOTIFICATION_TYPES`, so the shipped behaviour was
right; this is confirmation of a guess, not a fix.

**`permission_prompt` is debounced by roughly six seconds.** Measured across three runs, it
fired 6.01s, 6.02s and 6.03s after the corresponding `PermissionRequest` hook began — a fixed
delay, not a function of how long anything took. It fires even when the request is resolved
programmatically and no human ever sees a dialog.

This matters to Row 1: `PermissionRequest` fires at t≈0 and `Notification` at t≈6, so amber
currently arrives about six seconds later than the same information is available. Anything
wanting a faster blocked signal should key on `PermissionRequest` — but note it is *narrower*
than `Notification`, being a tool-permission event only, so it is an addition to the blocked
signal rather than a replacement for it.

### 4. `Stop` — FIRED

Fires once per completed assistant turn.

Verbatim payload:
```json
{"session_id":"9c008bb0-9aa5-4d03-a36c-d5c225c89132","transcript_path":"/Users/pk/.claude/projects/-Users-pk-code-flightdeck/9c008bb0-9aa5-4d03-a36c-d5c225c89132.jsonl","cwd":"/Users/pk/code/flightdeck","prompt_id":"4cb2eb04-bd13-41d1-8379-11e55d9085d7","permission_mode":"default","effort":{"level":"high"},"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Contents of `/Users/pk/code/flightdeck`:\n\n- `.claude/` — untracked\n- `.git/`\n- `.superpowers/`\n- `docs/`\n- `tools/` — untracked\n\nOnly directories at the top level; no loose files. `.claude/` and `tools/` are untracked in git.","background_tasks":[],"session_crons":[]}
```

Fields: `session_id`, `transcript_path`, `cwd`, `prompt_id`, `permission_mode` — same as
above — plus `effort` (object, e.g. `{"level":"high"}`), `hook_event_name` (literal
`"Stop"`), `stop_hook_active` (boolean, observed `false` — presumably `true` when a `Stop`
hook is itself in the middle of re-triggering the loop, to guard against infinite recursion),
`last_assistant_message` (string, full text of the assistant's final reply this turn),
`background_tasks` (array — see below), `session_crons` (array, observed empty `[]`).

**`background_tasks` — in-flight background work.** Originally recorded here as "observed
empty `[]`", which was true of the capture but badly misleading: the probe that produced the
payload above never had background work in flight, so the field looked inert and went unused.
It is not inert. Claude Code documents it as listing "in-flight background work
(running/pending + backgrounded) registered in this session", whose purpose is to let hooks
*"distinguish 'session is done' from 'session is paused waiting for background work to wake
it'"*. That distinction is exactly the one `Stop` alone cannot make, and missing it is what
painted busy sessions green — see
[#5](https://github.com/louisalexander/flightdeck/issues/5).

Re-probed against Claude Code 2.1.232 with work actually in flight. A backgrounded subagent:

```json
{"hook_event_name":"Stop","background_tasks":[{"id":"a9120695e511e34a9","type":"subagent","status":"running","description":"Background sleep test","agent_type":"general-purpose"}],"session_crons":[]}
```

A backgrounded shell command:

```json
{"hook_event_name":"Stop","background_tasks":[{"id":"b3l1piyt6","type":"shell","status":"running","description":"sleep 45","command":"sleep 45"}],"session_crons":[]}
```

Each entry carries `id`, `type`, `status` and `description`, plus type-specific extras
(`command` for shell, `agent_type` for subagent, `server`/`tool` for monitors, `name` for
workflows). Observed `type` labels: `subagent`, `shell`, `workflow`, `monitor`, `MCP task`,
`teammate`, `cloud session`, `dream`, `auto-mode scan`. Entries are filtered by Claude Code to
`status` of `running` or `pending`. A subagent's `id` matches the `agent_id` carried by
`SubagentStart`/`SubagentStop`.

The field is optional in Claude Code's schema, so older versions omit it entirely. Treat an
absent field as *no information* — not as an empty list.

### 4a. `SubagentStart` / `SubagentStop` — FIRED

Not used by flightdeck, but confirmed to exist and recorded here so the next person does not
have to rediscover them. They bracket every subagent, including backgrounded ones, and fire
with the **parent** session's `session_id`:

```
SubagentStart  keys: agent_id, agent_type, cwd, hook_event_name, prompt_id, session_id, transcript_path
SubagentStop   keys: agent_id, agent_transcript_path, agent_type, background_tasks, cwd,
                     hook_event_name, last_assistant_message, permission_mode, prompt_id,
                     session_crons, session_id, stop_hook_active, transcript_path
```

`background_tasks` on the `Stop` payload is preferred over counting these: it is stateless and
self-describing, where a start/stop counter is persistent state that can desync if a session
dies mid-subagent, and it covers backgrounded shells and workflows that these two never see.

**Probing note.** Claude Code snapshots its hook registry at session start, so hooks added to
a settings file mid-session never fire. Any future contract probe must launch a *fresh*
session with the probe hooks already registered — e.g.
`claude -p '<prompt>' --settings <probe-settings.json>`, with `FLEET_HOME` pointed at a
throwaway directory so the probe does not write into the live deck.

### 5. `SessionEnd` — FIRED

Fires once at session teardown. Two distinct `reason` values were observed depending on how
the session ended:

Verbatim payload (headless `-p` process exiting after its turn completes):
```json
{"session_id":"9c008bb0-9aa5-4d03-a36c-d5c225c89132","transcript_path":"/Users/pk/.claude/projects/-Users-pk-code-flightdeck/9c008bb0-9aa5-4d03-a36c-d5c225c89132.jsonl","cwd":"/Users/pk/code/flightdeck","prompt_id":"4cb2eb04-bd13-41d1-8379-11e55d9085d7","hook_event_name":"SessionEnd","reason":"other"}
```

Verbatim payload (interactive session ending via `/exit` typed while a prompt box still had
pending/queued text — an artifact of the scripted pty driver, but a real, distinct value):
```json
{"session_id":"837f2ddc-e399-4eb5-8d6b-ef3a15ca6609","transcript_path":"/Users/pk/.claude/projects/-Users-pk-code-flightdeck/837f2ddc-e399-4eb5-8d6b-ef3a15ca6609.jsonl","cwd":"/Users/pk/code/flightdeck","prompt_id":"5a34fb9b-9704-4817-afe7-5b61d31daae8","hook_event_name":"SessionEnd","reason":"prompt_input_exit"}
```

Fields: `session_id`, `transcript_path`, `cwd`, `prompt_id` — same as above — plus
`hook_event_name` (literal `"SessionEnd"`) and **`reason`** (string; observed values
`"other"` and `"prompt_input_exit"`). This is the field Task 3 should read to distinguish
exit paths, but note only two of presumably several possible values were observed (Claude
Code's docs mention values like `"clear"`, `"logout"`, `"prompt_input_exit"`, `"other"` — only
the latter two were confirmed here).

## Permission-decision events

Verified 2026-08-14 against v2.1.233 by the same project-scoped `--settings` method, driven
through `expect` in a pty for the interactive cases. `FLEET_HOME` pointed at a throwaway
directory throughout; no probe session reached the live deck.

### `PermissionRequest` — fires only when a human would be asked

It did **not** fire in headless `-p` mode, where the permission is silently declined with no
dialog. It fires in an interactive session at the moment a permission dialog is raised.

Verbatim payload:

```json
{"session_id":"c833a932-...","transcript_path":"...","cwd":"...","prompt_id":"ff3bcf0c-...",
 "permission_mode":"default","effort":{"level":"high"},"hook_event_name":"PermissionRequest",
 "tool_name":"WebFetch",
 "tool_input":{"url":"https://example.com","prompt":"Return the full text content of this page."},
 "permission_suggestions":[{"type":"addRules","destination":"localSettings",
   "rules":[{"toolName":"WebFetch","ruleContent":"domain:example.com"}],"behavior":"allow"}]}
```

Two fields beyond the usual shape. `tool_input` is the **full** input, unredacted and
untruncated. `permission_suggestions` is Claude Code's own proposal for a scoped rule that
would stop this prompt recurring — so a consumer never has to invent a rule width for itself.

**The output schema is not the documented `PreToolUse` one.** Claude Code's bundled hook
documentation says `permissionDecision` is "PreToolUse only", and that is accurate: emitting
`hookSpecificOutput.permissionDecision` from a `PermissionRequest` hook is silently ignored.
Two probes were wasted on this before the real schema was read out of the bundle:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest",
  "decision":{"behavior":"allow","updatedInput":{},"updatedPermissions":[]}}}

{"hookSpecificOutput":{"hookEventName":"PermissionRequest",
  "decision":{"behavior":"deny","message":"...","interrupt":true}}}
```

`updatedInput`, `updatedPermissions`, `message` and `interrupt` are all optional.
`deny.interrupt` halts the turn, and is preferable to a top-level `continue: false` because it
is part of the same decision rather than a second mechanism layered on top.

### A `PermissionRequest` hook may block, and the session waits

A hook that slept six seconds and then returned `allow` caused the tool to execute with no
human input. Confirmed in the transcript rather than on screen: `TOOL_USE WebFetch` followed
by a non-error `TOOL_RESULT`.

This is the one place flightdeck's "hooks must exit in milliseconds" rule can safely be
broken, and the reason is narrow enough to state as a rule of its own: **the only hook that
may block is one that fires when the agent is already blocked.** It adds no latency to a
session that is by definition waiting on a human.

Three properties make it safe to build on:

- **The dialog renders immediately and races the hook.** It is on screen the whole time the
  hook deliberates, and whichever answers first wins. An external approver is therefore an
  *additional* input channel, never a lockout.
- **Exceeding `timeout` falls through to the human.** With `timeout: 3` against a 12-second
  hook, the hook process was killed, nothing was printed to the terminal, and the ordinary
  dialog stayed answerable. Walking away cannot turn into an automatic denial.
- **Hooks tighten but cannot loosen.** A hook `allow` is still subject to deny rules; the
  bundle carries the string `PermissionRequest hook allowed with updatedInput, but rule
  overrides:` for exactly that case.

### `updatedPermissions` persists — but for a worktree, not where you expect

`updatedPermissions` echoed back from the payload's own `permission_suggestions` was applied
to the live permission context *and* written to disk. Persistence only happens for
`destination` values of `localSettings`, `userSettings` or `projectSettings`; anything else
(e.g. `session`) applies in memory for the rest of the session and is never saved.

**The trap: a session running in a linked worktree writes `localSettings` to the canonical
repo root, not to the worktree.** A probe with `cwd` inside `.claude/worktrees/rows-3-4`
created no `.claude/` there at all — the rule landed in
`<repo-root>/.claude/settings.local.json`. The bundle handles this deliberately, reasoning
that a per-worktree copy "would become a stale, revocation-resurrecting legacy overlay".

The consequence for a fleet is a safety property, not a detail: **remembering a permission for
one worktree agent widens permissions for every agent in every worktree of that repository,
including ones that do not exist yet.** Anything offering one-press "approve and remember"
has to name the repository it is widening, not the agent.

### `PreToolUse` gates every tool call in every permission mode

Claude Code says so itself, in a string aimed at SDK users:

> `canUseTool will not be invoked: permissionMode 'bypassPermissions' auto-approves every tool
> call (except explicit deny rules) before the callback is consulted. To gate every tool call,
> use a PreToolUse hook instead.`

Confirmed live, headlessly, twice. A `PreToolUse` hook returning

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
  "permissionDecisionReason":"FLEET HALTED by operator. Do not retry, do not work around this. Stop and wait."}}
```

blocked the tool under both `--permission-mode bypassPermissions` and
`--dangerously-skip-permissions`. The payload carries `permission_mode: "bypassPermissions"`,
so a hook can tell which mode it is gating.

Two qualifications belong attached to that result wherever it is quoted:

- **A deny is not a pause.** The model receives a denial and reasons about it; it is free to
  retry or route around. Both runs did produce stop-and-wait behaviour with the wording above
  ("Not retrying. Waiting for your go-ahead."), but that is a model complying with a sentence,
  not a mechanical stop. Anything advertised as *halting* an agent needs an interrupt too.
- **Coverage is per-session and fixed at launch.** Claude Code snapshots its hook registry at
  session start, so a fleet-wide gate covers only sessions that started with the hook already
  registered. A session launched before install, or with an overriding `--settings`, is not
  covered and cannot be made so while it lives.

Matchers are additive: with both a `"matcher": "WebFetch"` group and an unmatched catch-all
group registered, both ran for a WebFetch call. Multiple `PermissionRequest` groups run
**concurrently**, and a group returning no decision abstains without blocking the others.

## Field names for Task 3 (quick reference)

- Session id: **`session_id`** (top-level, string uuid) — present in every event.
- Working directory: **`cwd`** (top-level, string absolute path) — present in every event.
- SessionEnd reason/exit field: **`reason`** (top-level, string) — observed values `"other"`,
  `"prompt_input_exit"`.
- Notification's permission-vs-idle discriminator: **`notification_type`** (top-level,
  string) — observed value `"permission_prompt"` (idle-nudge variant not observed — see
  below).

The brief's assumed field names (`session_id`, `cwd`) are **confirmed correct verbatim**.

## REQUIRES INTERACTIVE VERIFICATION

The following could not be produced or confirmed by scripted automation and need a human at
a live prompt to check:

1. ~~**Idle-nudge `Notification`.**~~ **RESOLVED 2026-08-14.** It fires, ~70s after the turn
   ends, carrying `notification_type: "idle_prompt"` and `message: "Claude is waiting for your
   input"`. See "The second variant" under `Notification` above.
2. **`SessionStart` `source` values other than `"startup"`.** The docs suggest `"resume"`
   (via `--resume`/`--continue`) and `"clear"` (via `/clear`) as other possible values. Not
   exercised here.
3. **`SessionEnd` `reason` values other than `"other"` and `"prompt_input_exit"`.** Values
   like `"clear"` or `"logout"` were not produced. A human should try `/clear`, closing the
   terminal window outright, and killing the process to see what `reason` (if any) each
   produces.
4. **Whether `Notification` fires for permission types other than tool-use approval** — e.g.
   the "trust this folder" workspace-trust dialog observed here did *not* fire `Notification`
   at all; it would be worth having a human confirm this is consistent (it appears to be a
   pre-hook-system UI gate, not a tool permission event) and check whether other approval
   surfaces (e.g. MCP server connection consent) do or don't route through `Notification`.
5. **Multiple concurrent sessions / the real Stream Deck use case** — this spike only ever
   ran one `claude` process at a time. A human running several concurrent sessions in
   different terminal tabs, each writing to the same shared `~/.fleet-probe/probe.log` (or,
   in production, wherever Task 3's log lives), should confirm there's no event
   interleaving/corruption under concurrent writes from `tools/probe-hook.sh`'s simple
   `>>` append (the script does not lock the file).
