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
    [int]$OlderThanHours = 72,
    # End of event: ignore the age cutoff and delete every demo repo (same as -OlderThanHours 0, with a warning).
    [switch]$All,
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
$aiScanApiVersion = '2026-03-10'
# The UI's "Assign to Copilot" uses github-agentic-autofix[bot]; the GA changelog names
# copilot-swe-agent[bot], so it's kept as a fallback.
$copilotAutofixAssignees = @('github-agentic-autofix[bot]', 'copilot-swe-agent[bot]')
$codeqlWaitSeconds = if ($env:CODEQL_WAIT_SECONDS) { [int]$env:CODEQL_WAIT_SECONDS } else { 900 }
$projectsApiVersion = '2026-03-10'
$seedWaitSeconds = if ($env:SEED_WAIT_SECONDS) { [int]$env:SEED_WAIT_SECONDS } else { 600 }
$nonInteractive = -not [string]::IsNullOrWhiteSpace($Template)

if ($Cleanup -and ($nonInteractive -or $Serve -or $NoClone)) {
    throw '-Cleanup cannot be combined with -Template, -Serve, or -NoClone.'
}
if (-not $Cleanup -and ($DryRun -or $Yes -or $All)) {
    throw '-DryRun, -Yes, and -All only apply to -Cleanup.'
}
if ($All -and $PSBoundParameters.ContainsKey('OlderThanHours')) {
    throw '-All cannot be combined with -OlderThanHours.'
}
if ($All) { $OlderThanHours = 0 }
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
        # Only the blank workflow creates a repo without a template.
        if ($field -eq 'template' -and $Repo.workflow -eq 'blank') { continue }
        if ([string]::IsNullOrWhiteSpace($Repo.$field)) {
            $missing += $field
        }
    }

    if ($Repo.visibility -and $Repo.visibility -notin @('public', 'private', 'internal')) {
        throw "Invalid visibility '$($Repo.visibility)' (use public, private, or internal)."
    }

    switch ($Repo.workflow) {
        'repo_only' {}
        'blank' {
            if ($Repo.seed_prompt_file) {
                $seedPrompt = Join-Path $scriptDirectory $Repo.seed_prompt_file
                if (-not (Test-Path -LiteralPath $seedPrompt -PathType Leaf)) {
                    throw "seed_prompt_file not found: $seedPrompt"
                }
            }
        }
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
        'code_review_prs' {
            $missing += @(Assert-PullRequestEntries $Repo.prs 'prs' 1)
        }
        'ai_security' {
            # AI Scan entries need a PR; agentic autofix entries need "autofix".
            if ($Repo.PSObject.Properties['prs'] -or -not $Repo.PSObject.Properties['autofix']) {
                $missing += @(Assert-PullRequestEntries $Repo.prs 'prs' 1)
            }
            if ($Repo.seed) {
                foreach ($field in @('resource_dir', 'commit_message')) {
                    if ([string]::IsNullOrWhiteSpace($Repo.seed.$field)) {
                        $missing += "seed.$field"
                    }
                }
                if ($Repo.seed.resource_dir) {
                    $seedPath = Join-Path $scriptDirectory $Repo.seed.resource_dir
                    if (-not (Test-Path -LiteralPath $seedPath -PathType Container)) {
                        throw "seed.resource_dir not found: $seedPath"
                    }
                }
            }
        }
        'stacked_prs' {
            $missing += @(Assert-PullRequestEntries $Repo.stack 'stack' 2)
        }
        'project_board' {
            if ([string]::IsNullOrWhiteSpace($Repo.project.file)) {
                $missing += 'project.file'
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

function Connect-GitHubAccount {
    Write-Host 'Checking GitHub authentication...'
    # Authentication status is the one expected nonzero exit: offer login.
    & gh auth status | Out-Host
    if ($LASTEXITCODE -ne 0) {
        if ($nonInteractive) {
            throw 'Not authenticated with GitHub. In non-interactive mode, log in first (gh auth login) or set GH_TOKEN.'
        }
        Write-Host 'Not logged in to GitHub. Starting login process...'
        # delete_repo lets -Cleanup remove old demo repos; project lets Copilot Airways
        # create its GitHub Project (and cleanup delete it).
        Invoke-Native 'gh' @('auth', 'login', '-s', 'delete_repo,project') | Out-Host
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
    if ($All) {
        Write-Warning "-All ignores the age cutoff: every '$demoTopic' repo owned by $CleanupOwner will be deleted, including demos still in use."
        Write-Host "Looking for all '$demoTopic' repos owned by $CleanupOwner..."
    }
    else {
        Write-Host "Looking for '$demoTopic' repos owned by $CleanupOwner older than $($OlderThanHours)h..."
    }
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
        Remove-DemoProjects $repo.full_name
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

# Request a Copilot Code Review on a PR. Never fails the setup: older gh
# versions don't know "@copilot", and some tokens (e.g. GitHub App installation
# tokens) can't request it, so fall back to the REST API and finally just warn.
function Request-CopilotReview {
    param([int]$Number)

    Invoke-GhQuiet pr edit $Number --repo $fullRepoName --add-reviewer '@copilot' | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Copilot Code Review requested on PR #$Number"
        return
    }
    Invoke-GhQuiet api --method POST "repos/$fullRepoName/pulls/$Number/requested_reviewers" `
        -f 'reviewers[]=copilot-pull-request-reviewer[bot]' --silent | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Copilot Code Review requested on PR #$Number (via REST API)"
        return
    }
    Write-Warning "Could not request Copilot Code Review on PR #$Number. Open the PR and pick Copilot under Reviewers to request it manually."
}

# Wait (bounded) until a repo generated from a template has its default branch.
function Wait-RepoReady {
    $maxAttempts = 60
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

# Turn on AI Scan for pull requests. Org-owned repos inherit the org setting, so
# this is usually a no-op; it only warns because the org may enforce the value.
function Enable-AiScan {
    Write-Host 'Enabling AI Scan for pull requests...'
    Invoke-GhQuiet api --method PATCH "repos/$fullRepoName/code-scanning/ai-scan" `
        -H "X-GitHub-Api-Version: $aiScanApiVersion" -f pr_scan=enabled --silent | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'AI Scan for pull requests enabled.'
        return
    }
    $state = "$(@(Invoke-GhQuiet api "repos/$fullRepoName/code-scanning/ai-scan" `
        -H "X-GitHub-Api-Version: $aiScanApiVersion" --jq '.pr_scan')[-1])".Trim()
    if ($LASTEXITCODE -eq 0 -and $state -eq 'enabled') {
        Write-Host 'AI Scan for pull requests already enabled (inherited from the organization).'
        return
    }
    if (-not $state) { $state = 'unknown' }
    Write-Warning "Could not enable AI Scan for pull requests (current state: $state). An org owner must allow it under Settings -> Code security -> Global settings -> AI Scan."
}

# Open default-branch code scanning alerts as objects (empty on failure).
function Get-OpenCodeScanningAlerts {
    $json = Invoke-GhQuiet api "repos/$fullRepoName/code-scanning/alerts?state=open&ref=refs/heads/$defaultBranch&per_page=100"
    if ($LASTEXITCODE -ne 0 -or -not $json) { return @() }
    try { $parsed = ($json -join "`n") | ConvertFrom-Json } catch { return @() }
    # Windows PowerShell 5.1 emits a JSON array as one object; enumerate it explicitly.
    foreach ($alert in $parsed) { $alert }
}

# AI Scan only reviews PRs opened while code scanning is on, which for advanced
# setup means after the first analysis upload (the template's CodeQL run on its
# initial commit). Wait (bounded) for it; only warns on timeout.
function Wait-CodeScanningEnabled {
    Write-Host 'Waiting for code scanning to turn on (first CodeQL upload, usually 2-4 minutes)...'
    for ($waited = 0; $waited -lt $codeqlWaitSeconds; $waited += 10) {
        $count = "$(@(Invoke-GhQuiet api "repos/$fullRepoName/code-scanning/analyses?per_page=1" --jq 'length')[-1])".Trim()
        if ($LASTEXITCODE -eq 0 -and $count -match '^[1-9]') {
            Write-Host 'Code scanning is on.'
            return
        }
        Start-Sleep -Seconds 10
    }
    Write-Warning "Code scanning still had no analysis after $([int]($codeqlWaitSeconds / 60)) minutes; opening the PR anyway. If no AI findings appear, push a commit to the PR branch to rescan it."
}

# Wait (bounded) for the CodeQL workflow run on $Sha to finish and for open
# default-branch alerts to show up (preferring an alert for $Rule, since results
# for each language arrive separately). Throws a clear message on failure.
# $Event limits the run lookup to one trigger, so a dispatched run on an
# already-scanned commit isn't confused with that commit's earlier push run.
function Wait-CodeQLAnalysis {
    # $Event/$eventArgs are only automatic inside event handlers; this is a plain function.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '')]
    param([string]$Workflow, [string]$Sha, [string]$Rule, [string]$Event)

    Write-Host "Waiting for CodeQL ($Workflow) to analyze $defaultBranch (usually 3-6 minutes)..."
    $runId = $null
    $state = ''
    for ($waited = 0; $waited -lt $codeqlWaitSeconds; $waited += 10) {
        if (-not $runId) {
            $eventArgs = if ($Event) { @('--event', $Event) } else { @() }
            $runId = "$(@(Invoke-GhQuiet run list --repo $fullRepoName --workflow $Workflow --commit $Sha @eventArgs `
                --limit 1 --json databaseId --jq '.[0].databaseId // empty')[-1])".Trim()
        }
        if ($runId) {
            # One field per line; avoids embedded quotes that PowerShell 5.1 mangles.
            $fields = @(Invoke-GhQuiet run view $runId --repo $fullRepoName --json 'status,conclusion' --jq '.status, .conclusion')
            $state = (($fields | ForEach-Object { "$_".Trim() }) -join ' ').Trim()
            if ($state -eq 'completed success') { break }
            if ($state -like 'completed *') {
                throw "CodeQL finished with '$($state.Substring(10))' on $defaultBranch. See https://github.com/$fullRepoName/actions/runs/$runId"
            }
        }
        Start-Sleep -Seconds 10
    }
    if ($state -ne 'completed success') {
        if (-not $runId) {
            throw "CodeQL never started on $defaultBranch. Check that Actions are enabled for $fullRepoName."
        }
        throw "CodeQL was still running after $([int]($codeqlWaitSeconds / 60)) minutes. See https://github.com/$fullRepoName/actions/runs/$runId"
    }
    Write-Host 'CodeQL analysis finished.'

    # Processing uploaded results can lag the workflow run by several minutes.
    Write-Host 'Waiting for code scanning to process the results...'
    $alerts = @()
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        $alerts = @(Get-OpenCodeScanningAlerts)
        if ($alerts.Count -gt 0 -and (-not $Rule -or @($alerts | Where-Object { $_.rule.id -eq $Rule }).Count -gt 0)) { break }
        Start-Sleep -Seconds 5
    }
    if ($alerts.Count -eq 0) {
        throw "CodeQL finished but no open alerts appeared on $defaultBranch within 5 minutes. Check https://github.com/$fullRepoName/security/code-scanning and assign an alert to Copilot by hand."
    }
    Write-Host "$($alerts.Count) open code scanning alerts on $defaultBranch"
}

