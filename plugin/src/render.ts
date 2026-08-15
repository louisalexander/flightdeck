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
export function renderSvg(
  slot: Slot, cfg: Config, armed: boolean,
  permissionMode: string = "", halted: boolean = false,
): string {
  const states = (cfg && typeof cfg.states === "object" && cfg.states) || {};
  const style: StateStyle = armed
    ? (states as Record<string, StateStyle>)["armed"] ?? FALLBACK
    : (states as Record<string, StateStyle>)[slot.state] ?? FALLBACK;

  const color = esc(style.color);
  const glyphColor = esc(style.glyphColor);
  const textColor = esc(style.textColor);

  const drawGlyph = GLYPHS[style.glyph] ?? GLYPHS["none"];
  const glyph = `<g transform="translate(8,8)">${drawGlyph(glyphColor)}</g>`;

  const top = armed ? "" : esc((slot.label_top ?? "").toUpperCase());
  const bottom = armed ? "CONFIRM?" : esc(slot.label_bottom ?? "");

  const topText = top
    ? `<text x="72" y="103" text-anchor="middle" font-family="Helvetica,Arial" ` +
      `font-size="17" font-weight="600" letter-spacing="0.6" ` +
      `fill="${textColor}" fill-opacity="0.72">${top}</text>`
    : "";
  const bottomText = bottom
    ? `<text x="72" y="128" text-anchor="middle" font-family="Helvetica,Arial" ` +
      `font-size="23" font-weight="700" fill="${textColor}">${bottom}</text>`
    : "";

  // Selection, not state. Inset and thin so the lifecycle fill still reads as
  // the key's colour -- a heavy frame would compete with the one channel that
  // carries the actual information. Suppressed while armed, which owns the
  // whole key.
  const focusBorder = slot.focused && !armed
    ? `<rect x="2" y="2" width="140" height="140" rx="3" fill="none" ` +
      `stroke="#FFFFFF" stroke-width="4" stroke-opacity="0.92"/>`
    : "";

  // Quiet on purpose. A bypassed agent is a standing condition, often a
  // chosen one, and a marker that shouted would compete with amber -- the
  // one thing on this panel allowed to shout. The pip says "this one has no
  // brakes" to an operator who looks; it does not pull the eye across a desk.
  //
  // An unknown mode draws no pip. Absence must never be read as "default":
  // that would tell the operator a session is guarded when we simply have
  // not heard from it yet, which is the wrong direction to err.
  const pip = permissionMode === "bypassPermissions"
    ? `<circle cx="130" cy="14" r="5" fill="#F5A623" fill-opacity="0.85"/>`
    : "";

  // A halt is a fact about every agent, not one slot's state, so it hatches
  // the whole key rather than living in a corner like the pip -- an event,
  // where the pip is a standing condition. If Row 1 kept painting blue and
  // green there would be no way to tell nothing can run.
  const hatch = halted
    ? `<defs><pattern id="hatch" width="8" height="8" patternUnits="userSpaceOnUse" `
      + `patternTransform="rotate(45)"><rect width="3" height="8" fill="#000000" fill-opacity="0.55"/></pattern></defs>`
      + `<rect width="144" height="144" fill="url(#hatch)"/>`
    : "";

  return [
    '<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144">',
    `<rect width="144" height="144" fill="${color}"/>`,
    glyph,
    topText,
    bottomText,
    focusBorder,
    pip,
    hatch,
    "</svg>"
  ].join("");
}

export function toDataUri(svg: string): string {
  return "data:image/svg+xml;base64," + Buffer.from(svg, "utf8").toString("base64");
}
