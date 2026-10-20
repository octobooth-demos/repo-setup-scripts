const SIZE = 3;

const rows = [0, 1, 2].map((r) => [r * SIZE, r * SIZE + 1, r * SIZE + 2]);
const columns = [0, 1, 2].map((c) => [c, c + SIZE, c + 2 * SIZE]);
const diagonals = [[0, 4, 8], [2, 4, 6]];

/** Every line that counts as BINGO: 3 rows, 3 columns, 2 diagonals. */
export const LINES = [...rows, ...columns, ...diagonals];

/**
 * Returns the first completed line (an array of cell indexes), or null.
 * @param {boolean[]} board 9 cells in row-major order; true = marked.
 */
export function checkWin(board) {
  if (!Array.isArray(board) || board.length !== SIZE * SIZE) {
    throw new TypeError(`board must be an array of ${SIZE * SIZE} cells`);
  }
  return LINES.find((line) => line.every((i) => board[i])) ?? null;
}
