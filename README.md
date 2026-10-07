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

## Local checks

Run the standalone PowerShell checks without creating any GitHub resources. They mock GitHub CLI and Git commands and use temporary fixture directories.

```powershell
.\tests\create-repo.Tests.ps1
```
