# AGENTS.md

Guidance for AI coding agents and new maintainers. It summarizes the rules and links to the docs that hold the details; when they disagree, the linked doc wins, so update both.

## What this repo is

Public, [MIT](LICENSE). It creates booth demo repos from [`config.json`](config.json):

- [`create-repo.sh`](create-repo.sh) and [`create-repo.ps1`](create-repo.ps1) read `config.json` and create a demo (repo from a template, plus branches, issues, PRs, security features, Codespaces). See [README: Bash](README.md#bash), [PowerShell](README.md#powershell), and [Workflows and config fields](README.md#workflows-and-config-fields).
- [`.github/extensions/demo-launcher/`](.github/extensions/demo-launcher/): the **Demo Launcher** canvas extension for the GitHub Copilot app. It runs `create-repo` in the background and parses its output. Docs: [README: Demo Launcher canvas](README.md#demo-launcher-canvas).
- [`.github/extensions/demo-launcher-loader/`](.github/extensions/demo-launcher-loader/): the user-level loader, installable from a URL or written by `install.sh`. Docs: [loader README](.github/extensions/demo-launcher-loader/README.md).
- [`resources/<demo>/`](resources/): per-demo PR contents, seeds, seed prompts, and presenter answer keys (`ANSWER_KEY.md`, never copied into demo repos).
- [`templates/booth-bingo/`](templates/booth-bingo/): source for the `octobooth-demos/booth-bingo` template repo.
- ChatOps: [`new-demo.yml`](.github/workflows/new-demo.yml) and [`cleanup-demos.yml`](.github/workflows/cleanup-demos.yml). See [README: ChatOps](README.md#chatops).

Running it outside `octobooth-demos`: [docs/run-in-your-own-org.md](docs/run-in-your-own-org.md).

## Branches and releases

Full process: [docs/releasing.md](docs/releasing.md) ([Making a change](docs/releasing.md#making-a-change), [Cutting a release](docs/releasing.md#cutting-a-release)) and [README: Releases](README.md#releases).

- Changes land on `main` through PRs, and are tested there. Maintainer and dev machines track `main`.
- Booth machines run the moving major tag `v1`, installed by [machine-setup](https://github.com/octobooth-demos/machine-setup) (`--ref v1`, `-Ref v1`, or `BOOTH_RELEASE=v1`). **Merging never changes booth machines; only moving `v1` after testing does.**
- Each release tags this repo and machine-setup with the **same** `vX.Y.Z`, at the commits tested on a booth Mac and a Windows machine, then moves the matching major tag (`v1` for any `v1.y.z`).
- Patch for fixes, minor for new demos or behavior, major (`v2`) only for breaking setup changes (new manual steps, changed paths, new `gh` scopes).
- Never move or delete a pushed `vX.Y.Z` tag; cut a new one. Never move `v1` to a `v2.x.y` commit.
- **Agents:** don't create, move, or delete tags, or publish GitHub Releases, unless a maintainer explicitly asks.

## Change rules

- **Keep `create-repo.sh` and `create-repo.ps1` in parity:** same flags (`--no-clone` / `-NoClone`), same behavior, and the same output lines. The launcher parses that output (`parseLine` in [`extension.mjs`](.github/extensions/demo-launcher/extension.mjs)), so update it when output changes.
- **Windows PowerShell 5.1:** `create-repo.ps1` is `#Requires -Version 5.1`. No PowerShell 7-only syntax (`??`, `?.`, ternaries, `&&`/`||` pipeline chains, `ForEach-Object -Parallel`). Run git and `gh` through `Invoke-Native` (throws on a non-zero exit code) or `Invoke-GhQuiet` (hides stderr without 5.1 turning it into a terminating error), and follow the existing comments about quoting native arguments.
- **Tests and CI in the same PR:** update [`tests/`](tests/) for behavior changes. `config.json` schema changes (new fields, workflows, or referenced files) need matching updates to the `validate-config` job in [`ci.yml`](.github/workflows/ci.yml); new `new-demo.yml` template options must be `config.json` keys.
- **Docs in the same PR as behavior:** README, [docs/](docs/), and the loader README.
- Booth machines run the launcher on macOS and Windows; test both when a change is platform-sensitive.

## Intentional vulnerabilities: don't fix them

The demos exist to show security tools finding problems. These are **planted on purpose**:

- [`resources/ai-security/`](resources/ai-security/) (seed and `pr-infra`): SSRF, insecure scripts, hard-coded AWS example keys, and more. See its [answer key](resources/ai-security/ANSWER_KEY.md).
- [`resources/security-octo-supply-v4/`](resources/security-octo-supply-v4/): path traversal, intentional code-quality issues, and the vulnerable PHP app ([README](README.md#security-supply-chain-v4)).
- [`resources/octocart/`](resources/octocart/): issues for Copilot code review to find ([answer key](resources/octocart/ANSWER_KEY.md)).
- The template repos `security-octo-supply-v4` and `security-octo-supply`.

Any credentials there are fake or public example values. Never fix, remove, or "harden" them, and don't add suppressions. Close Copilot Autofix, agentic-autofix, and Dependabot PRs that would. Example: [#26](https://github.com/octobooth-demos/repo-setup-scripts/pull/26) (SSRF fix in the AI Security seed) was closed for this reason. If a planted issue changes on purpose, update its answer key and README section too.

## Templates

Template repos can't be pinned: GitHub always creates repos from a template's default branch, so a merged template change reaches every new demo on every machine immediately, with no release. Test it in the template repo's PR, then create one demo from it with the launcher right after merging. See [What booth machines need for each kind of change](docs/releasing.md#what-booth-machines-need-for-each-kind-of-change).

## Where repos go

Only `security-octo-supply-v4` and `ai-security` (`"owner": "org"`) create repos in the `octobooth-demos` org; every other demo uses the signed-in `gh` account, unless `--owner` / `-Owner` is passed. ChatOps always uses the org. See [README: Where repos are created](README.md#where-repos-are-created).

Booth machines use the booth account for both the Copilot app and `gh`. Never sign in with personal or staff accounts on booth machines.

## Testing changes

Run what CI runs ([`ci.yml`](.github/workflows/ci.yml), listed in [README: Local checks](README.md#local-checks)). None of these touch GitHub:

```bash
bash -n create-repo.sh && bash -n .github/extensions/demo-launcher/install.sh
shellcheck --severity=warning -x create-repo.sh .github/extensions/demo-launcher/install.sh
for f in .github/extensions/demo-launcher/*.mjs .github/extensions/demo-launcher-loader/*.mjs; do node --check "$f"; done
node --test tests/run-store.test.mjs tests/demo-launcher.test.mjs tests/demo-launcher-loader.test.mjs
pwsh -NoProfile -File tests/create-repo.Tests.ps1
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path ./create-repo.ps1 -Settings ./PSScriptAnalyzerSettings.psd1"
```

CI also validates `config.json` with `jq`; copy those steps from `ci.yml` to run them locally.

End to end (creates a real repo in the signed-in account, or the org for org-pinned demos):

```bash
DEMO_NO_BROWSER=1 bash create-repo.sh --template <key> --no-clone
```

Clean up afterwards: delete just your test repo with `gh repo delete <owner>/<repo> --yes` or the launcher's **Clean up** section. Every demo repo gets the `demo-generated` topic, and `create-repo.sh --cleanup` / `-Cleanup` deletes those older than 72 hours (always `--dry-run` first). `--all` or `--older-than 0` deletes **every** demo the owner has, including ones in use, so don't run them on `octobooth-demos` or a booth account during an event. See [README: Cleaning up](README.md#cleaning-up).

## Launcher gotchas

- Install the loader **one** way per machine: the script (`install.sh`, booth machines) or the URL install, never both. See [Don't install both](README.md#dont-install-both).
- Sessions in this project load the launcher from their own checkout. A **New worktree** session keeps a frozen copy on its own branch and never picks up `git pull`; use **Current checkout** to run the latest.
- Restart the Copilot app (or reload extensions) to load launcher changes. Re-run `install.sh` (or machine-setup's `install-demo-launcher`) only when the loader or `install.sh` changes.
