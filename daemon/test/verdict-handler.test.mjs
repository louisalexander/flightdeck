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
