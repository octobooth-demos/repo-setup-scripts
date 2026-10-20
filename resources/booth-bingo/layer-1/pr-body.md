## Stack layer 1 of 3: game logic

Adds the pure `checkWin(board)` function that decides whether a card has a BINGO, plus tests.

- `src/bingo.js`: lists the 8 winning lines (3 rows, 3 columns, 2 diagonals) and returns the first completed line, or `null`.
- `tests/bingo.test.js`: one test per line, plus near-miss and invalid-input cases (`npm test`).

No UI changes yet. The next PR in the stack wires this into the board.

### Review focus

- Are the winning lines correct?
- Is anything missing from the tests?
