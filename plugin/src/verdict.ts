import type { VerdictTarget } from "./types.js";

export type { VerdictTarget };

/**
 * Row 3 verdict keys.
 *
 * Monochrome like Row 2, because Row 1 owns saturated colour. The one
 * borrowed hue is the attention amber, used for `high` tier and for armed
 * -- the same amber Row 1 uses for an armed teardown, which already means
 * "you are one press from something serious". Reusing an established
 * meaning on a different row beats inventing a fourth colour language.
 *
 * No key ever renders tool input. At 96px `rm -rf ./build` and
 * `rm -rf ./ build` truncate identically, so a truncated command reads as
 * information while being ambiguous exactly where it matters. The key face
 * carries a classification; the complete request is one press away, drawn
 * by Claude Code in the blocked terminal.
 */

export type Feedback = "" | "delivered" | "refused" | "armed";

const NIGHT = "#0A0E13";
const INK = "#C9D4E2";
const INK_DIM = "#5A6675";
const INK_BRIGHT = "#FFFFFF";
const ATTENTION = "#F5A623";

function esc(text: string): string {
  return String(text ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function open(): string {
  return '<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144">'
    + `<rect width="144" height="144" fill="${NIGHT}"/>`;
}

export function renderVerdictSvg(
  label: string, tier: string, feedback: Feedback, active: boolean,
): string {
  // At rest the row is dimmed, never blank. Row 1's "absence should look
  // absent" does not transfer: a Row 1 slot's meaning is positional and may
  // genuinely not exist, whereas APPROVE is APPROVE whether or not there is
  // anything to approve. Blanking would destroy the row's spatial memory
  // and make eight keys flicker in and out of existence.
  const ink = feedback === "armed" ? ATTENTION
    : feedback === "refused" ? INK_BRIGHT
    : !active ? INK_DIM
    : tier === "high" ? ATTENTION
    : INK;

  const marker = feedback === "armed"
    ? `<text x="72" y="115" text-anchor="middle" font-family="Helvetica,Arial" `
      + `font-size="15" font-weight="700" letter-spacing="0.8" fill="${ATTENTION}">CONFIRM?</text>`
    : feedback === "refused"
    ? `<rect x="34" y="108" width="76" height="4" rx="2" fill="${INK_BRIGHT}"/>`
    : feedback === "delivered"
    ? `<circle cx="72" cy="112" r="5" fill="${INK}" fill-opacity="0.55"/>`
    : "";

  return [
    open(),
    `<text x="72" y="80" text-anchor="middle" font-family="Helvetica,Arial" `
      + `font-size="22" font-weight="700" letter-spacing="1.2" fill="${ink}">${esc(label)}</text>`,
    marker,
    "</svg>",
  ].join("");
}

export function renderDetailSvg(target: VerdictTarget | null): string {
  if (!target) {
    return [
      open(),
      `<text x="72" y="80" text-anchor="middle" font-family="Helvetica,Arial" `
        + `font-size="22" font-weight="700" letter-spacing="1.2" fill="${INK_DIM}">DETAIL</text>`,
      "</svg>",
    ].join("");
  }

  const high = target.tier === "high";
  // The amber triangle Row 1's armed teardown already owns. Geometry, never
  // a text glyph: U+25B2 is absent from Helvetica and would fall back to an
  // arbitrary font with different metrics.
  const warn = high
    ? `<polygon points="72,18 88,46 56,46" fill="${ATTENTION}"/>`
    : "";
  const repeats = target.repeats > 1
    ? `<text x="128" y="26" text-anchor="end" font-family="Helvetica,Arial" `
      + `font-size="16" font-weight="700" fill="${ATTENTION}">×${target.repeats}</text>`
    : "";

  return [
    open(),
    warn,
    `<text x="72" y="76" text-anchor="middle" font-family="Helvetica,Arial" `
      + `font-size="13" font-weight="600" letter-spacing="0.6" fill="${INK_DIM}">${esc(target.agent)}</text>`,
    `<text x="72" y="102" text-anchor="middle" font-family="Helvetica,Arial" `
      + `font-size="20" font-weight="700" fill="${high ? ATTENTION : INK}">${esc(target.tool)}</text>`,
    repeats,
    "</svg>",
  ].join("");
}