# Assign one default-branch alert to Copilot (agentic autofix) so a draft fix PR
# is ready by demo time. Prefers $Rule, else the first open alert. Only warns.
# Returns the alert URL when assigned.
function Set-CopilotAlertAssignee {
    param([string]$Rule)

    $alerts = @(Get-OpenCodeScanningAlerts)
    $alert = $null
    if ($Rule) {
        $alert = $alerts | Where-Object { $_.rule.id -eq $Rule } | Select-Object -First 1
        if (-not $alert) { Write-Host "No open '$Rule' alert; assigning the first open alert instead." }
    }
    if (-not $alert) { $alert = $alerts | Select-Object -First 1 }
    if (-not $alert) {
        Write-Warning 'No open alert to assign to Copilot.'
        return $null
    }
    $number = $alert.number
    $alertUrl = "https://github.com/$fullRepoName/security/code-scanning/$number"
    Write-Host "Assigning code scanning alert #$number to Copilot (agentic autofix)..."
    foreach ($assignee in $copilotAutofixAssignees) {
        $assignees = @(Invoke-GhQuiet api --method PATCH "repos/$fullRepoName/code-scanning/alerts/$number" `
            -H "X-GitHub-Api-Version: $aiScanApiVersion" -f "assignees[]=$assignee" `
            --jq '.assignees[]?.login')
        if ($LASTEXITCODE -ne 0 -or -not (($assignees | ForEach-Object { "$_".Trim() }) -contains $assignee)) { continue }
        Write-Host "Alert #$number assigned to Copilot; a draft fix PR appears in about 10 minutes."
        return $alertUrl
    }
    Write-Warning "Could not assign alert #$number to Copilot. Agentic autofix must be on for the repo, and the token needs a user (GitHub App tokens may not be able to assign Copilot). Assign it from $alertUrl (Assign to Copilot)."
    return $null
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
            --limit 1 --json 'status,conclusion' --jq '.[0].status, .[0].conclusion')
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

