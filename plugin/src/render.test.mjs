import assert from "node:assert";
import { renderSvg, toDataUri } from "../com.louisalexander.flightdeck.sdPlugin/bin/render.js";

const cfg = {
  states: {
    working: { color: "#1256A3", glyph: "working", glyphColor: "#FFFFFFCC", textColor: "#FFFFFF" },
    blocked: { color: "#F5A623", glyph: "blocked", glyphColor: "#1A1200", textColor: "#1A1200" },
    empty:   { color: "#000000", glyph: "none",    glyphColor: "#000000",  textColor: "#000000" },
    armed:   { color: "#0A0A0A", glyph: "armed",   glyphColor: "#F5A623",  textColor: "#F5A623" }
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

// Armed must NOT be red -- red is reserved for observed failure.
svg = renderSvg(slot, cfg, true);
assert.ok(svg.includes("#0A0A0A"), "armed uses the near-black background");
assert.ok(svg.includes("#F5A623"), "armed uses amber, not red");
assert.ok(!/#B42318/i.test(svg), "armed never uses the failure red");
assert.ok(svg.includes("CONFIRM"), "armed shows CONFIRM");

// XML injection through a branch name must not break the document.
svg = renderSvg({ ...slot, label_bottom: 'a<b>&"c' }, cfg, false);
assert.ok(!svg.includes("<b>"), "escapes angle brackets in labels");
assert.ok(svg.includes("&amp;"), "escapes ampersands in labels");

// Unknown states degrade instead of throwing.
svg = renderSvg({ ...slot, state: "no-such-state" }, cfg, false);
assert.ok(svg.includes("<svg"), "unknown state still renders");

assert.ok(toDataUri("<svg/>").startsWith("data:image/svg+xml;base64,"), "data uri prefix");

console.log("render tests passed");
