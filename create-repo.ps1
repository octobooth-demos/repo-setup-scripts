#Requires -Version 5.1

[CmdletBinding()]
param(
    # Non-interactive: config.json repo key to create. Never prompts or starts gh auth login.
    [string]$Template,
    # Account or org to create the repo in. Default: the template's "owner" in config.json, else the logged-in account.
    [string]$Owner,
    # Skip the permanent clone into $HOME/repos (useful in CI).
    [switch]$NoClone,
    # After setup, check out the default branch and serve it on http://localhost:8080 (npm start). Needs Node.js.
    [switch]$Serve,
    # Delete demo-generated repos owned by -Owner (default: logged-in account) older than -OlderThanHours.
    [switch]$Cleanup,
    [int]$OlderThanHours = 24,
    [switch]$DryRun,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$scriptDirectory = $PSScriptRoot
$configFile = Join-Path $scriptDirectory 'config.json'
$originalLocation = Get-Location
$tempDirectory = $null
$demoTopic = 'demo-generated'
$pagesWorkflow = 'pages.yml'
$nonInteractive = -not [string]::IsNullOrWhiteSpace($Template)

if ($Cleanup -and ($nonInteractive -or $Serve -or $NoClone)) {
    throw '-Cleanup cannot be combined with -Template, -Serve, or -NoClone.'
}
if (-not $Cleanup -and ($DryRun -or $Yes)) {
    throw '-DryRun and -Yes only apply to -Cleanup.'
}
if ($OlderThanHours -lt 0) {
    throw '-OlderThanHours must be zero or more.'
}
if ($Serve -and $NoClone) {
    throw '-Serve needs the local clone, so it cannot be combined with -NoClone.'
}

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

    if ($Repo.visibility -and $Repo.visibility -notin @('public', 'private', 'internal')) {
        throw "Invalid visibility '$($Repo.visibility)' (use public, private, or internal)."
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

function Connect-GitHubAccount {
    Write-Host 'Checking GitHub authentication...'
    # Authentication status is the one expected nonzero exit: offer login.
    & gh auth status | Out-Host
    if ($LASTEXITCODE -ne 0) {
        if ($nonInteractive) {
            throw 'Not authenticated with GitHub. In non-interactive mode, log in first (gh auth login) or set GH_TOKEN.'
        }
        Write-Host 'Not logged in to GitHub. Starting login process...'
        Invoke-Native 'gh' @('auth', 'login', '-s', 'delete_repo') | Out-Host
    }
    $currentUser = & gh api user --jq '.login'
    if ($LASTEXITCODE -ne 0) { $currentUser = $null }
    $userToken = $true
    if ([string]::IsNullOrWhiteSpace($currentUser) -and $nonInteractive) {
        # GitHub App installation tokens cannot read /user.
        $currentUser = if ($env:GITHUB_ACTOR) { $env:GITHUB_ACTOR } else { 'github-app' }
        $userToken = $false
    }
    if ([string]::IsNullOrWhiteSpace($currentUser)) {
        throw 'Failed to get current GitHub username.'
    }
    Write-Host "Current user: $currentUser"
    [pscustomobject]@{ User = $currentUser; UserToken = $userToken }
}

# Cleanup only ever deletes repos carrying $demoTopic, so an untagged demo repo
# would never be cleaned up. Retry, then delete the new repo rather than leave it.
function Add-DemoTopic {
    param([string]$RepoName)

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        & gh repo edit $RepoName --add-topic $demoTopic | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Added topic: $demoTopic"
            return
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
    }
    $message = "Could not add the '$demoTopic' topic to $RepoName, so cleanup would never find it."
    & gh repo delete $RepoName --yes
    if ($LASTEXITCODE -eq 0) {
        throw "$message Deleted the untagged repo; run the script again."
    }
    throw "$message Could not delete it either. Tag it with 'gh repo edit $RepoName --add-topic $demoTopic' or delete it with 'gh repo delete $RepoName --yes'."
}

# Delete demo repos (demo-generated topic) owned by $CleanupOwner older than -OlderThanHours.
# Never touches repos without the topic.
function Invoke-DemoCleanup {
    param([string]$CleanupOwner, [string]$CurrentUser)

    $endpoint = if ($CleanupOwner -eq $CurrentUser) { 'user/repos?affiliation=owner&per_page=100' } else { "orgs/$CleanupOwner/repos?per_page=100" }
    Write-Host "Looking for '$demoTopic' repos owned by $CleanupOwner older than $($OlderThanHours)h..."
    $lines = & gh api --paginate $endpoint --jq '.[] | {full_name, created_at, topics, owner: .owner.login}'
    if ($LASTEXITCODE -ne 0) { throw "gh api $endpoint failed with exit code $LASTEXITCODE." }
    $cutoff = [DateTimeOffset]::UtcNow.AddHours(-$OlderThanHours)
    $candidates = @($lines | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object {
        $_.owner -eq $CleanupOwner -and @($_.topics) -contains $demoTopic -and [DateTimeOffset]$_.created_at -lt $cutoff
    })

    if ($candidates.Count -eq 0) {
        Write-Host 'Nothing to clean up.'
        return
    }
    foreach ($repo in $candidates) { Write-Host "   $($repo.full_name)  (created $($repo.created_at))" }
    if ($DryRun) {
        Write-Host "Dry run: would delete $($candidates.Count) repo(s)."
        return
    }
    if (-not $Yes) {
        $answer = Read-Host "Delete these $($candidates.Count) repo(s)? [y/N]"
        if ($answer -notmatch '^[Yy]') {
            Write-Host 'Cancelled.'
            return
        }
    }
    $failed = 0
    foreach ($repo in $candidates) {
        & gh repo delete $repo.full_name --yes
        if ($LASTEXITCODE -eq 0) { Write-Host "Deleted $($repo.full_name)" } else { $failed++ }
    }
    if ($failed -gt 0) {
        throw "$failed repo(s) could not be deleted. If this is a permissions error, run: gh auth refresh -h github.com -s delete_repo"
    }
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

# Run gh with stderr hidden. Windows PowerShell 5.1 turns redirected native stderr into
# terminating errors under ErrorActionPreference=Stop, so relax it for this call only.
function Invoke-GhQuiet {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & gh @args 2>$null }
    finally { $ErrorActionPreference = $previous }
}

# Open a URL in the default browser (skipped in CI or when DEMO_NO_BROWSER is set).
function Open-Url {
    param([string]$Url)
    if ($env:GITHUB_ACTIONS -or $env:DEMO_NO_BROWSER) { return }
    try { Start-Process $Url } catch { Write-Host "Open $Url in your browser." }
}

# Turn on GitHub Pages (built by the template's pages.yml workflow), run the first
# deploy of the default branch, and wait (bounded) for it. Returns the site URL.
# Failures only warn: the repo and PRs are still usable without Pages.
function Enable-DemoPages {
    Write-Host ''
    Write-Host 'Turning on GitHub Pages...'
    Invoke-GhQuiet api --method POST "repos/$fullRepoName/pages" -f build_type=workflow --silent | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Invoke-GhQuiet api "repos/$fullRepoName/pages" --silent | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Could not turn on GitHub Pages for $fullRepoName."
            Write-Host '   Free accounts need a public repo; check Settings -> Pages on GitHub.'
            return $null
        }
    }
    $url = "$(@(Invoke-GhQuiet api "repos/$fullRepoName/pages" --jq '.html_url')[-1])".Trim()
    if ($LASTEXITCODE -ne 0 -or -not $url) { $url = "https://$($repoOwner.ToLower()).github.io/$repoName/" }
    Set-ActionOutput 'pages_url' $url

    $started = $false
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        Invoke-GhQuiet workflow run $pagesWorkflow --repo $fullRepoName --ref $defaultBranch | Out-Null
        if ($LASTEXITCODE -eq 0) { $started = $true; break }
        Start-Sleep -Seconds 3
    }
    if (-not $started) {
        Write-Host "Could not start the Pages deploy. Run it from the Actions tab: $pagesWorkflow"
        return $url
    }

    Write-Host "Deploying $defaultBranch to $url (usually under a minute)..."
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        # One field per line; avoids embedded quotes that PowerShell 5.1 mangles.
        $fields = @(Invoke-GhQuiet run list --repo $fullRepoName --workflow $pagesWorkflow --event workflow_dispatch `
            --limit 1 --json status,conclusion --jq '.[0].status, .[0].conclusion')
        $state = (($fields | ForEach-Object { "$_".Trim() }) -join ' ').Trim()
        if ($state -eq 'completed success') {
            Write-Host "Game is live: $url"
            return $url
        }
        if ($state -like 'completed *') {
            Write-Host "The Pages deploy finished with '$($state.Substring(10))'. Check the Actions tab of $fullRepoName."
            return $url
        }
        Start-Sleep -Seconds 5
    }
    Write-Host "The Pages deploy is still running; the site will appear at $url shortly."
    return $url
}

try {
    Write-Host 'GitHub demo repository creation tool'
    Write-Host '======================================='

    foreach ($command in @('gh', 'git')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "$command is not installed. Install it and make sure it is on PATH."
        }
    }
    if ($Serve -and -not (Get-Command 'npm' -ErrorAction SilentlyContinue)) {
        throw '-Serve needs Node.js (npm). Install it from https://nodejs.org/'
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
    if ($Cleanup) {
        $account = Connect-GitHubAccount
        $cleanupOwner = if ($Owner) { $Owner } else { $account.User }
        Invoke-DemoCleanup $cleanupOwner $account.User
        return
    }
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

    $account = Connect-GitHubAccount
    $currentUser = $account.User
    $userToken = $account.UserToken

    # Owner precedence: -Owner, then the entry's "owner" ("org" = top-level org),
    # then the logged-in account. App tokens have no account, so they use the org.
    $configOwner = $selectedRepo.owner
    if ($configOwner -eq 'org') { $configOwner = $config.org }
    $repoOwner = if ($Owner) { $Owner }
        elseif ($configOwner) { $configOwner }
        elseif ($userToken) { $currentUser }
        else { $config.org }
    Write-Host "Target owner: $repoOwner"

    # Entries with "serve": true start the local preview whenever there is a local clone.
    if ($selectedRepo.serve -eq $true -and -not $NoClone -and -not $Serve) {
        if (Get-Command 'npm' -ErrorAction SilentlyContinue) {
            $Serve = $true
        }
        else {
            Write-Host 'Skipping the local preview: Node.js (npm) is not installed.'
        }
    }

    $visibility = if ($selectedRepo.visibility) { $selectedRepo.visibility } else { 'private' }

    $templateOrg = $selectedRepo.template_org
    if (-not $templateOrg) { $templateOrg = $config.org }
    $templateRepo = "$templateOrg/$($selectedRepo.template)"
    $alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789'.ToCharArray()
    $suffix = -join (1..4 | ForEach-Object { $alphabet[(Get-Random -Maximum $alphabet.Length)] })
    $repoName = "$($selectedRepo.repo_base_name)-$suffix"
    $fullRepoName = "$repoOwner/$repoName"

    Write-Host "Creating repository: $fullRepoName"
    Write-Host "Using template: $templateRepo"
    Invoke-Native 'gh' @(
        'repo', 'create', $fullRepoName, "--template=$templateRepo",
        "--$visibility", "--description=$($selectedRepo.repo_description)"
    )
    Write-Host "Repository created successfully: $fullRepoName"
    Set-ActionOutput 'repo_name' $fullRepoName
    Set-ActionOutput 'repo_url' "https://github.com/$fullRepoName"

    Add-DemoTopic $fullRepoName

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

    $pagesUrl = $null
    if ($selectedRepo.pages -eq $true) {
        $pagesUrl = Enable-DemoPages
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
    if ($pagesUrl) {
        Write-Host "   Game (GitHub Pages): $pagesUrl"
    }
    foreach ($line in $selectedRepo.summary_lines) {
        if ($line) { Write-Host "   $line" }
    }
    if ($selectedRepo.workflow -in @('branch_and_codespace', 'issue_and_codespace')) {
        Write-Host 'You can access your codespace at: https://github.com/codespaces'
    }

    # Open the PR first and the game last so the game is the tab in front.
    if ($pagesUrl) {
        if ($topPullRequestUrl) { Open-Url $topPullRequestUrl }
        Open-Url $pagesUrl
    }

    if ($Serve) {
        Set-Location -LiteralPath $clonePath
        if ($tempDirectory -and (Test-Path -LiteralPath $tempDirectory)) {
            Remove-Item -LiteralPath $tempDirectory -Recurse -Force
        }
        if (-not (Test-Path -LiteralPath 'package.json' -PathType Leaf)) {
            Write-Host '-Serve: this template has no package.json, so there is nothing to serve.'
            return
        }
        # Start on the default branch so the audience sees the app before the PRs land.
        Invoke-Native 'git' @('fetch', '--quiet', 'origin') | Out-Host
        Invoke-Native 'git' @('checkout', '--quiet', $defaultBranch) | Out-Host
        Write-Host ''
        Write-Host "Serving $defaultBranch (before any PRs are merged). Ctrl+C to stop."
        if ((Get-Content -LiteralPath 'package.json' -Raw | ConvertFrom-Json).scripts.layer) {
            Write-Host "   From another terminal: cd `"$clonePath`""
            Write-Host '     npm run layer -- 1..3   preview a layer of the stack'
            Write-Host "     npm run layer -- 0      back to $defaultBranch; after merging the stack, this pulls the merged code"
            Write-Host '   Then reload the browser.'
        }
        # Ctrl+C ends the server; that is the normal way out, not a failure.
        & npm start '--' --open
    }
}
finally {
    Set-Location -LiteralPath $originalLocation.Path
    if ($tempDirectory -and (Test-Path -LiteralPath $tempDirectory)) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force
    }
}