# --- GitHub Projects (project_board workflow) ---

function Get-DayOffset {
    param([double]$Days)
    [DateTime]::UtcNow.Date.AddDays($Days).ToString('yyyy-MM-dd')
}

# Run gh and parse its JSON output.
function Invoke-GhJson {
    param([string[]]$Arguments)
    $output = Invoke-Native 'gh' $Arguments
    if ($null -eq $output) { return $null }
    ($output -join "`n") | ConvertFrom-Json
}

# Send a GraphQL request body ({query, variables}) through a temp file, which
# avoids native-argument quoting differences between PowerShell versions.
function Invoke-GraphQL {
    param([string]$Query, [hashtable]$Variables = @{})
    $file = [IO.Path]::GetTempFileName()
    try {
        $body = @{ query = $Query; variables = $Variables } | ConvertTo-Json -Depth 20 -Compress
        [IO.File]::WriteAllText($file, $body, (New-Object Text.UTF8Encoding $false))
        Invoke-GhJson @('api', 'graphql', '--input', $file)
    }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}

# Read a JSON file from the new repo's default branch.
function Get-RepoJsonFile {
    param([string]$Path)
    Invoke-GhJson @('api', "repos/$fullRepoName/contents/$($Path)?ref=$defaultBranch", '-H', 'Accept: application/vnd.github.raw')
}

