const COLUMNS = 8;

export function keyIndexToRowCol(index: number): { row: number; col: number } {
  return { row: Math.floor(index / COLUMNS), col: index % COLUMNS };
}

export function rowColToKeyIndex(row: number, col: number): number {
  return row * COLUMNS + col;
}
