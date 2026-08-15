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

/**
 * What the armed REMEMBER face names: the repository the rule will land in,
 * and the rule itself. Never the agent -- that is the one thing this press
 * is NOT scoped to, which is exactly why it must not appear on the
 * confirmation.
 */
export type ArmedScope = { repo: string; rule: string };

/**
 * Fit a string to `max` characters, keeping both ends.
 *
 * Blind truncation is wrong here for the same reason it is wrong on Row 1
 * (see fleetlib.shorten) and the same reason no key ever renders tool
 * input: `Bash(git push --force:*)` and `Bash(git push:*)` share a long
 * prefix, so a head-only cut reads as information while being ambiguous
 * exactly where it matters. The tail is what distinguishes one rule from
 * another, so keep it and elide the middle.
 */
export function fitRule(text: string, max = 20): string {
  const value = String(text ?? "").trim();
  if (value.length <= max) return value;
  // 1 char for the ellipsis; the tail gets the larger half because that is
  // where the scope of a rule lives (`:*` versus a specific argument).
  const keep = max - 1;
  const tail = Math.ceil(keep / 2);
  const head = keep - tail;
  return value.slice(0, head) + "…" + value.slice(value.length - tail);
}

/**
 * The word on a verdict key.
 *
 * A steer key is labelled by its VERB, not by the word STEER. Keys 5 and 7
 * both carry verdict: "steer" and differed only in a `verb` setting nothing
 * displayed, so they rendered pixel-identically -- reaching for one and
 * hitting the other sent a different denial to a blocked agent with no
 * visible difference before the press or after it.
 *
 * Uppercasing the verb id is exactly how Row 2's Command key labels itself
 * (plugin.ts, paintIdle), and it is the only mechanism available here: the
 * plugin never reads config/verbs, and a table of ids to display names
 * inside the plugin would be a second copy of the verb list to keep in sync
 * -- the drift the REACHABLE tests exist to catch. A steer key with no verb
 * chosen yet falls back to STEER rather than blanking, because an
 * unconfigured key must still say what it is.
 */
export function verdictLabel(verdict: string, verb: string): string {
  if (verdict === "steer" && verb) return verb.toUpperCase();
  return verdict.toUpperCase();
}

export function renderVerdictSvg(
  label: string, tier: string, feedback: Feedback, active: boolean,
  armedScope?: ArmedScope | null,
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

  // The armed REMEMBER face: repository, rule, CONFIRM?. Three lines, and
  // the verdict word is dropped -- at 96px there is no room for a fourth,
  // and "REMEMBER" is the one line the operator does not need, since the
  // key they just pressed is under their thumb. What they cannot otherwise
  // know is the blast radius: the rule persists to the CANONICAL repo root
  // and applies to every agent in every worktree of that repository,
  // including ones that do not exist yet. Naming it is the whole mitigation
  // (see the Rows 3-4 design, "The worktree trap"), so it is drawn only
  // when the scope is actually known and never faked from the label.
  if (feedback === "armed" && armedScope && (armedScope.repo || armedScope.rule)) {
    return [
      open(),
      `<text x="72" y="52" text-anchor="middle" font-family="Helvetica,Arial" `
        + `font-size="15" font-weight="600" letter-spacing="0.4" fill="${INK}">`
        + `${esc(fitRule(armedScope.repo, 14))}</text>`,
      `<text x="72" y="82" text-anchor="middle" font-family="Helvetica,Arial" `
        + `font-size="14" font-weight="700" letter-spacing="0.2" fill="${ATTENTION}">`
        + `${esc(fitRule(armedScope.rule, 20))}</text>`,
      `<text x="72" y="115" text-anchor="middle" font-family="Helvetica,Arial" `
        + `font-size="15" font-weight="700" letter-spacing="0.8" fill="${ATTENTION}">CONFIRM?</text>`,
      "</svg>",
    ].join("");
  }

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

/**
 * DETAIL's idle face carries a classification (agent, tool, tier), not a
 * feedback channel -- renderDetailSvg above has no marker for "refused".
 * But the press it answers for can genuinely fail: bin/fleet-verdict's
 * `_focus` returns REFUSED when the target has no recorded iterm_session,
 * or when fleet-focus itself exits non-zero or times out. A silent no-op
 * on that failure is exactly the "a key that does nothing is
 * indistinguishable from a broken one" failure the three-way exit status
 * exists to prevent, reintroduced at the last hop. So a non-delivered
 * outcome borrows the generic verdict face -- the one render path that
 * already has a "refused" marker -- instead of falling silently back to
 * the classification; the classification returns once the flash clears.
 */
export function renderDetailFeedback(target: VerdictTarget | null, feedback: Feedback): string {
  if (feedback === "") return renderDetailSvg(target);
  return renderVerdictSvg("DETAIL", target?.tier ?? "normal", feedback, target !== null);
}
