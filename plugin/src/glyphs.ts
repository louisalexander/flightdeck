/**
 * Lifecycle glyphs as SVG geometry rather than text.
 *
 * Helvetica has no U+25B2 or U+25B6, so a <text> glyph would fall back to
 * an arbitrary font with different metrics -- inconsistent positioning at
 * best, a blank key at worst. Geometry is exact and cannot fail to render.
 *
 * Each function draws inside a 48x48 box at the origin.
 */
export const GLYPHS: Record<string, (fill: string) => string> = {
  // ▲ blocked
  blocked: (f) => `<polygon points="24,8 42,38 6,38" fill="${f}"/>`,

  // ▶ working
  working: (f) => `<polygon points="12,8 40,24 12,40" fill="${f}"/>`,

  // ✓ done
  done: (f) =>
    `<path d="M9 25 l9 10 l21 -24" fill="none" stroke="${f}" stroke-width="7" ` +
    `stroke-linecap="round" stroke-linejoin="round"/>`,

  // · idle
  idle: (f) => `<circle cx="24" cy="24" r="6" fill="${f}"/>`,

  // × failed
  failed: (f) =>
    `<path d="M10 10 L38 38 M38 10 L10 38" stroke="${f}" stroke-width="7" ` +
    `stroke-linecap="round"/>`,

  // ⚠ armed — deliberately NOT red; red means observed failure
  armed: (f) =>
    `<polygon points="24,5 45,41 3,41" fill="none" stroke="${f}" stroke-width="5" ` +
    `stroke-linejoin="round"/>` +
    `<path d="M24 17 v11" stroke="${f}" stroke-width="5" stroke-linecap="round"/>` +
    `<circle cx="24" cy="35" r="2.6" fill="${f}"/>`,

  none: () => ""
};
