#Requires -Version 5.1

[CmdletBinding()]
param(
    # Non-interactive: config.json repo key to create. Never prompts or starts gh auth login.
    [string]$Template,
    # Skip the permanent clone into $HOME/repos (useful in CI).
    [switch]$NoClone
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$scriptDirectory = $PSScriptRoot
$configFile = Join-Path $scriptDirectory 'config.json'
$originalLocation = Get-Location
$tempDirectory = $null
$demoTopic = 'demo-generated'
$nonInteractive = -not [string]::IsNullOrWhiteSpace($Template)

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

function Assert-PullRequestEntries {
    param($Entries, [string]$Field, [int]$MinimumCount)

    $missing = @()
    $list = @($Entries | Where-Object { $null -ne $_ })
    if ($null -eq $Entries -or $list.Count -eq 0) {
        return @("$Field[]")
    }
    if ($list.Count -lt $MinimumCount) {
        throw "$Field[] needs at least $MinimumCount entries (found $($list.Count))."
    }
    $index = 0
    foreach ($pr in $list) {
        foreach ($name in @('branch', 'resource_dir', 'body_file', 'commit_message', 'title')) {
            if ([string]::IsNullOrWhiteSpace($pr.$name)) {
                $missing += "$Field[$index].$name"
            }
        }
        if ($pr.resource_dir) {
            $resourcePath = Join-Path $scriptDirectory $pr.resource_dir
            if (-not (Test-Path -LiteralPath $resourcePath -PathType Container)) {
                throw "$Field[$index].resource_dir not found: $resourcePath"
            }
        }
        if ($pr.body_file) {
            $bodyPath = Join-Path $scriptDirectory $pr.body_file
            if (-not (Test-Path -LiteralPath $bodyPath -PathType Leaf)) {
                throw "$Field[$index].body_file not found: $bodyPath"
            }
        }
        if ($pr.resource_dir -and $pr.body_file) {
            $resourceRoot = (Get-Item -LiteralPath $resourcePath).FullName.TrimEnd(
                [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar
            ) + [IO.Path]::DirectorySeparatorChar
            $bodyFullPath = (Get-Item -LiteralPath $bodyPath).FullName
            if (-not $bodyFullPath.StartsWith($resourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw "$Field[$index].body_file must be inside resource_dir."
            }
        }
        $index++
    }
    return $missing
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
            if ($NoClone) {
                throw '-NoClone is not supported for the branch_and_codespace workflow.'
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
            $missing += @(Assert-PullRequestEntries $Repo.prs 'prs' 1)
        }
        'stacked_prs' {
            $missing += @(Assert-PullRequestEntries $Repo.stack 'stack' 2)
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

# Fresh booth machines often have no git identity; fall back to the GitHub account's noreply address.
function Set-GitIdentity {
    $email = & git config user.email
    if ($LASTEXITCODE -eq 0 -and $email) { return }
    $userId = & gh api user --jq .id
    if ($LASTEXITCODE -ne 0) { $userId = $null }
    $email = if ($userId) { "$userId+$currentUser@users.noreply.github.com" } else { "$currentUser@users.noreply.github.com" }
    Write-Host "No git identity configured; committing as $currentUser <$email> in this clone only"
    Invoke-Native 'git' @('config', 'user.name', $currentUser) | Out-Host
    Invoke-Native 'git' @('config', 'user.email', $email) | Out-Host
}

function New-ResourcePullRequest {
    param($PullRequest, [string]$BaseBranch = $defaultBranch)

    $resourcePath = Join-Path $scriptDirectory $PullRequest.resource_dir
    $bodyPath = Join-Path $scriptDirectory $PullRequest.body_file
    $resourceRoot = (Get-Item -LiteralPath $resourcePath).FullName.TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    $relativeBodyPath = (Get-Item -LiteralPath $bodyPath).FullName.Substring($resourceRoot.Length)

    Write-Host "Creating PR: $($PullRequest.title) (base: $BaseBranch)..."
    Invoke-Native 'git' @('checkout', '--quiet', '-b', $PullRequest.branch, $BaseBranch) | Out-Host
    Get-ChildItem -LiteralPath $resourcePath -Force | Copy-Item -Destination . -Recurse -Force
    Remove-Item -LiteralPath (Join-Path (Get-Location).Path $relativeBodyPath) -Force
    Invoke-Native 'git' @('add', '-A') | Out-Host
    Invoke-Native 'git' @('commit', '-m', $PullRequest.commit_message, '--quiet') | Out-Host
    Invoke-Native 'git' @('push', '-u', 'origin', $PullRequest.branch, '--quiet') | Out-Host
    $url = Invoke-Native 'gh' @(
        'pr', 'create', '--repo', $fullRepoName,
        '--head', $PullRequest.branch, '--base', $BaseBranch,
        '--title', $PullRequest.title, '--body-file', $bodyPath
    )
    $url = "$(@($url)[-1])".Trim()
    $number = 0
    if (-not [int]::TryParse(($url -split '/')[-1], [ref]$number)) {
        throw "Could not determine PR number from: $url"
    }
    Write-Host "PR #$number created: $url"
    [pscustomobject]@{ Number = $number; Url = $url }
}

# Wait (bounded) until a repo generated from a template has its default branch.
function Wait-RepoReady {
    $maxAttempts = 15
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $branch = & gh api "repos/$fullRepoName" --jq '.default_branch'
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($branch)) {
            $branch = "$(@($branch)[-1])".Trim()
            & gh api "repos/$fullRepoName/branches/$branch" --silent | Out-Null
            if ($LASTEXITCODE -eq 0) {
                return $branch
            }
        }
        Start-Sleep -Seconds 2
    }
    throw "Repository $fullRepoName was not ready after $maxAttempts attempts."
}

# Register PR numbers (bottom to top) as a native stack and verify ordering.
function Register-PullRequestStack {
    param([int[]]$Numbers)

    Write-Host "Registering native stack: $($Numbers -join ' ') (bottom to top)..."
    $arguments = @('api', '--method', 'POST', "repos/$fullRepoName/stacks")
    foreach ($number in $Numbers) {
        $arguments += @('-F', "pull_requests[]=$number")
    }
    $arguments += '--silent'
    & gh @arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $links = ($Numbers | ForEach-Object { "https://github.com/$fullRepoName/pull/$_" }) -join ', '
        throw "Failed to register the native stack via the Stacks API. The dependent PR chain still exists: $links"
    }

    $expected = $Numbers -join ' '
    $actual = ''
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        # One number per line; avoids embedded quotes that PowerShell 5.1 mangles.
        $lines = & gh api "repos/$fullRepoName/stacks?pull_request=$($Numbers[0])" `
            --jq '.[0].pull_requests[]?.number'
        $actual = (@($lines) | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ' '
        if ($LASTEXITCODE -eq 0 -and $actual -eq $expected) { break }
        Start-Sleep -Seconds 2
    }
    if ($actual -ne $expected) {
        throw "Stack verification failed: expected [$expected], got [$actual]."
    }
    Write-Host "Native stack registered and verified: $actual"
}

# Write a key=value pair to $GITHUB_OUTPUT when running in GitHub Actions.
function Set-ActionOutput {
    param([string]$Name, [string]$Value)
    if ($env:GITHUB_OUTPUT) {
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$Name=$Value"
    }
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
    if ($nonInteractive) {
        $selectedRepo = $repos | Where-Object { $_.key -eq $Template } | Select-Object -First 1
        if ($null -eq $selectedRepo) {
            throw "Unknown template key: $Template. Valid keys: $(($repos | ForEach-Object { $_.key }) -join ', ')"
        }
        Write-Host "Selected template: $Template"
    }
    else {
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
    }
    Assert-SelectedRepo $selectedRepo

    Write-Host 'Checking GitHub authentication...'
    # Authentication status is the one expected nonzero exit: offer login.
    & gh auth status
    if ($LASTEXITCODE -ne 0) {
        if ($nonInteractive) {
            throw 'Not authenticated with GitHub. In non-interactive mode, log in first (gh auth login) or set GH_TOKEN.'
        }
        Write-Host 'Not logged in to GitHub. Starting login process...'
        Invoke-Native 'gh' @('auth', 'login')
    }
    $currentUser = & gh api user --jq '.login'
    if ($LASTEXITCODE -ne 0) { $currentUser = $null }
    if ([string]::IsNullOrWhiteSpace($currentUser) -and $nonInteractive) {
        # GitHub App installation tokens cannot read /user.
        $currentUser = if ($env:GITHUB_ACTOR) { $env:GITHUB_ACTOR } else { 'github-app' }
    }
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
    Set-ActionOutput 'repo_name' $fullRepoName
    Set-ActionOutput 'repo_url' "https://github.com/$fullRepoName"

    # The cleanup workflow only ever deletes repos carrying this topic.
    Invoke-Native 'gh' @('repo', 'edit', $fullRepoName, '--add-topic', $demoTopic) | Out-Null
    Write-Host "Added topic: $demoTopic"

    Write-Host 'Waiting for template to be fully processed...'
    $defaultBranch = Wait-RepoReady
    Write-Host "Default branch: $defaultBranch"

    $reposDirectory = Join-Path $HOME 'repos'
    $clonePath = Join-Path $reposDirectory $repoName
    if ($NoClone) {
        $clonePath = '(skipped: -NoClone)'
        Write-Host 'Skipping local clone (-NoClone).'
    }
    else {
        if (-not (Test-Path -LiteralPath $reposDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $reposDirectory | Out-Null
        }
        Write-Host "Cloning repository to $clonePath..."
        Invoke-Native 'gh' @('repo', 'clone', $fullRepoName, $clonePath, '--', '--quiet')
    }
    $topPullRequestUrl = $null

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
            Set-GitIdentity
            foreach ($pr in $selectedRepo.prs) {
                New-ResourcePullRequest $pr | Out-Null
            }
        }
        'stacked_prs' {
            Write-Host 'Setting up stacked PRs demo...'
            $tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
            New-Item -ItemType Directory -Path $tempDirectory | Out-Null
            Set-Location -LiteralPath $tempDirectory
            $tempClonePath = Join-Path $tempDirectory $repoName
            Invoke-Native 'gh' @('repo', 'clone', $fullRepoName, $tempClonePath, '--', '--quiet')
            Set-Location -LiteralPath $tempClonePath
            Set-GitIdentity
            $previousBranch = $defaultBranch
            $stackNumbers = @()
            foreach ($layer in $selectedRepo.stack) {
                $created = New-ResourcePullRequest $layer $previousBranch
                $stackNumbers += $created.Number
                $topPullRequestUrl = $created.Url
                $previousBranch = $layer.branch
            }
            Set-ActionOutput 'top_pr_url' $topPullRequestUrl
            Register-PullRequestStack $stackNumbers
        }
    }

    Write-Host ''
    Write-Host 'Setup complete!'
    Write-Host 'Summary:'
    Write-Host "   Repository: https://github.com/$fullRepoName"
    Write-Host "   Cloned to: $clonePath"
    Write-Host "   Template: $templateRepo"
    Write-Host "   User: $currentUser"
    if ($topPullRequestUrl) {
        Write-Host "   Top of stack: $topPullRequestUrl"
    }
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
