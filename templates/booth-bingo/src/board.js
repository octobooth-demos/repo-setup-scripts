export const SQUARES = [
  'Grabbed a sticker',
  'Watched a Copilot demo',
  'Met a Hubber',
  'Starred a repo',
  'FREE',
  'Took an Octocat selfie',
  'Opened a pull request',
  'Asked a great question',
  'Played a booth game',
];

export const FREE_INDEX = 4;

/** A fresh card: only the FREE square starts marked. */
export function createBoard() {
  return SQUARES.map((_, i) => i === FREE_INDEX);
}

/** Returns a new board with the square at `index` toggled. FREE stays marked. */
export function toggle(board, index) {
  const next = board.slice();
  if (index !== FREE_INDEX) {
    next[index] = !next[index];
  }
  return next;
}
