# Demo repository setup

Create demo repositories (private unless a template says otherwise) from the templates in [`config.json`](config.json), with optional branches, issues, demo pull requests, security features, and Codespaces.

There are three ways to create a demo, and all of them run the same scripts and config:

- **[Demo Launcher canvas](#demo-launcher-canvas)**: a side panel in the GitHub Copilot app. Pick a demo, click **Create**, then jump into the repo, PR, or session. This is the easiest option at the booth. If the canvas is ever unavailable, the [standalone Demo Launcher](#standalone-demo-launcher) is the same kind of GUI in a browser.
- **[`create-repo.sh` / `create-repo.ps1`](#bash)**: the scripts the launcher runs, used interactively or [non-interactively](#non-interactive-mode).
- **[ChatOps](#chatops)**: `/new-demo <key>` comments or the Actions tab. These create demos in the `octobooth-demos` org without a booth machine.

## Quick start (booth machine)

Do this once per machine (macOS):

1. Install the tools:

   ```bash
   brew install gh jq
   ```

   Then log in to the GitHub CLI **as the booth account** (for example `octobooth-1`), not your personal account. Demos are created in the logged-in account and in the `octobooth-demos` org:

   ```bash
   unset GH_TOKEN GITHUB_TOKEN   # login and refresh fail while either is set
   gh auth login        # GitHub.com → HTTPS → "Authenticate Git" Yes → Login with a web browser
   gh auth refresh -h github.com -s codespace,delete_repo
   gh auth status       # should show the booth account and both scopes
   ```

   - `codespace` lets Tailspin Toys create its Codespace.
   - `delete_repo` lets the launcher's **Clean up** (and `--cleanup`) delete old demo repos.
   - The default scopes (`repo`, `read:org`, `gist`) cover everything else. Answer **Yes** to "Authenticate Git" so the scripts can push demo branches over HTTPS.
   - The booth account must be a member of the `octobooth-demos` org and allowed to create repos there. The security demos (`security-octo-supply`, `security-octo-supply-v4`, and `ai-security`) always create their repo in that org.
   - The booth account also needs a Copilot seat (for Copilot code review and assigning issues to Copilot) and access to Codespaces (for Tailspin Toys).
   - If `GH_TOKEN` or `GITHUB_TOKEN` is set, `gh auth login`/`refresh` refuse to run and `gh` uses the token instead of the booth login. Remove them from your shell profile on booth machines too. The Demo Launcher already ignores them when a stored login exists, but terminal runs of `create-repo` don't.

2. Clone this repo to `~/repos/repo-setup-scripts`:

   ```bash
   gh repo clone octobooth-demos/repo-setup-scripts ~/repos/repo-setup-scripts
   ```

3. In the GitHub Copilot app, add that **existing local folder** (`~/repos/repo-setup-scripts`) as a project. Don't clone it again. Sessions in this project can always open the Demo Launcher.
4. Also install the loader so other sessions can open it too (see [details](#make-it-available-in-every-session)):

   ```bash
   cd ~/repos/repo-setup-scripts
   bash .github/extensions/demo-launcher/install.sh
   ```

   Then restart the Copilot app (or reload extensions in open sessions). The project and the loader now use the same checkout.

5. Optional fallback: run the [standalone Demo Launcher](#standalone-demo-launcher) as a login service so it's always at http://127.0.0.1:4747/ in a browser:

   ```bash
   bash standalone-launcher/install-service.sh
   ```

Before each booth day, run `git -C ~/repos/repo-setup-scripts pull` and restart the app; that updates both. Then ask Copilot to **"open the demo launcher"**. If a session outside the project can't find it, open it from a session in the `repo-setup-scripts` project instead. At the end of the day, use the launcher's **Clean up** section or `bash ./create-repo.sh --cleanup` (see [Cleaning up](#cleaning-up)).

## Demos

Each entry in [`config.json`](config.json) is one demo. Pass its key to `--template` / `-Template` or pick it in the launcher.

| Key | Demo | What gets created | Presenter notes |
| --- | --- | --- | --- |
| `securing-your-code` | Secure Code | Repo only, from `github-samples/securing-your-code` | Labs live in the repo |
| `security-octo-supply` | Security Supply Chain | Repo in the `octobooth-demos` org with Dependabot, autofix, and CodeQL turned on, plus two vulnerable PRs (TypeScript and PHP) | Pinned to the org for code scanning |
| `security-octo-supply-v4` | Security Supply Chain (v4) | Same as `security-octo-supply`, but built on the v4 OctoCAT Supply template (Express 5, React 19, Vite 8) | Pinned to the org. PHP findings need AI Code Scanning ([details](#security-supply-chain-v4)) |
| `tailspin-toys` | Tailspin Toys | Repo, an issue assigned to Copilot coding agent, and a Codespace | Needs coding agent and Codespaces on the owner ([note](#where-repos-are-created)) |
| `ctrl-slash` | Ctrl Slash | Repo only | |
| `booth-bingo` | Booth Bingo (stacked PRs) | Public repo, 3 stacked PRs registered as a native stack, and GitHub Pages | [Details](#booth-bingo-stacked-prs); talk track in the template's README |
| `octocart` | OctoCart (Copilot Code Review) | Repo with 4 feature PRs. Copilot Code Review is requested on 3 of them; the 4th is left for you to request live | [Details](#octocart-copilot-code-review); [answer key](resources/octocart/ANSWER_KEY.md) (presenters only) |
| `ai-security` | AI Security (AI Scan + agentic autofix) | Repo in the `octobooth-demos` org with an infra PR that AI Scan reviews, plus CodeQL alerts on `main` with one already assigned to Copilot | [Details](#ai-security-ai-scan--agentic-autofix); [presenter notes](resources/ai-security/ANSWER_KEY.md). **Pre-bake it:** it takes about 20 minutes to be fully ready |
| `fusion-blank` | GitHub Copilot Fusion: Blank Prompt | Empty repo (README only) in the booth account, plus a seed prompt you run with the GitHub Copilot Fusion model in autopilot | [Details](#github-copilot-fusion-blank-prompt); [presenter notes](resources/fusion-blank/ANSWER_KEY.md) |

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

When `GITHUB_OUTPUT` is set (in Actions, or by the Demo Launcher), the scripts write `repo_name`, `repo_url`, and, depending on the workflow, `top_pr_url`, `pages_url`, and `pulls_url` to it. `DEMO_NO_BROWSER=1` stops them from opening browser tabs. The launcher sets this unless you tick **Let script open browser tabs**.

Every repository the scripts create gets the `demo-generated` topic, which is what [cleanup](#cleaning-up) uses to find demo repos. If the topic cannot be added (after retries), the script deletes the new repo and stops, so no untagged demo repo is left behind.

## Demo Launcher canvas

[`.github/extensions/demo-launcher/`](.github/extensions/demo-launcher/) is a Copilot extension that adds a **Demo Launcher** canvas, a side panel, to the GitHub Copilot app and Copilot CLI. To open it, ask Copilot to **"open the demo launcher"**, or "open the demo launcher for octocart" to preselect a demo.

### What it does

- **Create demos in the background.** It lists every template in `config.json` and runs `create-repo.sh --template <key>` (or `create-repo.ps1 -Template <key>` on Windows) for the one you pick. Optional settings: owner, **Skip local clone** (`--no-clone`), and **Let script open browser tabs**. You can start several runs at once, and each gets its own repo, clone, and card, so every visitor can have their own copy.
- **Show live progress and links.** Each run card streams the script log. When the run finishes, the card links to the repo, PRs, issues, Pages site, and local clone.
- **Show Copilot Code Review state (OctoCart).** Each PR shows whether a review was requested:
  - ✓ requested
  - ✓ requested via REST
  - ⚠️ the request failed (pick Copilot under **Reviewers** on the PR)
  - 👋 deliberately left for a live review

  The card also links to the repo's pull request list and has a **🔑 Presenter answer key** button. The button opens `resources/<key>/ANSWER_KEY.md` from this repo on your machine (in VS Code if it's installed). The answer key is never copied into demo repos, so keep it off the shared screen.
- **One-click follow-ups.** **Open session in Copilot app** has Copilot add the repo as a project and open a fresh session. **Open PR session** and **Open issue session** open those items. **Open in VS Code** runs `code <clone>`.
- **Seed prompts.** For demos with a `seed_prompt_file` (like `fusion-blank`), the card shows the prompt with **📋 Copy** and **▶ Run with Fusion**. Run with Fusion has Copilot add the repo as a project and start a new autopilot session that runs the prompt on the GitHub Copilot Fusion model (`model: "auto"`, `auto_tier: "hydrafusion"`).
- **Clean up.** This works like `--cleanup`. Pick an owner and an age cutoff (default 72 hours, or **Any age**), review the matching `demo-generated` repos, and untick any you want to keep. Then delete the rest, optionally with their clones in `~/repos`. Deleting needs the `delete_repo` scope.

Runs use your stored `gh auth login`, not any `GH_TOKEN` the app injects, so they have the same scopes as a terminal run. Run history survives restarts. It's kept in `~/.copilot/extensions/demo-launcher/artifacts/runs.json`, and **Clear history** empties it. The panel is a plain loopback web page, so its URL also works in a browser, including VS Code's Simple Browser. The port changes each time the extension restarts.

### Where it's available

| Session | Canvas available? |
| --- | --- |
| Any session in the `repo-setup-scripts` project, including worktrees and PR sessions | Yes. Copilot loads project extensions from `.github/extensions/`, and each session uses its own checkout's copy. |
| Any other session (a demo repo, another project, or a chat) | Only after you [install the loader](#make-it-available-in-every-session), and only if your app build loads user-level extensions. |

On booth machines (macOS or Linux), set up both: add the repo as a project **and** run `install.sh`. The project is the guaranteed way in; the loader adds every other session. On Windows, use the project only.

#### Two Demo Launcher canvases

App builds that can open canvases without a session (staff builds) may list two "Demo Launcher" canvases when both are set up: `user:demo-launcher` (the loader) and `project:demo-launcher` (the project's copy). If you added the existing `~/repos/repo-setup-scripts` folder as the project, they're the same launcher from the same checkout, so either works. To hide one, remove `repo-setup-scripts` from the app's projects (keep the clone; the loader runs from it) and restart the app.

### Make it available in every session

Run the installer once per machine (macOS or Linux), from the **main checkout**:

```bash
cd ~/repos/repo-setup-scripts
bash .github/extensions/demo-launcher/install.sh
```

Then restart the Copilot app, or ask Copilot to reload extensions in sessions that are already open. In a session outside this project, ask Copilot to "open the demo launcher" to check that it worked.

How the loader works:

- The installer writes a small user-level extension (a loader) to `~/.copilot/extensions/demo-launcher/extension.mjs`, or to `$COPILOT_HOME/extensions/demo-launcher/` if `COPILOT_HOME` is set. App builds that support user-level extensions load them in every session.
- The loader imports `extension.mjs` straight from your checkout. **`git pull` updates the launcher**; you don't need to reinstall. Demos still run `create-repo` and `config.json` from that checkout.
- If you run the installer from a worktree, it points the loader at the **main checkout** anyway, because worktrees get deleted. If the main checkout doesn't have the extension yet, it falls back to the worktree with a warning. In that case, re-run it from the main checkout after merging.
- In sessions inside this repo, the loader does nothing and lets that checkout's copy provide the canvas. That avoids two Demo Launchers in the session, and a branch you're working on uses its own version. Staff app builds may still list [two canvases](#two-demo-launcher-canvases) outside a session.

**Update:** run `git -C ~/repos/repo-setup-scripts pull`, then reload extensions or restart the app. You only need to re-run `install.sh` if `install.sh` itself changes. Re-running it is always safe.

**Uninstall:** run `bash .github/extensions/demo-launcher/install.sh --uninstall`. This removes the loader and keeps your run history in `artifacts/`.

**Windows:** `install.sh` is for macOS and Linux. On Windows, add `repo-setup-scripts` as a project in the Copilot app and open the canvas from sessions in that project; don't also install a loader. Runs there use `create-repo.ps1`.

### Troubleshooting

| Symptom | Fix |
| --- | --- |
| The app shows two "Demo Launcher" canvases | Expected on staff builds with both the project and loader set up. Either one works. See [Two Demo Launcher canvases](#two-demo-launcher-canvases). |
| Copilot can't find the Demo Launcher outside this project | Run `install.sh`, then restart the app or reload extensions. Check that `~/.copilot/extensions/demo-launcher/extension.mjs` exists and that the path it imports exists. If it still doesn't appear, your app build may not load user-level extensions; open it from a session in the `repo-setup-scripts` project. |
| The panel shows old behavior | Run `git pull` in the main checkout and reload extensions. Sessions inside this project use their own checkout, so update that branch. |
| A run fails with an auth or scope error, or cleanup asks for `delete_repo` | Run `gh auth status` in a terminal, then `gh auth refresh -h github.com -s codespace,delete_repo`. |
| The demo was created in the wrong account | Repos go to the [logged-in account](#where-repos-are-created) unless you set **Owner**. Check `gh auth status`. |
| The panel URL stopped working | The extension restarted on a new port. Reopen the canvas. |
| A card says **interrupted** | The app or extension restarted mid-run. The repo may be half set up. Delete it with **Clean up** and run it again. |
| The canvas won't load at all (for example after a Copilot app update) | Use the [standalone Demo Launcher](#standalone-demo-launcher) at http://127.0.0.1:4747/ until it's fixed. |

### Agent actions

Copilot can drive the canvas directly with these actions:

- `list_templates`
- `launch` (`template`, `owner`, `noClone`, `openBrowser`)
- `get_run` and `list_runs`
- `cancel`
- `cleanup_preview` (`owner`, `olderThanHours`)
- `cleanup_delete` (`repos`, `removeClones`)

For example: "launch octocart in the demo launcher and tell me when Copilot has reviewed the PRs."

### Files

| File | Purpose |
| --- | --- |
| [`extension.mjs`](.github/extensions/demo-launcher/extension.mjs) | Registers the canvas and its actions, runs `create-repo` in the background, parses its output, and serves the panel on a loopback port |
| [`ui.html`](.github/extensions/demo-launcher/ui.html) | The panel UI |
| [`cleanup.mjs`](.github/extensions/demo-launcher/cleanup.mjs) | The Clean up section (preview and delete through `create-repo --cleanup`) |
| [`install.sh`](.github/extensions/demo-launcher/install.sh) | Installs or uninstalls the user-level loader |

If you change what the scripts print (repo, clone, `PR #N created: <url>`, Copilot review lines, and so on), update `parseLine` in `extension.mjs` and in [`standalone-launcher/core.mjs`](standalone-launcher/core.mjs) to match.

## Standalone Demo Launcher

A fallback for when the canvas isn't available, for example if a Copilot app update breaks extensions. [`standalone-launcher/`](standalone-launcher/) is a GUI for `create-repo` that runs in any browser. It works without the Copilot app.

It lives **alongside** the canvas and doesn't replace it. It shares no code with `.github/extensions/demo-launcher/` and doesn't import the Copilot SDK. Like the terminal, it reads `config.json` and runs `create-repo.sh` / `create-repo.ps1` from this checkout, so `git pull` updates its demo list. Its run history is kept separately from the canvas's.

```bash
node standalone-launcher/server.mjs --open     # http://127.0.0.1:4747/ (--port or DEMO_LAUNCHER_PORT to change)
```

It has the same demo picker, live logs, links, presenter answer key, and Clean up as the canvas. There's no Copilot agent behind it, so the session buttons become **📋 Copy … prompt**. They copy the instruction the canvas would send to Copilot; paste it into any Copilot app chat and Copilot opens the session (or the GitHub Copilot Fusion run) for you.

**Always on.** To start it at login and restart it if it stops, run the installer from the **main checkout**. Like `install.sh`, it uses the main checkout even when run from a worktree.

```bash
bash standalone-launcher/install-service.sh               # macOS LaunchAgent; logs in ~/Library/Logs/demo-launcher.log
bash standalone-launcher/install-service.sh --uninstall
```

```powershell
.\standalone-launcher\install-service.ps1                 # Windows logon task; logs in %LOCALAPPDATA%\demo-launcher\server.log
.\standalone-launcher\install-service.ps1 -Uninstall
```

After `git pull`, re-run the installer to restart the service with the new code. Re-run it as well after switching Node versions with nvm, because the service records the absolute `node` path.

Run history is in `~/Library/Application Support/demo-launcher/` on macOS (`%LOCALAPPDATA%\demo-launcher` on Windows). Set `DEMO_LAUNCHER_STATE_DIR` to override it.

**Security.** The server listens only on `127.0.0.1` and rejects requests with any other `Host` (DNS rebinding). POSTs must be JSON and come from the launcher's own page (CSRF). Other users and processes on the same machine can still reach it, so don't run it on a shared machine.

## Where repos are created

By default, repos are created in **the account that is logged in** (`gh api user`), so each booth machine (`octobooth-1`, `octobooth-2`, …) gets its own copies. The owner is resolved in this order:

1. `--owner <name>` / `-Owner <name>`
2. The config entry's `owner` field. `"owner": "org"` means the top-level `org`; any other value is used as-is. `security-octo-supply`, `security-octo-supply-v4`, and `ai-security` are pinned to the org because they need code scanning; everything else (including `fusion-blank`) goes to the logged-in booth account.
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

Delete old demo repos from the logged-in account (or `--owner` / `-Owner`). Only repos with the `demo-generated` topic that are older than the cutoff (default 72 hours) are considered; everything else is left alone. The script lists matches and asks before deleting.

```bash
bash ./create-repo.sh --cleanup [--older-than 72 | --all] [--dry-run] [--yes] [--owner <name>]
```

```powershell
.\create-repo.ps1 -Cleanup [-OlderThanHours 72 | -All] [-DryRun] [-Yes] [-Owner <name>]
```

**End of event:** `--all` / `-All` ignores the age cutoff and deletes every `demo-generated` repo the owner has, including ones created minutes ago. It prints a warning and still asks before deleting unless you pass `--yes` / `-Yes`. Run with `--dry-run` first to check the list.

Deleting repos needs the `delete_repo` scope. The scripts request it when they log in; for an existing login run `gh auth refresh -h github.com -s delete_repo`.

### Which cleanup covers which repos

| Where the demo repo lives | How it gets cleaned up |
| --- | --- |
| A booth account (`octobooth-1`, `octobooth-2`, …), the default | Run `--cleanup` / `-Cleanup` **on that machine**. Nothing else can reach it, because the [ChatOps App](#chatops) is only installed on the org. |
| The `octobooth-demos` org (`--owner octobooth-demos`, ChatOps, `security-octo-supply`, `security-octo-supply-v4`, `ai-security`) | Automatic: the [nightly cleanup](.github/workflows/cleanup-demos.yml) deletes them at 08:00 UTC once they are more than 72 hours old. To clean up sooner, comment `/cleanup [hours] --confirm` or run the workflow from the Actions tab. After an event, `/cleanup --all --confirm` deletes them all regardless of age. |

**Recommended booth routine (repos in each booth account):**

```bash
# Start of the day, once per machine
gh auth refresh -h github.com -s delete_repo

# Each demo
git pull
bash ./create-repo.sh --template booth-bingo

# End of the day (or the next morning): remove that account's demos older than 72h
bash ./create-repo.sh --cleanup
# or, after the event, remove every demo regardless of age: bash ./create-repo.sh --cleanup --all
```

**Fallback (repos in the org, cleaned up automatically):** add `--owner octobooth-demos` (or `-Owner octobooth-demos`) when creating demos. Nothing needs to run on the machines afterwards. This requires the booth accounts to be `octobooth-demos` members who are allowed to create repos, including **public** ones (Booth Bingo is public so GitHub Pages works).

## Workflows and config fields

Each `repos[]` entry needs `key`, `display_name`, `template` (except for the `blank` workflow), `repo_base_name`, and `workflow`. Optional `template_org` overrides the top-level `org` for the template source, optional `owner` pins where the repo is created (see [above](#where-repos-are-created)), optional `visibility` (`private` by default, or `public` / `internal`) sets the new repo's visibility, optional `"pages": true` turns on GitHub Pages and deploys it with the template's `pages.yml` workflow (see [Showing the game](#showing-the-game); Booth Bingo sets both), optional `"serve": true` starts the [local preview](#running-it-locally-instead-optional) whenever the repo is cloned, and `summary_lines` are printed at the end.

| `workflow` | Extra fields | What it does |
| --- | --- | --- |
| `repo_only` | — | Creates the repo. |
| `blank` | Optional `seed_prompt_file` | Creates an empty repo with only a README (`gh repo create --add-readme`, no template). `seed_prompt_file` is a prompt in this repo that the Demo Launcher shows with Copy and Run with Fusion buttons. |
| `issue_and_codespace` | `issue` | Creates an issue and a Codespace. |
| `security_prs` | `prs[]` | Enables security features (Dependabot alerts, automated security fixes, CodeQL default setup), disables the template's `codeql-advanced.yml` workflow if it has one, and opens one PR per entry against the default branch. |
| `branch_and_codespace` | `branch` | Creates a branch and a Codespace on it. |
| `code_review_prs` | `prs[]` | Opens one PR per entry against the default branch and requests a Copilot Code Review on each, except entries with `"request_review": false`, which are left for the presenter to request live. No security features are enabled. |
| `stacked_prs` | `stack[]` | Opens a chain of dependent PRs and registers them as a native [stacked PR](https://docs.github.com/en/pull-requests/reference/stacked-pull-requests-apis-and-webhooks). |
| `ai_security` | `prs[]` and/or `autofix`; optional `ai_scan`, `seed`, `codeql_workflow` | Enables Advanced Security, and AI Scan when `"ai_scan": true`. With `autofix`, it commits `seed.resource_dir` to the default branch (or dispatches `codeql_workflow`, default `codeql-advanced.yml`), waits for CodeQL alerts, and assigns the `autofix.preassign_rule` alert to Copilot. Then it opens one PR per `prs[]` entry; when `ai_scan` is on, it first makes sure code scanning has an analysis. It doesn't enable CodeQL default setup. |

`prs[]` and `stack[]` entries share the same shape: `branch`, `resource_dir`, `commit_message`, `title`, and `body_file` (a path inside `resource_dir`; it is used as the PR body and never committed). `stack[]` must have at least 2 entries, listed bottom to top. Each layer is branched from the one below, its `resource_dir` is copied over the tree, and the PR targets the branch below it. After all PRs are open the scripts call `POST /repos/{owner}/{repo}/stacks` and verify the order. If registration fails, the PR chain still exists and the script exits non-zero.

### Booth Bingo (stacked PRs)

`booth-bingo` creates a repo from [`octobooth-demos/booth-bingo`](https://github.com/octobooth-demos/booth-bingo) (a template repo whose source lives in [`templates/booth-bingo`](templates/booth-bingo)) and opens three small stacked PRs from [`resources/booth-bingo`](resources/booth-bingo):

1. `bingo/1-game-logic` → `main`: `checkWin()` plus `node --test` tests
2. `bingo/2-wire-ui` → layer 1: highlight the winning line
3. `bingo/3-celebration` → layer 2: banner, confetti, reset

Each overlay holds the cumulative files for its layer. The booth talk track is in the template's README. The game is served from [GitHub Pages](#showing-the-game) and updates itself after the stack is merged. Merge stacks from the GitHub UI, not `gh pr merge`.

### Security Supply Chain (v4)

`security-octo-supply-v4` creates a repo from [`octobooth-demos/security-octo-supply-v4`](https://github.com/octobooth-demos/security-octo-supply-v4), which is the v4 [OctoCAT Supply](https://github.com/octodemo-framework/demo_octocat_supply) template (Node.js API) plus the vulnerable PHP app from `security-octo-supply`. The older `security-octo-supply` option is still available. The script opens two PRs:

1. `feature-add-tos-download` (from [`resources/security-octo-supply-v4/pr-typescript`](resources/security-octo-supply-v4/pr-typescript)): a terms-of-service download with a path traversal for CodeQL and Copilot Autofix. It matches upstream's `feature-add-tos-download` branch and includes intentional code-quality issues in `userDetailsRepo.ts`, so the API build fails on that PR.
2. `feature/supplier-notes` (reuses [`resources/security-octo-supply/pr-php`](resources/security-octo-supply/pr-php)): supplier notes in the PHP app. CodeQL doesn't analyze PHP, so these findings come from AI Code Scanning.

Before the demo:

- **Turn on AI Code Scanning (preview) for the org:** **Settings → Advanced Security → Global settings → AI findings**. Without it, the PHP PR gets no findings.
- **Trigger AI findings by pushing an edit to the PHP PR.** It doesn't run when the PR is opened, so push a small commit to `feature/supplier-notes` (for example, from the github.com editor) and wait for the results.
- The script turns on CodeQL default setup and disables the template's `codeql-advanced.yml`. Otherwise its SARIF uploads are rejected and every PR shows a failing check.

### OctoCart (Copilot Code Review)

`octocart` creates a repo from [`octobooth-demos/octocart`](https://github.com/octobooth-demos/octocart). It's a small TypeScript store (Express API + React/Vite) whose `.github/copilot-instructions.md` and `.github/instructions/*.instructions.md` define house rules. The script then opens four feature PRs from [`resources/octocart`](resources/octocart):

1. `feature/stackable-promo-codes`: stackable promo codes and sale pricing, with subtle correctness bugs (a boundary error, float money math, missing `await`s)
2. `feature/order-history-export`: order history and a CSV export, with security, performance, and robustness issues (IDOR, token in the URL, CSV injection, N+1)
3. `feature/wishlist`: a wishlist that works, but breaks most of the repo's custom instructions, which makes it the custom-instructions showcase
4. `feature/product-reviews`: a small product reviews feature with stored XSS, unauthenticated impersonation, and missing validation. Its config entry sets `"request_review": false`, so no review is requested. Request it live from the PR on github.com (**Reviewers → Copilot**) or from a PR session in the Copilot app.

The overlays are written against the template's app (introduced in [octobooth-demos/octocart#1](https://github.com/octobooth-demos/octocart/pull/1)), so that PR must be merged before the demo is used. All four PRs pass the template's CI (lint, typecheck, tests, build), and the PR descriptions don't hint at the problems. After each of the first three PRs is opened, the script requests a review from Copilot with `gh pr edit --add-reviewer @copilot`. If that fails (for example, with an older `gh`), it falls back to `POST /pulls/{n}/requested_reviewers` with `copilot-pull-request-reviewer[bot]`. If both fail, it warns and keeps going, and you can request the review from the PR page instead.

Like every other template, the repo is created under `--owner` / `-Owner` or the signed-in booth account, and cloned to `~/repos/<repo>` unless you pass `--no-clone`. The PR branches are fetched into that clone, so the PRs show up in the Copilot app as well as on github.com. The script opens the repo's pull request list in the browser at the end.

The **presenter answer key**, [`resources/octocart/ANSWER_KEY.md`](resources/octocart/ANSWER_KEY.md), lists every planted issue with its file, line, and the rule it breaks. It stays in this repo and is never copied into the demo repo.

### AI Security (AI Scan + agentic autofix)

`ai-security` creates a repo in `octobooth-demos` from [`octobooth-demos/security-octo-supply`](https://github.com/octobooth-demos/security-octo-supply). It shows two features that became generally available on 2026-10-15: [AI Scan for pull requests](https://docs.github.com/en/enterprise-cloud@latest/code-security/concepts/code-scanning/ai-powered-security-detections) and [agentic autofix for code scanning alerts](https://docs.github.com/en/enterprise-cloud@latest/code-security/concepts/code-scanning/autofix-for-code-scanning). The script:

1. Turns on Advanced Security for the repo and sets AI Scan to enabled with `PATCH /repos/{owner}/{repo}/code-scanning/ai-scan`. The repo normally inherits that setting from the org already, so this is a safety net that warns rather than fails.
2. Commits [`resources/ai-security/seed`](resources/ai-security/seed) to `main`: a TypeScript route file that gives CodeQL four more alerts on the default branch (about six in total).
3. Waits (up to 15 minutes; override with `CODEQL_WAIT_SECONDS`) for the template's `codeql-advanced.yml` run on that commit. Then it waits up to 5 more minutes for the alerts to be processed, which can lag the run. If CodeQL fails or times out, it stops with a link to the run.
4. Assigns the `js/sql-injection` alert to Copilot with `PATCH /repos/{owner}/{repo}/code-scanning/alerts/{n}`, so a draft fix PR is ready by demo time. It assigns `github-agentic-autofix[bot]`, the account the UI's **Assign to Copilot** uses, and falls back to `copilot-swe-agent[bot]`. If both fail, it warns, and you can assign the alert yourself.
5. Opens "Containerize the supplier portal and deploy it to staging" from [`resources/ai-security/pr-infra`](resources/ai-security/pr-infra): a Dockerfile, a deploy shell script, Terraform, and a PHP health check, none of which CodeQL analyzes. AI Scan doesn't use CodeQL results, but it only reviews PRs opened after code scanning is on. Opening the PR after step 3 guarantees that.

**Pre-bake this demo.** The script takes about 5–10 minutes. AI Scan findings and Copilot's draft PR each take about 10 more minutes, and longer when GitHub is busy. Create it from the launcher before the booth opens, then work through the checklist in the [presenter notes](resources/ai-security/ANSWER_KEY.md). One repo can serve the whole day; the nightly cleanup deletes it after 72 hours.

The script doesn't turn on CodeQL default setup, because default setup can't run alongside the template's advanced workflow. Everything it does needs only admin on the repo it creates, so booth accounts that are org members (not owners) can run it. The org must already allow and enable AI Scan and agentic autofix; `octobooth-demos` does both. Each run uses Code Security AI credits and Actions minutes.

**Presenter script** (full version and pre-bake checklist in [`resources/ai-security/ANSWER_KEY.md`](resources/ai-security/ANSWER_KEY.md)):

1. **AI Scan:** on the PR, show the findings labeled **AI** on **Conversation** and **Files changed**. They cover Dockerfile, shell, Terraform, and PHP code, which CodeQL doesn't analyze. They're advisory, need no workflow, and may include Copilot Autofix suggestions. AI findings vary from run to run, so read them before visitors arrive.
2. **Agentic autofix:** in **Security → Code scanning**, open the pre-assigned alert and Copilot's draft PR: the fix summary, plus the CodeQL rerun that validates it. Optionally, select a few more alerts and choose **Assign to Copilot** to show a session starting in the **Agents** tab.

### GitHub Copilot Fusion: Blank Prompt

`fusion-blank` shows GitHub Copilot Fusion (formerly Project HydraFusion), the Copilot model option that orchestrates several models per request (Single, Cascade, or Critique) for frontier-level quality at lower cost. The preview works best on a substantial, well-scoped, first-turn prompt in autopilot, so the demo is just that: an empty repo in the booth account (like Ctrl Slash and Booth Bingo; the seed prompt and presenter notes stay in this repo) and one prompt from [`resources/fusion-blank/seed-prompt.txt`](resources/fusion-blank/seed-prompt.txt), which builds "Mona Merge Rush", a 2048-style Octocat game with `node:test` tests.

After the run finishes, click **▶ Run with Fusion** in the launcher, or copy the prompt and run it yourself with the GitHub Copilot Fusion model in autopilot. Expect about 4-5 minutes and a playable game whose tests pass. Talking points, benchmark numbers, and alternate prompts are in the [presenter notes](resources/fusion-blank/ANSWER_KEY.md). Use a fresh repo for each visitor, and remove old ones with the launcher's **Clean up** or `--cleanup` on that machine (see [Which cleanup covers which repos](#which-cleanup-covers-which-repos)). ChatOps (`/new-demo fusion-blank`) still creates it in the org, where the nightly cleanup deletes it after 72 hours.

## ChatOps

Two workflows in this repo let you create and clean up demos without a booth machine running the script.

- **[New demo](.github/workflows/new-demo.yml)**: run it from the Actions tab and pick a template, or comment `/new-demo <key>` on any issue or PR in this repo. Repos are always created in `octobooth-demos`, because App tokens cannot create repos in personal accounts. It replies with the repo URL and, for stacks, the top PR URL and the game URL (for OctoCart, the pull request list). Only `repo_only`, `blank`, `security_prs`, `stacked_prs`, `code_review_prs`, and `ai_security` templates are allowed, because Codespaces need a user token.
- **[Clean up demos](.github/workflows/cleanup-demos.yml)**: runs nightly, from the Actions tab (`max_age_hours`, default 72; `dry_run`, default on), or by comment: `/cleanup [hours | --all] [--dry-run | --confirm]`. Comment runs are dry runs unless they include `--confirm`; only the nightly run deletes without opting in. Manual and comment runs need a cutoff of at least 1 hour unless they use the end-of-event override (`--all` in a comment, or the `all` input on the Actions tab), which deletes every demo repo in the org regardless of age and adds a warning to the reply, and the comment must start with exactly `/cleanup`. If some deletions fail, the run continues with the rest, then fails and lists what was and was not deleted. It only deletes repos in `octobooth-demos` that have the `demo-generated` topic **and** are older than the cutoff. It cannot see repos in booth accounts; see [Which cleanup covers which repos](#which-cleanup-covers-which-repos).

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
   - Actions: Read and write (start the first Pages deploy, wait for CodeQL)
   - Code scanning alerts: Read and write (read the AI Security demo's alerts and assign one to Copilot)
   - Metadata: Read-only (required)
2. Install it on the `octobooth-demos` org with access to **All repositories** (new demo repos must be covered automatically).
3. In this repo's **Settings → Secrets and variables → Actions**, add `APP_ID` (the App ID) and `APP_PRIVATE_KEY` (the full contents of a generated `.pem` private key).

The security features enabled by `security_prs` (Dependabot alerts, automated security fixes, CodeQL default setup) and `ai_security` (Advanced Security, AI Scan) are covered by Administration write. If the App token can't assign the alert to Copilot, ChatOps `ai-security` demos skip that step with a warning, and you can assign the alert yourself from the alert page.

## Local checks

Run the standalone PowerShell checks without creating any GitHub resources. They mock GitHub CLI and Git commands and use temporary fixture directories.

```powershell
.\tests\create-repo.Tests.ps1
```

On macOS or Linux, run the same file with `pwsh -File tests/create-repo.Tests.ps1`. Other quick checks:

```bash
bash -n create-repo.sh
for f in .github/extensions/demo-launcher/*.mjs standalone-launcher/*.mjs; do node --check "$f"; done
bash -n .github/extensions/demo-launcher/install.sh
bash -n standalone-launcher/install-service.sh
shellcheck --severity=warning -x create-repo.sh .github/extensions/demo-launcher/install.sh standalone-launcher/install-service.sh
```

```powershell
Invoke-ScriptAnalyzer -Path .\create-repo.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
```

The [CI workflow](.github/workflows/ci.yml) runs these checks on every pull request and push to `main`, and also validates `config.json` (required fields, workflow names, and that every referenced resource file and directory exists). CI never creates repos or uses secrets.
