#Requires -Version 5.1

# Standalone integration tests: no Pester, network calls, or real repositories.
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path $PSScriptRoot -Parent
$testRoot = Microsoft.PowerShell.Management\Join-Path ([IO.Path]::GetTempPath()) ("setup tests " + [guid]::NewGuid())
$fixtureRoot = Microsoft.PowerShell.Management\Join-Path $testRoot 'script'
$homeRepos = Microsoft.PowerShell.Management\Join-Path $testRoot 'repos'
$originalLocation = Get-Location
$testState = [pscustomobject]@{
    Answers = $null; Calls = $null; NeedsLogin = $false; Failure = $null
    NextPr = 1; StackNumbers = @(); StackMismatch = $false; GitEmail = $null; ReviewApiFailure = $false
    CleanupRepos = @(); NpmCalls = $null; PagesDisabled = $false; Opened = $null
}
Remove-Item Env:DEMO_NO_BROWSER -ErrorAction SilentlyContinue

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

# Redirect the permanent clone into the fixture without changing the user's HOME.
function Join-Path {
    param([string]$Path, [string]$ChildPath)
    if ($Path -eq $HOME -and $ChildPath -eq 'repos') {
        return $homeRepos
    }
    Microsoft.PowerShell.Management\Join-Path $Path $ChildPath
}

function Read-Host {
    param([string]$Prompt)
    $testState.Answers.Dequeue()
}

function Start-Sleep {
    param([int]$Seconds)
}

function Start-Process {
    param([string]$FilePath)
    $testState.Opened.Add($FilePath)
}

function npm {
    $testState.NpmCalls.Add([pscustomobject]@{ Arguments = @($args); Location = (Get-Location).Path })
    $global:LASTEXITCODE = 0
}

function gh {
    $arguments = @($args)
    $testState.Calls.Add([pscustomobject]@{ Command = 'gh'; Arguments = $arguments; Location = (Get-Location).Path })
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'auth' -and $arguments[1] -eq 'status' -and $testState.NeedsLogin) {
        $global:LASTEXITCODE = 1
        return
    }
    if ($testState.Failure -and ($arguments[0..1] -join ' ') -eq $testState.Failure) {
        $global:LASTEXITCODE = 42
        return
    }
    if ($arguments[0] -eq 'api' -and ($arguments -join ' ') -like '*/pages*') {
        if ($testState.PagesDisabled) { $global:LASTEXITCODE = 1; return }
        if ($arguments -contains '.html_url') { return 'https://demo-user.github.io/booth-bingo-test/' }
        return
    }
    if ($arguments[0] -eq 'run' -and $arguments[1] -eq 'list') {
        return @('completed', 'success')
    }
    if ($arguments[0] -eq 'api' -and $arguments[1] -eq 'user') {
        return 'demo-user'
    }
    if ($arguments[0] -eq 'api' -and $arguments[1] -eq '--paginate') {
        return @($testState.CleanupRepos | ForEach-Object { $_ | ConvertTo-Json -Compress })
    }
    if ($arguments[0] -eq 'api' -and $arguments[-1] -eq '.default_branch') {
        return 'trunk'
    }
    if ($arguments[0] -eq 'pr' -and $arguments[1] -eq 'create') {
        $repo = $arguments[[array]::IndexOf($arguments, '--repo') + 1]
        $number = $testState.NextPr
        $testState.NextPr++
        return "https://github.com/$repo/pull/$number"
    }
    if ($arguments[0] -eq 'api' -and $arguments[1] -eq '--method' -and $arguments[3] -like '*/requested_reviewers') {
        if ($testState.ReviewApiFailure) { $global:LASTEXITCODE = 1 }
        return
    }
    if ($arguments[0] -eq 'api' -and $arguments[1] -eq '--method' -and $arguments[3] -like '*/stacks') {
        $testState.StackNumbers = @($arguments | Where-Object { $_ -like 'pull_requests`[`]=*' } |
            ForEach-Object { ($_ -split '=')[1] })
        return
    }
    if ($arguments[0] -eq 'api' -and $arguments[1] -like '*/stacks?pull_request=*') {
        if ($testState.StackMismatch) { return @('99') }
        return $testState.StackNumbers
    }
    if ($arguments[0] -eq 'repo' -and $arguments[1] -eq 'clone') {
        $clonePath = $arguments[3]
        New-Item -ItemType Directory -Path (Join-Path $clonePath 'api/src') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $clonePath 'api/src/existing.txt') -Value 'preserve me'
        if ($clonePath.StartsWith($homeRepos)) {
            Set-Content -LiteralPath (Join-Path $clonePath 'package.json') -Value '{"scripts":{"start":"x","layer":"y"}}'
        }
    }
}

