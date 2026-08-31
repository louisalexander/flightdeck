# Flightdeck HID Daemon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `daemon/`, a standalone Node process inside the `flightdeck` repo that drives a
Stream Deck XL directly over USB HID (no Elgato app), reusing `plugin/src/{render,glyphs,command,
verdict,splash,types}.ts` unmodified and dispatching to the same `bin/fleet-press`,
`bin/fleet-send`, `bin/fleet-verdict` scripts the existing Elgato-app plugin already uses.

**Architecture:** `@elgato-stream-deck/node` opens the device and yields key down/up events;
per-key handlers (`slot`, `command`, `verdict`, `boot`) compute an SVG via the reused pure
render functions, rasterize it to a raw RGBA buffer with `sharp`, and push it to the key. Key-up
events measure press duration and shell out to the existing fleet scripts exactly as `plugin.ts`
does. `daemon/config/keymap.json` statically assigns Row 2/3 key settings since there is no
property-inspector UI in this transport.

**Tech Stack:** TypeScript, Node.js, `@elgato-stream-deck/node` (HID transport), `sharp` (SVG→raw
pixel rasterization), rollup + `@rollup/plugin-typescript` (matching `plugin/`'s existing build),
Node's built-in `node:test`/`node:assert` (matching `plugin/src/render.test.mjs`'s convention).

**Spec:** `docs/superpowers/specs/2026-08-31-flightdeck-hid-daemon-design.md`

## Global Constraints

- `daemon/src/*.ts` imports `render.ts`, `glyphs.ts`, `command.ts`, `verdict.ts`, `splash.ts`,
  `types.ts` from `../../plugin/src/` by relative path — never copy or fork them.
- Every `bin/fleet-press`, `bin/fleet-send`, `bin/fleet-verdict` invocation must use the exact
  same argv shapes and env vars the Elgato-app plugin (`plugin/src/plugin.ts`) already uses.
- `install-daemon.sh` is a new, separate script. It must not modify `install.sh` or anything
  `install.sh` manages (the Elgato-app plugin build/link/restart steps).
- Row 4 stays unbuilt. No property-inspector-equivalent UI — key assignment is
  `daemon/config/keymap.json`, edited by hand.
- Row 2 default verb layout (edit after install to match your real layout):
  `test, diff, note, push, pr, review, stop, confirm`.
- Row 3 layout (fixed, all 8 keys bound, no unbound key):
  key1 DETAIL, key2 APPROVE, key3 REMEMBER, key4 DENY, key5 INTERRUPT, key6 STEER/justify,
  key7 STEER/otherway, key8 STEER/dryrun.
- launchd job uses `KeepAlive`, not `StartInterval` (this is a long-running process, not a
  periodic tick).
- The daemon refuses to start unless exactly one Stream Deck device is found (0 or 2+ is an
  error, not a guess).

---

## File Structure

```
daemon/
├── package.json
├── tsconfig.json
├── rollup.config.mjs
├── config/
│   └── keymap.json
├── src/
│   ├── row-math.ts           # pure: HID key index <-> {row, col}
│   ├── render-to-image.ts    # SVG string -> raw RGBA Buffer at a given size
│   ├── fleet-state.ts        # read slots.json/armed.json; watch + safety-interval helper
│   ├── interpreter.ts        # resolve pinned python path (mirrors plugin.ts's interpreter())
│   ├── dispatch.ts           # press-duration -> verb; execFile wrappers for the 3 bin scripts
│   ├── keymap.ts             # load/validate daemon/config/keymap.json
│   ├── slot-handler.ts       # Row 1: paint + key-up dispatch (mirrors FleetSlot)
│   ├── boot-handler.ts       # filler tiles for unassigned keys (mirrors BootTile)
│   ├── command-handler.ts    # Row 2: paint + key-up dispatch (mirrors Command)
│   ├── verdict-handler.ts    # Row 3: paint + key-up dispatch (mirrors Verdict)
│   └── index.ts              # entrypoint: open device, wire handlers, run
├── test/
│   ├── row-math.test.mjs
│   ├── render-to-image.test.mjs
│   ├── fleet-state.test.mjs
│   ├── interpreter.test.mjs
│   ├── dispatch.test.mjs
│   ├── keymap.test.mjs
│   ├── slot-handler.test.mjs
│   ├── command-handler.test.mjs
│   └── verdict-handler.test.mjs
├── install-daemon.sh
└── launchd/
    └── com.louisalexander.flightdeck.daemon.plist
```

---

### Task 1: Daemon scaffold + row/column math

**Files:**
- Create: `daemon/package.json`
- Create: `daemon/tsconfig.json`
- Create: `daemon/rollup.config.mjs`
- Create: `daemon/src/row-math.ts`
- Test: `daemon/test/row-math.test.mjs`

**Interfaces:**
- Produces: `keyIndexToRowCol(index: number): {row: number, col: number}` and
  `rowColToKeyIndex(row: number, col: number): number`, both exported from `row-math.ts`. Every
  later handler task uses these to translate the HID library's linear key index.

- [ ] **Step 1: Create `daemon/package.json`**

```json
{
  "name": "daemon",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "build": "rollup -c",
    "test": "npm run build && node --test test/"
  },
  "dependencies": {
    "@elgato-stream-deck/node": "^7.0.0",
    "sharp": "^0.33.0"
  },
  "devDependencies": {
    "@rollup/plugin-typescript": "^12.3.0",
    "@types/node": "^26.2.0",
    "rollup": "^4.62.4",
    "tslib": "^2.8.1",
    "typescript": "^6.0.3"
  }
}
```

- [ ] **Step 2: Create `daemon/tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "outDir": "dist",
    "rootDir": "."
  },
  "include": ["src/**/*.ts", "../plugin/src/*.ts"]
}
```

- [ ] **Step 3: Create `daemon/rollup.config.mjs`**

```js
import typescript from "@rollup/plugin-typescript";

const OUT = "dist";

function bundle(name) {
  return {
    input: `src/${name}.ts`,
    output: { file: `${OUT}/${name}.js`, format: "es", sourcemap: true },
    plugins: [typescript()],
    external: [
      "node:fs", "node:path", "node:os", "node:child_process", "node:events",
      "@elgato-stream-deck/node", "sharp"
    ]
  };
}

export default [
  "row-math", "render-to-image", "fleet-state", "interpreter", "dispatch",
  "keymap", "slot-handler", "boot-handler", "command-handler", "verdict-handler", "index"
].map(bundle);
```

- [ ] **Step 4: Install dependencies**

Run: `cd daemon && npm install`
Expected: `node_modules/` created, `package-lock.json` written, no errors. If `sharp` fails to
install a prebuilt binary here, stop and resolve that before continuing — Task 12 depends on it
working, and it's cheaper to find out now than after nine more tasks are built on top.

- [ ] **Step 5: Write `daemon/src/row-math.ts`**

```typescript
const COLUMNS = 8;

export function keyIndexToRowCol(index: number): { row: number; col: number } {
  return { row: Math.floor(index / COLUMNS), col: index % COLUMNS };
}

export function rowColToKeyIndex(row: number, col: number): number {
  return row * COLUMNS + col;
}
```

- [ ] **Step 6: Write the failing test**

```javascript
// daemon/test/row-math.test.mjs
import assert from "node:assert";
import { test } from "node:test";
import { keyIndexToRowCol, rowColToKeyIndex } from "../dist/row-math.js";

test("row 0, every column, matches index 0-7", () => {
  for (let col = 0; col < 8; col++) {
    assert.deepStrictEqual(keyIndexToRowCol(col), { row: 0, col });
  }
});

test("row 3 (Verdict row), key 6 (STEER/justify) is index 22", () => {
  assert.deepStrictEqual(keyIndexToRowCol(22), { row: 2, col: 6 });
});

test("round-trips for all 32 keys", () => {
  for (let i = 0; i < 32; i++) {
    const { row, col } = keyIndexToRowCol(i);
    assert.strictEqual(rowColToKeyIndex(row, col), i);
  }
});
```

