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
import { bootConfig, shouldShowSplash, splashTileSvg, renderBootTile } from "./splash.js";
import { renderCommandSvg } from "./command.js";
import type { Slot, SlotsFile, Config } from "./types.js";

const FLEET_HOME = join(homedir(), ".fleet");
const REPO = process.env.FLIGHTDECK_REPO ?? join(homedir(), "code", "flightdeck");
const SLOTS_PATH = join(FLEET_HOME, "slots.json");
const ARMED_PATH = join(FLEET_HOME, "armed.json");

// One epoch shared by every key: the moment this plugin process started.
// Silent Boot is a single panel-wide window, not a per-key timer.
const BOOT_STARTED_AT = Date.now();

type Settings = { slotIndex?: number };
type BootTileSettings = { row?: number; col?: number };

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
  return {
    states: { ...(base?.states ?? {}), ...(local?.states ?? {}) },
    boot: local?.boot ?? base?.boot
  };
}

const EMPTY = (index: number): Slot => ({
  index, state: "empty", label_top: "", label_bottom: "",
  session_id: "", host: "", iterm_session: "", cwd: "", app: "",
  focused: false
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

    // Silent Boot: during the boot window a Fleet Slot paints its own
    // splash tile (row 0, its own physical column) instead of live state --
    // UNLESS that live state is `blocked`. Amber means operator attention;
    // chrome must never hide an agent that needs one. `entry.autoIndex` is
    // the key's physical column (see autoIndexFor), independent of any
    // slotIndex override, so the splash lines up with its Boot Tile
    // neighbours regardless of which slot this key is configured to show.
    const entry = this.visible.get(ev.action.id);
    const column = entry?.autoIndex ?? index;
    const boot = bootConfig(this.config);
    const elapsed = Date.now() - BOOT_STARTED_AT;
    const showSplash = shouldShowSplash(boot, elapsed, slot.state);

    ev.action.setTitle("");            // the SVG carries all text
    const svg = showSplash ? splashTileSvg(0, column) : renderSvg(slot, this.config, armed);
    ev.action.setImage(toDataUri(svg));
  }
}

type BootTileEntry = { ev: WillAppearEvent<BootTileSettings>; row: number; col: number };

/**
 * Silent Boot filler: a key with no Fleet Slot assigned still shows the
 * brand artwork at startup, then settles to solid Night once the boot
 * window closes -- so absence still looks like absence, not a stuck splash.
 */
@action({ UUID: "com.louisalexander.flightdeck.boottile" })
export class BootTile extends SingletonAction<BootTileSettings> {
  private visible = new Map<string, BootTileEntry>();
  private config: Config = loadConfig();

  constructor() {
    super();
    try {
      watch(join(REPO, "config"), () => {
        this.config = loadConfig();
      });
    } catch (err) {
      streamDeck.logger.error(`cannot watch ${join(REPO, "config")}: ${String(err)}`);
    }
    // Safety net so the tile transitions off the splash once the boot
    // window closes, even without a settings change or a config edit.
    setInterval(() => this.repaintAll(), 1000);
  }

  /**
   * Row/col default from the key's own physical position -- exactly like
   * Fleet Slot's `slotIndex` -- because a property inspector never
   * persists a value until actively changed, so leaving every key at its
   * saved-empty default must not collapse all 32 tiles onto one window.
   */
  private autoRowColFor(ev: WillAppearEvent<BootTileSettings>): { row: number; col: number } {
    const coords = (ev.payload as { coordinates?: { row?: number; column?: number } }).coordinates;
    const row = Number.isFinite(Number(coords?.row)) ? Number(coords?.row) : 0;
    const col = Number.isFinite(Number(coords?.column)) ? Number(coords?.column) : 0;
    return { row, col };
  }

  private resolveRowCol(
    settings: BootTileSettings | undefined,
    auto: { row: number; col: number }
  ): { row: number; col: number } {
    const row =
      settings?.row !== undefined && settings?.row !== null && Number.isFinite(Number(settings.row))
        ? Number(settings.row)
        : auto.row;
    const col =
      settings?.col !== undefined && settings?.col !== null && Number.isFinite(Number(settings.col))
        ? Number(settings.col)
        : auto.col;
    return { row, col };
  }

  override onWillAppear(ev: WillAppearEvent<BootTileSettings>): void {
    const auto = this.autoRowColFor(ev);
    const { row, col } = this.resolveRowCol(ev.payload.settings, auto);
    this.visible.set(ev.action.id, { ev, row, col });
    this.paint(ev, row, col);
  }

  override onWillDisappear(ev: WillDisappearEvent<BootTileSettings>): void {
    this.visible.delete(ev.action.id);
  }

  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<BootTileSettings>): void {
    const entry = this.visible.get(ev.action.id);
    if (!entry) return;
    const auto = { row: entry.row, col: entry.col };
    const { row, col } = this.resolveRowCol(ev.payload.settings, auto);
    entry.row = row;
    entry.col = col;
    this.paint(entry.ev, row, col);
  }

  private repaintAll(): void {
    for (const { ev, row, col } of this.visible.values()) this.paint(ev, row, col);
  }

  private paint(ev: WillAppearEvent<BootTileSettings>, row: number, col: number): void {
    const boot = bootConfig(this.config);
    const elapsed = Date.now() - BOOT_STARTED_AT;
    ev.action.setTitle("");
    ev.action.setImage(toDataUri(renderBootTile(row, col, boot, elapsed)));
  }
}

/**
 * Stages a Row 2 verb against whichever agent is currently selected.
 * Mirrors the fleet-press invocation above, but unlike fleet-press this
 * script is deliberately allowed to exit non-zero (no selection, dead
 * session, unknown verb) -- that refusal is the boolean the key needs in
 * order to show "queued" vs. "refused" rather than claiming success blind.
 */
