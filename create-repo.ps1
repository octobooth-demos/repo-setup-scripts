#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$scriptDirectory = $PSScriptRoot
$configFile = Join-Path $scriptDirectory 'config.json'
$originalLocation = Get-Location
$tempDirectory = $null

# Native command failures do not throw consistently across PowerShell versions.
function Invoke-Native {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function Assert-SelectedRepo {
    param($Repo)

    $missing = @()
    foreach ($field in @('template', 'repo_base_name', 'repo_description', 'workflow')) {
        if ([string]::IsNullOrWhiteSpace($Repo.$field)) {
            $missing += $field
        }
    }

    switch ($Repo.workflow) {
        'repo_only' {}
        'branch_and_codespace' {
            if ([string]::IsNullOrWhiteSpace($Repo.branch_name)) {
                $missing += 'branch_name'
            }
        }
        'issue_and_codespace' {
            foreach ($field in @('title', 'body_file', 'assignee')) {
                if ([string]::IsNullOrWhiteSpace($Repo.issue.$field)) {
                    $missing += "issue.$field"
                }
            }
            if ($Repo.issue.body_file) {
                $bodyPath = Join-Path $scriptDirectory $Repo.issue.body_file
                if (-not (Test-Path -LiteralPath $bodyPath -PathType Leaf)) {
                    throw "issue.body_file not found: $bodyPath"
                }
            }
        }
        'security_prs' {
            if (@($Repo.prs).Count -eq 0 -or $null -eq $Repo.prs) {
                $missing += 'prs[]'
            }
            $index = 0
            foreach ($pr in $Repo.prs) {
                foreach ($field in @('branch', 'resource_dir', 'body_file', 'commit_message', 'title')) {
                    if ([string]::IsNullOrWhiteSpace($pr.$field)) {
                        $missing += "prs[$index].$field"
                    }
                }
                if ($pr.resource_dir) {
                    $resourcePath = Join-Path $scriptDirectory $pr.resource_dir
                    if (-not (Test-Path -LiteralPath $resourcePath -PathType Container)) {
                        throw "prs[$index].resource_dir not found: $resourcePath"
                    }
                }
                if ($pr.body_file) {
                    $bodyPath = Join-Path $scriptDirectory $pr.body_file
                    if (-not (Test-Path -LiteralPath $bodyPath -PathType Leaf)) {
                        throw "prs[$index].body_file not found: $bodyPath"
                    }
                }
                if ($pr.resource_dir -and $pr.body_file) {
                    $resourceRoot = (Get-Item -LiteralPath $resourcePath).FullName.TrimEnd(
                        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar
                    ) + [IO.Path]::DirectorySeparatorChar
                    $bodyFullPath = (Get-Item -LiteralPath $bodyPath).FullName
                    if (-not $bodyFullPath.StartsWith($resourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "prs[$index].body_file must be inside resource_dir."
                    }
                }
                $index++
            }
        }
        default {
            throw "Unknown workflow: $($Repo.workflow)"
        }
    }

    if ($missing.Count -gt 0) {
        throw "Selected repo '$($Repo.key)' is missing required config field(s): $($missing -join ', ')"
    }
}

function Start-DemoCodespace {
    param([string]$Branch)

    $arguments = @('codespace', 'create', '--repo', $fullRepoName)
    if ($config.codespace_machine) {
        $arguments += @('--machine', $config.codespace_machine)
    }
    if ($Branch) {
        $arguments += @('--branch', $Branch)
    }
    Write-Host 'Starting codespace...'
    Invoke-Native 'gh' $arguments
    Write-Host 'Codespace created successfully!'
}

function New-ResourcePullRequest {
    param($PullRequest)

    $resourcePath = Join-Path $scriptDirectory $PullRequest.resource_dir
    $bodyPath = Join-Path $scriptDirectory $PullRequest.body_file
    $resourceRoot = (Get-Item -LiteralPath $resourcePath).FullName.TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    $relativeBodyPath = (Get-Item -LiteralPath $bodyPath).FullName.Substring($resourceRoot.Length)

    Write-Host "Creating PR: $($PullRequest.title)..."
    Invoke-Native 'git' @('checkout', '-b', $PullRequest.branch, $defaultBranch)
    Get-ChildItem -LiteralPath $resourcePath -Force | Copy-Item -Destination . -Recurse -Force
    Remove-Item -LiteralPath (Join-Path (Get-Location).Path $relativeBodyPath) -Force
    Invoke-Native 'git' @('add', '-A')
    Invoke-Native 'git' @('commit', '-m', $PullRequest.commit_message, '--quiet')
    Invoke-Native 'git' @('push', '-u', 'origin', $PullRequest.branch, '--quiet')
    Invoke-Native 'gh' @(
        'pr', 'create', '--repo', $fullRepoName,
        '--head', $PullRequest.branch, '--base', $defaultBranch,
        '--title', $PullRequest.title, '--body-file', $bodyPath
    )
    Write-Host "PR created: $($PullRequest.title)"
}

try {
    Write-Host 'GitHub demo repository creation tool'
    Write-Host '======================================='

    foreach ($command in @('gh', 'git')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "$command is not installed. Install it and make sure it is on PATH."
        }
    }
    if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
        throw "Config file not found: $configFile"
    }
    try {
        $config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
    }
    catch {
        throw "Unable to read config JSON '$configFile': $($_.Exception.Message)"
    }
    if ([string]::IsNullOrWhiteSpace($config.org)) {
        throw "Config is missing top-level 'org'."
    }
    $repos = @($config.repos)
    if ($null -eq $config.repos -or $repos.Count -eq 0) {
        throw 'Config has no repos defined.'
    }
    Write-Host "Target org: $($config.org)"
    Write-Host ''
    Write-Host 'Available templates:'
    for ($index = 0; $index -lt $repos.Count; $index++) {
        $repo = $repos[$index]
        $displayName = $repo.display_name
        if (-not $displayName) { $displayName = $repo.key }
        $templateOrg = $repo.template_org
        if (-not $templateOrg) { $templateOrg = $config.org }
        Write-Host "$($index + 1). $displayName ($templateOrg/$($repo.template))"
        if ($repo.description_short) { Write-Host "   $($repo.description_short)" }
        if ($repo.workflow_hint) { Write-Host "   $($repo.workflow_hint)" }
        Write-Host ''
    }

    while ($true) {
        $choice = Read-Host "Select template (1-$($repos.Count))"
        $selection = 0
        if ($choice -match '^[0-9]+$' -and [int]::TryParse($choice, [ref]$selection) -and
            $selection -ge 1 -and $selection -le $repos.Count) {
            break
        }
        Write-Host "Invalid choice. Please enter a number between 1 and $($repos.Count)."
    }
    $selectedRepo = $repos[$selection - 1]
    Assert-SelectedRepo $selectedRepo

    Write-Host 'Checking GitHub authentication...'
    # Authentication status is the one expected nonzero exit: offer login.
    & gh auth status
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Not logged in to GitHub. Starting login process...'
        Invoke-Native 'gh' @('auth', 'login')
    }
    $currentUser = Invoke-Native 'gh' @('api', 'user', '--jq', '.login')
    if ([string]::IsNullOrWhiteSpace($currentUser)) {
        throw 'Failed to get current GitHub username.'
    }
    Write-Host "Current user: $currentUser"

    $templateOrg = $selectedRepo.template_org
    if (-not $templateOrg) { $templateOrg = $config.org }
    $templateRepo = "$templateOrg/$($selectedRepo.template)"
    $alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789'.ToCharArray()
    $suffix = -join (1..4 | ForEach-Object { $alphabet[(Get-Random -Maximum $alphabet.Length)] })
    $repoName = "$($selectedRepo.repo_base_name)-$suffix"
    $fullRepoName = "$($config.org)/$repoName"

    Write-Host "Creating repository: $fullRepoName"
    Write-Host "Using template: $templateRepo"
    Invoke-Native 'gh' @(
        'repo', 'create', $fullRepoName, "--template=$templateRepo",
        '--private', "--description=$($selectedRepo.repo_description)"
    )
    Write-Host "Repository created successfully: $fullRepoName"
    Write-Host 'Waiting for template to be fully processed...'
    Start-Sleep -Seconds 3

    $reposDirectory = Join-Path $HOME 'repos'
    $clonePath = Join-Path $reposDirectory $repoName
    if (-not (Test-Path -LiteralPath $reposDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $reposDirectory | Out-Null
    }
    Write-Host "Cloning repository to $clonePath..."
    Invoke-Native 'gh' @('repo', 'clone', $fullRepoName, $clonePath, '--', '--quiet')
    $defaultBranch = Invoke-Native 'gh' @('api', "repos/$fullRepoName", '--jq', '.default_branch')
    if ([string]::IsNullOrWhiteSpace($defaultBranch)) {
        throw 'Failed to get repository default branch.'
    }

    switch ($selectedRepo.workflow) {
        'repo_only' {
            Write-Host 'Repository creation complete (no additional actions needed).'
        }
        'branch_and_codespace' {
            Set-Location -LiteralPath $clonePath
            $branch = $selectedRepo.branch_name
            Invoke-Native 'git' @('checkout', $defaultBranch)
            Invoke-Native 'git' @('checkout', '-b', $branch)
            Invoke-Native 'git' @('push', '-u', 'origin', $branch)
            Start-DemoCodespace $branch
        }
        'issue_and_codespace' {
            $issue = $selectedRepo.issue
            Invoke-Native 'gh' @(
                'issue', 'create', '--repo', $fullRepoName, '--title', $issue.title,
                '--body-file', (Join-Path $scriptDirectory $issue.body_file),
                '--assignee', $issue.assignee
            )
            Write-Host "Issue created and assigned to $($issue.assignee)"
            Start-DemoCodespace
        }
        'security_prs' {
            if ($selectedRepo.enable_security_features -eq $true) {
                Write-Host 'Enabling security features...'
                Invoke-Native 'gh' @('api', "repos/$fullRepoName/vulnerability-alerts", '-X', 'PUT', '--silent')
                Invoke-Native 'gh' @('api', "repos/$fullRepoName/automated-security-fixes", '-X', 'PUT', '--silent')
                Invoke-Native 'gh' @(
                    'api', "repos/$fullRepoName/code-scanning/default-setup", '-X', 'PATCH',
                    '-f', 'state=configured', '-f', 'query_suite=default', '--silent'
                )
                Write-Host 'Dependabot alerts, security updates, and Code Scanning enabled.'
            }
            $tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
            New-Item -ItemType Directory -Path $tempDirectory | Out-Null
            Set-Location -LiteralPath $tempDirectory
            $tempClonePath = Join-Path $tempDirectory $repoName
            Invoke-Native 'gh' @('repo', 'clone', $fullRepoName, $tempClonePath, '--', '--quiet')
            Set-Location -LiteralPath $tempClonePath
            foreach ($pr in $selectedRepo.prs) {
                New-ResourcePullRequest $pr
            }
        }
    }

    Write-Host ''
    Write-Host 'Setup complete!'
    Write-Host 'Summary:'
    Write-Host "   Repository: https://github.com/$fullRepoName"
    Write-Host "   Cloned to: $clonePath"
    Write-Host "   Template: $templateRepo"
    Write-Host "   User: $currentUser"
    foreach ($line in $selectedRepo.summary_lines) {
        if ($line) { Write-Host "   $line" }
    }
    if ($selectedRepo.workflow -in @('branch_and_codespace', 'issue_and_codespace')) {
        Write-Host 'You can access your codespace at: https://github.com/codespaces'
    }
}
finally {
    Set-Location -LiteralPath $originalLocation.Path
    if ($tempDirectory -and (Test-Path -LiteralPath $tempDirectory)) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force
    }
}
