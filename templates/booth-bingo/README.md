# Booth Bingo

A tiny, no-build web game used to demo **stacked pull requests** on GitHub. Visitors tap squares on a 3x3 card of booth activities; three in a row is BINGO.

`main` contains only the base card. The demo setup script adds one feature as a stack of three small PRs:

| Layer | Branch | Base | What it adds |
| --- | --- | --- | --- |
| 1 | `bingo/1-game-logic` | `main` | `checkWin(board)` + tests |
| 2 | `bingo/2-wire-ui` | layer 1 | Highlight the winning line |
| 3 | `bingo/3-celebration` | layer 2 | CSS confetti, BINGO banner, reset |

## Run it

```bash
npm start   # serves on http://localhost:8080
npm test    # node --test
```

ES modules need to be served over HTTP, so open the page through `npm start` (or a Codespace / GitHub Pages), not from `file://`.

## Booth talk track (about 5 minutes)

1. **Open the top PR** (layer 3, "celebration"). Point out that it targets layer 2, not `main`.
2. **Show the stack navigator** at the top of the PR. Each layer is a small, focused change; reviewers see only that layer's diff.
3. **Review the small PR first.** Jump to layer 1 and review ~50 lines of pure logic and tests. Leave a comment or approve.
4. **(Optional) Fix the bottom of the stack.** Push a change to `bingo/1-game-logic` (for example, add a test for a near-miss board), then click **Rebase stack** so layers 2 and 3 pick it up.
5. **Merge from the top.** Merge layer 3 from the stack UI: the whole stack cascades into `main` in order.
6. **Play the game** on `main` and get a BINGO.

> Stacks must be merged from the GitHub UI (or the asynchronous merge API), not with `gh pr merge`.
