import { renderSvg } from "../../plugin/src/render";
import type { Config, Slot } from "../../plugin/src/types";
import { readFleetHome } from "./fleet-state.js";
import { keyIndexToRowCol } from "./row-math.js";

const EMPTY = (index: number): Slot => ({
  index, state: "empty", label_top: "", label_bottom: "",
  session_id: "", host: "", iterm_session: "", cwd: "", app: "",
  focused: false, permission_mode: ""
});

export function paintSlot(fleetHome: string, config: Config, keyIndex: number): string {
  const { col } = keyIndexToRowCol(keyIndex);
  const { slots, armed } = readFleetHome(fleetHome);
  const slotsList = (slots as { slots?: Slot[]; halted?: boolean } | null)?.slots ?? [];
  const slot = slotsList.find((s) => s.index === col) ?? EMPTY(col);
  const armedFile = armed as { index?: number } | null;
  const isArmed = armedFile?.index === col;
  const halted = Boolean((slots as { halted?: boolean } | null)?.halted);
  return renderSvg(slot, config, isArmed, slot.permission_mode, halted);
}
