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
