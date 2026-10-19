# Demo repository setup

Create private demo repositories from the templates in [`config.json`](config.json), with optional branches, issues, demo pull requests, security features, and Codespaces.

## PowerShell

Run [`create-repo.ps1`](create-repo.ps1) with Windows PowerShell 5.1 or [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell). Install the [GitHub CLI](https://cli.github.com/) and [Git](https://git-scm.com/downloads) first and ensure both are on your `PATH`. No `jq` installation is required.

```powershell
.\create-repo.ps1
```

Select a template when prompted. The script offers GitHub login if needed, creates a private repository in the configured organization, clones it into `$HOME/repos`, and runs the selected workflow. You need permission to create repositories in that organization and any permissions required for the selected security or Codespaces features.

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

Every repository the scripts create gets the `demo-generated` topic, which is what [cleanup](#chatops) uses to find demo repos.

## Workflows and config fields

Each `repos[]` entry needs `key`, `display_name`, `template`, `repo_base_name`, and `workflow`. Optional `template_org` overrides the top-level `org` for the template source, and `summary_lines` are printed at the end.

| `workflow` | Extra fields | What it does |
| --- | --- | --- |
| `repo_only` | — | Creates the repo. |
| `issue_and_codespace` | `issue` | Creates an issue and a Codespace. |
| `security_prs` | `prs[]` | Enables security features and opens one PR per entry against the default branch. |
| `branch_and_codespace` | `branch` | Creates a branch and a Codespace on it. |
| `stacked_prs` | `stack[]` | Opens a chain of dependent PRs and registers them as a native [stacked PR](https://docs.github.com/en/pull-requests/reference/stacked-pull-requests-apis-and-webhooks). |

`prs[]` and `stack[]` entries share the same shape: `branch`, `resource_dir`, `commit_message`, `title`, and `body_file` (a path inside `resource_dir`; it is used as the PR body and never committed). `stack[]` must have at least 2 entries, listed bottom to top. Each layer is branched from the one below, its `resource_dir` is copied over the tree, and the PR targets the branch below it. After all PRs are open the scripts call `POST /repos/{owner}/{repo}/stacks` and verify the order. If registration fails, the PR chain still exists and the script exits non-zero.

### Booth Bingo (stacked PRs)

`booth-bingo` creates a repo from [`octobooth-demos/booth-bingo`](https://github.com/octobooth-demos/booth-bingo) (a template repo whose source lives in [`templates/booth-bingo`](templates/booth-bingo)) and opens three small stacked PRs from [`resources/booth-bingo`](resources/booth-bingo):

1. `bingo/1-game-logic` → `main`: `checkWin()` plus `node --test` tests
2. `bingo/2-wire-ui` → layer 1: highlight the winning line
3. `bingo/3-celebration` → layer 2: banner, confetti, reset

Each overlay holds the cumulative files for its layer. The booth talk track is in the template's README. Merge stacks from the GitHub UI, not `gh pr merge`.

## ChatOps

Two workflows in this repo let you create and clean up demos without a booth machine running the script.

- **[New demo](.github/workflows/new-demo.yml)**: run it from the Actions tab and pick a template, or comment `/new-demo <key>` on any issue or PR in this repo. It replies with the repo URL and, for stacks, the top PR URL. Only `repo_only`, `security_prs`, and `stacked_prs` templates are allowed, because Codespaces need a user token.
- **[Clean up demos](.github/workflows/cleanup-demos.yml)**: runs nightly, from the Actions tab (`max_age_hours`, default 24; `dry_run`, default on), or by comment: `/cleanup [hours] [--dry-run]`. It only deletes repos in `octobooth-demos` that have the `demo-generated` topic **and** are older than the cutoff.

Comment commands only run for users with write, maintain, or admin access to this repository.

### GitHub App setup (one-time, org owner)

The workflows authenticate as a GitHub App so they can create and delete org repos.

1. Create a GitHub App owned by `octobooth-demos` (no webhook needed) with these **repository** permissions:
   - Administration: Read and write (create from template, add topics, delete repos)
   - Contents: Read and write (push branches)
   - Pull requests: Read and write (open PRs, register stacks)
   - Issues: Read and write (issue-based templates)
   - Workflows: Read and write (templates contain `.github/workflows`)
   - Metadata: Read-only (required)
2. Install it on the `octobooth-demos` org with access to **All repositories** (new demo repos must be covered automatically).
3. In this repo's **Settings → Secrets and variables → Actions**, add `APP_ID` (the App ID) and `APP_PRIVATE_KEY` (the full contents of a generated `.pem` private key).

The security features enabled by `security_prs` (Dependabot alerts, automated security fixes, CodeQL default setup) are covered by Administration write.

## Local checks

Run the standalone PowerShell checks without creating any GitHub resources. They mock GitHub CLI and Git commands and use temporary fixture directories.

```powershell
.\tests\create-repo.Tests.ps1
```