- [ ] **Step 7: Run test, expect it to fail on missing build output**

Run: `cd daemon && npm test`
Expected: FAIL — `dist/row-math.js` does not exist yet (no build has run against real source,
or the module resolution fails). This confirms the test harness is wired to the right path
before there's anything real to pass.

- [ ] **Step 8: Build and re-run**

Run: `cd daemon && npm run build && node --test test/row-math.test.mjs`
Expected: all 3 tests PASS.

- [ ] **Step 9: Commit**

```bash
cd daemon
git add package.json package-lock.json tsconfig.json rollup.config.mjs src/row-math.ts test/row-math.test.mjs
git commit -m "feat(daemon): scaffold daemon package, add row/column math"
```

---

### Task 2: SVG → raw pixel rasterization

**Files:**
- Create: `daemon/src/render-to-image.ts`
- Test: `daemon/test/render-to-image.test.mjs`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `renderSvgToRgba(svg: string, size: number): Promise<Buffer>` — a raw RGBA pixel
  buffer of exactly `size * size * 4` bytes, row-major, top-to-bottom. Task 11 (`index.ts`) is
  the only later task that calls this directly; the handler tasks (7, 9, 10) only produce SVG
  strings and never touch pixels.

- [ ] **Step 1: Write the failing test**

```javascript
// daemon/test/render-to-image.test.mjs
import assert from "node:assert";
import { test } from "node:test";
import { renderSvgToRgba } from "../dist/render-to-image.js";

test("rasterizes a solid-colour square to the exact requested pixel size", async () => {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144">
    <rect width="144" height="144" fill="#1256A3"/>
  </svg>`;
  const buf = await renderSvgToRgba(svg, 96);
  assert.strictEqual(buf.length, 96 * 96 * 4, "RGBA buffer at the requested size");
});

