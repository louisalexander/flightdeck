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
