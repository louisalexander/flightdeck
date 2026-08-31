import { readFileSync, existsSync } from "node:fs";

export type Row3Entry = { verdict: string; verb?: string };
export type Keymap = { row2: string[]; row3: Row3Entry[] };

export const DEFAULT_KEYMAP: Keymap = {
  row2: ["test", "diff", "note", "push", "pr", "review", "stop", "confirm"],
  row3: [
    { verdict: "detail" },
    { verdict: "approve" },
    { verdict: "remember" },
    { verdict: "deny" },
    { verdict: "interrupt" },
    { verdict: "steer", verb: "justify" },
    { verdict: "steer", verb: "otherway" },
    { verdict: "steer", verb: "dryrun" }
  ]
};

export function loadKeymap(path: string): Keymap {
  try {
    if (!existsSync(path)) return DEFAULT_KEYMAP;
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    if (!Array.isArray(parsed.row2) || !Array.isArray(parsed.row3)) return DEFAULT_KEYMAP;
    return parsed as Keymap;
  } catch {
    return DEFAULT_KEYMAP;
  }
}
