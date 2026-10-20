# Booth Bingo

A tiny, no-build web game used to demo **stacked pull requests** on GitHub. Visitors tap squares on a 3x3 card of booth activities; three in a row is BINGO.

`main` contains only the base card. The demo setup script adds one feature as a stack of three small PRs:

| Layer | Branch | Base | What it adds |
| --- | --- | --- | --- |
| 1 | `bingo/1-game-logic` | `main` | `checkWin(board)` + tests |
| 2 | `bingo/2-wire-ui` | layer 1 | Highlight the winning line |
| 3 | `bingo/3-celebration` | layer 2 | CSS confetti, BINGO banner, reset |

## Play it

The game is published to **GitHub Pages** from `main` by `.github/workflows/pages.yml` (the demo setup script turns Pages on and opens the site for you). After every push to `main`, the open page swaps in the new version by itself within about a minute; the badge in the corner says **Updated from main** when it does. No terminal, no refresh.

The setup script creates Booth Bingo repos as **public** so Pages works on free personal accounts.

### Running it locally (optional, offline fallback)

```bash
npm start              # http://localhost:8080 (add "-- --open" to open the browser)
npm run stop           # stop the Booth Bingo server
npm run layer -- 2     # switch to a layer: 0 = main (pulls merged code), 1-3 = the stack
npm test               # node --test
```

No `npm install` is needed; it only uses Node.js 18+. Only one Booth Bingo server runs at a time; starting one stops the previous one.

## Booth talk track (about 5 minutes)

1. **Play the base game** on the Pages site (the setup script opens it): you can tap squares, but nothing happens on three in a row.
2. **Open the top PR** (layer 3, "celebration"). Point out that it targets layer 2, not `main`.
3. **Show the stack navigator** at the top of the PR. Each layer is a small, focused change; reviewers see only that layer's diff.
4. **Review the small PR first.** Jump to layer 1 and review ~50 lines of pure logic and tests. Leave a comment or approve.
5. **(Optional) Fix the bottom of the stack.** Push a change to `bingo/1-game-logic` (for example, add a test for a near-miss board), then click **Rebase stack** so layers 2 and 3 pick it up.
6. **Merge from the top.** Merge layer 3 from the stack UI: the whole stack cascades into `main` in order.
7. **Go back to the game tab.** About a minute later it shows **Updated from main**; get a BINGO.

> Stacks must be merged from the GitHub UI (or the asynchronous merge API), not with `gh pr merge`.
