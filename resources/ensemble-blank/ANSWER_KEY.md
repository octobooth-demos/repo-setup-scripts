# Ensemble blank-prompt answer key

> **Presenters only.** This file lives in `repo-setup-scripts` and is never copied into
> demo repos (the `blank` workflow creates an empty repo with only a README). Don't show it on screen.

`create-repo` creates an empty repo (`ensemble-blank-xxxx`, README only) in `octobooth-demos`.
You hand Copilot **one** prompt, pick **Ensemble**, switch to **autopilot**, and let it build a
working, tested game from nothing while you talk.

## The seed prompt

Also in [`seed-prompt.txt`](seed-prompt.txt). The Demo Launcher shows it with a **Copy** button.

> Build a single-page browser game called "Mona Merge Rush": a 2048-style game where tiles merge into GitHub Octocat variants. Use plain HTML, CSS and JS with no build step. Include keyboard and swipe controls, score and best score in localStorage, smooth animations, a game-over screen and restart. Add a small test file for the merge logic using node:test, and make sure the tests pass.

## Running it

**Fastest: Demo Launcher.** After the run finishes, click **▶ Run with Ensemble**. Copilot opens a new
session in the demo repo with the seed prompt, the Ensemble model, and autopilot already set.

**By hand (Copilot app):**

1. In the launcher, click **Open session in Copilot app** (or open the repo as a project).
2. In the model picker, choose **Auto** and then the **Ensemble** tier (it may still be labeled
   **HydraFusion** in some builds).
3. Switch the mode to **Autopilot**.
4. Paste the seed prompt and send.

**By hand (Copilot CLI):** `cd ~/repos/ensemble-blank-xxxx && copilot`, pick the Ensemble/HydraFusion
model with `/model`, switch to autopilot (<kbd>Shift</kbd>+<kbd>Tab</kbd>), and paste the prompt.

## What to expect

- **~4-5 minutes** end to end. In our dry run it finished in about 4.3 minutes.
- Files: `index.html`, `styles.css`, `game.js`, `logic.js`, `logic.test.js`, `README.md`
  (names can vary a little between runs).
- `node --test` passes (10/10 in our dry run). Copilot runs it itself because the prompt says
  "make sure the tests pass".
- Open `index.html` in a browser (or ask Copilot to "open it") and play: arrow keys/WASD on a
  laptop, swipe on a phone or trackpad. Refresh to show the best score persists.
- Good closer: ask Copilot to commit and push, or to open a PR, so the audience sees a real repo.

If a run stalls or fails, delete the repo (launcher **Clean up** section) and create a fresh one.
It's non-deterministic: the game will look a bit different every time, which is part of the fun.

## Talking points

**What it is.** Ensemble (formerly Project HydraFusion) is a Copilot model option that delivers
frontier-level quality by orchestrating *several* models per request. You pick it once like any
other model; it plans the workflow behind the scenes.

**How it decides.** For each request it picks the least complex workflow likely to meet the quality bar:

| Pattern | What happens | When it helps |
|---------|--------------|---------------|
| **Single** | One selected model solves the task directly. | The task is straightforward; keeps it fast and cheap. |
| **Cascade** | An efficient model drafts; a quality gate accepts it or escalates to a stronger model. | Most tasks: cheap first try, strong fallback. |
| **Critique** | One model drafts; an independent, **read-only** critic from a *different model family* reviews it (the Rubber Duck pattern); the drafter revises once. | Tasks where a second opinion beats another solo attempt. |

**The numbers** (offline benchmarks vs. Claude Opus 5, from the blog post):

| Benchmark | Cost vs. Opus 5 | Quality vs. Opus 5 |
|-----------|-----------------|--------------------|
| TerminalBench 2.1 | **67% lower** | **+4.9 points** |
| DeepSWE | 36% lower | -1.5 points |
| CheckpointBench (real Copilot sessions) | 65% lower | -0.1 points |

Sound bite: **"Frontier quality, about Opus 5 or better, at 36-67% lower cost."**

**Why it's safe to hand it a repo.** Review steps run in isolated, tool-less contexts (critics can't
edit your code); every leg has timeouts and cost accounting; if a workflow is cancelled or fails
validation, no patch is applied. You get one coherent answer and one change set.

**Why this demo shape.** The preview works best on **first-turn, single-prompt, substantial,
well-scoped** tasks run in **autopilot**. That's exactly this demo: an empty repo and one prompt.

Source: [Project HydraFusion: frontier quality via multi-model orchestration](https://github.blog/ai-and-ml/github-copilot/project-hydrafusion-frontier-quality-via-multi-model-orchestration/).
Feedback goes to `/feedback` in Copilot CLI or the [community discussion](https://github.com/orgs/community/discussions/206492).

## Alternate prompts

Use these for repeat visitors or a longer slot. Same setup: fresh blank repo, Ensemble, autopilot.

**Harder game (~6-8 min).**

> Build a single-page browser game called "Mona Merge Rush Deluxe": a 2048-style game where tiles merge into GitHub Octocat variants. Use plain HTML, CSS and JS with no build step. Include keyboard and swipe controls, an undo button (one step), three switchable themes (light, dark, and high contrast) remembered in localStorage, and sound effects generated with the Web Audio API (no audio files) with a mute toggle. Keep score and best score in localStorage, add smooth animations, a win screen at the 2048 tile with "keep playing", a game-over screen and restart. Put the game logic in its own module and test it with node:test, including merges, undo, and win/lose detection, and make sure the tests pass.

**Terminal CLI (Python).**

> Create a Python command-line tool called `octostat` that prints statistics for the git repository in the current directory: total commits, commits per author, the busiest weekday and hour, the most frequently changed files, and lines added/removed over the last 30 days. Use only the standard library plus `subprocess` calls to `git`, render a tidy text table with a simple bar chart, and support `--since`, `--top N`, and `--json` options. Package it with a `pyproject.toml` so `pip install -e .` adds an `octostat` command. Add pytest tests that build a temporary git repo with known commits, and make sure the tests pass.

Tip for the CLI prompt: after it finishes, run `octostat` on `repo-setup-scripts` itself for a fun reveal.

**Small web app.**

> Build a single-page "Booth Badge Maker" web app with plain HTML, CSS and JS and no build step: the user types a name and GitHub handle, picks an Octocat avatar and a color theme, and sees a live preview of a conference badge they can download as a PNG using a canvas. Make it responsive and accessible (labels, keyboard focus, good contrast). Put the badge layout logic in its own module, test it with node:test, and make sure the tests pass.