// fleet-send reports three outcomes, not two: 0 delivered, 1 refused, and 2
// armed -- an outward-facing verb asking to be pressed again. Collapsing that
// to a boolean would paint an armed key as "refused", telling the operator
// the press failed at the exact moment it is waiting on them to confirm.
type SendOutcome = "queued" | "refused" | "armed";
const ARMED_EXIT = 2;

function runFleetSend(verb: string): Promise<SendOutcome> {
  return new Promise((resolve) => {
    execFile(interpreter(), [join(REPO, "bin", "fleet-send"), verb], (err) => {
      if (!err) return resolve("queued");
      // execFile surfaces the exit status on `code`; anything else (a signal,
      // a spawn failure) has no code and is a genuine refusal.
      // Node puts the exit status on `code`, but the ErrnoException type
      // declares it a string, so widen through unknown and compare numerically
      // rather than trusting either shape.
      const code = (err as unknown as { code?: number | string }).code;
      if (Number(code) === ARMED_EXIT) {
        streamDeck.logger.info(`fleet-send ${verb} armed; awaiting confirm`);
        return resolve("armed");
      }
      streamDeck.logger.error(`fleet-send ${verb} refused: ${err.message}`);
      resolve("refused");
    });
  });
}

/**
 * Row 2: one key, one verb, sent to whichever agent Row 1 has selected.
 * A press only stages the verb -- delivery happens on the agent's own
 * schedule -- so the feedback here can only say "queued" or "refused",
 * never "done".
 */
@action({ UUID: "com.louisalexander.flightdeck.command" })
export class Command extends SingletonAction<{ verb?: string }> {
  // House pattern from FleetSlot's downAt/visible maps: per-action-id state
  // keyed by action.id. Here it tracks the pending feedback-restore timer,
  // so a second press inside the 1200ms window cancels the first press's
  // restore instead of racing it -- without this, the first timer fires
  // during the second press's feedback and blanks it early, even though the
  // verb genuinely was staged.
  private pending = new Map<string, ReturnType<typeof setTimeout>>();

  override onWillAppear(ev: WillAppearEvent<{ verb?: string }>): void {
    ev.action.setTitle("");           // the SVG carries the label
    this.paintIdle(ev.action, ev.payload.settings?.verb ?? "");
  }

  override onWillDisappear(ev: WillDisappearEvent<{ verb?: string }>): void {
    // A pending restore firing against a torn-down action context is
    // probably a harmless no-op in the SDK, but both sibling actions clean
    // up on disappear and there is no reason for this one not to.
    this.clearPending(ev.action.id);
  }

  override onDidReceiveSettings(ev: DidReceiveSettingsEvent<{ verb?: string }>): void {
    // A settings change makes any in-flight feedback stale by definition --
    // it refers to a verb this key may no longer send -- so a pending
    // restore is cancelled here on its own terms, not just to dodge a
    // stale closure over the old verb.
    this.clearPending(ev.action.id);
    // The operator just picked a different verb in the property inspector;
    // the key face must catch up now, not wait for the next profile switch.
    this.paintIdle(ev.action, ev.payload.settings?.verb ?? "");
  }

  override async onKeyUp(ev: KeyUpEvent<{ verb?: string }>): Promise<void> {
    const id = ev.action.id;
    this.clearPending(id);

    const verb = ev.payload.settings?.verb ?? "";
    if (!verb) {
      // Unconfigured is a refusal too: without this the operator can't
      // tell "nothing to send" from "the press was missed".
      ev.action.setImage(toDataUri(renderCommandSvg("", "refused")));
      this.scheduleRestore(id, ev.action, "");
      return;
    }

    const outcome = await runFleetSend(verb);
    ev.action.setImage(toDataUri(renderCommandSvg(verb.toUpperCase(), outcome)));
    // An armed key must stay readable for as long as the arm is actually
    // live. Reverting early is worse than reverting late: the key would stop
    // inviting a press it would still honour, and the operator reads that as
    // the arm having lapsed. Held just under fleet-send's verbArmSecs (10s)
    // so it stops inviting a press only once it truly cannot honour one.
    // If that setting changes, change this with it -- they are one decision
    // split across two processes.
    this.scheduleRestore(id, ev.action, verb, outcome === "armed" ? 9000 : 1200);
  }

  private paintIdle(action: { setImage(image?: string): Promise<void> }, verb: string): void {
    action.setImage(toDataUri(renderCommandSvg(verb.toUpperCase(), "")));
  }

  // Feedback is a brief change of ink, not a lasting one -- the key returns
  // to idle so it always reads as ready for the next press. What is painted
  // here never changes; only when the restore fires is now tracked.
  private scheduleRestore(
    id: string, action: { setImage(image?: string): Promise<void> }, verb: string,
    afterMs = 1200
  ): void {
    // Clear-before-set, unconditionally: `pending` must never hold a timer
    // that has been superseded. Without this, two presses whose fleet-send
    // round-trips overlap can both reach here with clearPending already
    // behind them (called at the top of onKeyUp, before either awaited) --
    // the first press's timer would then be silently overwritten in the
    // map without being cancelled, so it still fires later and reverts the
    // second press's feedback early.
    this.clearPending(id);
    const timer = setTimeout(() => {
      this.pending.delete(id);
      this.paintIdle(action, verb);
    }, afterMs);
    this.pending.set(id, timer);
  }

  private clearPending(id: string): void {
    const timer = this.pending.get(id);
    if (timer !== undefined) {
      clearTimeout(timer);
      this.pending.delete(id);
    }
  }
}

streamDeck.actions.registerAction(new FleetSlot());
streamDeck.actions.registerAction(new BootTile());
streamDeck.actions.registerAction(new Command());
streamDeck.connect();
