import streamDeck, {
  action, SingletonAction,
  type WillAppearEvent, type WillDisappearEvent,
  type KeyDownEvent, type KeyUpEvent, type DidReceiveSettingsEvent
} from "@elgato/streamdeck";
import { readFileSync, watch, existsSync } from "node:fs";
import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { renderSvg, toDataUri } from "./render.js";
import type { Slot, SlotsFile, Config } from "./types.js";

const FLEET_HOME = join(homedir(), ".fleet");
const REPO = process.env.FLIGHTDECK_REPO ?? join(homedir(), "code", "flightdeck");
const SLOTS_PATH = join(FLEET_HOME, "slots.json");
const ARMED_PATH = join(FLEET_HOME, "armed.json");

type Settings = { slotIndex?: number };

function readJson<T>(path: string): T | null {
  try {
    if (!existsSync(path)) return null;
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch {
    return null;                     // mid-write or corrupt: skip this tick
  }
}

/**
 * The Stream Deck app does not inherit a shell PATH, and this machine has
 * four python3 installs. install.sh records the chosen absolute path.
 */
function interpreter(): string {
  try {
    const pinned = readFileSync(join(FLEET_HOME, "interpreter"), "utf8").trim();
    if (pinned) return pinned;
  } catch { /* fall through */ }
  return "python3";
}

function loadConfig(): Config {
  const base = readJson<Config>(join(REPO, "config", "fleet.json"));
  const local = readJson<Partial<Config>>(join(REPO, "config", "fleet.local.json"));
  return { states: { ...(base?.states ?? {}), ...(local?.states ?? {}) } };
}

const EMPTY = (index: number): Slot => ({
  index, state: "empty", label_top: "", label_bottom: "",
  session_id: "", host: "", iterm_session: "", cwd: "", app: ""
});

@action({ UUID: "com.louisalexander.flightdeck.slot" })
export class FleetSlot extends SingletonAction<Settings> {
  private visible = new Map<string, { ev: WillAppearEvent<Settings>; index: number; autoIndex: number }>();
  private downAt = new Map<string, number>();
  private config: Config = loadConfig();
  private longPressMs = 800;

  constructor() {
    super();
    // Watch the DIRECTORY: fleet-reconcile replaces slots.json by rename,
    // which permanently breaks a watch bound to the old inode.
    try {
      watch(FLEET_HOME, (_type, filename) => {
        if (filename === "slots.json" || filename === "armed.json") this.repaintAll();
      });
    } catch (err) {
      streamDeck.logger.error(`cannot watch ${FLEET_HOME}: ${String(err)}`);
    }
    // Safety net for missed events, and it expires the armed state on time.
    setInterval(() => this.repaintAll(), 1000);
  }

  /**
   * Which fleet slot a key shows.
   *
   * Defaults to the key's COLUMN, so dropping Fleet Slot across row 1 just
   * works with no configuration. An explicit slotIndex setting overrides it.
   *
   * This matters because a Stream Deck property inspector does not persist a
   * value until the user actively changes it — so every key left at its
   * default saved `{}` and fell back to slot 0, making all eight keys show
   * the same agent. Position is information we already have; asking the
   * operator to retype it was the bug.
   */
  private autoIndexFor(ev: WillAppearEvent<Settings>): number {
    const coords = (ev.payload as { coordinates?: { column?: number } }).coordinates;
    const column = coords?.column;
    return Number.isFinite(Number(column)) ? Number(column) : 0;
  }

  private resolveIndex(settings: Settings | undefined, autoIndex: number): number {
    const explicit = settings?.slotIndex;
    if (explicit !== undefined && explicit !== null && Number.isFinite(Number(explicit))) {
      return Number(explicit);
    }
    return autoIndex;
  }

  override onWillAppear(ev: WillAppearEvent<Settings>): void {
    const autoIndex = this.autoIndexFor(ev);
    const index = this.resolveIndex(ev.payload.settings, autoIndex);
    this.visible.set(ev.action.id, { ev, index, autoIndex });
    this.paint(ev, index);
  }

  override onWillDisappear(ev: WillDisappearEvent<Settings>): void {
    this.visible.delete(ev.action.id);
    this.downAt.delete(ev.action.id);
  }

  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<Settings>): void {
    const entry = this.visible.get(ev.action.id);
    if (entry) {
      // The key's position never changes, so reuse the index resolved at
      // willAppear as the fallback rather than re-deriving coordinates here.
      const explicit = ev.payload.settings?.slotIndex;
      if (explicit !== undefined && explicit !== null && Number.isFinite(Number(explicit))) {
        entry.index = Number(explicit);
      } else {
        entry.index = entry.autoIndex;
      }
      this.paint(entry.ev, entry.index);
    }
  }

  override onKeyDown(ev: KeyDownEvent<Settings>): void {
    this.downAt.set(ev.action.id, Date.now());
  }

  override onKeyUp(ev: KeyUpEvent<Settings>): void {
    const down = this.downAt.get(ev.action.id) ?? Date.now();
    this.downAt.delete(ev.action.id);
    const verb = Date.now() - down >= this.longPressMs ? "long" : "short";
    const index = this.visible.get(ev.action.id)?.index ?? 0;

    execFile(interpreter(), [join(REPO, "bin", "fleet-press"), String(index), verb], (err) => {
      if (err) streamDeck.logger.error(`fleet-press failed: ${err.message}`);
      this.repaintAll();
    });
  }

  private repaintAll(): void {
    this.config = loadConfig();
    for (const { ev, index } of this.visible.values()) this.paint(ev, index);
  }

  private paint(ev: WillAppearEvent<Settings>, index: number): void {
    const file = readJson<SlotsFile>(SLOTS_PATH);
    const slot = file?.slots?.find((s) => s.index === index) ?? EMPTY(index);

    const arm = readJson<{ index: number; expires: number }>(ARMED_PATH);
    const armed = !!arm && arm.index === index && Date.now() / 1000 < arm.expires;

    ev.action.setTitle("");            // the SVG carries all text
    ev.action.setImage(toDataUri(renderSvg(slot, this.config, armed)));
  }
}

streamDeck.actions.registerAction(new FleetSlot());
streamDeck.connect();