# Wait (bounded) for the template's issue-seeding workflow to finish. Repos made
# from a template run it on their first push; if no run shows up, start one.
function Wait-SeedWorkflow {
    param([string]$Workflow)
    Write-Host "Waiting for $Workflow to seed issues (up to $([int]($seedWaitSeconds / 60)) min)..."
    $dispatched = $false
    for ($waited = 0; $waited -lt $seedWaitSeconds; $waited += 5) {
        $fields = @(Invoke-GhQuiet run list --repo $fullRepoName --workflow $Workflow --limit 1 `
            --json 'status,conclusion,url' --jq '.[0] // empty | .status, .conclusion, .url')
        $status = if ($fields.Count -gt 0) { "$($fields[0])".Trim() } else { '' }
        if ($status -eq 'completed') {
            $conclusion = "$($fields[1])".Trim()
            if ($conclusion -ne 'success') {
                throw "$Workflow finished with '$conclusion': $("$($fields[2])".Trim())"
            }
            Write-Host "Issues seeded by $Workflow"
            return
        }
        if (-not $status -and -not $dispatched -and $waited -ge 60) {
            Write-Host "No $Workflow run yet; starting one"
            Invoke-GhQuiet workflow run $Workflow --repo $fullRepoName --ref $defaultBranch | Out-Null
            $dispatched = $true
        }
        Start-Sleep -Seconds 5
    }
    throw "$Workflow did not finish in time. Check the Actions tab of $fullRepoName."
}

# Set an item's field values in one request. Dates are days from today and
# iterations are 1-based (oldest first).
function Set-ProjectItemFields {
    param([string]$ProjectId, [string]$ItemId, [hashtable]$FieldMap, $Values)
    if ($null -eq $Values) { return }
    $inputs = @()
    foreach ($property in $Values.PSObject.Properties) {
        $field = $FieldMap[$property.Name]
        if ($null -eq $field) { throw "Unknown project field: $($property.Name)" }
        $value = switch ($field.Type) {
            'SINGLE_SELECT' {
                $optionId = $field.Options["$($property.Value)"]
                if (-not $optionId) { throw "Unknown $($property.Name) option: $($property.Value)" }
                @{ singleSelectOptionId = $optionId }
            }
            'NUMBER' { @{ number = [double]$property.Value } }
            'DATE' { @{ date = (Get-DayOffset $property.Value) } }
            'ITERATION' {
                $index = [int]$property.Value - 1
                if ($index -lt 0 -or $index -ge $field.Iterations.Count) { throw "No $($property.Name) number $($property.Value)" }
                @{ iterationId = $field.Iterations[$index] }
            }
            default { @{ text = "$($property.Value)" } }
        }
        $inputs += , @{ projectId = $ProjectId; itemId = $ItemId; fieldId = $field.Id; value = $value }
    }
    if ($inputs.Count -eq 0) { return }
    $declarations = @(); $mutations = @(); $variables = @{}
    for ($i = 0; $i -lt $inputs.Count; $i++) {
        $declarations += "`$i$($i): UpdateProjectV2ItemFieldValueInput!"
        $mutations += "u$($i): updateProjectV2ItemFieldValue(input: `$i$($i)) { clientMutationId }"
        $variables["i$i"] = $inputs[$i]
    }
    Invoke-GraphQL "mutation($($declarations -join ', ')) { $($mutations -join ' ') }" $variables | Out-Null
}

# Create the saved views (REST, so they can be filtered, grouped, and sorted),
# then remove the default "View 1".
function New-ProjectViews {
    param([int]$Number, [string]$ProjectId, $Views)
    if (@($Views).Count -eq 0) { return }
    $ownerType = "$(@(Invoke-Native 'gh' @('api', "users/$repoOwner", '--jq', '.type'))[-1])".Trim()
    $base = if ($ownerType -eq 'Organization') { "orgs/$repoOwner" } else { "users/$repoOwner" }
    $restIds = @{}
    foreach ($field in @(Invoke-GhJson @('api', '-H', "X-GitHub-Api-Version: $projectsApiVersion", "$base/projectsV2/$Number/fields?per_page=100"))) {
        $restIds[$field.name] = $field.id
    }
    $fieldId = {
        param([string]$Name)
        if (-not $restIds.ContainsKey($Name)) { throw "Unknown field in view: $Name" }
        $restIds[$Name]
    }
    foreach ($view in $Views) {
        $body = @{ name = $view.name; layout = $view.layout }
        if ($view.filter) { $body.filter = $view.filter }
        if ($view.visible_fields) { $body.visible_fields = @($view.visible_fields | ForEach-Object { & $fieldId $_ }) }
        if ($view.group_by) { $body.group_by = @(& $fieldId $view.group_by) }
        if ($view.vertical_group_by) { $body.vertical_group_by = @(& $fieldId $view.vertical_group_by) }
        if ($view.sort_by) { $body.sort_by = @($view.sort_by | ForEach-Object { , @((& $fieldId $_[0]), $_[1]) }) }
        $file = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($file, ($body | ConvertTo-Json -Depth 10 -Compress), (New-Object Text.UTF8Encoding $false))
            Invoke-Native 'gh' @('api', '-X', 'POST', '-H', "X-GitHub-Api-Version: $projectsApiVersion",
                "$base/projectsV2/$Number/views", '--input', $file, '--silent') | Out-Null
        }
        finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        Write-Host "View: $($view.name)"
    }
    $existing = Invoke-GraphQL 'query($p: ID!) { node(id: $p) { ... on ProjectV2 { views(first: 50) { nodes { id name } } } } }' @{ p = $ProjectId }
    foreach ($default in @($existing.data.node.views.nodes | Where-Object { $_.name -eq 'View 1' })) {
        try {
            Invoke-GraphQL 'mutation($v: ID!) { deleteProjectV2View(input: { viewId: $v }) { clientMutationId } }' @{ v = $default.id } | Out-Null
        }
        catch { Write-Host "Could not remove the default 'View 1'" }
    }
}

