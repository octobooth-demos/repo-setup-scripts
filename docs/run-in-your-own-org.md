# Run the Demo Launcher in your own org

This repo is built for the `octobooth-demos` org and its booth accounts (`octobooth-1`, `octobooth-2`, …), but nothing in the Demo Launcher or `create-repo` is tied to them. Everything org-specific lives in [`config.json`](../config.json), plus a few spots in the ChatOps workflows and tests listed under [Currently hard-coded](#currently-hard-coded). This guide shows how to install the launcher on your own machine, point it at your org or personal account, and add demos of your own.

- [Quick start](#quick-start)
- [Installing the Demo Launcher canvas: options and limitations](#installing-the-demo-launcher-canvas-options-and-limitations)
- [Point it at your org](#point-it-at-your-org)
- [Add a demo of your own](#add-a-demo-of-your-own)
- [Reference: what each demo needs](#reference-what-each-demo-needs)
- [Reference: ChatOps, cleanup, and machine setup](#reference-chatops-cleanup-and-machine-setup)
- [Currently hard-coded](#currently-hard-coded)

## Quick start

You can try the launcher with no config changes. The templates are public, so most demos work from any GitHub account.

1. **Install the tools and log in.** The launcher runs `create-repo` with your `gh` login, so it needs the [GitHub CLI](https://cli.github.com/) and Git on your `PATH`, plus [`jq`](https://jqlang.org/) on macOS and Linux:

   ```bash
   brew install gh jq   # macOS; use your package manager on Linux
   gh auth login        # answer Yes to "Authenticate Git"
   gh auth refresh -h github.com -s codespace,delete_repo
   ```

   `codespace` is only for Tailspin Toys, and `delete_repo` is only for **Clean up**.

2. **Fork this repo** (recommended, so you can edit `config.json` and still pull updates), or clone it directly. Then clone your copy:

   ```bash
   gh repo clone <you>/repo-setup-scripts ~/repos/repo-setup-scripts
   ```

3. **Install the launcher from a URL.** In a Copilot app chat, ask:

   > Install the extension from https://github.com/octobooth-demos/repo-setup-scripts/tree/main/.github/extensions/demo-launcher-loader

   For your fork, use your fork's URL. This works on Windows, macOS, and Linux with no script to run, and makes the launcher available in any chat, including a blank new one. It loads the launcher from the clone in step 2, so keep it at `~/repos/repo-setup-scripts` (`%USERPROFILE%\repos\repo-setup-scripts` on Windows) or set `DEMO_LAUNCHER_REPO`. Prefer a script? See [Option B](#option-b-install-script), but [don't use both](#dont-use-both).

   Optional, for quick access: also add the existing `~/repos/repo-setup-scripts` folder as a project in the GitHub Copilot app (don't clone it again). Then you can pin a session in it, or pin the canvas. Start that session with **Current checkout**, not **New worktree**: a worktree session runs its own frozen copy of the launcher that `git pull` never updates.

4. **Restart the Copilot app.** Extensions only load at startup (or when you ask Copilot to reload extensions).
5. **Open it.** In any chat, ask Copilot to **"open the demo launcher."**
6. **Create a demo.** Pick **Booth Bingo** or **Ctrl Slash** and click **Create**. The repo is created in your logged-in account from the public template in `octobooth-demos`.

With an unchanged `config.json`, these demos work in your own account: `securing-your-code`, `ctrl-slash`, `booth-bingo`, `octocart`, `tailspin-toys`, `fusion-blank`, and `fusion-routing` (subject to the [features each one needs](#reference-what-each-demo-needs)). `security-octo-supply-v4` and `ai-security` fail, because they're pinned to the `octobooth-demos` org. To fix that, [point the config at your org](#point-it-at-your-org).

## Installing the Demo Launcher canvas: options and limitations

The Demo Launcher is a Copilot extension in [`.github/extensions/demo-launcher/`](../.github/extensions/demo-launcher/). A small user-level loader makes it available in every session. You can install the loader from a URL (recommended here) or with a script, and you can also add the repo as a project. Use **one** loader per machine.

| | Option A: loader from a URL (recommended) | Option B: install script | Option C: project |
| --- | --- | --- | --- |
| How | Ask Copilot to install the [`demo-launcher-loader`](../.github/extensions/demo-launcher-loader/) folder's URL | `install.sh` (macOS, Linux), or machine-setup's scripts | Add your checkout as a project (repository) in the Copilot app |
| Where it's available | Every session, including a blank new chat | Every session, including a blank new chat | Sessions in that project, including its worktrees. You can pin a session or the canvas |
| Platforms | Windows, macOS, and Linux | `install.sh`: macOS and Linux. machine-setup also has a Windows script | Windows, macOS, and Linux |
| Updating | `git pull` in the checkout, then restart the app or reload extensions | Same | Same. Each session uses its own checkout's copy |
| Removing | Remove `demo-launcher-loader` from the app's Extensions screen | `install.sh --uninstall` (keeps run history) | Remove the project from the app |

**Why the URL is the default outside the booth:** there's no script to run, and it works the same on every OS. Booth machines use the install scripts instead, because machine-setup clones the repo and writes the loader in one automatic step, and its `install-demo-launcher` scripts repair or update it later.

**Either way, clone the repo.** The loader imports the launcher from your checkout, and the launcher runs `config.json`, `create-repo`, and `resources/` from there. It looks in `DEMO_LAUNCHER_REPO` if set, then the checkout `install.sh` ran from (script installs only), then `~/repos/repo-setup-scripts` (`%USERPROFILE%\repos\repo-setup-scripts` on Windows). If the clone is missing, the canvas opens a page that says where to clone it. `git pull` updates the launcher; you don't need to reinstall.

In a session whose repo ships its own `.github/extensions/demo-launcher/extension.mjs` (this repo or your fork), the loader does nothing and lets that copy provide the canvas. That avoids two launchers in one session.

#### Option A: install the loader from a URL

In a Copilot app chat, ask (for your fork, use your fork's URL):

> Install the extension from https://github.com/octobooth-demos/repo-setup-scripts/tree/main/.github/extensions/demo-launcher-loader

Then restart the app. It installs to `~/.copilot/extensions/demo-launcher-loader/`.

#### Option B: install script

If you want automation (for example, setting up several presenter machines), run `bash ~/repos/repo-setup-scripts/.github/extensions/demo-launcher/install.sh` on macOS or Linux, or use [machine-setup](#presenter-machines-and-machine-setup). The script writes the loader to `~/.copilot/extensions/demo-launcher/` (or `$COPILOT_HOME/extensions/demo-launcher/`) and bakes in your checkout's path, preferring the main checkout over a worktree because worktrees get deleted. If you move, rename, or delete the checkout, re-run it from the new location. You only need to re-run it otherwise if `install.sh` itself changes.

#### Don't use both

A URL install is named after its folder, `demo-launcher-loader`, even if you ask for the name `demo-launcher` (verified on Windows). So it doesn't replace the script's `demo-launcher` loader, and with both you get two "Demo Launcher" canvases labeled **Personal**. The app's Extensions screen shows the folder names. To fix it, remove one and restart the app: remove `demo-launcher-loader` from the Extensions screen (or delete `~/.copilot/extensions/demo-launcher-loader`), or run `install.sh --uninstall`.

**Adding the project too.** For quick access, you can also add the **same local folder** the loader uses as a project, so one `git pull` updates both. Start the session you pin with **Current checkout**, not **New worktree**. A worktree session gets its own copy under `copilot-worktrees` on its own branch, so it keeps loading the launcher as it was when the session was created. To fix one, archive it and start a **Current checkout** session; the session's `EXTENSION_PATH` in the app logs should be under `repos/repo-setup-scripts`. The canvas list then shows two "Demo Launcher" entries, **Personal** and **repository: repo-setup-scripts**. They run the same code, so either works. See [Two Demo Launcher canvases](../README.md#two-demo-launcher-canvases).

**Limitations:**

- **Open it from a chat.** Opening canvases from the app-wide canvas picker, without a session, is currently a staff-build feature. On other builds, ask Copilot in a session or chat to "open the demo launcher." Opened from the picker, the session and Fusion buttons only open the project's composer; see [Opened without a chat](../README.md#opened-without-a-chat).
- **`install.sh` is bash-only.** It runs on macOS and Linux. On Windows, use [Option A](#option-a-install-the-loader-from-a-url).
- **It runs locally, as you.** The launcher runs `create-repo.sh` (or `create-repo.ps1` on Windows) from its checkout, using that checkout's `config.json` and `resources/`. It uses your stored `gh auth login` and ignores a `GH_TOKEN` or `GITHUB_TOKEN` the app injects whenever a stored login exists, so `gh`, `git`, and (for bash) `jq` must be installed and logged in.
- **The panel is a loopback web page.** It's served on `127.0.0.1` on a port that changes every time the extension restarts. The URL also works in a browser.
- **Run history is shared.** It's kept in `~/.copilot/extensions/demo-launcher/artifacts/runs.json` and shared by every open launcher.
- **Follow-up buttons are Copilot app features.** **Open session**, **Open PR session**, **Open issue session**, and **Run with Fusion** ask Copilot to create a project and session in the app. **Run with Fusion** also needs the GitHub Copilot Fusion model on your account.
- **Copilot CLI.** The README lists Copilot CLI as a host for the extension, but we haven't tested the canvas there. In a terminal there's no side panel; ask Copilot to use the launcher's [agent actions](../README.md#agent-actions) (`list_templates`, `launch`, `get_run`), or run `create-repo` directly.

**Proposed alternatives (not merged):** [#14](https://github.com/octobooth-demos/repo-setup-scripts/pull/14) adds a VS Code extension, and [#15](https://github.com/octobooth-demos/repo-setup-scripts/pull/15) adds a standalone browser launcher. Neither is available yet.

## Point it at your org

Everything the launcher creates is driven by [`config.json`](../config.json). These are the fields to change.

| Field | What it does | What to change |
| --- | --- | --- |
| `org` (top level) | The default template source for every entry, the target for `"owner": "org"`, and the owner for GitHub App tokens (ChatOps) | Your org (or your username) |
| `template_org` (per demo) | Where that demo's template lives. Falls back to `org` | Leave it out if you copied the template into your org. Set `"template_org": "octobooth-demos"` to keep using our public template |
| `owner` (per demo) | Where the repo is created. `"org"` means the top-level `org`; any other value is used as-is | Use `"org"` for demos that need org features (like Advanced Security). Leave it out to create the repo in whoever is logged in |
| `codespace_machine` (top level) | The machine type for Tailspin Toys' Codespace | Any machine type your account can use |

`--owner` / `-Owner` (or **Owner** in the launcher) overrides `owner` for a single run. See [Where repos are created](../README.md#where-repos-are-created) for the full order.

**Changing `org` changes where templates come from.** Every entry without `template_org` reads its template from `org`. After you change `org`, either copy the templates into your org (below) or add `"template_org": "octobooth-demos"` to each entry. `securing-your-code` already sets `"template_org": "github-samples"`.

For example, to keep our templates and create the security demo in your org:

```json
{
  "org": "my-org",
  "repos": [
    {
      "key": "security-octo-supply-v4",
      "owner": "org",
      "template": "security-octo-supply-v4",
      "template_org": "octobooth-demos",
      ...
    }
  ]
}
```

### Fork, use the template, or copy?

- **This repo:** fork it (or clone it and push to your own repo). You need your own copy to change `config.json`, and the launcher always uses the checkout it runs from.
- **Demo templates:** we recommend copying the ones you use into your org and leaving out `template_org`. That way, a change to our templates can't break your demos mid-event. To copy one and mark the copy as a template:

  ```bash
  gh repo create my-org/octocart --template octobooth-demos/octocart --public
  gh repo edit my-org/octocart --template
  ```

  Repos created from a template aren't templates themselves, so the second command matters. `create-repo` uses `gh repo create --template`, so a template has to be marked as one and visible to whoever runs the script.

  Pointing `template_org` at `octobooth-demos` also works, since all our templates are public.

- **Demo content in this repo:** PR overlays (`resources/<key>/…`), PR bodies, seed prompts, and the presenter answer keys (`resources/<key>/ANSWER_KEY.md`) live in this repo, not in the templates. Edit them in your fork. OctoCart's PR overlays are written against the template's current app, so copy the template from its latest `main`.
- **Templates that reference our org:** the `security-octo-supply` and `security-octo-supply-v4` templates call the public `octobooth-demos/octocat-supply-reusable-workflows/.github/workflows/build-publish-containers.yml@v1` reusable workflow. It works as-is from any org. Fork that repo and update the `uses:` lines in your template copies if you'd rather not depend on it.

## Add a demo of your own

The simplest demo is a `repo_only` entry from a template you own. Add it to `repos` in `config.json`:

```json
{
  "key": "my-demo",
  "display_name": "My demo",
  "description_short": "One line the launcher shows under the name",
  "template": "my-template",
  "template_org": "my-org",
  "repo_base_name": "my-demo",
  "repo_description": "My demo repo",
  "workflow": "repo_only",
  "summary_lines": ["Status: Repository ready for use"]
}
```

- `key` must be lowercase letters, numbers, and hyphens, and unique.
- `my-org/my-template` must be marked as a template repository.
- Each run creates `<owner>/my-demo-<4 random characters>` (private unless you set `"visibility"`), tagged with the `demo-generated` topic.
- `description_short` and `workflow_hint` are optional; the launcher shows them on the card.

Save the file, then reopen the launcher (or restart the app). It reads `config.json` each time it lists templates. To try it from a terminal first:

```bash
bash ./create-repo.sh --template my-demo --no-clone
```

From there, add PRs, a stack, an issue, or seed prompts with the other workflows. See [Workflows and config fields](../README.md#workflows-and-config-fields). CI validates `config.json` and checks that every referenced `resources/` file exists.

## Reference: what each demo needs

The account that runs the script needs permission to create repos in the target owner. Private repos are the default.

| Demo | Workflow | Where it's created | Needs |
| --- | --- | --- | --- |
| `securing-your-code` | `repo_only` | Logged-in account | Nothing extra. Template: `github-samples/securing-your-code` |
| `security-octo-supply-v4` | `security_prs` | `org` | Code scanning (GitHub Advanced Security or GitHub Code Security for private repos), Dependabot alerts, CodeQL default setup, Copilot Autofix, and AI Code Scanning (preview) for the PHP findings. Actions minutes |
| `tailspin-toys` | `issue_and_codespace` | Logged-in account | Copilot coding agent (to assign the issue to `@copilot`), Codespaces, and the `codespace` scope. Not available through ChatOps |
| `ctrl-slash` | `repo_only` | Logged-in account | GitHub Pages. Public repo |
| `booth-bingo` | `stacked_prs` | Logged-in account | GitHub Pages and native stacked pull requests. Public repo |
| `octocart` | `code_review_prs` | Logged-in account | Copilot code review for the account that opens the PRs. Without it, the script warns and you can request reviews later |
| `ai-security` | `ai_security` | `org` | Advanced Security, AI Scan and agentic autofix allowed and enabled by an org owner, and Copilot. Uses Code Security AI credits and Actions minutes |
| `fusion-blank` | `blank` | Logged-in account | The GitHub Copilot Fusion model to run the seed prompt |
| `fusion-routing` | `repo_only` | Logged-in account | The GitHub Copilot Fusion model to run the seed prompts. Template: OctoCart |

**What you can skip.** Remove any entry you don't need from `config.json`. Without Advanced Security, keep the `repo_only`, `blank`, `stacked_prs`, and `code_review_prs` demos and drop `security-octo-supply-v4` and `ai-security`. Without Codespaces, drop `tailspin-toys`. Without Fusion, drop the two Fusion demos. If you removed a demo, also remove it from the `new-demo.yml` options (CI checks them) and see the note on [tests](#currently-hard-coded).

## Reference: ChatOps, cleanup, and machine setup

### ChatOps (optional)

[`new-demo.yml`](../.github/workflows/new-demo.yml) and [`cleanup-demos.yml`](../.github/workflows/cleanup-demos.yml) create and clean up demos in an org from GitHub Actions, without a presenter machine. You don't need them to use the launcher. GitHub turns workflows off in new forks until you enable them on the **Actions** tab. If you enable Actions for CI, disable these two unless you set them up, because the nightly cleanup fails without the App secrets.

To set them up:

1. Create a GitHub App owned by your org, with the repository permissions listed in [GitHub App setup](../README.md#github-app-setup-one-time-org-owner).
2. Install it on your org with access to **All repositories**.
3. In your fork's **Settings → Secrets and variables → Actions**, add `APP_ID` and `APP_PRIVATE_KEY`.
4. Replace `octobooth-demos` with your org in both workflows: `owner:` and `--owner` in `new-demo.yml`, and `ORG:` and `owner:` in `cleanup-demos.yml`. These don't read `config.json`.
5. Make `new-demo.yml`'s `template` options match the keys in your `config.json`.

ChatOps always creates repos in the org, because App tokens can't create repos in personal accounts, and it can't run `tailspin-toys` (Codespaces need a user token).

### Cleanup and the `demo-generated` topic

Every repo the scripts create gets the `demo-generated` topic. Cleanup only deletes repos that have it **and** are older than the cutoff (72 hours by default):

- **Any owner:** the launcher's **Clean up** section, or `bash ./create-repo.sh --cleanup [--owner <name>]`. Needs the `delete_repo` scope.
- **Your org, automatically:** `cleanup-demos.yml` runs nightly at 08:00 UTC once ChatOps is set up.
- **Personal accounts:** nothing in this repo reaches them on a schedule. Run `--cleanup` on each machine, or add a scheduled workflow in each account (the `octobooth-*` accounts use a private `demo-cleanup` repo for this).

### Presenter machines and machine-setup

On each presenter machine, clone **your fork**, [install the loader from your fork's URL](#option-a-install-the-loader-from-a-url), and optionally add it as a project for quick access, as in the [Quick start](#quick-start). Or use install scripts for the whole setup (below), but not both. Run `git pull` and restart the app before each event.

If you use [`octobooth-demos/machine-setup`](https://github.com/octobooth-demos/machine-setup) to set up machines, fork it too and change:

- `shared.repos_to_clone` in its `config.json` to your fork and your template repos.
- `DEMO_LAUNCHER_REPO` in [`setup.sh`](https://github.com/octobooth-demos/machine-setup/blob/main/setup.sh) and `$script:TrustedDemoLauncherRepo` in [`install-demo-launcher.ps1`](https://github.com/octobooth-demos/machine-setup/blob/main/install-demo-launcher.ps1). Both are hard-coded to `octobooth-demos/repo-setup-scripts`, and the PowerShell script ignores any other repo in `config.json` and checks the checkout's `origin` remote, so a config change alone isn't enough.

## Currently hard-coded

These spots name `octobooth-demos` directly instead of reading `config.json`. Change them in your fork if you use them:

| Where | What |
| --- | --- |
| [`.github/workflows/new-demo.yml`](../.github/workflows/new-demo.yml) | `owner: octobooth-demos` (App token) and `--owner octobooth-demos`; the `template` options list |
| [`.github/workflows/cleanup-demos.yml`](../.github/workflows/cleanup-demos.yml) | `ORG: octobooth-demos` and `owner: octobooth-demos` (App token) |
| [`tests/create-repo.Tests.ps1`](../tests/create-repo.Tests.ps1) | Reads the real `config.json` and expects `octobooth-demos` as the org, template source, and owner of the security demos, and expects the shipped demo keys. If you change `org` or remove demos, update these assertions, or CI's **Test PowerShell** job fails |
| [`octobooth-demos/machine-setup`](https://github.com/octobooth-demos/machine-setup) | `DEMO_LAUNCHER_REPO` in `setup.sh` and `$script:TrustedDemoLauncherRepo` in `install-demo-launcher.ps1` |
| `security-octo-supply` and `security-octo-supply-v4` templates | `uses: octobooth-demos/octocat-supply-reusable-workflows/...@v1` (public, so it works from any org) |

The Demo Launcher extension, `install.sh`, `create-repo.sh`, and `create-repo.ps1` have no hard-coded org. Some presenter notes in `resources/` mention the booth accounts by name; that's text only.
