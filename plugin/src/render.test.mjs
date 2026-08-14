import assert from "node:assert";
import { renderSvg, toDataUri } from "../com.louisalexander.flightdeck.sdPlugin/bin/render.js";

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

console.log("render tests passed");
