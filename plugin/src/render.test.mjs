import assert from "node:assert";
import { test } from "node:test";
import { renderSvg, toDataUri } from "../com.louisalexander.flightdeck.sdPlugin/bin/render.js";
import {
  tileViewBox, splashTileSvg, nightTileSvg, bootConfig, isBooting,
  shouldShowSplash, renderBootTile, SPLASH_INNER, NIGHT
} from "../com.louisalexander.flightdeck.sdPlugin/bin/splash.js";

const cfg = {
  states: {
    working: { color: "#1256A3", glyph: "working", glyphColor: "#FFFFFFCC", textColor: "#FFFFFF" },
    blocked: { color: "#F5A623", glyph: "blocked", glyphColor: "#1A1200", textColor: "#1A1200" },
    empty:   { color: "#000000", glyph: "none",    glyphColor: "#000000",  textColor: "#000000" },
    armed:   { color: "#0A0A0A", glyph: "armed",   glyphColor: "#F5A623",  textColor: "#F5A623" },
    // Realistic failed entry, matching config/fleet.json, so the
    // "armed never red" test has an actual failure-red value in the
    // fixture that could leak into the armed render if a future change
    // ever made armed fall back to (or alias) the failed style.
    failed:  { color: "#B42318", glyph: "failed",  glyphColor: "#FFFFFFEE", textColor: "#FFFFFF" }
  }
};
const slot = {
  index: 0, state: "working", label_top: "flightdeck", label_bottom: "main",
  session_id: "S1", host: "iterm2", iterm_session: "U", cwd: "/tmp", app: ""
};

let svg = renderSvg(slot, cfg, false);
assert.ok(svg.includes("#1256A3"), "uses the state colour");
assert.ok(svg.includes("FLIGHTDECK"), "repo line is uppercased");
assert.ok(svg.includes("main"), "renders the task line");

// Glyphs must be geometry, never text: Helvetica lacks U+25B2/U+25B6.
assert.ok(!svg.includes("▶") && !svg.includes("▲"),
  "no literal arrow characters anywhere in the output");
assert.ok(/<(polygon|path|circle|line)\b/.test(svg), "glyph is drawn as geometry");

// Empty must be genuinely blank: black, no glyph, no text.
const emptySvg = renderSvg({ ...slot, state: "empty", label_top: "", label_bottom: "" }, cfg, false);
assert.ok(emptySvg.includes("#000000"), "empty is pure black");
assert.ok(!/<(polygon|path|circle|line)\b/.test(emptySvg), "empty draws no glyph");
assert.ok(!emptySvg.includes("<text"), "empty emits no <text> elements at all");

// Armed must NOT be red -- red is reserved for observed failure.
//
// This is the single most important visual invariant in the project: an
// operator one press from destroying a worktree must never look like an
// agent that already failed. To make the "no red" assertion capable of
// actually failing, the fixture slot is a *failed* agent (state: "failed",
// which DOES render #B42318 -- see the sanity check below) and we then arm
// it. If armed ever stopped overriding the underlying state's colour, this
// red would leak straight through.
const failedSlot = { ...slot, state: "failed" };

const failedSvg = renderSvg(failedSlot, cfg, false);
assert.ok(failedSvg.includes("#B42318"), "sanity: an actually-failed slot does render the failure red");

