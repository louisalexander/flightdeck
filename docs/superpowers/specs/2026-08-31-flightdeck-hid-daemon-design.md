# Flightdeck HID Daemon — a transport swap, not a rewrite

**Date:** 2026-08-31
**Status:** Approved design, ready for implementation planning
**Follows:** `2026-08-13-streamdeck-fleet-design.md` (Row 1), `2026-08-14-flightdeck-row2-commands-design.md`
(Row 2), `2026-08-15-flightdeck-rows-3-4-design.md` (Row 3; Row 4 unbuilt)

## What changes

The Elgato Stream Deck app is blocked by corporate policy on the machine this needs to run on.
Every other flightdeck design so far assumed that app was present, because `plugin.ts` talks to
the physical deck only through `@elgato/streamdeck`'s websocket connection into it. Without the
app, none of Rows 1–3 can paint or receive a keypress.

This is a transport problem, not a logic problem. `render.ts`, `glyphs.ts`, `command.ts`,
`verdict.ts`, `splash.ts` and `types.ts` have no dependency on `@elgato/streamdeck` at all — they
are pure functions that take fleet state in and produce SVG strings out. Only `plugin.ts` touches
the SDK, and only for four things: receiving key-down/key-up events, calling `setImage`/`setTitle`,
and the final `streamDeck.connect()`. A new component that gets those four things from USB HID
directly needs no new decision logic, no new rendering, and no changes to any `bin/` script.

## Decisions taken

### 1. It lives in this repo, as `daemon/`, not a separate project

**Rejected — a standalone repo.** The reusable code, the `bin/` scripts it must shell out to
identically, and `config/fleet.json` all already live here. A separate repo would have to either
copy those files (a sync problem on every future render/glyph change) or `git submodule` them (real
overhead for a one-person project). Neither buys anything: this is a second transport for the same
product, not a second product.

`daemon/src/` imports `render.ts`, `glyphs.ts`, `command.ts`, `verdict.ts`, `splash.ts` and
`types.ts` from `../../plugin/src/` by relative path, unmodified. `render.test.mjs` keeps testing
the same built output it always has. There is exactly one copy of the rendering layer.

### 2. Transport is `@elgato-stream-deck/node`, not a rewrite of the app-facing half either

This is an open-source library that talks to the deck over `node-hid`/`usb`, with no Elgato app in
the loop. It exposes per-device key-down/key-up events and a `fillKeyBuffer`-style call for pushing
a raw image to a key — the same two operations `plugin.ts` already performs through the SDK, just
addressed differently.

**Rejected — Python + `python-elgato-streamdeck`.** `bin/` stays Python regardless, so this would
buy consistency with the scripts but at the cost of porting `render.ts`/`glyphs.ts`/`command.ts`/
`verdict.ts` (SVG-geometry glyphs, XML escaping, all the invariants `render.test.mjs` locks down)
into Pillow calls from scratch, with no shared test file afterward. The daemon side is a thin shell
around the existing pure layer; the language that shell is written in should be the language that
layer is already written in.

### 3. Key assignment becomes a static file, because there is no property inspector anymore

The Elgato app's drag-and-drop UI is what let each key's action type and settings (`slotIndex`,
`verb`, `verdict`) get set per-key today, persisted in the app's own preferences — which a HID
daemon has no access to and no equivalent for. `daemon/config/keymap.json` replaces it: one entry
per physical key index (0–31 on the Stream Deck XL), each carrying the action type and whatever
settings that type needs. Row 1 needs no explicit entries at all — its existing auto-by-column
default (`autoIndexFor` in `plugin.ts`) is preserved, so an unlisted key in the first eight still
resolves to its column. Rows 2 and 3 are listed explicitly, because their settings (which verb,
which verdict) have no positional default.

Shipped defaults:

**Row 2** (no committed layout exists anywhere — the Elgato app's per-key verb assignment was never
written to a file in this repo): `test, diff, note, push, pr, review, stop, confirm`, picked as a
reasonable starting eight from the fourteen available verbs. Edit `keymap.json` to match whatever
was actually dragged onto the real panel.

