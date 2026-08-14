import type { Slot, Config, StateStyle } from "./types.js";
import { GLYPHS } from "./glyphs.js";

const FALLBACK: StateStyle = {
  color: "#000000", glyph: "none", glyphColor: "#000000", textColor: "#000000"
};

function esc(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * One key at @2x (144px) for a 96px Stream Deck XL key. Pure.
 *
 * Three layers only: state background, one lifecycle glyph, two identity
 * lines anchored near the bottom. No chrome.
 */
export function renderSvg(slot: Slot, cfg: Config, armed: boolean): string {
  const style: StateStyle = armed
    ? cfg.states["armed"] ?? FALLBACK
    : cfg.states[slot.state] ?? FALLBACK;

  const drawGlyph = GLYPHS[style.glyph] ?? GLYPHS["none"];
  const glyph = `<g transform="translate(8,8)">${drawGlyph(style.glyphColor)}</g>`;

  const top = armed ? "" : esc((slot.label_top ?? "").toUpperCase());
  const bottom = armed ? "CONFIRM?" : esc(slot.label_bottom ?? "");

  return [
    '<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144">',
    `<rect width="144" height="144" fill="${style.color}"/>`,
    glyph,
    `<text x="72" y="103" text-anchor="middle" font-family="Helvetica,Arial" `,
    `font-size="17" font-weight="600" letter-spacing="0.6" `,
    `fill="${style.textColor}" fill-opacity="0.72">${top}</text>`,
    `<text x="72" y="128" text-anchor="middle" font-family="Helvetica,Arial" `,
    `font-size="23" font-weight="700" fill="${style.textColor}">${bottom}</text>`,
    "</svg>"
  ].join("");
}

export function toDataUri(svg: string): string {
  return "data:image/svg+xml;base64," + Buffer.from(svg, "utf8").toString("base64");
}
