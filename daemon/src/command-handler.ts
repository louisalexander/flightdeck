import { renderCommandSvg } from "../../plugin/src/command.js";
import { runFleetSend } from "./dispatch.js";
import type { Keymap } from "./keymap.js";
import { keyIndexToRowCol } from "./row-math.js";

function verbForKey(keymap: Keymap, keyIndex: number): string | undefined {
  const { row, col } = keyIndexToRowCol(keyIndex);
  if (row !== 1) return undefined;
  return keymap.row2[col];
}

export function paintCommandIdle(keymap: Keymap, keyIndex: number): string {
  const verb = verbForKey(keymap, keyIndex);
  return renderCommandSvg(verb ? verb.toUpperCase() : "", "");
}

export async function handleCommandKeyUp(
  interpreter: string, repoRoot: string, keymap: Keymap, keyIndex: number
): Promise<{ svg: string; outcome: "" | "queued" | "refused" | "armed" }> {
  const verb = verbForKey(keymap, keyIndex);
  if (!verb) return { svg: renderCommandSvg("", "refused"), outcome: "refused" };

  const exitCode = await runFleetSend(interpreter, repoRoot, verb);
  const outcome = exitCode === 0 ? "queued" : exitCode === 2 ? "armed" : "refused";
  return { svg: renderCommandSvg(verb.toUpperCase(), outcome), outcome };
}
