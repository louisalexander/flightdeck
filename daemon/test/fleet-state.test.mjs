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
