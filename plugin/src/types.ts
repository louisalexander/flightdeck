export type Slot = {
  index: number;
  state: string;
  label_top: string;
  label_bottom: string;
  session_id: string;
  host: string;
  iterm_session: string;
  cwd: string;
  app: string;
  focused: boolean;
  // Whatever fleet-emit last recorded for this session, or "" if it never
  // has. Absence means unknown, not "default" -- see Row 1's bypass pip in
  // render.ts, which must never claim a session is guarded when it does not
  // know that.
  permission_mode: string;
};

// The one request Row 3 is answering right now: the selected session's
// pending decision if it has one, otherwise the oldest pending decision.
// bin/fleet-reconcile resolves which; the plugin only renders what it wrote.
export type VerdictTarget = {
  session_id: string;
  agent: string;
  tool: string;
  tier: string;
  repeats: number;
};

export type SlotsFile = {
  ts: number;
  overflow: number;
  slots: Slot[];
  // Fleet-wide deny latch (bin/fleet-halt). An event, not a per-slot state,
  // so it hatches the whole of Row 1 rather than living on one key.
  halted: boolean;
  // null when nothing is pending -- most of the time. Row 3 stays dimmed,
  // not blank, when this is null; see verdict.ts.
  verdict: VerdictTarget | null;
};

export type StateStyle = {
  color: string;
  glyph: string;
  glyphColor: string;
  textColor: string;
};

export type BootConfig = { enabled: boolean; durationMs: number };

export type Config = { states: Record<string, StateStyle>; boot?: BootConfig };
