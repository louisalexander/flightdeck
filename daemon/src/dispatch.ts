import { execFile } from "node:child_process";
import { join } from "node:path";

const LONG_PRESS_MS = 800; // matches config/fleet.json's timings.longPressMs

export function pressVerb(downAtMs: number, upAtMs: number): "short" | "long" {
  return upAtMs - downAtMs >= LONG_PRESS_MS ? "long" : "short";
}

export function runFleetPress(
  interpreter: string, repoRoot: string, index: number, verb: "short" | "long"
): Promise<number> {
  return new Promise((resolve) => {
    execFile(interpreter, [join(repoRoot, "bin", "fleet-press"), String(index), verb], (err) => {
      resolve(err && "code" in err && typeof err.code === "number" ? err.code : 0);
    });
  });
}

export function runFleetSend(interpreter: string, repoRoot: string, verb: string): Promise<number> {
  return new Promise((resolve) => {
    execFile(interpreter, [join(repoRoot, "bin", "fleet-send"), verb], (err) => {
      resolve(err && "code" in err && typeof err.code === "number" ? err.code : 0);
    });
  });
}

export function runFleetVerdict(
  interpreter: string, repoRoot: string, verdict: string, verb?: string
): Promise<number> {
  const args = verb ? [verdict, verb] : [verdict];
  return new Promise((resolve) => {
    execFile(interpreter, [join(repoRoot, "bin", "fleet-verdict"), ...args], (err) => {
      resolve(err && "code" in err && typeof err.code === "number" ? err.code : 0);
    });
  });
}
