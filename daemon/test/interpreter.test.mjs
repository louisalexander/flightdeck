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
