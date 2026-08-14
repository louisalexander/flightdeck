/**
 * Row 2 command keys.
 *
 * Deliberately monochrome. Row 1 owns saturated colour because lifecycle
 * state is the information on this panel; a command key that competed for
 * that channel would make the deck harder to read, not richer. Feedback is
 * a brief change of ink, never a change of hue into lifecycle territory.
 */

const NIGHT = "#0A0E13";
const INK = "#C9D4E2";
const INK_DIM = "#5A6675";
const INK_BRIGHT = "#FFFFFF";

export type Feedback = "" | "queued" | "refused";

export function renderCommandSvg(label: string, feedback: Feedback): string {
  const safe = label.replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;");

  // Queued is not success: the verb may not run for minutes. It gets a dimmed
  // label and a small marker rather than anything that reads as "done".
  const ink = feedback === "refused" ? INK_BRIGHT
    : feedback === "queued" ? INK_DIM : INK;

  const marker = feedback === "queued"
    ? `<circle cx="72" cy="112" r="5" fill="${INK}" fill-opacity="0.55"/>`
    : feedback === "refused"
      ? `<rect x="34" y="108" width="76" height="4" rx="2" fill="${INK_BRIGHT}"/>`
      : "";

  return [
    '<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144">',
    `<rect width="144" height="144" fill="${NIGHT}"/>`,
    `<text x="72" y="80" text-anchor="middle" font-family="Helvetica,Arial" ` +
      `font-size="22" font-weight="700" letter-spacing="1.2" fill="${ink}">${safe}</text>`,
    marker,
    "</svg>"
  ].join("");
}