**Row 3** (this one *is* committed, and confirmed against the actual physical layout rather than
just the README's original draft):

| Key | Verdict | Verb |
|---|---|---|
| 1 | DETAIL | — |
| 2 | APPROVE | — |
| 3 | REMEMBER | — |
| 4 | DENY | — |
| 5 | INTERRUPT | — |
| 6 | STEER | justify |
| 7 | STEER | otherway |
| 8 | STEER | dryrun |

All eight Row 3 keys are bound; there is no unused slot in this layout (the README's original
`key8 unbound` draft is superseded here).

### 4. No PI-equivalent settings channel; `onDidReceiveSettings` has nothing to receive from

`plugin.ts` never calls `getSettings`/`setSettings` itself — settings arrive passively in each
event's payload, written by the property inspector's own embedded JS talking to its own websocket.
That whole channel is Elgato-app-specific and has no HID equivalent. The daemon reads `keymap.json`
once at startup (and on `SIGHUP`, to allow editing without a restart) instead of receiving settings
per-event. This is strictly simpler than what it replaces, not a reduced version of it — the
information content (type + params per key) is identical, just read from one file instead of
pushed per-key from an app that no longer exists in this picture.

### 5. The daemon owns no fleet-state logic it doesn't already own today

Repaint triggers are identical to `plugin.ts`'s: `fs.watch(~/.fleet)` on `slots.json`/`armed.json`
renames, plus a 1-second interval safety net (the SDK's own repaint triggers have no HID analogue,
so the daemon needs the same belt-and-suspenders `plugin.ts` already uses for exactly the same
reason — a watch bound to an inode that a rename replaces). Dispatch on key-up is identical:
measure held-duration since key-down, `execFile` the interpreter against `bin/fleet-press`,
`bin/fleet-send`, or `bin/fleet-verdict` with the exact argv shapes and env vars `plugin.ts` uses
today (see the Row 1/2/3 design docs for those contracts). Nothing here is new logic; it is the same
logic driven by a different event source.

### 6. Packaging mirrors the existing reaper launchd job, not a new pattern

`install.sh`'s reaper install (template a `.plist` with `__PYTHON__`/`__REPO__`/`__HOME__`
substituted, `launchctl load`) is the closest existing precedent for "a background process this
repo manages." A new `daemon/install-daemon.sh` does the equivalent: pin a node path, build
`daemon/`, template `com.louisalexander.flightdeck.daemon.plist`, load it. It uses `KeepAlive`
rather than the reaper's `StartInterval`, since this is a long-running process rather than a
periodic tick — a HID error or a device unplug should exit the process and let launchd restart it,
which naturally retries opening the device on reconnect rather than needing its own reconnect loop.

**`install-daemon.sh` is separate from `install.sh` and touches nothing in it.** `install.sh`'s
existing steps — building and symlinking `plugin/` into the Elgato app's Plugins directory,
restarting that app — stay exactly as they are, for any machine where that app is actually usable.
This repo now supports two transports for the same panel; installing one must not require or
disturb the other.

## Architecture

```
Stream Deck XL (USB HID)
        │  @elgato-stream-deck/node
        ▼
daemon/src/index.ts ──reads──► daemon/config/keymap.json  (key index -> action + settings)
        │        ▲
        │ fs.watch + 1s interval     │ execFile on key-up
        ▼        │                   ▼
~/.fleet/slots.json, armed.json      bin/fleet-press <slot> <verb>
                                      bin/fleet-send <verb>
                                      bin/fleet-verdict <verdict> [verb]
        │
        │ renderSvg / renderCommandSvg / renderVerdictSvg / splashTileSvg
        │ (imported unmodified from ../../plugin/src/)
        ▼
daemon/src/render-to-image.ts  (sharp: SVG -> 96x96 PNG)
        │
        ▼
device.fillKeyBuffer(index, buffer, {format: "png"})
```

### `daemon/src/index.ts`

Opens the device via `openStreamDecks()`, loads `keymap.json`, and for each of the 32 keys resolves
one of four per-key handlers — `slot`, `command`, `verdict`, or `boot` (the filler for any key with
no explicit or positional assignment, reusing `splash.ts`'s `renderBootTile`/`nightTileSvg`
unchanged) — mirroring the four `SingletonAction` subclasses in `plugin.ts` one-for-one, minus the
SDK plumbing:

| `plugin.ts` class | daemon equivalent |
|---|---|
| `FleetSlot` | `slot` handler: same `paint`/`autoIndexFor`/`resolveIndex` logic, `fleet-press` on key-up |
| `BootTile` | `boot` handler: paints only, no key-up handler at all |
| `Command` | `command` handler: `paintIdle`/feedback-then-restore, `fleet-send` on key-up |
| `Verdict` | `verdict` handler: same, `fleet-verdict` on key-up, DETAIL's no-dispatch special case preserved |

Row/column math: HID key index is row-major (`row = floor(index / 8)`, `col = index % 8`), matching
the XL's 4×8 grid that `render.test.mjs` already asserts against.

### `daemon/src/render-to-image.ts`

Each handler's paint step already produces an SVG string via the reused pure functions. This module
is the one genuinely new piece of code: `sharp` rasterizes that SVG to a 96×96 PNG buffer (the XL's
native key resolution), handed to `fillKeyBuffer`. No other rendering logic exists here — it is a
format conversion, not a redesign.

### `daemon/config/keymap.json`

```json
{
  "row2": ["test", "diff", "note", "push", "pr", "review", "stop", "confirm"],
  "row3": [
    { "verdict": "detail" },
    { "verdict": "approve" },
    { "verdict": "remember" },
    { "verdict": "deny" },
    { "verdict": "interrupt" },
    { "verdict": "steer", "verb": "justify" },
    { "verdict": "steer", "verb": "otherway" },
    { "verdict": "steer", "verb": "dryrun" }
  ]
}
```

