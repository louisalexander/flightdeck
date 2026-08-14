# Claude Code Hook Contract (empirically verified)

**Verified against:** Claude Code CLI `v2.1.232`, macOS (Darwin 24.6.0), on 2026-08-13/14.

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
| `Notification` | YES | only observed interactively, when a tool call required permission approval |

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

1. **Idle-nudge `Notification`.** Claude Code's documentation describes a second
   `Notification` trigger — the terminal going idle (~60s) awaiting user input — separate
   from a permission prompt. Only the `notification_type: "permission_prompt"` variant was
   observed in this spike. A human should sit at an interactive session, let it idle after
   Claude asks a question, and confirm (a) that `Notification` fires again, and (b) what
   `notification_type` value (or absence of the field) distinguishes it from a permission
   prompt.
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
