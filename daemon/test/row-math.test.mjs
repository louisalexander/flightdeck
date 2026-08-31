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