Row 1 has no section: every key in indices 0–7 not otherwise claimed defaults to a Fleet Slot at
its column, exactly as `plugin.ts` does today.

## Non-goals

- No property-inspector-equivalent UI. Re-laying-out a row means editing `keymap.json` and sending
  the daemon `SIGHUP` (or restarting it).
- No support for running the daemon and the Elgato-app plugin against the same physical device at
  once. This machine has no working Elgato app, so there is no conflict to arbitrate; a machine that
  does have one should keep using `plugin/`, not this.
- No new fleet-state logic, no new render logic, no new `bin/` script. Everything on the fleet side
  of the diagram above is unchanged.
- Row 4 stays unbuilt here exactly as it is unbuilt in `plugin/`.

## Risks

### HID device access on macOS can prompt or silently fail without an entitlement

`node-hid` needs the process to have permission to access USB HID devices; unlike a signed,
notarized app the Elgato SDK ships, a local Node script may hit `IOHIDDeviceOpen` failures that look
like "device not found" rather than "permission denied." `install-daemon.sh` should check for this
explicitly (open, read one report, fail loud) rather than let it surface as a silent blank panel —
the same doctrine `fleet-doctor` already applies to iTerm2 automation permission.

### `sharp`'s native binary and a corporate laptop's build tooling

`sharp` ships prebuilt binaries for common platforms, so this is usually a non-issue, but a locked-down
laptop is exactly the environment where an `npm install` reaching for a native module can go
sideways. Worth a `daemon/install-daemon.sh` check (`node -e "require('sharp')"`) before anything
else, so a failure here is diagnosed in one line rather than as a mysteriously blank deck later.

### Two transports, one set of `bin/` script contracts

Nothing stops the two implementations (`plugin.ts` and the daemon) from drifting on argv shape or
env vars if either changes later without the other being updated. Both are thin dispatchers over
the same five scripts, so this is a discipline risk, not an architectural one; the mitigation is
that both call sites live in the same repo and the same PR review would touch both.

## Testing

- **`render.test.mjs` is unchanged and still runs** — it exercises the built `render`/`splash`/
  `command`/`verdict` bundles directly, with no dependency on either transport.
- **`daemon/src/render-to-image.ts`** gets its own small test: feed it a known SVG, assert the
  output PNG decodes to the expected pixel dimensions and a spot-checked pixel color, since this is
  the one piece of logic that has no analogue in `plugin.ts` to have already exercised it.
- **Row/column math** — a pure-function test asserting `row = floor(index/8), col = index % 8` for
  all 32 indices, matching the grid `render.test.mjs` already assumes.
- **`keymap.json` loading** — malformed or partial config degrades to Row 1 auto-by-column plus
  boot tiles everywhere else, never a crash; this mirrors the "config never throws" discipline
  `loadConfig` already applies in `plugin.ts`.
- **What cannot be faked** gets a live check on real hardware, the way the Row 1 plugin was
  verified: plug in the XL, confirm all three rows paint on daemon start, confirm a short press and
  a long press on a Fleet Slot key produce the same effect `fleet-doctor` already knows how to
  verify for the plugin path.

## First slice

1. **Row 1 only, hardcoded key-to-slot (no `keymap.json` yet)** — open the device, paint eight Fleet
   Slot keys from `~/.fleet/slots.json`, dispatch `fleet-press` on key-up. This alone proves the HID
   transport, the reused render layer, and the dispatch path all work together, with the smallest
   possible surface.
2. **`render-to-image.ts` as its own tested module**, pulled out of step 1's inline code once it's
   proven, rather than designed up front.
3. **`keymap.json` and the `boot` handler** — generalizes step 1 to all 32 keys and removes the
   hardcoding.
4. **Row 2 (`command` handler)** — `fleet-send` dispatch, feedback-then-restore timers.
5. **Row 3 (`verdict` handler)** — `fleet-verdict` dispatch, DETAIL's no-dispatch case, the armed
   REMEMBER face.
6. **`install-daemon.sh` and the launchd job** — last, because steps 1–5 are more easily iterated by
   running the daemon directly from a terminal than by round-tripping through launchd each time.

## Open decisions

- **`SIGHUP` reload vs. restart-only for `keymap.json` edits.** Reload is nicer but is new code with
  its own edge cases (a reload mid-armed-window, a reload that removes a key another handler has a
  pending timer against); restart-only is one line in a README. Worth deciding once the daemon
  exists to iterate against, not before.
- **Whether `daemon/` should share a `tsconfig`/build step with `plugin/`** or have its own. They
  compile the same imported source files, so keeping the compiler options identical avoids a class
  of "works in one, not the other" bug, but a shared build config across two otherwise-independent
  npm packages needs a decision about where it lives.
- **Multi-device behavior** is unspecified — `openStreamDecks()` can see more than one deck. This
  repo has exactly one XL in play; the daemon should probably just refuse to start with zero or more
  than one device found rather than guess, but this hasn't been decided.