test("centre pixel matches the fill colour #1256A3", async () => {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144">
    <rect width="144" height="144" fill="#1256A3"/>
  </svg>`;
  const size = 96;
  const buf = await renderSvgToRgba(svg, size);
  const centre = (Math.floor(size / 2) * size + Math.floor(size / 2)) * 4;
  assert.strictEqual(buf[centre], 0x12, "R channel");
  assert.strictEqual(buf[centre + 1], 0x56, "G channel");
  assert.strictEqual(buf[centre + 2], 0xA3, "B channel");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd daemon && npm run build 2>&1 | tail -20; node --test test/render-to-image.test.mjs`
Expected: FAIL — `render-to-image.ts` does not exist, build error or module-not-found.

- [ ] **Step 3: Write `daemon/src/render-to-image.ts`**

```typescript
import sharp from "sharp";

export async function renderSvgToRgba(svg: string, size: number): Promise<Buffer> {
  return sharp(Buffer.from(svg))
    .resize(size, size)
    .ensureAlpha()
    .raw()
    .toColourspace("srgb")
    .toBuffer();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd daemon && npm run build && node --test test/render-to-image.test.mjs`
Expected: both tests PASS. If the colour-channel test fails with swapped R/B, sharp's default
raw output for an sRGB source is RGBA in that channel order — check `.toColourspace("srgb")` is
present rather than reordering the assertions, since `fillKeyBuffer`'s expected channel order
(confirmed in Task 11) must match what this function actually produces.

- [ ] **Step 5: Commit**

```bash
cd daemon
git add src/render-to-image.ts test/render-to-image.test.mjs
git commit -m "feat(daemon): rasterize SVG key art to raw RGBA buffers"
```

---

### Task 3: Fleet state reader

**Files:**
- Create: `daemon/src/fleet-state.ts`
- Test: `daemon/test/fleet-state.test.mjs`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `readFleetHome(fleetHome: string): {slots: SlotsFile | null, armed: unknown | null}`,
  and `watchFleetHome(fleetHome: string, onChange: () => void): {stop: () => void}`. Tasks 7 and
  10 (slot-handler, verdict-handler) call `readFleetHome`; Task 11 (`index.ts`) calls
  `watchFleetHome` plus its own `setInterval` safety net, exactly mirroring `plugin.ts`'s
  `fs.watch(FLEET_HOME, ...)` + `setInterval(repaintAll, 1000)` pair.

- [ ] **Step 1: Write the failing test**

```javascript
// daemon/test/fleet-state.test.mjs
import assert from "node:assert";
import { test } from "node:test";
import { mkdtempSync, writeFileSync, renameSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readFleetHome, watchFleetHome } from "../dist/fleet-state.js";

test("returns null for both files when neither exists", () => {
  const dir = mkdtempSync(join(tmpdir(), "fleet-"));
  const result = readFleetHome(dir);
  assert.strictEqual(result.slots, null);
  assert.strictEqual(result.armed, null);
});

test("parses slots.json and armed.json when present", () => {
  const dir = mkdtempSync(join(tmpdir(), "fleet-"));
  writeFileSync(join(dir, "slots.json"), JSON.stringify({ slots: [], halted: false }));
  writeFileSync(join(dir, "armed.json"), JSON.stringify({ index: 2 }));
  const result = readFleetHome(dir);
  assert.deepStrictEqual(result.slots, { slots: [], halted: false });
  assert.deepStrictEqual(result.armed, { index: 2 });
});

test("mid-write / corrupt JSON is skipped, not thrown", () => {
  const dir = mkdtempSync(join(tmpdir(), "fleet-"));
  writeFileSync(join(dir, "slots.json"), "{not valid json");
  assert.doesNotThrow(() => readFleetHome(dir));
  assert.strictEqual(readFleetHome(dir).slots, null);
});

test("watchFleetHome fires on a rename-replace of slots.json", (t, done) => {
  const dir = mkdtempSync(join(tmpdir(), "fleet-"));
  const watch = watchFleetHome(dir, () => {
    watch.stop();
    done();
  });
  const tmpFile = join(dir, "slots.json.tmp");
  writeFileSync(tmpFile, "{}");
  renameSync(tmpFile, join(dir, "slots.json"));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd daemon && npm run build 2>&1 | tail -20; node --test test/fleet-state.test.mjs`
Expected: FAIL — module not found.

- [ ] **Step 3: Write `daemon/src/fleet-state.ts`**

```typescript
import { readFileSync, existsSync, watch, type FSWatcher } from "node:fs";
import { join } from "node:path";

function readJson<T>(path: string): T | null {
  try {
    if (!existsSync(path)) return null;
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch {
    return null; // mid-write or corrupt: skip this tick, matching plugin.ts's readJson
  }
}

export function readFleetHome(fleetHome: string): { slots: unknown | null; armed: unknown | null } {
  return {
    slots: readJson(join(fleetHome, "slots.json")),
    armed: readJson(join(fleetHome, "armed.json"))
  };
}

export function watchFleetHome(fleetHome: string, onChange: () => void): { stop: () => void } {
  const watcher: FSWatcher = watch(fleetHome, (_type, filename) => {
    if (filename === "slots.json" || filename === "armed.json") onChange();
  });
  return { stop: () => watcher.close() };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd daemon && npm run build && node --test test/fleet-state.test.mjs`
Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
cd daemon
git add src/fleet-state.ts test/fleet-state.test.mjs
git commit -m "feat(daemon): read and watch ~/.fleet state files"
```

---

### Task 4: Interpreter path resolution

**Files:**
- Create: `daemon/src/interpreter.ts`
- Test: `daemon/test/interpreter.test.mjs`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `resolveInterpreter(fleetHome: string): string` — the absolute pinned python3 path
  from `<fleetHome>/interpreter` if present and non-empty, else the literal `"python3"`. Task 5
  (`dispatch.ts`) calls this once at startup and passes the result into every `execFile` call.

- [ ] **Step 1: Write the failing test**

```javascript
// daemon/test/interpreter.test.mjs
import assert from "node:assert";
import { test } from "node:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveInterpreter } from "../dist/interpreter.js";

test("falls back to python3 when no pinned file exists", () => {
  const dir = mkdtempSync(join(tmpdir(), "fleet-"));
  assert.strictEqual(resolveInterpreter(dir), "python3");
});

test("uses the pinned interpreter path, trimmed", () => {
  const dir = mkdtempSync(join(tmpdir(), "fleet-"));
  writeFileSync(join(dir, "interpreter"), "/usr/local/bin/python3.11\n");
  assert.strictEqual(resolveInterpreter(dir), "/usr/local/bin/python3.11");
});

test("falls back to python3 when the pinned file is empty", () => {
  const dir = mkdtempSync(join(tmpdir(), "fleet-"));
  writeFileSync(join(dir, "interpreter"), "  \n");
  assert.strictEqual(resolveInterpreter(dir), "python3");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd daemon && npm run build 2>&1 | tail -20; node --test test/interpreter.test.mjs`
Expected: FAIL — module not found.

- [ ] **Step 3: Write `daemon/src/interpreter.ts`**

```typescript
import { readFileSync } from "node:fs";
import { join } from "node:path";

export function resolveInterpreter(fleetHome: string): string {
  try {
    const pinned = readFileSync(join(fleetHome, "interpreter"), "utf8").trim();
    if (pinned) return pinned;
  } catch {
    // no pinned file: fall through
  }
  return "python3";
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd daemon && npm run build && node --test test/interpreter.test.mjs`
Expected: all 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
cd daemon
git add src/interpreter.ts test/interpreter.test.mjs
git commit -m "feat(daemon): resolve the pinned python interpreter path"
```

---

### Task 5: Dispatch — press duration and the three `bin/` script wrappers

**Files:**
- Create: `daemon/src/dispatch.ts`
- Test: `daemon/test/dispatch.test.mjs`

**Interfaces:**
- Consumes: nothing from earlier tasks directly (takes an interpreter path as a plain string
  argument, produced by Task 4's `resolveInterpreter` at the call site in `index.ts`).
- Produces: `pressVerb(downAtMs: number, upAtMs: number): "short" | "long"`,
  `runFleetPress(interpreter: string, repoRoot: string, index: number, verb: "short"|"long"): Promise<number>`,
  `runFleetSend(interpreter: string, repoRoot: string, verb: string): Promise<number>`,
  `runFleetVerdict(interpreter: string, repoRoot: string, verdict: string, verb?: string): Promise<number>`.
  Every function resolves to the child process's exit code. Tasks 7, 9, and 10 call these three
  `run*` functions from their `onKeyUp` handlers.

- [ ] **Step 1: Write the failing test, using stub scripts instead of the real `bin/` scripts**

```javascript
// daemon/test/dispatch.test.mjs
import assert from "node:assert";
import { test } from "node:test";
import { mkdtempSync, writeFileSync, chmodSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  pressVerb, runFleetPress, runFleetSend, runFleetVerdict
} from "../dist/dispatch.js";

function makeStubRepo() {
  const repo = mkdtempSync(join(tmpdir(), "flightdeck-repo-"));
  writeFileSync(join(repo, "bin"), "", { flag: "a" }); // placeholder, replaced below
  return repo;
}

function writeStub(repo, name) {
  const binDir = join(repo, "bin");
  try { require("node:fs").mkdirSync(binDir); } catch { /* exists */ }
  const path = join(binDir, name);
  const logPath = join(binDir, `${name}.args.log`);
  writeFileSync(path, `#!/bin/sh\necho "$@" > "${logPath}"\nexit 0\n`);
  chmodSync(path, 0o755);
  return logPath;
}

test("pressVerb: under 800ms is short, at or over is long", () => {
  assert.strictEqual(pressVerb(1000, 1799), "short");
  assert.strictEqual(pressVerb(1000, 1800), "long");
  assert.strictEqual(pressVerb(1000, 2500), "long");
});

test("runFleetPress calls bin/fleet-press with index and verb as separate argv", async () => {
  const repo = mkdtempSync(join(tmpdir(), "flightdeck-repo-"));
  require("node:fs").mkdirSync(join(repo, "bin"));
  const logPath = writeStub(repo, "fleet-press");
  const code = await runFleetPress("/bin/sh", repo, 3, "long");
  assert.strictEqual(code, 0);
  assert.strictEqual(readFileSync(logPath, "utf8").trim(), "3 long");
});

test("runFleetSend calls bin/fleet-send with the verb as the sole argv", async () => {
  const repo = mkdtempSync(join(tmpdir(), "flightdeck-repo-"));
  require("node:fs").mkdirSync(join(repo, "bin"));
  const logPath = writeStub(repo, "fleet-send");
  const code = await runFleetSend("/bin/sh", repo, "test");
  assert.strictEqual(code, 0);
  assert.strictEqual(readFileSync(logPath, "utf8").trim(), "test");
});

test("runFleetVerdict omits the verb argv entirely when not given", async () => {
  const repo = mkdtempSync(join(tmpdir(), "flightdeck-repo-"));
  require("node:fs").mkdirSync(join(repo, "bin"));
  const logPath = writeStub(repo, "fleet-verdict");
  const code = await runFleetVerdict("/bin/sh", repo, "approve");
  assert.strictEqual(code, 0);
  assert.strictEqual(readFileSync(logPath, "utf8").trim(), "approve");
});

test("runFleetVerdict passes verb for steer", async () => {
  const repo = mkdtempSync(join(tmpdir(), "flightdeck-repo-"));
  require("node:fs").mkdirSync(join(repo, "bin"));
  const logPath = writeStub(repo, "fleet-verdict");
  const code = await runFleetVerdict("/bin/sh", repo, "steer", "justify");
  assert.strictEqual(code, 0);
  assert.strictEqual(readFileSync(logPath, "utf8").trim(), "steer justify");
});
```

Note: this test file uses CommonJS `require` inside ESM test files via Node's built-in
interop for `node:fs` only as a convenience — if that errors under `"type": "module"`, replace
each `require("node:fs").mkdirSync(...)` with a top-level `import { mkdirSync } from "node:fs"`
and call `mkdirSync` directly. Prefer the import form; it is shown inline here only to keep the
stub-writing helper terse.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd daemon && npm run build 2>&1 | tail -20; node --test test/dispatch.test.mjs`
Expected: FAIL — module not found.

- [ ] **Step 3: Write `daemon/src/dispatch.ts`**

```typescript
import { execFile } from "node:child_process";
import { join } from "node:path";

const LONG_PRESS_MS = 800; // matches config/fleet.json's timings.longPressMs

export function pressVerb(downAtMs: number, upAtMs: number): "short" | "long" {
  return upAtMs - downAtMs >= LONG_PRESS_MS ? "long" : "short";
}

function run(interpreter: string, script: string, args: string[]): Promise<number> {
  return new Promise((resolve) => {
    execFile(interpreter, [script, ...args], (_err, _stdout, _stderr) => {
      // exit code is what every fleet-* script's contract is defined on; err.code carries it
      // when non-zero, but a clean run has no err at all, so resolve 0 in that case.
      execFile(interpreter, [script, ...args]); // placeholder removed below
      resolve(0);
    });
  });
}

export function runFleetPress(
  interpreter: string, repoRoot: string, index: number, verb: "short" | "long"
): Promise<number> {
  return new Promise((resolve) => {
    execFile(interpreter, [join(repoRoot, "bin", "fleet-press"), String(index), verb], (err) => {
      resolve(err && "code" in err && typeof err.code === "number" ? err.code : 0);
    });
  });
}

export function runFleetSend(interpreter: string, repoRoot: string, verb: string): Promise<number> {
  return new Promise((resolve) => {
    execFile(interpreter, [join(repoRoot, "bin", "fleet-send"), verb], (err) => {
      resolve(err && "code" in err && typeof err.code === "number" ? err.code : 0);
    });
  });
}

export function runFleetVerdict(
  interpreter: string, repoRoot: string, verdict: string, verb?: string
): Promise<number> {
  const args = verb ? [verdict, verb] : [verdict];
  return new Promise((resolve) => {
    execFile(interpreter, [join(repoRoot, "bin", "fleet-verdict"), ...args], (err) => {
      resolve(err && "code" in err && typeof err.code === "number" ? err.code : 0);
    });
  });
}
```

Delete the stray `run()` helper and its placeholder double-call left in mid-draft above — it was
scaffolding while working out the exit-code plumbing and is not used by any exported function;
the three `runFleet*` functions each implement the same pattern directly and completely.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd daemon && npm run build && node --test test/dispatch.test.mjs`
Expected: all 6 tests PASS. `execFile`'s callback receives a non-null `err` whenever the child
exits non-zero — `err.code` is the exit code in that case; a clean exit (0) calls back with
`err === null`, which the `resolve(err && ... : 0)` ternary already handles.

- [ ] **Step 5: Commit**

```bash
cd daemon
git add src/dispatch.ts test/dispatch.test.mjs
git commit -m "feat(daemon): dispatch to fleet-press/fleet-send/fleet-verdict"
```

---

### Task 6: `keymap.json` loading

**Files:**
- Create: `daemon/config/keymap.json`
- Create: `daemon/src/keymap.ts`
- Test: `daemon/test/keymap.test.mjs`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  ```typescript
  type Row2Entry = string; // a verb id
  type Row3Entry = { verdict: string; verb?: string };
  type Keymap = { row2: Row2Entry[]; row3: Row3Entry[] };
  function loadKeymap(path: string): Keymap;
  ```
  `loadKeymap` never throws — malformed, partial, or missing files degrade to defaults matching
  the Global Constraints' Row 2/Row 3 defaults. Tasks 9 and 10 (`command-handler.ts`,
  `verdict-handler.ts`) index into `keymap.row2[col]` / `keymap.row3[col]` by column.

- [ ] **Step 1: Write `daemon/config/keymap.json`**

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

- [ ] **Step 2: Write the failing test**

```javascript
// daemon/test/keymap.test.mjs
import assert from "node:assert";
import { test } from "node:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadKeymap, DEFAULT_KEYMAP } from "../dist/keymap.js";

test("loads a well-formed keymap.json verbatim", () => {
  const dir = mkdtempSync(join(tmpdir(), "keymap-"));
  const path = join(dir, "keymap.json");
  const contents = { row2: ["stop"], row3: [{ verdict: "approve" }] };
  writeFileSync(path, JSON.stringify(contents));
  assert.deepStrictEqual(loadKeymap(path), contents);
});

test("missing file falls back to DEFAULT_KEYMAP", () => {
  const dir = mkdtempSync(join(tmpdir(), "keymap-"));
  assert.deepStrictEqual(loadKeymap(join(dir, "does-not-exist.json")), DEFAULT_KEYMAP);
});

test("malformed JSON falls back to DEFAULT_KEYMAP rather than throwing", () => {
  const dir = mkdtempSync(join(tmpdir(), "keymap-"));
  const path = join(dir, "keymap.json");
  writeFileSync(path, "{not valid");
  assert.doesNotThrow(() => loadKeymap(path));
  assert.deepStrictEqual(loadKeymap(path), DEFAULT_KEYMAP);
});

test("DEFAULT_KEYMAP matches the committed Row 2/Row 3 defaults", () => {
  assert.deepStrictEqual(DEFAULT_KEYMAP.row2,
    ["test", "diff", "note", "push", "pr", "review", "stop", "confirm"]);
  assert.strictEqual(DEFAULT_KEYMAP.row3.length, 8);
  assert.deepStrictEqual(DEFAULT_KEYMAP.row3[5], { verdict: "steer", verb: "justify" });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd daemon && npm run build 2>&1 | tail -20; node --test test/keymap.test.mjs`
Expected: FAIL — module not found.

- [ ] **Step 4: Write `daemon/src/keymap.ts`**

```typescript
import { readFileSync, existsSync } from "node:fs";

export type Row3Entry = { verdict: string; verb?: string };
export type Keymap = { row2: string[]; row3: Row3Entry[] };

export const DEFAULT_KEYMAP: Keymap = {
  row2: ["test", "diff", "note", "push", "pr", "review", "stop", "confirm"],
  row3: [
    { verdict: "detail" },
    { verdict: "approve" },
    { verdict: "remember" },
    { verdict: "deny" },
    { verdict: "interrupt" },
    { verdict: "steer", verb: "justify" },
    { verdict: "steer", verb: "otherway" },
    { verdict: "steer", verb: "dryrun" }
  ]
};

export function loadKeymap(path: string): Keymap {
  try {
    if (!existsSync(path)) return DEFAULT_KEYMAP;
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    if (!Array.isArray(parsed.row2) || !Array.isArray(parsed.row3)) return DEFAULT_KEYMAP;
    return parsed as Keymap;
  } catch {
    return DEFAULT_KEYMAP;
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd daemon && npm run build && node --test test/keymap.test.mjs`
Expected: all 4 tests PASS.

- [ ] **Step 6: Commit**

```bash
cd daemon
git add config/keymap.json src/keymap.ts test/keymap.test.mjs
git commit -m "feat(daemon): load Row 2/Row 3 key assignment from keymap.json"
```

---

### Task 7: Slot handler (Row 1)

**Files:**
- Create: `daemon/src/slot-handler.ts`
- Test: `daemon/test/slot-handler.test.mjs`

**Interfaces:**
- Consumes: `readFleetHome` from `fleet-state.ts` (Task 3), `renderSvg` and `toDataUri`-adjacent
  raw-SVG production from `../../plugin/src/render.ts` (imported directly, unmodified),
  `keyIndexToRowCol` from `row-math.ts` (Task 1).
- Produces: `paintSlot(fleetHome: string, config: Config, keyIndex: number): string` — an SVG
  string for one Row 1 key. Task 11 (`index.ts`) calls this for every key whose
  `keyIndexToRowCol(index).row === 0` and passes the result into `renderSvgToRgba` (Task 2).

- [ ] **Step 1: Write the failing test**

```javascript
// daemon/test/slot-handler.test.mjs
import assert from "node:assert";
import { test } from "node:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { paintSlot } from "../dist/slot-handler.js";

const CONFIG = {
  states: {
    working: { color: "#1256A3", glyph: "working", glyphColor: "#FFFFFFCC", textColor: "#FFFFFF" },
    empty:   { color: "#000000", glyph: "none",    glyphColor: "#000000",  textColor: "#000000" },
    armed:   { color: "#0A0A0A", glyph: "armed",   glyphColor: "#F5A623",  textColor: "#F5A623" }
  }
};

test("an empty slots.json paints every Row 1 key as empty (black, no text)", () => {
  const dir = mkdtempSync(join(tmpdir(), "fleet-"));
  writeFileSync(join(dir, "slots.json"), JSON.stringify({ slots: [] }));
  const svg = paintSlot(dir, CONFIG, 3); // key index 3 = row 0, col 3
  assert.ok(svg.includes("#000000"));
});

test("a populated slot at the matching column renders its lifecycle colour", () => {
  const dir = mkdtempSync(join(tmpdir(), "fleet-"));
  const slots = { slots: [
    { index: 3, state: "working", label_top: "flightdeck", label_bottom: "main", session_id: "S1" }
  ] };
  writeFileSync(join(dir, "slots.json"), JSON.stringify(slots));
  const svg = paintSlot(dir, CONFIG, 3);
  assert.ok(svg.includes("#1256A3"));
});

test("armed.json for this index overrides to the armed face", () => {
  const dir = mkdtempSync(join(tmpdir(), "fleet-"));
  const slots = { slots: [{ index: 3, state: "working", label_top: "", label_bottom: "" }] };
  writeFileSync(join(dir, "slots.json"), JSON.stringify(slots));
  writeFileSync(join(dir, "armed.json"), JSON.stringify({ index: 3 }));
  const svg = paintSlot(dir, CONFIG, 3);
  assert.ok(svg.includes("CONFIRM"));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd daemon && npm run build 2>&1 | tail -20; node --test test/slot-handler.test.mjs`
Expected: FAIL — module not found.

- [ ] **Step 3: Write `daemon/src/slot-handler.ts`**

```typescript
import { renderSvg } from "../../plugin/src/render.js";
import type { Config, Slot } from "../../plugin/src/types.js";
import { readFleetHome } from "./fleet-state.js";
import { keyIndexToRowCol } from "./row-math.js";

const EMPTY = (index: number): Slot => ({
  index, state: "empty", label_top: "", label_bottom: "",
  session_id: "", host: "", iterm_session: "", cwd: "", app: "",
  focused: false, permission_mode: ""
});

export function paintSlot(fleetHome: string, config: Config, keyIndex: number): string {
  const { col } = keyIndexToRowCol(keyIndex);
  const { slots, armed } = readFleetHome(fleetHome);
  const slotsList = (slots as { slots?: Slot[]; halted?: boolean } | null)?.slots ?? [];
  const slot = slotsList.find((s) => s.index === col) ?? EMPTY(col);
  const armedFile = armed as { index?: number } | null;
  const isArmed = armedFile?.index === col;
  const halted = Boolean((slots as { halted?: boolean } | null)?.halted);
  return renderSvg(slot, config, isArmed, slot.permission_mode, halted);
}
```

Note: this imports `render.js`/`types.js` (the compiled `.js` extensions), not `render.ts` — the
daemon's rollup config (Task 1) compiles TypeScript with the source's own `.ts` extension in the
import specifier resolved by the TypeScript compiler's module resolution; if the build reports an
extension-resolution error here, change the import to `../../plugin/src/render` (no extension)
and let `moduleResolution: "Bundler"` from Task 1's `tsconfig.json` resolve it — this is a real
toolchain detail to confirm against the actual build output, not a stylistic choice.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd daemon && npm run build && node --test test/slot-handler.test.mjs`
Expected: all 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
cd daemon
git add src/slot-handler.ts test/slot-handler.test.mjs
git commit -m "feat(daemon): paint Row 1 Fleet Slot keys from ~/.fleet state"
```

---

### Task 8: Boot handler (filler tiles)

**Files:**
- Create: `daemon/src/boot-handler.ts`
- Test: none — this is a two-line pass-through and is covered end-to-end by Task 11's manual
  hardware check; a unit test here would just re-assert that `splashTileSvg`/`nightTileSvg`
  (already tested by the reused `render.test.mjs`) were called, which adds no real coverage.

**Interfaces:**
- Consumes: `nightTileSvg` from `../../plugin/src/splash.ts` (imported directly, unmodified),
  `keyIndexToRowCol` from `row-math.ts` (Task 1).
- Produces: `paintBootTile(keyIndex: number): string`. Task 11 calls this for any key with no
  `slot`/`command`/`verdict` assignment.

- [ ] **Step 1: Write `daemon/src/boot-handler.ts`**

```typescript
import { nightTileSvg } from "../../plugin/src/splash.js";
import { keyIndexToRowCol } from "./row-math.js";

export function paintBootTile(keyIndex: number): string {
  const { row, col } = keyIndexToRowCol(keyIndex);
  return nightTileSvg(row, col);
}
```

- [ ] **Step 2: Build and confirm no compile errors**

Run: `cd daemon && npm run build`
Expected: succeeds with no errors. There is no runtime assertion for this task beyond compiling —
see the note in Files above for why.

- [ ] **Step 3: Commit**

```bash
cd daemon
git add src/boot-handler.ts
git commit -m "feat(daemon): paint filler tiles for unassigned keys"
```

---

### Task 9: Command handler (Row 2)

**Files:**
- Create: `daemon/src/command-handler.ts`
- Test: `daemon/test/command-handler.test.mjs`

**Interfaces:**
- Consumes: `renderCommandSvg` from `../../plugin/src/command.ts` (unmodified),
  `runFleetSend` from `dispatch.ts` (Task 5), `Keymap` from `keymap.ts` (Task 6),
  `keyIndexToRowCol` from `row-math.ts` (Task 1).
- Produces:
  ```typescript
  function paintCommandIdle(keymap: Keymap, keyIndex: number): string;
  function handleCommandKeyUp(
    interpreter: string, repoRoot: string, keymap: Keymap, keyIndex: number
  ): Promise<string>; // resolves to the feedback-face SVG to paint immediately
  ```
  Task 11 calls `paintCommandIdle` on every repaint tick and `handleCommandKeyUp` on a key-up
  event, then schedules a restore-to-idle repaint after the feedback window (1200ms, or 9000ms
  if the outcome was `"armed"` — matching `config/fleet.json`'s `timings.verbArmSecs`).

- [ ] **Step 1: Write the failing test**

```javascript
// daemon/test/command-handler.test.mjs
import assert from "node:assert";
import { test } from "node:test";
import { mkdtempSync, mkdirSync, writeFileSync, chmodSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { paintCommandIdle, handleCommandKeyUp } from "../dist/command-handler.js";

const KEYMAP = { row2: ["test", "diff"], row3: [] };

test("paints the idle face for the verb bound to this key's column", () => {
  const svg = paintCommandIdle(KEYMAP, 8); // row 1, col 0 -> "test"
  assert.ok(svg.includes("TEST"));
});

test("an unbound column paints the refused/idle-empty face, not a crash", () => {
  assert.doesNotThrow(() => paintCommandIdle(KEYMAP, 15)); // row 1, col 7 -> no entry
});

test("key-up runs fleet-send with the bound verb and returns a feedback face", async () => {
  const repo = mkdtempSync(join(tmpdir(), "flightdeck-repo-"));
  mkdirSync(join(repo, "bin"));
  const script = join(repo, "bin", "fleet-send");
  const logPath = join(repo, "bin", "fleet-send.args.log");
  writeFileSync(script, `#!/bin/sh\necho "$@" > "${logPath}"\nexit 0\n`);
  chmodSync(script, 0o755);

  const svg = await handleCommandKeyUp("/bin/sh", repo, KEYMAP, 8);
  assert.strictEqual(readFileSync(logPath, "utf8").trim(), "test");
  assert.ok(svg.includes("TEST"));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd daemon && npm run build 2>&1 | tail -20; node --test test/command-handler.test.mjs`
Expected: FAIL — module not found.

- [ ] **Step 3: Write `daemon/src/command-handler.ts`**

```typescript
import { renderCommandSvg } from "../../plugin/src/command.js";
import { runFleetSend } from "./dispatch.js";
import type { Keymap } from "./keymap.js";
import { keyIndexToRowCol } from "./row-math.js";

function verbForKey(keymap: Keymap, keyIndex: number): string | undefined {
  const { row, col } = keyIndexToRowCol(keyIndex);
  if (row !== 1) return undefined;
  return keymap.row2[col];
}

export function paintCommandIdle(keymap: Keymap, keyIndex: number): string {
  const verb = verbForKey(keymap, keyIndex);
  return renderCommandSvg(verb ? verb.toUpperCase() : "", "");
}

export async function handleCommandKeyUp(
  interpreter: string, repoRoot: string, keymap: Keymap, keyIndex: number
): Promise<string> {
  const verb = verbForKey(keymap, keyIndex);
  if (!verb) return renderCommandSvg("", "refused");

  const exitCode = await runFleetSend(interpreter, repoRoot, verb);
  const outcome = exitCode === 0 ? "queued" : exitCode === 2 ? "armed" : "refused";
  return renderCommandSvg(verb.toUpperCase(), outcome);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd daemon && npm run build && node --test test/command-handler.test.mjs`
Expected: all 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
cd daemon
git add src/command-handler.ts test/command-handler.test.mjs
git commit -m "feat(daemon): Row 2 Command handler dispatching to fleet-send"
```

---

### Task 10: Verdict handler (Row 3)

**Files:**
- Create: `daemon/src/verdict-handler.ts`
- Test: `daemon/test/verdict-handler.test.mjs`

**Interfaces:**
- Consumes: `renderVerdictSvg`, `renderDetailFeedback`, `verdictLabel` (and the `Feedback` type)
  from `../../plugin/src/verdict.ts` (unmodified), `VerdictTarget`/`SlotsFile` types from
  `../../plugin/src/types.ts`, `runFleetVerdict` from `dispatch.ts` (Task 5), `readFleetHome`
  from `fleet-state.ts` (Task 3), `Keymap`/`Row3Entry` from `keymap.ts` (Task 6),
  `keyIndexToRowCol` from `row-math.ts` (Task 1).
- **Verified directly against `plugin/src/verdict.ts` and `plugin/src/plugin.ts`'s real `Verdict`
  action** (not assumed): the real signature is
  `renderVerdictSvg(label: string, tier: string, feedback: Feedback, active: boolean, armedScope?: ArmedScope | null): string`
  — nothing like a `(verdict, target, outcome, verb)` shape. `plugin.ts`'s own `Verdict.render()`
  method computes `active`/`tier`/`scope` from a `VerdictTarget | null` and calls
  `renderVerdictSvg(verdictLabel(verdict, verb), tier, feedback, active, scope)`. `VerdictTarget`
  (from `types.ts`) carries `tier: string`, `repo?: string`, `rule?: string` among other fields;
  it comes from `SlotsFile.verdict` — i.e. the SAME `slots.json` Task 3's `readFleetHome` already
  reads, under a `verdict` key, not from any separate file. `verdict === "detail"` is special: it
  never calls `renderVerdictSvg` at all, only `renderDetailFeedback(target, feedback)`, for both
  its idle and its feedback states. The implementation below mirrors `plugin.ts`'s `render()`
  method exactly, ported from the SDK-driven code to a plain function.
- Produces:
  ```typescript
  function paintVerdictIdle(fleetHome: string, keymap: Keymap, keyIndex: number): string;
  function handleVerdictKeyUp(
    interpreter: string, repoRoot: string, fleetHome: string, keymap: Keymap, keyIndex: number
  ): Promise<string>;
  ```
  Same calling convention as Task 9's command handler: Task 11 calls `paintVerdictIdle` on every
  repaint tick and `handleVerdictKeyUp` on key-up, scheduling the same 1200ms/9000ms restore.

- [ ] **Step 1: Write the failing test**

```javascript
// daemon/test/verdict-handler.test.mjs
import assert from "node:assert";
import { test } from "node:test";
import { mkdtempSync, mkdirSync, writeFileSync, chmodSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { paintVerdictIdle, handleVerdictKeyUp } from "../dist/verdict-handler.js";

const KEYMAP = {
  row2: [],
  row3: [
    { verdict: "detail" }, { verdict: "approve" }, { verdict: "remember" }, { verdict: "deny" },
    { verdict: "interrupt" }, { verdict: "steer", verb: "justify" },
    { verdict: "steer", verb: "otherway" }, { verdict: "steer", verb: "dryrun" }
  ]
};

test("paints APPROVE's idle face at column 1 of row 2 (key index 17)", () => {
  const dir = mkdtempSync(join(tmpdir(), "fleet-"));
  writeFileSync(join(dir, "slots.json"), JSON.stringify({ slots: [] }));
  const svg = paintVerdictIdle(dir, KEYMAP, 17);
  assert.ok(svg.includes("APPROVE"));
});

test("a steer key is labelled by its verb, never the word STEER", () => {
  const dir = mkdtempSync(join(tmpdir(), "fleet-"));
  writeFileSync(join(dir, "slots.json"), JSON.stringify({ slots: [] }));
  const svg = paintVerdictIdle(dir, KEYMAP, 21); // row 2 col 5 -> steer/justify
  assert.ok(svg.includes("JUSTIFY"));
  assert.ok(!svg.includes(">STEER<"));
});

test("key-up with no pending target runs fleet-verdict and reports refused", async () => {
  const repo = mkdtempSync(join(tmpdir(), "flightdeck-repo-"));
  mkdirSync(join(repo, "bin"));
  const script = join(repo, "bin", "fleet-verdict");
  const logPath = join(repo, "bin", "fleet-verdict.args.log");
  // exit 1: refused, matching fleet-verdict's contract with no pending record
  writeFileSync(script, `#!/bin/sh\necho "$@" > "${logPath}"\nexit 1\n`);
  chmodSync(script, 0o755);
  const dir = mkdtempSync(join(tmpdir(), "fleet-"));
  writeFileSync(join(dir, "slots.json"), JSON.stringify({ slots: [] }));

  const svg = await handleVerdictKeyUp("/bin/sh", repo, dir, KEYMAP, 18); // remember
  assert.strictEqual(readFileSync(logPath, "utf8").trim(), "remember");
  assert.ok(svg.length > 0);
});

test("a steer key passes its verb as the second argv to fleet-verdict", async () => {
  const repo = mkdtempSync(join(tmpdir(), "flightdeck-repo-"));
  mkdirSync(join(repo, "bin"));
  const script = join(repo, "bin", "fleet-verdict");
  const logPath = join(repo, "bin", "fleet-verdict.args.log");
  writeFileSync(script, `#!/bin/sh\necho "$@" > "${logPath}"\nexit 0\n`);
  chmodSync(script, 0o755);
  const dir = mkdtempSync(join(tmpdir(), "fleet-"));
  writeFileSync(join(dir, "slots.json"), JSON.stringify({ slots: [] }));

  await handleVerdictKeyUp("/bin/sh", repo, dir, KEYMAP, 21); // steer/justify
  assert.strictEqual(readFileSync(logPath, "utf8").trim(), "steer justify");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd daemon && npm run build 2>&1 | tail -20; node --test test/verdict-handler.test.mjs`
Expected: FAIL — module not found.

- [ ] **Step 3: Write `daemon/src/verdict-handler.ts`**

```typescript
import { renderVerdictSvg, renderDetailFeedback, verdictLabel, type Feedback } from "../../plugin/src/verdict";
import type { VerdictTarget, SlotsFile } from "../../plugin/src/types";
import { runFleetVerdict } from "./dispatch";
import { readFleetHome } from "./fleet-state";
import type { Keymap, Row3Entry } from "./keymap";
import { keyIndexToRowCol } from "./row-math";

function entryForKey(keymap: Keymap, keyIndex: number): Row3Entry | undefined {
  const { row, col } = keyIndexToRowCol(keyIndex);
  if (row !== 2) return undefined;
  return keymap.row3[col];
}

function targetFrom(fleetHome: string): VerdictTarget | null {
  const { slots } = readFleetHome(fleetHome);
  return (slots as SlotsFile | null)?.verdict ?? null;
}

// Mirrors plugin.ts's Verdict.render() exactly: DETAIL never touches renderVerdictSvg at all,
// every other verdict computes active/tier/scope from the target and calls it with the real
// 5-argument shape.
function render(entry: Row3Entry, target: VerdictTarget | null, feedback: Feedback): string {
  if (entry.verdict === "detail") return renderDetailFeedback(target, feedback);
  const active = target !== null;
  const tier = target?.tier ?? "normal";
  const scope = entry.verdict === "remember"
    ? { repo: target?.repo ?? "", rule: target?.rule ?? "" }
    : null;
  return renderVerdictSvg(verdictLabel(entry.verdict, entry.verb ?? ""), tier, feedback, active, scope);
}

export function paintVerdictIdle(fleetHome: string, keymap: Keymap, keyIndex: number): string {
  const entry = entryForKey(keymap, keyIndex);
  if (!entry) return renderVerdictSvg("", "normal", "refused", false, null);
  return render(entry, targetFrom(fleetHome), "");
}

export async function handleVerdictKeyUp(
  interpreter: string, repoRoot: string, fleetHome: string, keymap: Keymap, keyIndex: number
): Promise<string> {
  const entry = entryForKey(keymap, keyIndex);
  if (!entry) return renderVerdictSvg("", "normal", "refused", false, null);

  const exitCode = await runFleetVerdict(interpreter, repoRoot, entry.verdict, entry.verb);
  const outcome: Feedback = exitCode === 0 ? "delivered" : exitCode === 2 ? "armed" : "refused";
  const target = targetFrom(fleetHome);

  if (entry.verdict === "detail") {
    return outcome !== "delivered"
      ? renderDetailFeedback(target, "refused")
      : renderDetailFeedback(target, "");
  }
  return render(entry, target, outcome);
}
```

This corrects an earlier draft of this task that assumed a `renderVerdictSvg(verdict, target,
outcome, verb)` shape — verified wrong by reading `plugin/src/verdict.ts` and
`plugin/src/plugin.ts`'s real `Verdict` action directly before this task was dispatched. The
`target()`/`render()` logic above is a direct, unmodified-in-meaning port of `plugin.ts`'s own
`private target()` and `private render()` methods (lines ~533-552 as of this writing) from
class-method form to plain exported functions — same computation, same special-casing of
`detail` and `remember`, same `tier`/`active`/`scope` derivation.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd daemon && npm run build && node --test test/verdict-handler.test.mjs`
Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
cd daemon
git add src/verdict-handler.ts test/verdict-handler.test.mjs
git commit -m "feat(daemon): Row 3 Verdict handler dispatching to fleet-verdict"
```

---

### Task 11: Entrypoint — wire the HID device to the four handlers

**Files:**
- Create: `daemon/src/index.ts`

**Interfaces:**
- Consumes: everything from Tasks 1–10 (`row-math.ts`, `render-to-image.ts`, `fleet-state.ts`,
  `interpreter.ts`, `dispatch.ts`, `keymap.ts`, `slot-handler.ts`, `boot-handler.ts`,
  `command-handler.ts`, `verdict-handler.ts`).
- Produces: nothing further consumed by another task — this is the process entrypoint.

This task has no automated test: it requires the physical Stream Deck XL plugged in. Verification
is the manual hardware check in Step 5.

- [ ] **Step 1: Confirm the installed HID library's exact image-push method**

Run: `cat daemon/node_modules/@elgato-stream-deck/node/dist/*.d.ts | grep -A3 -i "fillKey"`
Expected output: a method on the device instance such as `fillKeyBuffer(keyIndex: number, buffer: Buffer, options: {format: "rgb" | "rgba"}): Promise<void>`. Note the exact method name, its
image-buffer channel order, and whether it wants the buffer at `device.ICON_SIZE` or something
you must resize to yourself — Task 2's `renderSvgToRgba(svg, size)` already takes an arbitrary
`size`, so pass whatever `device.ICON_SIZE` reports. Use the confirmed method name and channel
order in Step 2 below instead of the placeholder shown; if the installed version instead exposes
`fillKeyPNG`/`fillKeyJPEG` rather than a raw buffer, adjust Step 2's push logic to call `sharp`'s
`.png()`/`.jpeg()` output instead of `.raw()` and skip `renderSvgToRgba` for that call site.

- [ ] **Step 2: Write `daemon/src/index.ts`**

```typescript
import { openStreamDeck, listStreamDecks } from "@elgato-stream-deck/node";
import { homedir } from "node:os";
import { join } from "node:path";
import { readFileSync, existsSync } from "node:fs";
import { renderSvgToRgba } from "./render-to-image.js";
import { watchFleetHome } from "./fleet-state.js";
import { resolveInterpreter } from "./interpreter.js";
import { pressVerb, runFleetPress } from "./dispatch.js";
import { loadKeymap } from "./keymap.js";
import { paintSlot } from "./slot-handler.js";
import { paintBootTile } from "./boot-handler.js";
import { paintCommandIdle, handleCommandKeyUp } from "./command-handler.js";
import { paintVerdictIdle, handleVerdictKeyUp } from "./verdict-handler.js";
import { keyIndexToRowCol } from "./row-math.js";
import type { Config } from "../../plugin/src/types.js";

const FLEET_HOME = join(homedir(), ".fleet");
const REPO = process.env.FLIGHTDECK_REPO ?? join(homedir(), "repos", "flightdeck");
const KEYMAP_PATH = process.env.FLIGHTDECK_KEYMAP ?? join(REPO, "daemon", "config", "keymap.json");

function loadConfig(): Config {
  const path = join(REPO, "config", "fleet.json");
  const localPath = join(REPO, "config", "fleet.local.json");
  const base = existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : { states: {} };
  const local = existsSync(localPath) ? JSON.parse(readFileSync(localPath, "utf8")) : {};
  return { states: { ...(base.states ?? {}), ...(local.states ?? {}) } };
}

async function main() {
  const devices = await listStreamDecks();
  if (devices.length !== 1) {
    throw new Error(
      `expected exactly one Stream Deck, found ${devices.length}. ` +
      `Plug in exactly one XL and retry.`
    );
  }
  const device = await openStreamDeck(devices[0].path);
  const interpreter = resolveInterpreter(FLEET_HOME);
  const config = loadConfig();
  const keymap = loadKeymap(KEYMAP_PATH);
  const downAt = new Map<number, number>();

  async function paintKey(index: number): Promise<void> {
    const { row } = keyIndexToRowCol(index);
    const svg = row === 0 ? paintSlot(FLEET_HOME, config, index)
      : row === 1 ? paintCommandIdle(keymap, index)
      : row === 2 ? paintVerdictIdle(FLEET_HOME, keymap, index)
      : paintBootTile(index);
    const buffer = await renderSvgToRgba(svg, device.ICON_SIZE);
    await device.fillKeyBuffer(index, buffer, { format: "rgba" });
  }

  async function repaintAll(): Promise<void> {
    for (let i = 0; i < device.NUM_KEYS; i++) await paintKey(i);
  }

  watchFleetHome(FLEET_HOME, () => { repaintAll().catch(console.error); });
  setInterval(() => { repaintAll().catch(console.error); }, 1000);

  device.on("down", (index: number) => downAt.set(index, Date.now()));
  device.on("up", async (index: number) => {
    const startedAt = downAt.get(index) ?? Date.now();
    downAt.delete(index);
    const { row } = keyIndexToRowCol(index);
    const verb = pressVerb(startedAt, Date.now());

    let feedbackSvg: string | null = null;
    if (row === 0) {
      const { col } = keyIndexToRowCol(index);
      await runFleetPress(interpreter, REPO, col, verb);
    } else if (row === 1) {
      feedbackSvg = await handleCommandKeyUp(interpreter, REPO, keymap, index);
    } else if (row === 2) {
      feedbackSvg = await handleVerdictKeyUp(interpreter, REPO, FLEET_HOME, keymap, index);
    }

    if (feedbackSvg) {
      const buffer = await renderSvgToRgba(feedbackSvg, device.ICON_SIZE);
      await device.fillKeyBuffer(index, buffer, { format: "rgba" });
      setTimeout(() => { paintKey(index).catch(console.error); }, 1200);
    } else {
      await paintKey(index);
    }
  });

  device.on("error", (err: unknown) => {
    console.error("Stream Deck HID error, exiting for launchd to restart:", err);
    process.exit(1);
  });

  await repaintAll();
  console.log("flightdeck daemon running against", devices[0].path);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
```

- [ ] **Step 3: Build**

Run: `cd daemon && npm run build`
Expected: succeeds. Fix any compile error surfaced by Step 1's real method signature not
matching the placeholder above before moving on — this is the one file in the whole plan whose
correctness depends on an external package's actual shipped API rather than on this repo's own
code, so a compile error here is expected to require a small adjustment, not a sign the plan is
wrong.

- [ ] **Step 4: Smoke-test against the real device**

Run: `cd daemon && FLIGHTDECK_REPO=$(cd .. && pwd) node dist/index.js`
Expected: logs `flightdeck daemon running against <path>`, and the physical Row 1 keys light up
matching whatever's currently in `~/.fleet/slots.json` (or all-black if that file doesn't exist
yet — start `fleet-reconcile` or write a fixture `slots.json` by hand first if you want to see a
populated key). Row 2 shows the eight default verb labels. Row 3 shows DETAIL/APPROVE/REMEMBER/
DENY/INTERRUPT/JUSTIFY/OTHERWAY/DRYRUN.

- [ ] **Step 5: Manual hardware verification of press behavior**

Press and quickly release a Row 1 key with a live slot: the terminal for that session should
focus (via `fleet-focus`), matching what `bin/fleet-press <index> short` does when run by hand.
Hold a Row 1 key for over a second: it should show the armed/CONFIRM face. Press a Row 2 key:
it should show a feedback face (queued/refused) for about 1.2 seconds then revert. This is the
same manual check `fleet-doctor` already documents for the Elgato-app plugin path — there is no
new verification concept here, only a new transport to point it at.

- [ ] **Step 6: Commit**

```bash
cd daemon
git add src/index.ts
git commit -m "feat(daemon): wire HID device events to the four key handlers"
```

---

### Task 12: `install-daemon.sh` and the launchd job

**Files:**
- Create: `daemon/install-daemon.sh`
- Create: `daemon/launchd/com.louisalexander.flightdeck.daemon.plist`

**Interfaces:**
- Consumes: the built `daemon/dist/index.js` from Task 11.
- Produces: a loaded launchd job. No later task depends on this one's interfaces — it's the
  last task in the plan.

- [ ] **Step 1: Write `daemon/launchd/com.louisalexander.flightdeck.daemon.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.louisalexander.flightdeck.daemon</string>
  <key>ProgramArguments</key>
  <array>
    <string>__NODE__</string>
    <string>__REPO__/daemon/dist/index.js</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FLIGHTDECK_REPO</key><string>__REPO__</string>
  </dict>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>__HOME__/.fleet/daemon.err.log</string>
  <key>StandardOutPath</key><string>__HOME__/.fleet/daemon.out.log</string>
</dict>
</plist>
```

- [ ] **Step 2: Write `daemon/install-daemon.sh`**

```bash
#!/usr/bin/env bash
set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON_DIR="$REPO_ROOT/daemon"
NODE_BIN="$(command -v node)"
if [ -z "$NODE_BIN" ]; then
  echo "error: node not found on PATH" >&2
  exit 1
fi

echo "==> checking native dependencies"
if ! node -e "require('sharp')" 2>/dev/null; then
  echo "error: sharp did not load. Run 'npm install' inside daemon/ and check for a" >&2
  echo "       prebuilt-binary download failure before continuing." >&2
  exit 1
fi
if ! node -e "require('@elgato-stream-deck/node')" 2>/dev/null; then
  echo "error: @elgato-stream-deck/node did not load. Run 'npm install' inside daemon/." >&2
  exit 1
fi

echo "==> checking HID device access"
if ! node -e "
  const { listStreamDecks } = require('@elgato-stream-deck/node');
  listStreamDecks().then((devices) => {
    if (devices.length === 0) {
      console.error('no Stream Deck found — plug it in and retry');
      process.exit(1);
    }
    console.log('found', devices.length, 'device(s)');
  }).catch((err) => { console.error('HID open failed:', err); process.exit(1); });
"; then
  echo "error: could not enumerate HID devices. On macOS this can be a permission" >&2
  echo "       prompt hidden behind another window rather than a real absence — check" >&2
  echo "       System Settings > Privacy & Security before assuming the device is gone." >&2
  exit 1
fi

echo "==> building daemon"
(cd "$DAEMON_DIR" && npm install --silent && npm run build --silent)

echo "==> installing launchd job"
PLIST_SRC="$DAEMON_DIR/launchd/com.louisalexander.flightdeck.daemon.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.louisalexander.flightdeck.daemon.plist"
sed -e "s|__NODE__|$NODE_BIN|g" -e "s|__REPO__|$REPO_ROOT|g" -e "s|__HOME__|$HOME|g" \
  "$PLIST_SRC" > "$PLIST_DST"

launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"

echo "==> done. Tail $HOME/.fleet/daemon.out.log and daemon.err.log to confirm it's running."
```

- [ ] **Step 3: Make it executable**

Run: `chmod +x daemon/install-daemon.sh`

- [ ] **Step 4: Run it**

Run: `./daemon/install-daemon.sh`
Expected: each `==>` step prints and succeeds, ending in "done." Check
`launchctl list | grep flightdeck` shows `com.louisalexander.flightdeck.daemon`, and
`~/.fleet/daemon.out.log` contains the "flightdeck daemon running against ..." line from
Task 11.

- [ ] **Step 5: Commit**

```bash
cd daemon
git add install-daemon.sh launchd/com.louisalexander.flightdeck.daemon.plist
git commit -m "feat(daemon): install-daemon.sh and launchd job, independent of install.sh"
```

---

## Self-Review Notes

- **Spec coverage:** Decision 1 (location) → file structure + Global Constraints. Decision 2
  (transport library) → Task 1's dependency + Task 11. Decision 3 (`keymap.json`) → Tasks 6, 9,
  10. Decision 4 (no PI channel) → Task 6's `loadKeymap` being the sole settings source. Decision
  5 (repaint/dispatch parity) → Tasks 3, 5, 7, 9, 10 mirroring `plugin.ts` exactly. Decision 6
  (launchd, separate install) → Task 12. The "First slice" ordering in the spec (Row 1 hardcoded
  first, generalize after) is intentionally *not* replicated task-for-task here: since the reused
  pure modules and dispatch layer are fully unit-testable without hardware, this plan builds
  every piece bottom-up with tests first and defers the one truly hardware-dependent step
  (Task 11) to last, which reaches the same "prove the transport early, cheaply" goal the spec's
  first slice was after, without a throwaway hardcoded version to delete afterward.
- **Placeholder scan:** Task 5's first `run()` draft is deliberately shown mid-correction and
  explicitly instructed to be deleted in the same step, not left as a TBD — flagged for the
  implementer rather than silently omitted, since dispatch's exit-code plumbing is worth showing
  the reasoning for.
- **Type consistency:** `Keymap`/`Row3Entry` (Task 6) are the same shape used in Tasks 9, 10, and
  11. `pressVerb`, `runFleetPress`, `runFleetSend`, `runFleetVerdict` (Task 5) are used with
  matching signatures in Tasks 7, 9, 10, 11. `paintSlot`/`paintCommandIdle`/`paintVerdictIdle`/
  `paintBootTile` all take `(…, keyIndex: number)` last and return `string`, matching how Task 11
  dispatches on `row` to pick one.

---

Plan complete and saved to `docs/superpowers/plans/2026-08-31-flightdeck-hid-daemon.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
