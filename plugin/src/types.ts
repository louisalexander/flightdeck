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
};

export type SlotsFile = { ts: number; overflow: number; slots: Slot[] };

export type StateStyle = {
  color: string;
  glyph: string;
  glyphColor: string;
  textColor: string;
};

export type Config = { states: Record<string, StateStyle> };
