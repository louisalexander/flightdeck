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
