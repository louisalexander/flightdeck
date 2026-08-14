#!/usr/bin/env node
/**
 * Asserts the sleep wallpaper and the Silent Boot splash are the same image.
 *
 * The deck shows the splash two ways: as 32 independent per-key images at boot
 * (plugin/src/splash.ts), and as one panel-wide wallpaper while asleep
 * (assets/brand/flightdeck-wallpaper-768x384.svg, set as the Stream Deck app's
 * sleep wallpaper). Those are separate files with separately-written geometry,
 * so they can drift -- and drift would show as the artwork jumping when the
 * deck falls asleep.
 *
 * This composites the real per-key tiles into a panel, renders the wallpaper
 * over the same area, and diffs them in a canvas. Requires Google Chrome,
 * which is why it lives in tools/ and not in the bats suite.
 */
import { execFileSync } from "node:child_process";
import { writeFileSync, readFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
// Compare at the tiles' own native 144px, so neither side is resampled: the
// tiles draw 1:1 and the wallpaper is vector-rendered to the same panel size.
// Downscaling the tiles to 96px instead would blur their edges and the diff
// would measure the resampler rather than the artwork.
const COLS = 8, ROWS = 4, KEY = 144;
const W = COLS * KEY, H = ROWS * KEY;

const { splashTileSvg } = await import(
  join(ROOT, "plugin/com.louisalexander.flightdeck.sdPlugin/bin/splash.js")
);
const wallpaper = readFileSync(join(ROOT, "assets/brand/flightdeck-wallpaper-768x384.svg"), "utf8");

const uri = (svg) => `data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}`;

const tiles = [];
for (let r = 0; r < ROWS; r++)
  for (let c = 0; c < COLS; c++) tiles.push({ r, c, uri: uri(splashTileSvg(r, c)) });

const page = `<!doctype html><meta charset="utf-8"><body><script>
const W=${W},H=${H},COLS=${COLS},ROWS=${ROWS},KW=W/COLS,KH=H/ROWS;
const TILES=${JSON.stringify(tiles)}, WALL=${JSON.stringify(uri(wallpaper))};
const load=(src,label)=>new Promise((res,rej)=>{const i=new Image();i.onload=()=>res(i);i.onerror=()=>rej(new Error("failed to load "+label));i.src=src});
const ctx=(w,h)=>{const cv=document.createElement("canvas");cv.width=w;cv.height=h;return cv.getContext("2d",{willReadFrequently:true})};
(async()=>{
  try{
    const a=ctx(W,H), b=ctx(W,H);
    for(const t of TILES) a.drawImage(await load(t.uri,"tile r"+t.r+"c"+t.c), t.c*KW, t.r*KH, KW, KH);
    b.drawImage(await load(WALL,"wallpaper"), 0, 0, W, H);
    const pa=a.getImageData(0,0,W,H).data, pb=b.getImageData(0,0,W,H).data;
    let maxDelta=0, differing=0;
    for(let i=0;i<pa.length;i+=4){
      let d=0;
      for(let k=0;k<3;k++) d=Math.max(d,Math.abs(pa[i+k]-pb[i+k]));
      if(d>0) differing++;
      if(d>maxDelta) maxDelta=d;
    }
    document.title="RESULT "+JSON.stringify({maxDelta,differing,total:W*H});
  }catch(e){document.title="RESULT "+JSON.stringify({error:String(e)})}
})();
</script></body>`;

const dir = mkdtempSync(join(tmpdir(), "fd-wall-"));
const file = join(dir, "diff.html");
writeFileSync(file, page);

const dom = execFileSync(CHROME, [
  "--headless", "--disable-gpu", "--hide-scrollbars",
  "--virtual-time-budget=6000", "--dump-dom", file
], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });

const m = dom.match(/RESULT (\{.*?\})/);
if (!m) { console.error("check-wallpaper: the diff page never reported a result"); process.exit(2); }
const res = JSON.parse(m[1]);
if (res.error) { console.error("check-wallpaper: " + res.error); process.exit(2); }

/*
 * A correct match is not bit-exact, and expecting it to be is a mistake worth
 * not repeating. The glyph is the only stroked element, and the two files
 * reach it through different transform chains (a per-tile viewBox offset vs a
 * nested scale(.8)); each tile also anti-aliases against its own cut edge
 * where a stroke crosses a key boundary. That leaves a thin residual along
 * the glyph outline and nowhere else.
 *
 * Measured on this artwork, aligned vs deliberately drifted:
 *
 *   aligned        739 px  (0.11%)  max delta  80
 *   drift 0.5px   5991 px  (0.90%)  max delta 232
 *   drift 1px     7532 px  (1.14%)  max delta 251
 *   drift 2px     9374 px  (1.41%)  max delta 251
 *
 * Even a half-pixel drift lights up 8x the pixels, because it disturbs the
 * wordmark and the progress bar too, not just the glyph edge. 0.3% sits in
 * that gap: far above the residual, far below the smallest real drift.
 */
const THRESHOLD_PCT = 0.3;
const pct = (res.differing / res.total) * 100;
console.log(
  `differing pixels: ${res.differing}/${res.total} (${pct.toFixed(4)}%)  ` +
  `max channel delta: ${res.maxDelta}  threshold: ${THRESHOLD_PCT}%`
);
if (pct > THRESHOLD_PCT) {
  console.error(
    "FAIL: the sleep wallpaper has drifted from the per-key boot splash.\n" +
    "      Both must carry the same geometry: the 800x480 source scaled 0.8\n" +
    "      and centred, 64px Night bars left and right."
  );
  process.exit(1);
}
console.log("OK: sleep wallpaper matches the assembled boot splash.");