svg = renderSvg(failedSlot, cfg, true);
assert.ok(svg.includes("#0A0A0A"), "armed uses the near-black background");
assert.ok(svg.includes("#F5A623"), "armed uses amber, not red");
assert.ok(!/#B42318/i.test(svg), "armed never uses the failure red, even when the underlying agent has failed");
assert.ok(svg.includes("CONFIRM"), "armed shows CONFIRM");

// XML injection through a branch name must not break the document.
svg = renderSvg({ ...slot, label_bottom: 'a<b>&"c' }, cfg, false);
assert.ok(!svg.includes("<b>"), "escapes angle brackets in labels");
assert.ok(svg.includes("&amp;"), "escapes ampersands in labels");

// XML injection through a config-supplied colour must not break the
// document either. config/fleet.json is a real, editable input; a colour
// value containing a stray quote must not let attacker-controlled markup
// escape the fill="" attribute.
const hostileCfg = {
  states: {
    working: { color: '#000" onload="alert(1)', glyph: "working", glyphColor: '#FFF"><script>x</script>', textColor: '"><b>x</b>' }
  }
};
svg = renderSvg(slot, hostileCfg, false);
assert.ok(!svg.includes('fill="#000" onload="alert(1)"'), "hostile background colour cannot break out of the fill attribute");
assert.ok(!svg.includes("<script>"), "hostile glyphColor cannot inject a script tag");
assert.ok(!svg.includes("<b>x</b>"), "hostile textColor cannot inject markup");
assert.ok(svg.includes("&quot;"), "colour values are escaped like labels");

// Unknown states degrade instead of throwing.
svg = renderSvg({ ...slot, state: "no-such-state" }, cfg, false);
assert.ok(svg.includes("<svg"), "unknown state still renders");

// Malformed config must degrade to a rendered key, never throw. The plugin
// repaints on every file change, so a throw here could crash the repaint
// loop or leave keys stuck.
assert.doesNotThrow(() => renderSvg(slot, {}, false), "config with no states object at all does not throw");
assert.ok(renderSvg(slot, {}, false).includes("<svg"), "config with no states object still renders a key");

assert.doesNotThrow(() => renderSvg(slot, { states: null }, false), "config with states: null does not throw");
assert.ok(renderSvg(slot, { states: null }, false).includes("<svg"), "config with states: null still renders a key");

assert.ok(toDataUri("<svg/>").startsWith("data:image/svg+xml;base64,"), "data uri prefix");

// --- Silent Boot splash -----------------------------------------------

/**
 * Minimal well-formedness check: every opening tag is matched by a closing
 * tag (or is self-closing), properly nested, with no bare `<` or `>` inside
 * attribute-free text. No XML parser dependency needed -- this only has to
 * catch a broken tile, not validate arbitrary XML.
 */
function assertWellFormedXml(svg, msg) {
  assert.ok(svg.startsWith("<svg") && svg.trimEnd().endsWith("</svg>"), `${msg}: has svg root`);
  const tagRe = /<\/?[a-zA-Z][\w-]*(?:\s[^<>]*)?\/?>/g;
  const stack = [];
  let m;
  let sawTag = false;
  while ((m = tagRe.exec(svg))) {
    sawTag = true;
    const tag = m[0];
    if (tag.endsWith("/>")) continue;                 // self-closing
    if (tag.startsWith("</")) {
      const name = tag.slice(2, -1).trim();
      const top = stack.pop();
      assert.strictEqual(top, name, `${msg}: mismatched close tag ${tag}`);
    } else {
      const name = tag.slice(1).split(/[\s>]/)[0];
      stack.push(name);
    }
  }
  assert.ok(sawTag, `${msg}: contains at least one element`);
  assert.strictEqual(stack.length, 0, `${msg}: all tags closed (unclosed: ${stack.join(",")})`);
  // No unescaped bare "<" or "&" outside of tags/entities -- would indicate
  // the artwork or a coordinate leaked unescaped text into the document.
  const withoutTags = svg.replace(tagRe, "");
  assert.ok(!/[<>]/.test(withoutTags), `${msg}: no stray angle brackets outside tags`);
}

// Splash artwork embedded once, stripped of <svg>/<title>/<desc>.
assert.ok(!SPLASH_INNER.includes("<svg"), "SPLASH_INNER has no outer svg wrapper");
assert.ok(!SPLASH_INNER.includes("<title"), "SPLASH_INNER strips <title>");
assert.ok(!SPLASH_INNER.includes("<desc"), "SPLASH_INNER strips <desc>");
assert.ok(SPLASH_INNER.includes("FLIGHTDECK"), "SPLASH_INNER carries the wordmark");

// viewBox math for all 32 keys (4 rows x 8 cols) on the Stream Deck XL.
for (let row = 0; row < 4; row++) {
  for (let col = 0; col < 8; col++) {
    const vb = tileViewBox(row, col);
    assert.strictEqual(vb.x, 120 * col - 80, `row ${row} col ${col}: x`);
    assert.strictEqual(vb.y, 120 * row, `row ${row} col ${col}: y`);
    assert.strictEqual(vb.w, 120, `row ${row} col ${col}: w`);
    assert.strictEqual(vb.h, 120, `row ${row} col ${col}: h`);

    const svg = splashTileSvg(row, col);
    assert.ok(
      svg.includes(`viewBox="${vb.x} ${vb.y} 120 120"`),
      `row ${row} col ${col}: viewBox rendered into the tile SVG`
    );
    assertWellFormedXml(svg, `tile (${row},${col})`);
  }
}

// Corner tiles (col 0 and col 7) fall partly outside the source's 0..800
// range -- that's the letterbox, and it must still be valid, parseable SVG
// that paints Night rather than leaving pixels transparent.
for (const row of [0, 3]) {
  for (const col of [0, 7]) {
    const svg = splashTileSvg(row, col);
    assertWellFormedXml(svg, `corner tile (${row},${col})`);
    assert.ok(svg.includes(NIGHT), `corner tile (${row},${col}) paints Night under the letterbox`);
  }
}

// Boot config: defaults, and degrades instead of throwing on garbage.
assert.deepStrictEqual(bootConfig(undefined), { enabled: true, durationMs: 2000 }, "boot defaults");
assert.deepStrictEqual(bootConfig({ states: {} }), { enabled: true, durationMs: 2000 }, "missing boot block defaults");
assert.deepStrictEqual(
  bootConfig({ states: {}, boot: { enabled: false, durationMs: 500 } }),
  { enabled: false, durationMs: 500 },
  "boot config read through"
);
assert.doesNotThrow(() => bootConfig({ states: {}, boot: "nonsense" }), "malformed boot block does not throw");
assert.deepStrictEqual(
  bootConfig({ states: {}, boot: "nonsense" }),
  { enabled: true, durationMs: 2000 },
  "malformed boot block degrades to defaults"
);

// A boot tile after expiry renders Night with no artwork at all.
const enabledCfg = { enabled: true, durationMs: 2000 };
assert.ok(isBooting(enabledCfg, 0), "boot window open at t=0");
assert.ok(isBooting(enabledCfg, 1999), "boot window open just before expiry");
assert.ok(!isBooting(enabledCfg, 2000), "boot window closed exactly at duration");
assert.ok(!isBooting(enabledCfg, 5000), "boot window closed well after duration");

const expired = renderBootTile(1, 3, enabledCfg, 5000);
assertWellFormedXml(expired, "expired boot tile");
assert.strictEqual(expired, nightTileSvg(), "expired boot tile is exactly the Night tile");
assert.ok(expired.includes(NIGHT), "expired boot tile paints Night");
assert.ok(!expired.includes("FLIGHTDECK"), "expired boot tile carries no wordmark");
assert.ok(!expired.includes("viewBox"), "expired boot tile has no splash viewBox at all");

const active = renderBootTile(1, 3, enabledCfg, 500);
assert.ok(active.includes("FLIGHTDECK"), "active boot tile shows the splash");

// Boot disabled in config produces no splash at all, even at t=0.
const disabledCfg = { enabled: false, durationMs: 2000 };
assert.ok(!isBooting(disabledCfg, 0), "disabled boot config never boots");
const disabled = renderBootTile(0, 0, disabledCfg, 0);
assert.strictEqual(disabled, nightTileSvg(), "disabled boot renders straight to Night");
assert.ok(!disabled.includes("FLIGHTDECK"), "disabled boot never shows the wordmark");

// The rule that outranks the splash: amber means operator attention, and a
// boot tile must NEVER hide an agent that needs it. A `blocked` Fleet Slot
// wins immediately, boot window or not.
assert.ok(shouldShowSplash(enabledCfg, 0, "working"), "non-blocked state shows splash during boot");
assert.ok(shouldShowSplash(enabledCfg, 0, "idle"), "idle also shows splash during boot");
assert.ok(!shouldShowSplash(enabledCfg, 0, "blocked"), "blocked is NEVER overpainted by boot, even at t=0");
assert.ok(!shouldShowSplash(enabledCfg, 1999, "blocked"), "blocked is NEVER overpainted, even just before expiry");
assert.ok(!shouldShowSplash(disabledCfg, 0, "blocked"), "blocked stays live even when boot is disabled");
assert.ok(!shouldShowSplash(enabledCfg, 5000, "working"), "no splash once the boot window has closed");

assert.ok(toDataUri(splashTileSvg(0, 0)).startsWith("data:image/svg+xml;base64,"), "splash tile encodes as a data uri");

// --- focus border -------------------------------------------------------
const focusedSlot = {
  index: 0, state: "working", label_top: "REPO", label_bottom: "main",
  session_id: "S1", host: "iterm2", iterm_session: "U1", cwd: "/tmp", app: "",
  focused: true
};
const unfocusedSlot = { ...focusedSlot, focused: false };

assert.ok(
  renderSvg(focusedSlot, cfg, false).includes('stroke="#FFFFFF"'),
  "a focused slot draws a white border"
);
assert.ok(
  !renderSvg(unfocusedSlot, cfg, false).includes('stroke="#FFFFFF"'),
  "an unfocused slot draws no border"
);
// The lifecycle fill must still dominate: a thin stroke, not a thick frame.
{
  const m = renderSvg(focusedSlot, cfg, false).match(/stroke-width="(\d+)"/);
  assert.ok(m && Number(m[1]) <= 6, "focus border stays thin (<=6 at 144px)");
}
// Selection is not a state. The background must be the lifecycle colour.
assert.ok(
  renderSvg(focusedSlot, cfg, false).includes('fill="#1256A3"'),
  "focus does not replace the lifecycle background"
);
// Arming owns the whole key; a stale selection must not draw over it.
assert.ok(
  !renderSvg(focusedSlot, cfg, true).includes('stroke="#FFFFFF"'),
  "an armed key shows no focus border"
);

// --- Row 2 command keys -------------------------------------------------
import { renderCommandSvg } from "../com.louisalexander.flightdeck.sdPlugin/bin/command.js";

const plain = renderCommandSvg("TEST", "");
assert.ok(plain.includes("TEST"), "the verb label is drawn");
// Row 1 owns saturation because state is the information. Row 2 must not
// compete, and must never borrow the one colour that means "come look".
assert.ok(!plain.includes("#F5A623"), "a command key is never amber");
assert.ok(!plain.includes("#1256A3"), "a command key is never lifecycle blue");
assert.ok(!plain.includes("#238636"), "a command key is never lifecycle green");

// Queued and delivered are different moments; the key must not claim success
// at press time, so queued gets its own restrained treatment.
const queued = renderCommandSvg("TEST", "queued");
assert.notStrictEqual(queued, plain, "queued looks different from idle");
assert.ok(!queued.includes("#F5A623"), "queued is not amber either");

const refused = renderCommandSvg("TEST", "refused");
assert.notStrictEqual(refused, plain, "refused looks different from idle");
assert.notStrictEqual(refused, queued, "refused is distinguishable from queued");

console.log("render tests passed");

// --- armed feedback on a confirm verb -----------------------------------
// ARMED is the one Row 2 state that is genuinely "operator attention
// required": the next press does something outward-facing. Row 1's armed
// state already speaks that with amber, so the panel keeps one vocabulary
// rather than inventing a second. This is a deliberate, narrow exception to
// Row 2 being monochrome -- it is not decoration, and missing it is exactly
// the failure that matters.
{
  const armed = renderCommandSvg("ISSUE", "armed");
  assert.ok(armed.includes("#F5A623"), "armed speaks with amber, like Row 1's armed");
  assert.ok(/CONFIRM|AGAIN/i.test(armed), "armed says what to do next");

  const idle = renderCommandSvg("ISSUE", "");
  const queued = renderCommandSvg("ISSUE", "queued");
  const refused = renderCommandSvg("ISSUE", "refused");
  for (const [name, svg] of [["idle", idle], ["queued", queued], ["refused", refused]]) {
    assert.ok(!svg.includes("#F5A623"), `${name} must not borrow the armed amber`);
  }
  assert.notStrictEqual(armed, refused, "armed is not refused -- opposite meanings");
}

// --- Row 3 verdict keys --------------------------------------------------
// Import from the bundle rollup actually emits, matching how renderSvg and
// renderCommandSvg are imported above -- there is no separate dist/ output.
import { renderVerdictSvg, renderDetailSvg } from "../com.louisalexander.flightdeck.sdPlugin/bin/verdict.js";

test("a verdict key at rest keeps its label, dimmed", () => {
  const svg = renderVerdictSvg("APPROVE", "normal", "", false);
  assert.match(svg, /APPROVE/);
  assert.match(svg, /#5A6675/);   // INK_DIM -- legible, not blank
});

test("a verdict key with a target is bright", () => {
  const svg = renderVerdictSvg("APPROVE", "normal", "", true);
  assert.match(svg, /#C9D4E2/);
});

test("a high tier borrows the attention amber, never a new colour", () => {
  const svg = renderVerdictSvg("APPROVE", "high", "", true);
  assert.match(svg, /#F5A623/);
});

test("armed says CONFIRM?, matching Row 2", () => {
  assert.match(renderVerdictSvg("REMEMBER", "low", "armed", true), /CONFIRM\?/);
});

test("detail at rest shows its label and no content lines", () => {
  const svg = renderDetailSvg(null);
  assert.match(svg, /DETAIL/);
  assert.doesNotMatch(svg, /Bash/);
});

test("detail names the agent and the tool", () => {
  const svg = renderDetailSvg({ session_id: "S1", agent: "flightdeck", tool: "Bash", tier: "high", repeats: 1 });
  assert.match(svg, /flightdeck/);
  assert.match(svg, /Bash/);
});

test("detail shows a repeat count only when it is above one", () => {
  const once = renderDetailSvg({ session_id: "S1", agent: "a", tool: "Bash", tier: "normal", repeats: 1 });
  const many = renderDetailSvg({ session_id: "S1", agent: "a", tool: "Bash", tier: "normal", repeats: 4 });
  assert.doesNotMatch(once, /×/);
  assert.match(many, /×4/);
});

test("detail never renders tool input", () => {
  const svg = renderDetailSvg({
    session_id: "S1", agent: "a", tool: "Bash", tier: "high", repeats: 1,
    input_summary: "rm -rf /",
  });
  assert.doesNotMatch(svg, /rm -rf/);
});