function git {
    $arguments = @($args)
    $testState.Calls.Add([pscustomobject]@{ Command = 'git'; Arguments = $arguments; Location = (Get-Location).Path })
    $global:LASTEXITCODE = 0
    if ($testState.Failure -eq "git $($arguments[0])") {
        $global:LASTEXITCODE = 42
        return
    }
    if ($arguments[0] -eq 'config' -and $arguments.Count -eq 2) {
        if ($testState.GitEmail) { return $testState.GitEmail }
        $global:LASTEXITCODE = 1
        return
    }
    if ($arguments[0] -eq 'commit') {
        Assert (Test-Path -LiteralPath './api/src/existing.txt') 'Copying resources removed an existing file.'
        Assert (-not (Test-Path -LiteralPath './pr-body.md')) 'PR body would be committed.'
        Assert (-not (Test-Path -LiteralPath './metadata/body.md')) 'Nested PR body would be committed.'
        Assert (-not (Test-Path -LiteralPath './ANSWER_KEY.md')) 'Presenter answer key would be committed.'
        switch ($arguments[2]) {
            'feat: Adds terms of services download' {
                Assert (Test-Path -LiteralPath './api/src/routes/legal.ts') 'TypeScript resources were not copied.'
                Assert (Test-Path -LiteralPath './api/documents/legal/en/terms_v2.1.pdf') 'Binary resources were not copied.'
            }
            'feat: add checkWin game logic with tests' {
                Assert (Test-Path -LiteralPath './src/bingo.js') 'Stack layer 1 resources were not copied.'
                Assert (Test-Path -LiteralPath './tests/bingo.test.js') 'Stack layer 1 tests were not copied.'
            }
            'feat: highlight the winning line on the card' {
                Assert ((Get-Content -LiteralPath './app.js' -Raw).Contains('checkWin')) 'Stack layer 2 resources were not copied.'
                Assert (Test-Path -LiteralPath './src/bingo.js') 'Stack layer 2 lost layer 1 files.'
            }
            'feat: add BINGO banner, confetti, and reset' {
                Assert ((Get-Content -LiteralPath './index.html' -Raw).Contains('banner')) 'Stack layer 3 resources were not copied.'
            }
            'feat: support stacking promo codes and sale pricing' {
                Assert ((Get-Content -LiteralPath './api/src/lib/pricing.ts' -Raw).Contains('applyPromoCodes')) 'Promo code overlay was not copied.'
            }
            'feat: add order history page with CSV export' {
                Assert (Test-Path -LiteralPath './web/src/components/OrderHistory.tsx') 'Order export overlay was not copied.'
            }
            'feat: add a wishlist' {
                Assert (Test-Path -LiteralPath './api/src/routes/wishlist.ts') 'Wishlist overlay was not copied.'
                Assert (Test-Path -LiteralPath './web/src/components/Wishlist.tsx') 'Wishlist component was not copied.'
            }
            default {
                Assert (Test-Path -LiteralPath './php/src/Controllers/NoteController.php') 'PHP resources were not copied.'
            }
        }
    }
}

