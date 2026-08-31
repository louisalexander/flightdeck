import { openStreamDeck, listStreamDecks } from "@elgato-stream-deck/node";
import type { StreamDeckButtonControlDefinition } from "@elgato-stream-deck/node";
import { homedir } from "node:os";
import { join } from "node:path";
import { readFileSync, existsSync } from "node:fs";
import { renderSvgToRgba } from "./render-to-image.js";
import { watchFleetHome } from "./fleet-state.js";
import { resolveInterpreter } from "./interpreter.js";
import { pressVerb, runFleetPress } from "./dispatch.js";
import { loadKeymap } from "./keymap.js";
import { paintSlot } from "./slot-handler.js";
import { paintBootTile } from "./boot-handler.js";
import { paintCommandIdle, handleCommandKeyUp } from "./command-handler.js";
import { paintVerdictIdle, handleVerdictKeyUp } from "./verdict-handler.js";
import { keyIndexToRowCol } from "./row-math.js";
import type { Config } from "../../plugin/src/types";

const FLEET_HOME = join(homedir(), ".fleet");
const REPO = process.env.FLIGHTDECK_REPO ?? join(homedir(), "repos", "flightdeck");
const KEYMAP_PATH = process.env.FLIGHTDECK_KEYMAP ?? join(REPO, "daemon", "config", "keymap.json");
// Documented fixed native key resolution for the Stream Deck XL (see plugin/src/render.ts's own
// doc comment) -- not exposed as a queryable property on the StreamDeck interface.
const ICON_SIZE = 96;

function loadConfig(): Config {
  const path = join(REPO, "config", "fleet.json");
  const localPath = join(REPO, "config", "fleet.local.json");
  const base = existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : { states: {} };
  const local = existsSync(localPath) ? JSON.parse(readFileSync(localPath, "utf8")) : {};
  return { states: { ...(base.states ?? {}), ...(local.states ?? {}) } };
}

function isButton(
  control: { type: string },
): control is StreamDeckButtonControlDefinition {
  return control.type === "button";
}

async function main() {
  const devices = await listStreamDecks();
  if (devices.length !== 1) {
    throw new Error(
      `expected exactly one Stream Deck, found ${devices.length}. ` +
      `Plug in exactly one XL and retry.`
    );
  }
  const device = await openStreamDeck(devices[0].path);
  const interpreter = resolveInterpreter(FLEET_HOME);
  const config = loadConfig();
  const keymap = loadKeymap(KEYMAP_PATH);
  const downAt = new Map<number, number>();

  const buttonIndices = device.CONTROLS.filter(isButton).map((c) => c.index);

  async function paintKey(index: number): Promise<void> {
    const { row } = keyIndexToRowCol(index);
    const svg = row === 0 ? paintSlot(FLEET_HOME, config, index)
      : row === 1 ? paintCommandIdle(keymap, index)
      : row === 2 ? paintVerdictIdle(FLEET_HOME, keymap, index)
      : paintBootTile(index);
    const buffer = await renderSvgToRgba(svg, ICON_SIZE);
    await device.fillKeyBuffer(index, buffer, { format: "rgba" });
  }

  async function repaintAll(): Promise<void> {
    for (const index of buttonIndices) await paintKey(index);
  }

  watchFleetHome(FLEET_HOME, () => { repaintAll().catch(console.error); });
  setInterval(() => { repaintAll().catch(console.error); }, 1000);

  device.on("down", (control) => {
    if (!isButton(control)) return;
    downAt.set(control.index, Date.now());
  });
  device.on("up", async (control) => {
    if (!isButton(control)) return;
    const index = control.index;
    const startedAt = downAt.get(index) ?? Date.now();
    downAt.delete(index);
    const { row } = keyIndexToRowCol(index);
    const verb = pressVerb(startedAt, Date.now());

    let feedbackSvg: string | null = null;
    if (row === 0) {
      const { col } = keyIndexToRowCol(index);
      await runFleetPress(interpreter, REPO, col, verb);
    } else if (row === 1) {
      feedbackSvg = await handleCommandKeyUp(interpreter, REPO, keymap, index);
    } else if (row === 2) {
      feedbackSvg = await handleVerdictKeyUp(interpreter, REPO, FLEET_HOME, keymap, index);
    }

    if (feedbackSvg) {
      const buffer = await renderSvgToRgba(feedbackSvg, ICON_SIZE);
      await device.fillKeyBuffer(index, buffer, { format: "rgba" });
      setTimeout(() => { paintKey(index).catch(console.error); }, 1200);
    } else {
      await paintKey(index);
    }
  });

  device.on("error", (err: unknown) => {
    console.error("Stream Deck HID error, exiting for launchd to restart:", err);
    process.exit(1);
  });

  await repaintAll();
  console.log("flightdeck daemon running against", devices[0].path);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
