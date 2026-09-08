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
  writeFileSync(join(dir, "armed.json"), JSON.stringify({ index: 3, expires: Date.now() / 1000 + 60 }));
  const svg = paintSlot(dir, CONFIG, 3);
  assert.ok(svg.includes("CONFIRM"));
});

test("an expired armed.json for this index does not render the armed face", () => {
  const dir = mkdtempSync(join(tmpdir(), "fleet-"));
  const slots = { slots: [{ index: 3, state: "working", label_top: "", label_bottom: "" }] };
  writeFileSync(join(dir, "slots.json"), JSON.stringify(slots));
  writeFileSync(join(dir, "armed.json"), JSON.stringify({ index: 3, expires: Date.now() / 1000 - 10 }));
  const svg = paintSlot(dir, CONFIG, 3);
  assert.ok(!svg.includes("CONFIRM"));
});