function Find-Calls {
    param([string]$Command, [string]$Prefix)
    @($testState.Calls | Where-Object {
        $_.Command -eq $Command -and ($_.Arguments -join ' ').StartsWith($Prefix)
    })
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'create-repo.ps1') -Destination $fixtureRoot
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'resources') -Destination $fixtureRoot -Recurse
    $scriptPath = Join-Path $fixtureRoot 'create-repo.ps1'
    $configPath = Join-Path $fixtureRoot 'config.json'
    $originalConfig = Get-Content -LiteralPath (Join-Path $sourceRoot 'config.json') -Raw
    $branchRepo = [pscustomobject]@{
        key = 'branch-demo'; template = 'branch-template'; repo_base_name = 'branch-demo'
        repo_description = 'Branch demo'; workflow = 'branch_and_codespace'; branch_name = 'feature/demo'
    }

    foreach ($scenario in @(
        'repo-only', 'security-prs', 'issue-codespace', 'branch-codespace',
        'login', 'invalid-selection', 'no-machine', 'nested-body',
        'missing-template', 'missing-body', 'empty-prs', 'unknown-workflow',
        'outside-body', 'invalid-json', 'missing-org', 'empty-repos',
        'create-failure', 'topic-failure', 'push-failure', 'login-failure',
        'stacked-prs', 'stack-one-layer', 'stack-missing-field', 'stack-api-failure', 'stack-verify-mismatch',
        'non-interactive', 'unknown-template', 'non-interactive-login', 'no-clone-branch',
        'owner-override', 'serve', 'serve-no-clone', 'pages-failure', 'bad-visibility', 'dry-run-without-cleanup', 'cleanup-with-template',
        'cleanup', 'cleanup-dry-run', 'cleanup-cancel', 'cleanup-org',
        'cleanup-all', 'cleanup-all-with-age',
        'code-review-prs', 'code-review-fallback', 'code-review-unsupported', 'code-review-no-clone'
    )) {
        $config = $originalConfig | ConvertFrom-Json
        $config.repos += $branchRepo
        $selection = '1'
        $scriptArgs = @{}
        $testState.NeedsLogin = $false
        $testState.Failure = $null
        $testState.NextPr = 1
        $testState.StackNumbers = @()
        $testState.StackMismatch = $false
        $testState.GitEmail = $null
        $testState.ReviewApiFailure = $false
        $testState.PagesDisabled = $false
        $testState.Opened = New-Object 'System.Collections.Generic.List[string]'
        $testState.NpmCalls = New-Object 'System.Collections.Generic.List[object]'
        $old = '2020-01-01T00:00:00Z'
        $fresh = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $testState.CleanupRepos = @(
            [pscustomobject]@{ full_name = 'demo-user/old-demo'; created_at = $old; topics = @('demo-generated'); owner = 'demo-user' }
            [pscustomobject]@{ full_name = 'demo-user/fresh-demo'; created_at = $fresh; topics = @('demo-generated'); owner = 'demo-user' }
            [pscustomobject]@{ full_name = 'demo-user/old-personal'; created_at = $old; topics = @('other'); owner = 'demo-user' }
            [pscustomobject]@{ full_name = 'someone/old-demo'; created_at = $old; topics = @('demo-generated'); owner = 'someone' }
        )
        $expectedFailure = $null
        switch ($scenario) {
            'security-prs' { $selection = '2' }
            'issue-codespace' { $selection = '3' }
            'branch-codespace' { $selection = '7' }
            'code-review-prs' { $selection = '6' }
            'code-review-fallback' { $selection = '6'; $testState.Failure = 'pr edit' }
            'code-review-unsupported' { $selection = '6'; $testState.Failure = 'pr edit'; $testState.ReviewApiFailure = $true }
            'code-review-no-clone' { $selection = $null; $scriptArgs = @{ Template = 'octocart'; NoClone = $true } }
            'login' { $testState.NeedsLogin = $true }
            'no-machine' { $selection = '3'; $config.codespace_machine = $null }
            'nested-body' {
                $selection = '2'
                $resourcePath = Join-Path $fixtureRoot $config.repos[1].prs[0].resource_dir
                New-Item -ItemType Directory -Path (Join-Path $resourcePath 'metadata') -Force | Out-Null
                Move-Item -LiteralPath (Join-Path $resourcePath 'pr-body.md') -Destination (Join-Path $resourcePath 'metadata/body.md')
                $config.repos[1].prs[0].body_file = $config.repos[1].prs[0].resource_dir + '/metadata/body.md'
            }
            'missing-template' { $config.repos[0].template = ''; $expectedFailure = 'missing required config' }
            'missing-body' { $selection = '3'; $config.repos[2].issue.body_file = 'absent.md'; $expectedFailure = 'not found' }
            'empty-prs' { $selection = '2'; $config.repos[1].prs = @(); $expectedFailure = 'prs[]' }
            'unknown-workflow' { $config.repos[0].workflow = 'unknown'; $expectedFailure = 'Unknown workflow' }
            'outside-body' {
                $selection = '2'
                $config.repos[1].prs[0].body_file = 'resources/tailspin-toys/issue-body.md'
                $expectedFailure = 'must be inside'
            }
            'invalid-json' { $expectedFailure = 'Unable to read config JSON' }
            'missing-org' { $config.org = ''; $expectedFailure = "top-level 'org'" }
            'empty-repos' { $config.repos = @(); $expectedFailure = 'no repos' }
            'create-failure' { $testState.Failure = 'repo create'; $expectedFailure = 'exit code 42' }
            'topic-failure' { $selection = '5'; $testState.Failure = 'repo edit'; $expectedFailure = 'cleanup would never find it' }
            'push-failure' { $selection = '2'; $testState.Failure = 'git push'; $expectedFailure = 'exit code 42' }
            'login-failure' { $testState.NeedsLogin = $true; $testState.Failure = 'auth login'; $expectedFailure = 'exit code 42' }
            'stacked-prs' { $selection = '5' }
            'stack-one-layer' {
                $selection = '5'
                $config.repos[4].stack = @($config.repos[4].stack[0])
                $expectedFailure = 'at least 2'
            }
            'stack-missing-field' {
                $selection = '5'
                $config.repos[4].stack[1].title = ''
                $expectedFailure = 'stack[1].title'
            }
            'stack-api-failure' { $selection = '5'; $testState.Failure = 'api --method'; $expectedFailure = 'Failed to register the native stack' }
            'stack-verify-mismatch' { $selection = '5'; $testState.StackMismatch = $true; $expectedFailure = 'Stack verification failed' }
            'non-interactive' {
                $selection = $null
                $scriptArgs = @{ Template = 'booth-bingo'; NoClone = $true }
                $testState.GitEmail = 'booth@example.com'
            }
            'unknown-template' { $selection = $null; $scriptArgs = @{ Template = 'nope' }; $expectedFailure = 'Unknown template key: nope' }
            'non-interactive-login' {
                $selection = $null
                $scriptArgs = @{ Template = 'booth-bingo' }
                $testState.NeedsLogin = $true
                $expectedFailure = 'Not authenticated'
            }
            'owner-override' { $selection = $null; $scriptArgs = @{ Template = 'booth-bingo'; NoClone = $true; Owner = 'other-org' } }
            'serve' { $selection = $null; $scriptArgs = @{ Template = 'booth-bingo'; Serve = $true } }
            'pages-failure' { $selection = '5'; $testState.PagesDisabled = $true }
            'bad-visibility' { $selection = '5'; $config.repos[4].visibility = 'secret'; $expectedFailure = "Invalid visibility 'secret'" }
            'serve-no-clone' {
                $selection = $null
                $scriptArgs = @{ Template = 'booth-bingo'; Serve = $true; NoClone = $true }
                $expectedFailure = 'cannot be combined with -NoClone'
            }
            'dry-run-without-cleanup' { $selection = $null; $scriptArgs = @{ DryRun = $true }; $expectedFailure = 'only apply to -Cleanup' }
            'cleanup-all' { $selection = $null; $scriptArgs = @{ Cleanup = $true; Yes = $true; All = $true } }
            'cleanup-all-with-age' {
                $selection = $null
                $scriptArgs = @{ Cleanup = $true; All = $true; OlderThanHours = 5 }
                $expectedFailure = '-All cannot be combined'
            }
            'cleanup-with-template' {
                $selection = $null
                $scriptArgs = @{ Cleanup = $true; Template = 'booth-bingo' }
                $expectedFailure = '-Cleanup cannot be combined'
            }
            'cleanup' { $selection = $null; $scriptArgs = @{ Cleanup = $true; Yes = $true } }
            'cleanup-dry-run' { $selection = $null; $scriptArgs = @{ Cleanup = $true; DryRun = $true } }
            'cleanup-cancel' { $selection = 'n'; $scriptArgs = @{ Cleanup = $true } }
            'cleanup-org' {
                $selection = $null
                $scriptArgs = @{ Cleanup = $true; Yes = $true; Owner = 'someone'; OlderThanHours = 1 }
            }
            'no-clone-branch' {
                $selection = $null
                $scriptArgs = @{ Template = 'branch-demo'; NoClone = $true }
                $expectedFailure = 'not supported'
            }
        }
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath
        if ($scenario -eq 'invalid-json') { Set-Content -LiteralPath $configPath -Value '{' }
        $testState.Answers = New-Object 'System.Collections.Generic.Queue[string]'
        if ($scenario -eq 'invalid-selection') {
            foreach ($answer in @('text', '0', '999999999999999999999', '8', '1')) { $testState.Answers.Enqueue($answer) }
        }
        elseif ($selection) { $testState.Answers.Enqueue($selection) }
        $testState.Calls = New-Object 'System.Collections.Generic.List[object]'
        $caught = $null
        try { & $scriptPath @scriptArgs }
        catch { $caught = $_.Exception.Message }

        Assert ((Get-Location).Path -eq $originalLocation.Path) "$scenario did not restore location."
        if ($expectedFailure) {
            Assert ($null -ne $caught -and $caught.Contains($expectedFailure)) "$scenario expected '$expectedFailure', got '$caught'."
            if ($scenario -notin @('create-failure', 'topic-failure', 'push-failure', 'login-failure', 'stack-api-failure', 'stack-verify-mismatch', 'non-interactive-login')) {
                Assert ($testState.Calls.Count -eq 0) "$scenario invoked a remote command before validation."
            }
            if ($scenario -eq 'non-interactive-login') {
                Assert ((Find-Calls 'gh' 'auth login').Count -eq 0) 'Non-interactive mode started gh auth login.'
                Assert ((Find-Calls 'gh' 'repo create').Count -eq 0) 'Created a repo without authentication.'
            }
            if ($scenario -in @('stack-api-failure', 'stack-verify-mismatch')) {
                Assert ((Find-Calls 'gh' 'pr create').Count -eq 3) 'Dependent PR chain was not created before stack registration.'
            }
            if ($scenario -eq 'push-failure') {
                Assert ((Find-Calls 'gh' 'pr create').Count -eq 0) 'Created a PR after push failed.'
            }
            if ($scenario -eq 'topic-failure') {
                Assert ((Find-Calls 'gh' 'repo edit').Count -eq 3) 'Tagging was not retried.'
                $deleted = @((Find-Calls 'gh' 'repo delete') | ForEach-Object { $_.Arguments[2] })
                $created = @(Find-Calls 'gh' 'repo create')[0].Arguments[2]
                Assert (($deleted -join ',') -eq $created) "Untagged repo was not deleted (deleted '$($deleted -join ',')')."
                Assert ((Find-Calls 'gh' 'repo clone').Count -eq 0) 'Cloned an untagged repository.'
            }
            if ($scenario -eq 'create-failure') {
                Assert ((Find-Calls 'gh' 'repo clone').Count -eq 0) 'Cloned after repository creation failed.'
            }
        }
        elseif ($scenario -like 'cleanup*') {
            Assert ($null -eq $caught) "$scenario failed: $caught"
            Assert ((Find-Calls 'gh' 'repo create').Count -eq 0) 'Cleanup created a repository.'
            $list = @(Find-Calls 'gh' 'api --paginate')
            Assert ($list.Count -eq 1) 'Cleanup did not list repositories.'
            $deleted = @((Find-Calls 'gh' 'repo delete') | ForEach-Object { $_.Arguments[2] })
            switch ($scenario) {
                'cleanup' {
                    Assert ($list[0].Arguments[2] -like 'user/repos*') 'Own account should use user/repos.'
                    Assert (($deleted -join ',') -eq 'demo-user/old-demo') "Deleted '$($deleted -join ',')'."
                }
                'cleanup-all' {
                    Assert (($deleted -join ',') -eq 'demo-user/old-demo,demo-user/fresh-demo') "Deleted '$($deleted -join ',')'."
                }
                'cleanup-org' {
                    Assert ($list[0].Arguments[2] -like 'orgs/someone/repos*') 'Other owner should use orgs/<owner>/repos.'
                    Assert (($deleted -join ',') -eq 'someone/old-demo') "Deleted '$($deleted -join ',')'."
                }
                default { Assert ($deleted.Count -eq 0) "$scenario deleted '$($deleted -join ',')'." }
            }
            Assert ($testState.Answers.Count -eq 0) "$scenario did not consume the expected input."
        }
        else {
            Assert ($null -eq $caught) "$scenario failed: $caught"
            $create = @(Find-Calls 'gh' 'repo create')[0]
            $expectedOwner = switch ($scenario) {
                'security-prs' { 'octobooth-demos' }
                'nested-body' { 'octobooth-demos' }
                'owner-override' { 'other-org' }
                default { 'demo-user' }
            }
            Assert ($create.Arguments[2] -match "^$expectedOwner/[a-z-]+-[a-z0-9]{4}$") "Invalid repository name '$($create.Arguments[2])'."
            $isBingo = $create.Arguments[2] -like '*/booth-bingo-*'
            $expectedVisibility = if ($isBingo) { '--public' } else { '--private' }
            Assert ($create.Arguments -contains $expectedVisibility) "Repository was not created with $expectedVisibility."
            $pagesPost = @(Find-Calls 'gh' 'api --method POST repos/').Where({ $_.Arguments[3] -like '*/pages' })
            $deploy = @(Find-Calls 'gh' 'workflow run pages.yml')
            if ($isBingo -and $scenario -ne 'pages-failure') {
                Assert ($pagesPost.Count -eq 1 -and ($pagesPost[0].Arguments -join ' ').Contains('-f build_type=workflow')) 'Pages was not enabled for workflow builds.'
                Assert ($deploy.Count -eq 1 -and ($deploy[0].Arguments -join ' ').Contains('--ref trunk')) 'Pages deploy was not started on the default branch.'
                Assert ((Find-Calls 'gh' 'run list').Count -ge 1) 'Did not wait for the Pages deploy.'
                $expectedOpened = "https://github.com/$($create.Arguments[2])/pull/3,https://demo-user.github.io/booth-bingo-test/"
                Assert (($testState.Opened -join ',') -eq $expectedOpened) "Opened '$($testState.Opened -join ',')' (want PR, then game)."
            }
            elseif ($scenario -eq 'pages-failure') {
                Assert ($deploy.Count -eq 0) 'Started a Pages deploy without Pages.'
                Assert ($testState.Opened.Count -eq 0) 'Opened a browser without a Pages site.'
            }
            else {
                Assert ($pagesPost.Count -eq 0 -and $deploy.Count -eq 0) "$scenario touched GitHub Pages."
            }
            $topic = @(Find-Calls 'gh' 'repo edit')[0]
            Assert ($null -ne $topic -and $topic.Arguments -contains 'demo-generated') 'demo-generated topic was not added.'
            if ($selection -eq '1') {
                Assert ($create.Arguments -contains '--template=github-samples/securing-your-code') 'Template org override was ignored.'
            }
            else {
                Assert (($create.Arguments -join ' ').Contains('--template=octobooth-demos/')) 'Template org fallback was ignored.'
            }
            if ($selection -eq '2') {
                Assert ((Find-Calls 'gh' 'pr create').Count -eq 2) 'Expected two PRs.'
                Assert ((Find-Calls 'gh' 'api repos/').Count -eq 5) 'Expected readiness checks and three security API calls.'
                foreach ($prCall in (Find-Calls 'gh' 'pr create')) {
                    Assert ($prCall.Arguments -contains 'trunk') 'PR did not use the default branch.'
                }
            }
            if ($scenario -eq 'serve') {
                Assert ($testState.NpmCalls.Count -eq 1) 'Serve did not start npm.'
                Assert (($testState.NpmCalls[0].Arguments -join ' ') -eq 'start -- --open') 'Serve ran the wrong npm command.'
                Assert ($testState.NpmCalls[0].Location.StartsWith($homeRepos)) 'Serve did not run in the local clone.'
                Assert ((Find-Calls 'git' 'checkout --quiet trunk').Count -eq 1) 'Serve did not check out the default branch.'
            }
            elseif ($testState.NpmCalls.Count -ne 0) { throw "$scenario ran npm without -Serve." }
            if ($scenario -in @('stacked-prs', 'non-interactive')) {
                $prCalls = @(Find-Calls 'gh' 'pr create')
                Assert ($prCalls.Count -eq 3) 'Expected three stacked PRs.'
                $expectedChain = @(
                    @('bingo/1-game-logic', 'trunk'),
                    @('bingo/2-wire-ui', 'bingo/1-game-logic'),
                    @('bingo/3-celebration', 'bingo/2-wire-ui')
                )
                for ($i = 0; $i -lt 3; $i++) {
                    $a = $prCalls[$i].Arguments
                    $head = $a[[array]::IndexOf($a, '--head') + 1]
                    $base = $a[[array]::IndexOf($a, '--base') + 1]
                    Assert ($head -eq $expectedChain[$i][0]) "Layer $($i + 1) head was '$head'."
                    Assert ($base -eq $expectedChain[$i][1]) "Layer $($i + 1) base was '$base'."
                    $checkout = @(Find-Calls 'git' "checkout --quiet -b $($expectedChain[$i][0]) $($expectedChain[$i][1])")
                    Assert ($checkout.Count -eq 1) "Layer $($i + 1) was not branched from the layer below."
                }
                $stackCalls = @(Find-Calls 'gh' 'api --method POST repos/').Where({ $_.Arguments[3] -like '*/stacks' })
                Assert ($stackCalls.Count -eq 1) 'Expected one stack registration.'
                Assert ($stackCalls[0].Arguments[3] -match '^repos/demo-user/booth-bingo-[a-z0-9]{4}/stacks$') 'Wrong stacks endpoint.'
                $numbers = @($stackCalls[0].Arguments | Where-Object { $_ -like 'pull_requests`[`]=*' })
                Assert (($numbers -join ',') -eq 'pull_requests[]=1,pull_requests[]=2,pull_requests[]=3') "Stack order was '$($numbers -join ',')'."
                Assert ((Find-Calls 'gh' 'api repos/').Where({ $_.Arguments[1] -like '*/stacks?pull_request=1' }).Count -ge 1) 'Stack was not verified.'
            }
            if ($scenario -eq 'stacked-prs') {
                $identity = @(Find-Calls 'git' 'config user.email demo-user+demo-user@users.noreply.github.com')
                Assert ($identity.Count -eq 1) 'Missing git identity was not filled in.'
            }
            if ($scenario -eq 'non-interactive') {
                Assert ((Find-Calls 'git' 'config user.name').Count -eq 0) 'Overwrote an existing git identity.'
                Assert ($testState.Answers.Count -eq 0) 'Non-interactive mode consumed input.'
                foreach ($clone in (Find-Calls 'gh' 'repo clone')) {
                    Assert (-not $clone.Arguments[3].StartsWith($homeRepos)) '-NoClone still cloned into ~/repos.'
                }
            }
            if ($selection -in @('3', '7')) {
                $codespace = @(Find-Calls 'gh' 'codespace create')[0]
                Assert (($codespace.Arguments -contains '--machine') -eq ($scenario -ne 'no-machine')) 'Wrong machine arguments.'
                Assert (($codespace.Arguments -contains '--branch') -eq ($selection -eq '7')) 'Wrong branch arguments.'
            }
            if ($selection -eq '3') {
                $issue = @(Find-Calls 'gh' 'issue create')[0]
                Assert ($issue.Arguments -contains '@copilot') 'Issue assignee was not preserved.'
            }
            if ($selection -eq '7') {
                Assert ((Find-Calls 'git' 'checkout trunk').Count -eq 1) 'Branch workflow did not checkout default branch.'
                Assert ((Find-Calls 'git' 'push -u origin feature/demo').Count -eq 1) 'Branch was not pushed.'
            }
            if ($scenario -like 'code-review-*') {
                $fullName = $create.Arguments[2]
                Assert ($fullName -like 'demo-user/octocart-*') "Code review demo created '$fullName'."
                $prCalls = @(Find-Calls 'gh' 'pr create')
                Assert ($prCalls.Count -eq 3) 'Expected three code review PRs.'
                $heads = @($prCalls | ForEach-Object { $_.Arguments[[array]::IndexOf($_.Arguments, '--head') + 1] })
                Assert (($heads -join ',') -eq 'feature/stackable-promo-codes,feature/order-history-export,feature/wishlist') "PR heads were '$($heads -join ',')'."
                foreach ($prCall in $prCalls) {
                    Assert ($prCall.Arguments -contains 'trunk') 'Code review PR did not target the default branch.'
                }
                $edits = @(Find-Calls 'gh' 'pr edit')
                Assert ($edits.Count -eq 3) 'Expected a Copilot review request per PR.'
                for ($i = 0; $i -lt 3; $i++) {
                    $expected = "pr edit $($i + 1) --repo $fullName --add-reviewer @copilot"
                    Assert (($edits[$i].Arguments -join ' ') -eq $expected) "Review request was '$($edits[$i].Arguments -join ' ')'."
                }
                $rest = @(Find-Calls 'gh' 'api --method POST').Where({ $_.Arguments[3] -like '*/requested_reviewers' })
                if ($scenario -eq 'code-review-prs' -or $scenario -eq 'code-review-no-clone') {
                    Assert ($rest.Count -eq 0) 'Used the REST fallback although gh pr edit succeeded.'
                }
                else {
                    Assert ($rest.Count -eq 3) 'REST fallback was not used for every PR.'
                    Assert ($rest[0].Arguments[3] -eq "repos/$fullName/pulls/1/requested_reviewers") "Wrong fallback endpoint '$($rest[0].Arguments[3])'."
                    Assert ($rest[0].Arguments -contains 'reviewers[]=copilot-pull-request-reviewer[bot]') 'Fallback did not request the Copilot reviewer bot.'
                }
                Assert ((Find-Calls 'gh' 'api repos/').Where({ $_.Arguments -contains 'PUT' }).Count -eq 0) 'Code review demo enabled security features.'
                $fetch = @(Find-Calls 'git' '-C').Where({ ($_.Arguments -join ' ').Contains('fetch --quiet origin') })
                if ($scenario -eq 'code-review-no-clone') {
                    Assert ($fetch.Count -eq 0) 'Fetched PR branches without a local clone.'
                }
                else {
                    Assert ($fetch.Count -eq 1 -and $fetch[0].Arguments[1].StartsWith($homeRepos)) 'PR branches were not fetched into the local clone.'
                }
                Assert ($testState.Opened -contains "https://github.com/$fullName/pulls") 'Pull request list was not opened.'
            }
            if ($scenario -eq 'login') {
                Assert ((Find-Calls 'gh' 'auth login').Count -eq 1) 'Authentication failure did not trigger login.'
            }
        }
        foreach ($clone in (Find-Calls 'gh' 'repo clone')) {
            if (-not $clone.Arguments[3].StartsWith($homeRepos)) {
                Assert (-not (Test-Path -LiteralPath (Split-Path $clone.Arguments[3] -Parent))) 'Temporary clone was not cleaned up.'
            }
        }
        if ($scenario -eq 'nested-body') {
            Move-Item -LiteralPath (Join-Path $resourcePath 'metadata/body.md') -Destination (Join-Path $resourcePath 'pr-body.md')
            Remove-Item -LiteralPath (Join-Path $resourcePath 'metadata') -Force
        }
        Write-Host "PASS: $scenario"
    }
}
finally {
    Set-Location -LiteralPath $originalLocation.Path
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
