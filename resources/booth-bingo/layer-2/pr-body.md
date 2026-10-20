## Stack layer 2 of 3: wire the UI

Calls `checkWin` (from layer 1) after every tap and highlights the winning line on the card.

- `app.js`: tracks `winningLine` and adds a `win` class to those cells.
- `styles.css`: gold highlight with a gentle pulse for the winning cells.

Builds on layer 1. The next PR adds the celebration.

### Try it

Run `npm start`, open the URL it prints, and tap any row, column, or diagonal.
