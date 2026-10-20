# Demo repository setup

Create demo repositories (private unless a template says otherwise) from the templates in [`config.json`](config.json), with optional branches, issues, demo pull requests, security features, and Codespaces.

## PowerShell

Run [`create-repo.ps1`](create-repo.ps1) with Windows PowerShell 5.1 or [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell). Install the [GitHub CLI](https://cli.github.com/) and [Git](https://git-scm.com/downloads) first and ensure both are on your `PATH`. No `jq` installation is required.

```powershell
.\create-repo.ps1
```

Select a template when prompted. The script offers GitHub login if needed, creates a repository in the [target owner](#where-repos-are-created), clones it into `$HOME/repos`, and runs the selected workflow. You need permission to create repositories in that organization and any permissions required for the selected security or Codespaces features.

Configuration and resource paths are resolved relative to the script, so it can be invoked from another directory. The script restores your working directory and removes its temporary security-demo clone even if a command fails. The permanent clone and any already-created GitHub resources are retained on failure; errors stop the script rather than continuing with incomplete setup.

## Bash

[`create-repo.sh`](create-repo.sh) uses the same configuration and resources. It requires the GitHub CLI, Git, and [`jq`](https://jqlang.org/).

```bash
bash ./create-repo.sh
```

## Non-interactive mode

Both scripts accept a template key (the `key` field in `config.json`) to skip the menu:

```bash
bash ./create-repo.sh --template booth-bingo [--no-clone]
```

```powershell
.\create-repo.ps1 -Template booth-bingo [-NoClone]
```

With no arguments the scripts behave exactly as before. In non-interactive mode they never start `gh auth login`; authenticate first (or set `GH_TOKEN`), otherwise the script fails. `--no-clone` / `-NoClone` skips the permanent clone into `~/repos` and is rejected for `branch_and_codespace`. Unknown keys fail before anything is created and list the valid keys.

Every repository the scripts create gets the `demo-generated` topic, which is what [cleanup](#cleaning-up) uses to find demo repos.

## Where repos are created

By default, repos are created in **the account that is logged in** (`gh api user`), so each booth machine (`octobooth-1`, `octobooth-2`, …) gets its own copies. The owner is resolved in this order:

1. `--owner <name>` / `-Owner <name>`
2. The config entry's `owner` field. `"owner": "org"` means the top-level `org`; any other value is used as-is. `security-octo-supply` is pinned to the org because it needs code scanning.
3. The logged-in account.
4. The top-level `org` (only when there is no user account, such as a GitHub App token in Actions).

The script prints `Target owner:` before creating anything. Templates in `octobooth-demos` are internal, so the booth account must be an org member to use them.

> [!NOTE]
> `tailspin-toys` assigns an issue to `@copilot` and starts a Codespace. In a personal account those need Copilot coding agent and Codespaces access on that account. If they are not available, run it with `--owner octobooth-demos`.

## Showing the game

Booth Bingo is published to **GitHub Pages**. After creating the stack, the script turns Pages on, deploys `main`, waits for the deploy (usually under a minute), and opens two browser tabs: the top PR and the game (in front). Nothing runs locally.

```bash
bash ./create-repo.sh --template booth-bingo
```

```powershell
.\create-repo.ps1 -Template booth-bingo
```

The game page checks for a new deploy every few seconds and swaps it in by itself, so after you merge the stack, just switch back to the game tab: about a minute later the corner badge says **Updated from main** and the finished game is there. No terminal and no refresh. The deploy comes from the template's `.github/workflows/pages.yml`, which runs on every push to `main`.

Pages on free personal accounts only works for public repos, so Booth Bingo repos are created **public** (`"visibility": "public"` in `config.json`). If Pages can't be turned on, the script warns and still finishes; the repo and stack are usable without it.

### Running it locally instead (optional)

`--serve` / `-Serve` checks out `main` in `~/repos/<repo>` and runs `npm start -- --open` (http://localhost:8080, Node.js 18+, not combinable with `--no-clone`). Only one Booth Bingo server runs at a time, and `npm run stop` stops it. Locally, you switch code yourself: `npm run layer -- 1`..`3` previews a layer and `npm run layer -- 0` pulls the merged `main`.

## Cleaning up

Delete old demo repos from the logged-in account (or `--owner` / `-Owner`). Only repos with the `demo-generated` topic that are older than the cutoff (default 24 hours) are considered; everything else is left alone. The script lists matches and asks before deleting.

```bash
bash ./create-repo.sh --cleanup [--older-than 24] [--dry-run] [--yes] [--owner <name>]
```

```powershell
.\create-repo.ps1 -Cleanup [-OlderThanHours 24] [-DryRun] [-Yes] [-Owner <name>]
```

Deleting repos needs the `delete_repo` scope. The scripts request it when they log in; for an existing login run `gh auth refresh -h github.com -s delete_repo`.

### Which cleanup covers which repos

| Where the demo repo lives | How it gets cleaned up |
| --- | --- |
| A booth account (`octobooth-1`, `octobooth-2`, …), the default | Run `--cleanup` / `-Cleanup` **on that machine**. Nothing else can reach it, because the [ChatOps App](#chatops) is only installed on the org. |
| The `octobooth-demos` org (`--owner octobooth-demos`, ChatOps, `security-octo-supply`) | Automatic: the [nightly cleanup](.github/workflows/cleanup-demos.yml) deletes them at 08:00 UTC. To clean up sooner, comment `/cleanup` or run the workflow from the Actions tab. |

**Recommended booth routine (repos in each booth account):**

```bash
# Start of the day, once per machine
gh auth refresh -h github.com -s delete_repo

# Each demo
git pull
bash ./create-repo.sh --template booth-bingo

# End of the day (or the next morning): remove that account's demos older than 24h
bash ./create-repo.sh --cleanup
# or remove everything from today: bash ./create-repo.sh --cleanup --older-than 0
```

**Fallback (repos in the org, cleaned up automatically):** add `--owner octobooth-demos` (or `-Owner octobooth-demos`) when creating demos. Nothing needs to run on the machines afterwards. This requires the booth accounts to be `octobooth-demos` members who are allowed to create repos, including **public** ones (Booth Bingo is public so GitHub Pages works).

## Workflows and config fields

Each `repos[]` entry needs `key`, `display_name`, `template`, `repo_base_name`, and `workflow`. Optional `template_org` overrides the top-level `org` for the template source, optional `owner` pins where the repo is created (see [above](#where-repos-are-created)), optional `visibility` (`private` by default, or `public` / `internal`) sets the new repo's visibility, optional `"pages": true` turns on GitHub Pages and deploys it with the template's `pages.yml` workflow (see [Showing the game](#showing-the-game); Booth Bingo sets both), optional `"serve": true` starts the [local preview](#running-it-locally-instead-optional) whenever the repo is cloned, and `summary_lines` are printed at the end.

| `workflow` | Extra fields | What it does |
| --- | --- | --- |
| `repo_only` | — | Creates the repo. |
| `issue_and_codespace` | `issue` | Creates an issue and a Codespace. |
| `security_prs` | `prs[]` | Enables security features and opens one PR per entry against the default branch. |
| `branch_and_codespace` | `branch` | Creates a branch and a Codespace on it. |
| `code_review_prs` | `prs[]` | Opens one PR per entry against the default branch and requests a Copilot Code Review on each. No security features are enabled. |
| `stacked_prs` | `stack[]` | Opens a chain of dependent PRs and registers them as a native [stacked PR](https://docs.github.com/en/pull-requests/reference/stacked-pull-requests-apis-and-webhooks). |

`prs[]` and `stack[]` entries share the same shape: `branch`, `resource_dir`, `commit_message`, `title`, and `body_file` (a path inside `resource_dir`; it is used as the PR body and never committed). `stack[]` must have at least 2 entries, listed bottom to top. Each layer is branched from the one below, its `resource_dir` is copied over the tree, and the PR targets the branch below it. After all PRs are open the scripts call `POST /repos/{owner}/{repo}/stacks` and verify the order. If registration fails, the PR chain still exists and the script exits non-zero.

### Booth Bingo (stacked PRs)

`booth-bingo` creates a repo from [`octobooth-demos/booth-bingo`](https://github.com/octobooth-demos/booth-bingo) (a template repo whose source lives in [`templates/booth-bingo`](templates/booth-bingo)) and opens three small stacked PRs from [`resources/booth-bingo`](resources/booth-bingo):

1. `bingo/1-game-logic` → `main`: `checkWin()` plus `node --test` tests
2. `bingo/2-wire-ui` → layer 1: highlight the winning line
3. `bingo/3-celebration` → layer 2: banner, confetti, reset

Each overlay holds the cumulative files for its layer. The booth talk track is in the template's README. The game is served from [GitHub Pages](#showing-the-game) and updates itself after the stack is merged. Merge stacks from the GitHub UI, not `gh pr merge`.

### OctoCart (Copilot Code Review)

`octocart` creates a repo from [`octobooth-demos/octocart`](https://github.com/octobooth-demos/octocart). It's a small TypeScript store (Express API + React/Vite) whose `.github/copilot-instructions.md` and `.github/instructions/*.instructions.md` define house rules. The script then opens three feature PRs from [`resources/octocart`](resources/octocart):

1. `feature/stackable-promo-codes`: stackable promo codes and sale pricing, with subtle correctness bugs (a boundary error, float money math, missing `await`s)
2. `feature/order-history-export`: order history and a CSV export, with security, performance, and robustness issues (IDOR, token in the URL, CSV injection, N+1)
3. `feature/wishlist`: a wishlist that works, but breaks most of the repo's custom instructions, which makes it the custom-instructions showcase

The overlays are written against the template's app (introduced in [octobooth-demos/octocart#1](https://github.com/octobooth-demos/octocart/pull/1)), so that PR must be merged before the demo is used. All three PRs pass the template's CI (lint, typecheck, tests, build), and the PR descriptions don't hint at the problems. After each PR is opened, the script requests a review from Copilot with `gh pr edit --add-reviewer @copilot`. If that fails (for example, with an older `gh`), it falls back to `POST /pulls/{n}/requested_reviewers` with `copilot-pull-request-reviewer[bot]`. If both fail, it warns and keeps going, and you can request the review from the PR page instead.

Like every other template, the repo is created under `--owner` / `-Owner` or the signed-in booth account, and cloned to `~/repos/<repo>` unless you pass `--no-clone`. The PR branches are fetched into that clone, so the PRs show up in the Copilot app as well as on github.com. The script opens the repo's pull request list in the browser at the end.

The **presenter answer key**, [`resources/octocart/ANSWER_KEY.md`](resources/octocart/ANSWER_KEY.md), lists every planted issue with its file, line, and the rule it breaks. It stays in this repo and is never copied into the demo repo.

## ChatOps

Two workflows in this repo let you create and clean up demos without a booth machine running the script.

- **[New demo](.github/workflows/new-demo.yml)**: run it from the Actions tab and pick a template, or comment `/new-demo <key>` on any issue or PR in this repo. Repos are always created in `octobooth-demos`, because App tokens cannot create repos in personal accounts. It replies with the repo URL and, for stacks, the top PR URL and the game URL (for OctoCart, the pull request list). Only `repo_only`, `security_prs`, `stacked_prs`, and `code_review_prs` templates are allowed, because Codespaces need a user token.
- **[Clean up demos](.github/workflows/cleanup-demos.yml)**: runs nightly, from the Actions tab (`max_age_hours`, default 24; `dry_run`, default on), or by comment: `/cleanup [hours] [--dry-run]`. It only deletes repos in `octobooth-demos` that have the `demo-generated` topic **and** are older than the cutoff. It cannot see repos in booth accounts; see [Which cleanup covers which repos](#which-cleanup-covers-which-repos).

Comment commands only run for users with write, maintain, or admin access to this repository.

### GitHub App setup (one-time, org owner)

The workflows authenticate as a GitHub App so they can create and delete org repos.

1. Create a GitHub App owned by `octobooth-demos` (no webhook needed) with these **repository** permissions:
   - Administration: Read and write (create from template, add topics, delete repos)
   - Contents: Read and write (push branches)
   - Pull requests: Read and write (open PRs, register stacks)
   - Issues: Read and write (issue-based templates)
   - Workflows: Read and write (templates contain `.github/workflows`)
   - Pages: Read and write (turn on GitHub Pages for Booth Bingo)
   - Actions: Read and write (start the first Pages deploy)
   - Metadata: Read-only (required)
2. Install it on the `octobooth-demos` org with access to **All repositories** (new demo repos must be covered automatically).
3. In this repo's **Settings → Secrets and variables → Actions**, add `APP_ID` (the App ID) and `APP_PRIVATE_KEY` (the full contents of a generated `.pem` private key).

The security features enabled by `security_prs` (Dependabot alerts, automated security fixes, CodeQL default setup) are covered by Administration write.

## Local checks

Run the standalone PowerShell checks without creating any GitHub resources. They mock GitHub CLI and Git commands and use temporary fixture directories.

```powershell
.\tests\create-repo.Tests.ps1
```
