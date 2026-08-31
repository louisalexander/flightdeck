import assert from "node:assert";
import { test } from "node:test";
import { mkdtempSync, writeFileSync, chmodSync, readFileSync, mkdirSync } from "node:fs";
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
  try { mkdirSync(binDir); } catch { /* exists */ }
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
  mkdirSync(join(repo, "bin"));
  const logPath = writeStub(repo, "fleet-press");
  const code = await runFleetPress("/bin/sh", repo, 3, "long");
  assert.strictEqual(code, 0);
  assert.strictEqual(readFileSync(logPath, "utf8").trim(), "3 long");
});

test("runFleetSend calls bin/fleet-send with the verb as the sole argv", async () => {
  const repo = mkdtempSync(join(tmpdir(), "flightdeck-repo-"));
  mkdirSync(join(repo, "bin"));
  const logPath = writeStub(repo, "fleet-send");
  const code = await runFleetSend("/bin/sh", repo, "test");
  assert.strictEqual(code, 0);
  assert.strictEqual(readFileSync(logPath, "utf8").trim(), "test");
});

test("runFleetVerdict omits the verb argv entirely when not given", async () => {
  const repo = mkdtempSync(join(tmpdir(), "flightdeck-repo-"));
  mkdirSync(join(repo, "bin"));
  const logPath = writeStub(repo, "fleet-verdict");
  const code = await runFleetVerdict("/bin/sh", repo, "approve");
  assert.strictEqual(code, 0);
  assert.strictEqual(readFileSync(logPath, "utf8").trim(), "approve");
});

test("runFleetVerdict passes verb for steer", async () => {
  const repo = mkdtempSync(join(tmpdir(), "flightdeck-repo-"));
  mkdirSync(join(repo, "bin"));
  const logPath = writeStub(repo, "fleet-verdict");
  const code = await runFleetVerdict("/bin/sh", repo, "steer", "justify");
  assert.strictEqual(code, 0);
  assert.strictEqual(readFileSync(logPath, "utf8").trim(), "steer justify");
});
