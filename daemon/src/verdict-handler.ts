import { renderVerdictSvg, renderDetailFeedback, verdictLabel, type Feedback } from "../../plugin/src/verdict";
import type { VerdictTarget, SlotsFile } from "../../plugin/src/types";
import { runFleetVerdict } from "./dispatch";
import { readFleetHome } from "./fleet-state";
import type { Keymap, Row3Entry } from "./keymap";
import { keyIndexToRowCol } from "./row-math";

function entryForKey(keymap: Keymap, keyIndex: number): Row3Entry | undefined {
  const { row, col } = keyIndexToRowCol(keyIndex);
  if (row !== 2) return undefined;
  return keymap.row3[col];
}

function targetFrom(fleetHome: string): VerdictTarget | null {
  const { slots } = readFleetHome(fleetHome);
  return (slots as SlotsFile | null)?.verdict ?? null;
}

// Mirrors plugin.ts's Verdict.render() exactly: DETAIL never touches renderVerdictSvg at all,
// every other verdict computes active/tier/scope from the target and calls it with the real
// 5-argument shape.
function render(entry: Row3Entry, target: VerdictTarget | null, feedback: Feedback): string {
  if (entry.verdict === "detail") return renderDetailFeedback(target, feedback);
  const active = target !== null;
  const tier = target?.tier ?? "normal";
  const scope = entry.verdict === "remember"
    ? { repo: target?.repo ?? "", rule: target?.rule ?? "" }
    : null;
  return renderVerdictSvg(verdictLabel(entry.verdict, entry.verb ?? ""), tier, feedback, active, scope);
}

export function paintVerdictIdle(fleetHome: string, keymap: Keymap, keyIndex: number): string {
  const entry = entryForKey(keymap, keyIndex);
  if (!entry) return renderVerdictSvg("", "normal", "refused", false, null);
  return render(entry, targetFrom(fleetHome), "");
}

export async function handleVerdictKeyUp(
  interpreter: string, repoRoot: string, fleetHome: string, keymap: Keymap, keyIndex: number
): Promise<string> {
  const entry = entryForKey(keymap, keyIndex);
  if (!entry) return renderVerdictSvg("", "normal", "refused", false, null);

  const exitCode = await runFleetVerdict(interpreter, repoRoot, entry.verdict, entry.verb);
  const outcome: Feedback = exitCode === 0 ? "delivered" : exitCode === 2 ? "armed" : "refused";
  const target = targetFrom(fleetHome);

  if (entry.verdict === "detail") {
    return outcome !== "delivered"
      ? renderDetailFeedback(target, "refused")
      : renderDetailFeedback(target, "");
  }
  return render(entry, target, outcome);
}
