import type { Config } from "./types.js";

/**
 * Silent Boot splash.
 *
 * The source artwork is assets/brand/flightdeck-splash-800x480.svg -- an
 * 800x480 canvas that letterboxes into the Stream Deck XL's 768x384 panel
 * (8 cols x 4 rows of 96px keys) at scale 0.8: 640x384 centred, leaving a
 * 64px bar on each side (no vertical letterbox -- 480*0.8 == 384 exactly).
 *
 * Rather than rasterize per-key PNGs, each key renders the SAME artwork
 * through an SVG viewBox window. At @2x (144px key canvas) that window is
 * 120x120 source units per key (96 panel px / 0.8 scale), offset by 80
 * source units (64 panel px / 0.8) to account for the horizontal letterbox:
 *
 *   viewBox="${120*col - 80} ${120*row} 120 120"
 *
 * Columns 0 and 7 partly fall outside the source's 0..800 x range, which is
 * correct -- that's the letterbox bar, and it must still paint solid Night
 * rather than leaving those pixels transparent.
 */

// Inner content of assets/brand/flightdeck-splash-800x480.svg, verbatim,
// with the outer <svg> wrapper and the <title>/<desc> elements stripped.
export const SPLASH_INNER = `<rect width="800" height="480" fill="#020304"/>
  <g transform="translate(310 76) scale(.7)">
    <path d="M130 20 212 186 130 152 48 186Z" fill="#0C131D" stroke="#EEF5FF" stroke-width="15" stroke-linejoin="round"/>
    <path d="M130 20V152" fill="none" stroke="#1256A3" stroke-width="15"/>
    <circle cx="130" cy="152" r="15" fill="#F5A623"/>
    <circle cx="130" cy="152" r="32" fill="none" stroke="#F5A623" stroke-width="3" opacity=".22"/>
  </g>
  <text x="400" y="305" text-anchor="middle" fill="#EEF5FF" font-family="Inter, Helvetica Neue, Arial, sans-serif" font-size="39" font-weight="600" letter-spacing="12">FLIGHTDECK</text>
  <text x="400" y="346" text-anchor="middle" fill="#617083" font-family="SFMono-Regular, Menlo, Consolas, monospace" font-size="12" letter-spacing="5">FLEET CONTROL</text>
  <rect x="310" y="393" width="180" height="3" rx="1.5" fill="#18212D"/>
  <rect x="310" y="393" width="118" height="3" rx="1.5" fill="#1256A3"/>
  <circle cx="428" cy="394.5" r="5" fill="#F5A623"/>`;

// Night -- absence must look like absence, not like a missing image.
export const NIGHT = "#020304";

export type ViewBox = { x: number; y: number; w: number; h: number };

/** The source-space window a given (row, col) key looks through. Pure. */
export function tileViewBox(row: number, col: number): ViewBox {
  return { x: 120 * col - 80, y: 120 * row, w: 120, h: 120 };
}

/**
 * One splash tile at @2x (144px). A background rect exactly matching the
 * viewBox is drawn first so the letterbox bars (columns 0 and 7, which
 * extend outside the source's own 0..800 rect) still paint solid Night
 * instead of leaving those pixels transparent.
 */
export function splashTileSvg(row: number, col: number): string {
  const { x, y, w, h } = tileViewBox(row, col);
  return [
    `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="${x} ${y} ${w} ${h}">`,
    `<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="${NIGHT}"/>`,
    SPLASH_INNER,
    "</svg>"
  ].join("");
}

/** Chrome gone: solid Night, no artwork, no glow -- absence looks absent. */
export function nightTileSvg(): string {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144"><rect width="144" height="144" fill="${NIGHT}"/></svg>`;
}

export type BootConfig = { enabled: boolean; durationMs: number };

const DEFAULT_BOOT: BootConfig = { enabled: true, durationMs: 2000 };

/** Reads config.boot, degrading to the default rather than throwing. */
export function bootConfig(cfg: Config | null | undefined): BootConfig {
  const raw = cfg && typeof cfg === "object" ? (cfg as { boot?: unknown }).boot : undefined;
  const b = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  const enabled = typeof b.enabled === "boolean" ? b.enabled : DEFAULT_BOOT.enabled;
  const durationCandidate = Number(b.durationMs);
  const durationMs =
    Number.isFinite(durationCandidate) && durationCandidate >= 0 ? durationCandidate : DEFAULT_BOOT.durationMs;
  return { enabled, durationMs };
}

/** Is the boot window still open at this elapsed time? Pure -- no clock reads. */
export function isBooting(cfg: BootConfig, elapsedMs: number): boolean {
  return cfg.enabled && elapsedMs < cfg.durationMs;
}

/**
 * Amber means operator attention; do not use it decoratively, and chrome
 * must never obscure an agent that needs the operator. A boot tile is
 * chrome. So a Fleet Slot showing `blocked` -- the state that means "come
 * look at this" -- is never eligible for the splash, boot window or not.
 */
export function shouldShowSplash(bootCfg: BootConfig, elapsedMs: number, slotState: string): boolean {
  return isBooting(bootCfg, elapsedMs) && slotState !== "blocked";
}

/** A standalone Boot Tile key: splash while booting, Night once expired. */
export function renderBootTile(row: number, col: number, bootCfg: BootConfig, elapsedMs: number): string {
  return isBooting(bootCfg, elapsedMs) ? splashTileSvg(row, col) : nightTileSvg();
}
