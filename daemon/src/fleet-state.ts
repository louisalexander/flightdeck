import { readFileSync, existsSync, watch, type FSWatcher } from "node:fs";
import { join } from "node:path";

function readJson<T>(path: string): T | null {
  try {
    if (!existsSync(path)) return null;
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch {
    return null; // mid-write or corrupt: skip this tick, matching plugin.ts's readJson
  }
}

export function readFleetHome(fleetHome: string): { slots: unknown | null; armed: unknown | null } {
  return {
    slots: readJson(join(fleetHome, "slots.json")),
    armed: readJson(join(fleetHome, "armed.json"))
  };
}

export function watchFleetHome(fleetHome: string, onChange: () => void): { stop: () => void } {
  const watcher: FSWatcher = watch(fleetHome, (_type, filename) => {
    if (filename === "slots.json" || filename === "armed.json") onChange();
  });
  return { stop: () => watcher.close() };
}
