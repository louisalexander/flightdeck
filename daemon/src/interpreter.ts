import { readFileSync } from "node:fs";
import { join } from "node:path";

export function resolveInterpreter(fleetHome: string): string {
  try {
    const pinned = readFileSync(join(fleetHome, "interpreter"), "utf8").trim();
    if (pinned) return pinned;
  } catch {
    // no pinned file: fall through
  }
  return "python3";
}