# Create a GitHub Project from the template's project definition, link it to the
# repo, and add the seeded issues with their field values. Returns the project URL.
function New-DemoProject {
    $settings = $selectedRepo.project
    if ($settings.seed_workflow) { Wait-SeedWorkflow $settings.seed_workflow }
    $definition = Get-RepoJsonFile $settings.file
    $issueData = if ($settings.issues_file) { Get-RepoJsonFile $settings.issues_file } else { $null }

    $title = "$($definition.title) ($repoName)"
    Write-Host "Creating project: $title"
    $created = Invoke-GhJson @('project', 'create', '--owner', $repoOwner, '--title', $title, '--format', 'json')
    $number = [int]$created.number
    $projectId = $created.id
    $editArgs = @('project', 'edit', "$number", '--owner', $repoOwner)
    if ($definition.short_description) { $editArgs += @('--description', $definition.short_description) }
    if ($definition.readme) { $editArgs += @('--readme', $definition.readme) }
    Invoke-Native 'gh' $editArgs | Out-Null
    Invoke-Native 'gh' @('project', 'link', "$number", '--owner', $repoOwner, '--repo', $fullRepoName) | Out-Null
    Write-Host "Project linked to $fullRepoName"

    if (@($definition.status_options).Count -gt 0) {
        $status = Invoke-GraphQL 'query($p: ID!) { node(id: $p) { ... on ProjectV2 { field(name: "Status") { ... on ProjectV2SingleSelectField { id } } } } }' @{ p = $projectId }
        $options = @($definition.status_options | ForEach-Object { @{ name = $_.name; color = $_.color; description = "$($_.description)" } })
        Invoke-GraphQL 'mutation($input: UpdateProjectV2FieldInput!) { updateProjectV2Field(input: $input) { clientMutationId } }' `
            @{ input = @{ fieldId = $status.data.node.field.id; singleSelectOptions = $options } } | Out-Null
        Write-Host "Status options: $(($definition.status_options | ForEach-Object { $_.name }) -join ', ')"
    }

    foreach ($field in @($definition.fields)) {
        if ($null -eq $field) { continue }
        $fieldInput = @{ projectId = $projectId; name = $field.name; dataType = $field.type.ToUpperInvariant() }
        if ($field.type -eq 'single_select') {
            $fieldInput.singleSelectOptions = @($field.options | ForEach-Object { @{ name = $_.name; color = $_.color; description = "$($_.description)" } })
        }
        if ($field.type -eq 'iteration') {
            $start = if ($null -ne $field.start_offset_days) { [int]$field.start_offset_days } else { 0 }
            $length = if ($field.duration_days) { [int]$field.duration_days } else { 14 }
            $count = if ($field.count) { [int]$field.count } else { 3 }
            $fieldInput.iterationConfiguration = @{
                startDate = (Get-DayOffset $start); duration = $length
                iterations = @(0..($count - 1) | ForEach-Object {
                    @{ title = "Sprint $($_ + 1)"; startDate = (Get-DayOffset ($start + $_ * $length)); duration = $length }
                })
            }
        }
        Invoke-GraphQL 'mutation($input: CreateProjectV2FieldInput!) { createProjectV2Field(input: $input) { clientMutationId } }' @{ input = $fieldInput } | Out-Null
        Write-Host "Field: $($field.name)"
    }

    $fields = Invoke-GraphQL @'
query($p: ID!) { node(id: $p) { ... on ProjectV2 { fields(first: 50) { nodes {
  ... on ProjectV2Field { id name dataType }
  ... on ProjectV2SingleSelectField { id name dataType options { id name } }
  ... on ProjectV2IterationField { id name dataType configuration {
    iterations { id startDate } completedIterations { id startDate } } } } } } } }
'@ @{ p = $projectId }
    $fieldMap = @{}
    foreach ($node in @($fields.data.node.fields.nodes)) {
        $options = @{}
        foreach ($option in @($node.options)) { if ($option) { $options[$option.name] = $option.id } }
        $iterations = @(@($node.configuration.completedIterations) + @($node.configuration.iterations) |
            Where-Object { $_ } | Sort-Object startDate | ForEach-Object { $_.id })
        $fieldMap[$node.name] = @{ Id = $node.id; Type = $node.dataType; Options = $options; Iterations = $iterations }
    }

    $added = 0
    $projectIssues = @($issueData.issues | Where-Object { $_ -and $_.project })
    if ($projectIssues.Count -gt 0) {
        $issueIds = @{}
        foreach ($issue in @(Invoke-GhJson @('issue', 'list', '--repo', $fullRepoName, '--state', 'all', '--limit', '500', '--json', 'id,title'))) {
            $issueIds[$issue.title] = $issue.id
        }
        foreach ($issue in $projectIssues) {
            if (-not $issueIds.ContainsKey($issue.title)) {
                Write-Warning "Issue not found, so not added to the project: $($issue.title)"
                continue
            }
            $item = Invoke-GraphQL 'mutation($p: ID!, $c: ID!) { addProjectV2ItemById(input: { projectId: $p, contentId: $c }) { item { id } } }' `
                @{ p = $projectId; c = $issueIds[$issue.title] }
            Set-ProjectItemFields $projectId $item.data.addProjectV2ItemById.item.id $fieldMap $issue.project
            $added++
        }
    }
    Write-Host "Added $added issue(s) to the project with their field values"

    foreach ($draft in @($definition.drafts | Where-Object { $_ })) {
        $item = Invoke-GraphQL 'mutation($input: AddProjectV2DraftIssueInput!) { addProjectV2DraftIssue(input: $input) { projectItem { id } } }' `
            @{ input = @{ projectId = $projectId; title = $draft.title; body = "$($draft.body)" } }
        Set-ProjectItemFields $projectId $item.data.addProjectV2DraftIssue.projectItem.id $fieldMap $draft.fields
        Write-Host "Draft item: $($draft.title)"
    }

    New-ProjectViews $number $projectId @($definition.views | Where-Object { $_ })

    if ($definition.status_update) {
        $update = $definition.status_update
        $updateInput = @{ projectId = $projectId; status = $(if ($update.status) { $update.status } else { 'ON_TRACK' }); body = "$($update.body)" }
        if ($null -ne $update.start_offset_days) { $updateInput.startDate = Get-DayOffset $update.start_offset_days }
        if ($null -ne $update.target_offset_days) { $updateInput.targetDate = Get-DayOffset $update.target_offset_days }
        Invoke-GraphQL 'mutation($input: CreateProjectV2StatusUpdateInput!) { createProjectV2StatusUpdate(input: $input) { clientMutationId } }' @{ input = $updateInput } | Out-Null
        Write-Host 'Project status update posted'
    }

    Write-Host "Project ready: $($created.url)"
    Set-ActionOutput 'project_url' $created.url
    return $created.url
}

# Delete the projects New-DemoProject created for a demo repo: linked to it and
# titled "... (<repo name>)". Projects outlive their repo, so cleanup does this
# first. Never fails cleanup.
function Remove-DemoProjects {
    param([string]$FullName)
    $owner, $name = $FullName -split '/', 2
    try {
        $result = Invoke-GraphQL 'query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { projectsV2(first: 20) { nodes { id title } } } }' `
            @{ owner = $owner; name = $name }
    }
    catch {
        Write-Warning "Could not look up projects for $FullName; any demo project is left behind (needs the 'project' scope: gh auth refresh -s project)"
        return
    }
    foreach ($project in @($result.data.repository.projectsV2.nodes | Where-Object { $_ -and $_.title.EndsWith(" ($name)") })) {
        try {
            Invoke-GraphQL 'mutation($id: ID!) { deleteProjectV2(input: { projectId: $id }) { clientMutationId } }' @{ id = $project.id } | Out-Null
            Write-Host "Deleted project: $($project.title)"
        }
        catch { Write-Warning "Could not delete project '$($project.title)' (needs the 'project' scope: gh auth refresh -s project)" }
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
            if ($repo.template) { Write-Host "$($index + 1). $displayName ($templateOrg/$($repo.template))" }
            else { Write-Host "$($index + 1). $displayName (empty repo)" }
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
    if ($selectedRepo.workflow -eq 'project_board') {
        if (-not $userToken) {
            throw "The project_board workflow needs a user token with the 'project' scope."
        }
        # Classic OAuth tokens list their scopes; fine-grained tokens don't, so only check when listed.
        $scopeHeader = @(Invoke-GhQuiet api -i user | Where-Object { "$_" -match '^x-oauth-scopes:' } | Select-Object -First 1)
        if ($scopeHeader.Count -gt 0) {
            $scopes = @(("$($scopeHeader[0])" -replace '^[^:]+:', '') -split ',' | ForEach-Object { $_.Trim() })
            if ($scopes -notcontains 'project') {
                throw "This demo creates a GitHub Project, so your gh login needs the 'project' scope. Run: gh auth refresh -h github.com -s project"
            }
        }
    }

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
    $templateRepo = if ($selectedRepo.template) { "$templateOrg/$($selectedRepo.template)" } else { $null }
    $alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789'.ToCharArray()
    $suffix = -join (1..4 | ForEach-Object { $alphabet[(Get-Random -Maximum $alphabet.Length)] })
    $repoName = "$($selectedRepo.repo_base_name)-$suffix"
    $fullRepoName = "$repoOwner/$repoName"

    Write-Host "Creating repository: $fullRepoName"
    if ($templateRepo) {
        Write-Host "Using template: $templateRepo"
        Invoke-Native 'gh' @(
            'repo', 'create', $fullRepoName, "--template=$templateRepo",
            "--$visibility", "--description=$($selectedRepo.repo_description)"
        )
    }
    else {
        # No template: an empty repo with just a README, so it has a default branch to clone.
        Write-Host 'No template: creating an empty repo with a README'
        Invoke-Native 'gh' @(
            'repo', 'create', $fullRepoName, '--add-readme',
            "--$visibility", "--description=$($selectedRepo.repo_description)"
        )
    }
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
    $pullsUrl = $null
    $alertsUrl = $null
    $assignedAlertUrl = $null
    $projectUrl = $null

    switch ($selectedRepo.workflow) {
        'repo_only' {
            Write-Host 'Repository creation complete (no additional actions needed).'
        }
        'blank' {
            Write-Host 'Empty repository ready for a blank-prompt demo.'
            if ($selectedRepo.seed_prompt_file) {
                Write-Host "Seed prompt: $(Join-Path $scriptDirectory $selectedRepo.seed_prompt_file)"
            }
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
                # Private repos need Advanced Security before Code Scanning default setup.
                Invoke-Native 'gh' @(
                    'api', "repos/$fullRepoName", '-X', 'PATCH',
                    '-f', 'security_and_analysis[advanced_security][status]=enabled', '--silent'
                )
                Invoke-Native 'gh' @(
                    'api', "repos/$fullRepoName/code-scanning/default-setup", '-X', 'PATCH',
                    '-f', 'state=configured', '-f', 'query_suite=default', '--silent'
                )
                Write-Host 'Dependabot alerts, security updates, and Code Scanning enabled.'
                # Default setup rejects advanced-setup SARIF uploads, which would fail a check on every PR.
                Invoke-GhQuiet workflow disable codeql-advanced.yml -R $fullRepoName | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host 'Disabled codeql-advanced.yml (default setup is on).'
                }
                else {
                    Write-Host 'codeql-advanced.yml not found or already disabled.'
                }
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
        'code_review_prs' {
            Write-Host 'Setting up Copilot Code Review demo with PRs...'
            $tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
            New-Item -ItemType Directory -Path $tempDirectory | Out-Null
            Set-Location -LiteralPath $tempDirectory
            $tempClonePath = Join-Path $tempDirectory $repoName
            Invoke-Native 'gh' @('repo', 'clone', $fullRepoName, $tempClonePath, '--', '--quiet')
            Set-Location -LiteralPath $tempClonePath
            Set-GitIdentity
            foreach ($pr in $selectedRepo.prs) {
                $created = New-ResourcePullRequest $pr
                # "request_review": false leaves the PR for the presenter to request live.
                if ($pr.request_review -eq $false) {
                    Write-Host "Copilot Code Review not requested on PR #$($created.Number): request it live from the PR (Reviewers -> Copilot)."
                } else {
                    Request-CopilotReview $created.Number
                }
            }
            # Make the PR branches visible in the local clone (Copilot app, editor).
            if (-not $NoClone) {
                Invoke-Native 'git' @('-C', $clonePath, 'fetch', '--quiet', 'origin') | Out-Host
                Write-Host "PR branches fetched into $clonePath"
            }
            $pullsUrl = "https://github.com/$fullRepoName/pulls"
            Set-ActionOutput 'pulls_url' $pullsUrl
        }
        'ai_security' {
            Write-Host 'Setting up AI code security demo...'
            # The template runs CodeQL through its own advanced workflow. Default setup
            # is deliberately not enabled: it would reject that workflow's uploads.
            # Private repos need Advanced Security before code scanning results are accepted.
            Invoke-Native 'gh' @(
                'api', "repos/$fullRepoName", '-X', 'PATCH',
                '-f', 'security_and_analysis[advanced_security][status]=enabled', '--silent'
            )
            Write-Host 'Advanced Security enabled.'
            if ($selectedRepo.ai_scan -eq $true) { Enable-AiScan }

            $tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
            New-Item -ItemType Directory -Path $tempDirectory | Out-Null
            Set-Location -LiteralPath $tempDirectory
            $tempClonePath = Join-Path $tempDirectory $repoName
            Invoke-Native 'gh' @('repo', 'clone', $fullRepoName, $tempClonePath, '--', '--quiet')
            Set-Location -LiteralPath $tempClonePath
            Set-GitIdentity

            # Agentic autofix only works on default-branch alerts, so wait for CodeQL first.
            if ($selectedRepo.PSObject.Properties['autofix']) {
                $codeqlWorkflow = if ($selectedRepo.codeql_workflow) { $selectedRepo.codeql_workflow } else { 'codeql-advanced.yml' }
                $codeqlEvent = ''
                if ($selectedRepo.seed) {
                    Write-Host 'Adding extra default-branch code for CodeQL to flag...'
                    $seedPath = Join-Path $scriptDirectory $selectedRepo.seed.resource_dir
                    Get-ChildItem -LiteralPath $seedPath -Force | Copy-Item -Destination . -Recurse -Force
                    Invoke-Native 'git' @('add', '-A') | Out-Host
                    Invoke-Native 'git' @('commit', '-m', $selectedRepo.seed.commit_message, '--quiet') | Out-Host
                    Invoke-Native 'git' @('push', 'origin', $defaultBranch, '--quiet') | Out-Host
                }
                else {
                    Invoke-Native 'gh' @('workflow', 'run', $codeqlWorkflow, '--repo', $fullRepoName, '--ref', $defaultBranch) | Out-Null
                    $codeqlEvent = 'workflow_dispatch'
                }
                $headSha = "$(@(Invoke-Native 'git' @('rev-parse', 'HEAD'))[-1])".Trim()
                Wait-CodeQLAnalysis $codeqlWorkflow $headSha $selectedRepo.autofix.preassign_rule $codeqlEvent
                $assignedAlertUrl = Set-CopilotAlertAssignee $selectedRepo.autofix.preassign_rule
                $alertsUrl = "https://github.com/$fullRepoName/security/code-scanning"
                Set-ActionOutput 'alerts_url' $alertsUrl
            }

            $aiScanPrs = @($selectedRepo.prs | Where-Object { $null -ne $_ })
            # Waiting for CodeQL above already guarantees code scanning is on.
            if ($aiScanPrs.Count -gt 0 -and $selectedRepo.ai_scan -eq $true -and -not $alertsUrl) { Wait-CodeScanningEnabled }
            foreach ($pr in $aiScanPrs) {
                New-ResourcePullRequest $pr | Out-Null
            }
            if (-not $NoClone) {
                Invoke-Native 'git' @('-C', $clonePath, 'pull', '--quiet', 'origin', $defaultBranch) | Out-Host
                Invoke-Native 'git' @('-C', $clonePath, 'fetch', '--quiet', 'origin') | Out-Host
            }
            $pullsUrl = "https://github.com/$fullRepoName/pulls"
            Set-ActionOutput 'pulls_url' $pullsUrl
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
        'project_board' {
            Write-Host 'Setting up GitHub Projects demo...'
            $projectUrl = New-DemoProject
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
    Write-Host "   Template: $(if ($templateRepo) { $templateRepo } else { '(none, empty repo)' })"
    Write-Host "   User: $currentUser"
    if ($topPullRequestUrl) {
        Write-Host "   Top of stack: $topPullRequestUrl"
    }
    if ($pullsUrl) {
        Write-Host "   Pull requests: $pullsUrl"
    }
    if ($alertsUrl) {
        Write-Host "   Code scanning alerts: $alertsUrl"
    }
    if ($assignedAlertUrl) {
        Write-Host "   Assigned to Copilot: $assignedAlertUrl"
    }
    if ($pagesUrl) {
        Write-Host "   Game (GitHub Pages): $pagesUrl"
    }
    if ($projectUrl) {
        Write-Host "   Project: $projectUrl"
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
    if ($alertsUrl) { Open-Url $alertsUrl }
    if ($pullsUrl) { Open-Url $pullsUrl }
    if ($projectUrl) { Open-Url $projectUrl }

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
