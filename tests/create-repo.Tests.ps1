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
    CodeqlConclusion = 'success'; AssignFailure = $false; AutofixBotMissing = $false; AnalysesCount = '2'; LateRulePolls = 0
    StalePushRun = $false; GitCredentialUser = $null
}
Remove-Item Env:DEMO_NO_BROWSER -ErrorAction SilentlyContinue
# Behave the same locally and in CI: the script skips browsers under Actions and
# would append test outputs to the runner's real step output file.
Remove-Item Env:GITHUB_ACTIONS, Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue

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
    $jsonIndex = [array]::IndexOf($arguments, '--json')
    if ($jsonIndex -ge 0 -and $arguments[$jsonIndex + 1] -isnot [string]) {
        # PowerShell splits an unquoted comma list into separate native args, which gh rejects.
        $global:LASTEXITCODE = 1
        return
    }
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
        if ($arguments -contains 'databaseId') {
            # An older failed push run on the same commit, visible before the dispatched run.
            if ($testState.StalePushRun -and ($arguments -join ' ') -notlike '*--event workflow_dispatch*') { return '999' }
            return '123'
        }
        return @('completed', 'success')
    }
    if ($arguments[0] -eq 'run' -and $arguments[1] -eq 'view') {
        if ($arguments[2] -eq '999') { return @('completed', 'failure') }
        return @('completed', $testState.CodeqlConclusion)
    }
    if ($arguments[0] -eq 'api' -and $arguments[1] -like '*/code-scanning/analyses?*') {
        return $testState.AnalysesCount
    }
    if ($arguments[0] -eq 'api' -and $arguments[1] -like '*/code-scanning/alerts?*') {
        if ($testState.LateRulePolls -gt 0) {
            $testState.LateRulePolls--
            return '[{"number":1,"rule":{"id":"actions/missing-workflow-permissions"}}]'
        }
        return '[{"number":3,"rule":{"id":"js/path-injection"}},{"number":4,"rule":{"id":"js/sql-injection"}}]'
    }
    if ($arguments[0] -eq 'api' -and $arguments[1] -eq '--method' -and $arguments[3] -like '*/code-scanning/alerts/*') {
        $assignee = (@($arguments | Where-Object { $_ -like 'assignees`[`]=*' })[0] -split '=', 2)[1]
        if ($testState.AssignFailure) { $global:LASTEXITCODE = 1; return }
        if ($testState.AutofixBotMissing -and $assignee -eq 'github-agentic-autofix[bot]') { $global:LASTEXITCODE = 1; return }
        return $assignee
    }
    if ($arguments[0] -eq 'api' -and $arguments[1] -eq 'user') {
        if ($env:GH_TOKEN -eq 'git-helper-token') { return $testState.GitCredentialUser }
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
    if (($arguments -join ' ') -like '*credential fill') {
        if (-not $testState.GitCredentialUser) { $global:LASTEXITCODE = 1; return }
        return @('protocol=https', 'host=github.com', 'username=x-access-token', 'password=git-helper-token')
    }
    if ($arguments[0] -eq 'rev-parse') {
        return 'abc1234'
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
                Assert ((Get-Content -LiteralPath './api/package.json' -Raw).Contains('ua-parser-js')) 'TypeScript dependency change was not copied.'
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
            'feat: add product reviews' {
                Assert (Test-Path -LiteralPath './api/src/routes/reviews.ts') 'Product reviews overlay was not copied.'
                Assert (Test-Path -LiteralPath './web/src/components/ProductReviews.tsx') 'Product reviews component was not copied.'
            }
            'feat: add supplier portal document center' {
                Assert (Test-Path -LiteralPath './api/src/routes/supplierPortal.ts') 'AI Security seed was not copied.'
            }
            'feat: containerize the supplier portal and deploy it to staging' {
                Assert (Test-Path -LiteralPath './php/Dockerfile') 'AI Scan PR Dockerfile was not copied.'
                Assert (Test-Path -LiteralPath './scripts/deploy-staging.sh') 'AI Scan PR shell script was not copied.'
                Assert (Test-Path -LiteralPath './infra/terraform/main.tf') 'AI Scan PR Terraform was not copied.'
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

    # Every PR/issue resource referenced by the real config must exist.
    foreach ($repo in ($originalConfig | ConvertFrom-Json).repos) {
        $paths = @($repo.prs | Where-Object { $_ } | ForEach-Object { $_.resource_dir; $_.body_file })
        $paths += @($repo.stack | Where-Object { $_ } | ForEach-Object { $_.resource_dir; $_.body_file })
        if ($repo.issue) { $paths += $repo.issue.body_file }
        if ($repo.seed_prompt_file) { $paths += $repo.seed_prompt_file }
        $paths += @($repo.seed_prompts | Where-Object { $_ } | ForEach-Object { $_.file })
        foreach ($path in ($paths | Where-Object { $_ })) {
            Assert (Test-Path -LiteralPath (Join-Path $sourceRoot $path)) "$($repo.key): '$path' does not exist."
        }
    }
    Write-Host 'PASS: config-resources'

    foreach ($scenario in @(
        'repo-only', 'security-prs', 'security-prs-v4', 'issue-codespace', 'branch-codespace',
        'login', 'invalid-selection', 'no-machine', 'nested-body',
        'missing-template', 'missing-body', 'empty-prs', 'unknown-workflow',
        'outside-body', 'invalid-json', 'missing-org', 'empty-repos',
        'create-failure', 'topic-failure', 'push-failure', 'login-failure',
        'git-account-match', 'git-account-mismatch', 'blank-git-account-mismatch',
        'stacked-prs', 'stack-one-layer', 'stack-missing-field', 'stack-api-failure', 'stack-verify-mismatch',
        'non-interactive', 'unknown-template', 'non-interactive-login', 'no-clone-branch',
        'owner-override', 'serve', 'serve-no-clone', 'pages-failure', 'bad-visibility', 'dry-run-without-cleanup', 'cleanup-with-template',
        'cleanup', 'cleanup-dry-run', 'cleanup-cancel', 'cleanup-org',
        'cleanup-all', 'cleanup-all-with-age',
        'code-review-prs', 'code-review-fallback', 'code-review-unsupported', 'code-review-no-clone',
        'ai-security', 'ai-security-no-clone', 'ai-security-not-enabled', 'ai-security-late-rule',
        'ai-security-assign-failure', 'ai-security-assign-fallback', 'ai-security-codeql-failure',
        'ai-security-missing-seed', 'ai-security-no-seed', 'ai-security-scan-only', 'ai-security-autofix-only',
        'ai-security-missing-prs',
        'blank', 'blank-interactive', 'blank-missing-seed', 'blank-needs-workflow',
        'routing', 'routing-missing-seed', 'routing-duplicate-label', 'routing-case-collision', 'routing-prefix-collision', 'routing-trailing-space-collision', 'routing-empty-seeds', 'routing-seed-without-file'
    )) {
        $config = $originalConfig | ConvertFrom-Json
        $config.repos += $branchRepo
        $branchSelection = [string]@($config.repos).Count
        $aiIndex = [array]::IndexOf(@($config.repos | ForEach-Object { $_.key }), 'ai-security')
        $aiSelection = [string]($aiIndex + 1)
        $blankIndex = [array]::IndexOf(@($config.repos | ForEach-Object { $_.key }), 'fusion-blank')
        $routingIndex = [array]::IndexOf(@($config.repos | ForEach-Object { $_.key }), 'fusion-routing')
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
        $testState.CodeqlConclusion = 'success'
        $testState.AssignFailure = $false
        $testState.AutofixBotMissing = $false
        $testState.AnalysesCount = '2'
        $testState.LateRulePolls = 0
        $testState.StalePushRun = $false
        $testState.GitCredentialUser = $null
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
            'security-prs-v4' { $selection = $null; $scriptArgs = @{ Template = 'security-octo-supply-v4'; NoClone = $true } }
            'issue-codespace' { $selection = '3' }
            'branch-codespace' { $selection = $branchSelection }
            'code-review-prs' { $selection = '6' }
            'code-review-fallback' { $selection = '6'; $testState.Failure = 'pr edit' }
            'code-review-unsupported' { $selection = '6'; $testState.Failure = 'pr edit'; $testState.ReviewApiFailure = $true }
            'code-review-no-clone' { $selection = $null; $scriptArgs = @{ Template = 'octocart'; NoClone = $true } }
            'ai-security' { $selection = $aiSelection }
            'ai-security-no-clone' { $selection = $null; $scriptArgs = @{ Template = 'ai-security'; NoClone = $true } }
            'ai-security-not-enabled' {
                $selection = $aiSelection
                $testState.AnalysesCount = '0'
                $config.repos[$aiIndex].PSObject.Properties.Remove('autofix')
                $config.repos[$aiIndex].PSObject.Properties.Remove('seed')
            }
            'ai-security-late-rule' { $selection = $aiSelection; $testState.LateRulePolls = 3 }
            'ai-security-assign-failure' { $selection = $aiSelection; $testState.AssignFailure = $true }
            'ai-security-assign-fallback' { $selection = $aiSelection; $testState.AutofixBotMissing = $true }
            'ai-security-codeql-failure' { $selection = $aiSelection; $testState.CodeqlConclusion = 'failure'; $expectedFailure = "CodeQL finished with 'failure'" }
            'ai-security-missing-seed' { $selection = $aiSelection; $config.repos[$aiIndex].seed.commit_message = ''; $expectedFailure = 'seed.commit_message' }
            'ai-security-no-seed' { $selection = $aiSelection; $config.repos[$aiIndex].PSObject.Properties.Remove('seed'); $testState.StalePushRun = $true }
            'ai-security-scan-only' {
                $selection = $aiSelection
                $config.repos[$aiIndex].PSObject.Properties.Remove('autofix')
                $config.repos[$aiIndex].PSObject.Properties.Remove('seed')
            }
            'ai-security-autofix-only' {
                $selection = $aiSelection
                $config.repos[$aiIndex].PSObject.Properties.Remove('prs')
                $config.repos[$aiIndex].PSObject.Properties.Remove('ai_scan')
            }
            'ai-security-missing-prs' {
                $selection = $aiSelection
                $config.repos[$aiIndex].PSObject.Properties.Remove('prs')
                $config.repos[$aiIndex].PSObject.Properties.Remove('autofix')
                $expectedFailure = 'prs[]'
            }
            'blank' { $selection = $null; $scriptArgs = @{ Template = 'fusion-blank'; NoClone = $true } }
            'blank-interactive' { $selection = [string]($blankIndex + 1) }
            'blank-missing-seed' {
                $selection = $null
                $scriptArgs = @{ Template = 'fusion-blank' }
                $config.repos[$blankIndex].seed_prompt_file = 'resources/fusion-blank/absent.txt'
                $expectedFailure = 'seed_prompt_file not found'
            }
            'blank-needs-workflow' {
                # Only the blank workflow may omit the template.
                $selection = $null
                $scriptArgs = @{ Template = 'fusion-blank' }
                $config.repos[$blankIndex].workflow = 'repo_only'
                $expectedFailure = 'missing required config'
            }
            'routing' { $selection = $null; $scriptArgs = @{ Template = 'fusion-routing'; NoClone = $true } }
            'routing-missing-seed' {
                $selection = $null
                $scriptArgs = @{ Template = 'fusion-routing' }
                $config.repos[$routingIndex].seed_prompts[2].file = 'resources/fusion-routing/absent.txt'
                $expectedFailure = 'seed_prompts file not found'
            }
            'routing-duplicate-label' {
                $selection = $null
                $scriptArgs = @{ Template = 'fusion-routing' }
                $config.repos[$routingIndex].seed_prompts[1].label = 'Single'
                $expectedFailure = 'stay unique'
            }
            'routing-case-collision' {
                # The launcher matches labels case-insensitively, so these would pick the same prompt.
                $selection = $null
                $scriptArgs = @{ Template = 'fusion-routing' }
                $config.repos[$routingIndex].seed_prompts[1].label = 'single'
                $expectedFailure = 'stay unique'
            }
            'routing-prefix-collision' {
                # The launcher keeps the first 40 characters of a label.
                $selection = $null
                $scriptArgs = @{ Template = 'fusion-routing' }
                $config.repos[$routingIndex].seed_prompts[1].label = 'Cascade ' + ('x' * 33) + ' one'
                $config.repos[$routingIndex].seed_prompts[2].label = 'Cascade ' + ('x' * 33) + ' two'
                $expectedFailure = 'stay unique'
            }
            'routing-trailing-space-collision' {
                # Cutting to 40 characters leaves a trailing space, which is trimmed again.
                $selection = $null
                $scriptArgs = @{ Template = 'fusion-routing' }
                $config.repos[$routingIndex].seed_prompts[1].label = ('A' * 39) + ' X'
                $config.repos[$routingIndex].seed_prompts[2].label = 'A' * 39
                $expectedFailure = 'stay unique'
            }
            'routing-empty-seeds' {
                $selection = $null
                $scriptArgs = @{ Template = 'fusion-routing' }
                $config.repos[$routingIndex].seed_prompts = @()
                $expectedFailure = 'non-empty list'
            }
            'routing-seed-without-file' {
                $selection = $null
                $scriptArgs = @{ Template = 'fusion-routing' }
                $config.repos[$routingIndex].seed_prompts[0].PSObject.Properties.Remove('file')
                $expectedFailure = 'non-empty list'
            }
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
            'push-failure' { $selection = '2'; $testState.Failure = 'git push'; $expectedFailure = 'different GitHub account than gh' }
            'git-account-match' { $selection = '5'; $testState.GitCredentialUser = 'demo-user' }
            'blank-git-account-mismatch' {
                $selection = $null
                $scriptArgs = @{ Template = 'fusion-blank'; NoClone = $true }
                $testState.GitCredentialUser = 'app-user'
            }
            'git-account-mismatch' {
                $selection = '5'
                $testState.GitCredentialUser = 'app-user'
                $expectedFailure = "git would push as 'app-user', but gh is logged in as 'demo-user'"
            }
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
            foreach ($answer in @('text', '0', '999999999999999999999', [string](@($config.repos).Count + 1), '1')) { $testState.Answers.Enqueue($answer) }
        }
        elseif ($selection) { $testState.Answers.Enqueue($selection) }
        $testState.Calls = New-Object 'System.Collections.Generic.List[object]'
        $caught = $null
        try { & $scriptPath @scriptArgs }
        catch { $caught = $_.Exception.Message }

        Assert ((Get-Location).Path -eq $originalLocation.Path) "$scenario did not restore location."
        if ($expectedFailure) {
            Assert ($null -ne $caught -and $caught.Contains($expectedFailure)) "$scenario expected '$expectedFailure', got '$caught'."
            if ($scenario -notin @('create-failure', 'topic-failure', 'push-failure', 'login-failure', 'git-account-mismatch', 'stack-api-failure', 'stack-verify-mismatch', 'non-interactive-login', 'ai-security-codeql-failure')) {
                Assert ($testState.Calls.Count -eq 0) "$scenario invoked a remote command before validation."
            }
            if ($scenario -eq 'non-interactive-login') {
                Assert ((Find-Calls 'gh' 'auth login').Count -eq 0) 'Non-interactive mode started gh auth login.'
                Assert ((Find-Calls 'gh' 'repo create').Count -eq 0) 'Created a repo without authentication.'
            }
            if ($scenario -in @('stack-api-failure', 'stack-verify-mismatch')) {
                Assert ((Find-Calls 'gh' 'pr create').Count -eq 3) 'Dependent PR chain was not created before stack registration.'
            }
            if ($scenario -eq 'git-account-mismatch') {
                Assert ((Find-Calls 'gh' 'repo create').Count -eq 0) 'Created a repo although git and gh use different accounts.'
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
            if ($scenario -eq 'ai-security-codeql-failure') {
                Assert ((Find-Calls 'gh' 'pr create').Count -eq 0) 'Opened the AI Scan PR although CodeQL failed.'
                Assert ((Find-Calls 'gh' 'api --method PATCH').Where({ $_.Arguments[3] -like '*/code-scanning/alerts/*' }).Count -eq 0) 'Assigned an alert although CodeQL failed.'
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
            if ($scenario -eq 'blank-git-account-mismatch') {
                Assert ((Find-Calls 'git' '-c').Count -eq 0) 'Checked the git account for a gh-only run.'
            }
            $create = @(Find-Calls 'gh' 'repo create')[0]
            $expectedOwner = switch ($scenario) {
                'security-prs' { 'octobooth-demos' }
                'security-prs-v4' { 'octobooth-demos' }
                'nested-body' { 'octobooth-demos' }
                { $_ -like 'ai-security*' } { 'octobooth-demos' }
                'owner-override' { 'other-org' }
                default { 'demo-user' }
            }
            Assert ($create.Arguments[2] -match "^$expectedOwner/[a-z0-9-]+-[a-z0-9]{4}$") "Invalid repository name '$($create.Arguments[2])'."
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
            if ($scenario -like 'blank*') {
                Assert ($create.Arguments[2] -like 'demo-user/fusion-blank-*') "Blank demo created '$($create.Arguments[2])'."
                Assert ($create.Arguments -contains '--add-readme') 'Blank repo was created without a README.'
                Assert (-not ($create.Arguments | Where-Object { $_ -like '--template*' })) 'Blank repo was created from a template.'
                Assert ((Find-Calls 'gh' 'pr create').Count -eq 0 -and (Find-Calls 'gh' 'issue create').Count -eq 0) 'Blank demo opened a PR or issue.'
                Assert ((Find-Calls 'git' 'push').Count -eq 0) 'Blank demo pushed commits.'
                $clones = @(Find-Calls 'gh' 'repo clone')
                Assert ($clones.Count -eq ([int]($scenario -eq 'blank-interactive'))) 'Blank demo clone count was wrong.'
            }
            elseif ($scenario -eq 'routing') {
                Assert ($create.Arguments[2] -like 'demo-user/fusion-routing-*') "Routing demo created '$($create.Arguments[2])'."
                Assert ($create.Arguments -contains '--template=octobooth-demos/octocart') 'Routing demo was not created from the OctoCart template.'
                Assert ((Find-Calls 'gh' 'pr create').Count -eq 0 -and (Find-Calls 'gh' 'issue create').Count -eq 0) 'Routing demo opened a PR or issue.'
                Assert ((Find-Calls 'gh' 'repo clone').Count -eq 0) 'Routing demo cloned despite -NoClone.'
            }
            elseif ($selection -eq '1') {
                Assert ($create.Arguments -contains '--template=github-samples/securing-your-code') 'Template org override was ignored.'
            }
            else {
                Assert (($create.Arguments -join ' ').Contains('--template=octobooth-demos/')) 'Template org fallback was ignored.'
            }
            if ($selection -eq '2' -or $scenario -eq 'security-prs-v4') {
                Assert ((Find-Calls 'gh' 'pr create').Count -eq 2) 'Expected two PRs.'
                Assert ((Find-Calls 'gh' 'api repos/').Count -eq 6) 'Expected readiness checks and four security API calls.'
                $disable = @(Find-Calls 'gh' 'workflow disable codeql-advanced.yml')
                Assert ($disable.Count -eq 1 -and $disable[0].Arguments -contains $create.Arguments[2]) 'codeql-advanced.yml was not disabled.'
                $firstPr = $testState.Calls.IndexOf((Find-Calls 'gh' 'pr create')[0])
                Assert ($testState.Calls.IndexOf($disable[0]) -lt $firstPr) 'codeql-advanced.yml was disabled after PRs were opened.'
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
            if ($selection -in @('3', $branchSelection)) {
                $codespace = @(Find-Calls 'gh' 'codespace create')[0]
                Assert (($codespace.Arguments -contains '--machine') -eq ($scenario -ne 'no-machine')) 'Wrong machine arguments.'
                Assert (($codespace.Arguments -contains '--branch') -eq ($selection -eq $branchSelection)) 'Wrong branch arguments.'
            }
            if ($selection -eq '3') {
                $issue = @(Find-Calls 'gh' 'issue create')[0]
                Assert ($issue.Arguments -contains '@copilot') 'Issue assignee was not preserved.'
            }
            if ($selection -eq $branchSelection) {
                Assert ((Find-Calls 'git' 'checkout trunk').Count -eq 1) 'Branch workflow did not checkout default branch.'
                Assert ((Find-Calls 'git' 'push -u origin feature/demo').Count -eq 1) 'Branch was not pushed.'
            }
            if ($scenario -like 'code-review-*') {
                $fullName = $create.Arguments[2]
                Assert ($fullName -like 'demo-user/octocart-*') "Code review demo created '$fullName'."
                $prCalls = @(Find-Calls 'gh' 'pr create')
                Assert ($prCalls.Count -eq 4) 'Expected four code review PRs.'
                $heads = @($prCalls | ForEach-Object { $_.Arguments[[array]::IndexOf($_.Arguments, '--head') + 1] })
                Assert (($heads -join ',') -eq 'feature/stackable-promo-codes,feature/order-history-export,feature/wishlist,feature/product-reviews') "PR heads were '$($heads -join ',')'."
                foreach ($prCall in $prCalls) {
                    Assert ($prCall.Arguments -contains 'trunk') 'Code review PR did not target the default branch.'
                }
                $edits = @(Find-Calls 'gh' 'pr edit')
                Assert ($edits.Count -eq 3) 'Expected a Copilot review request on each PR except the live-review one.'
                for ($i = 0; $i -lt 3; $i++) {
                    $expected = "pr edit $($i + 1) --repo $fullName --add-reviewer @copilot"
                    Assert (($edits[$i].Arguments -join ' ') -eq $expected) "Review request was '$($edits[$i].Arguments -join ' ')'."
                }
                $rest = @(Find-Calls 'gh' 'api --method POST').Where({ $_.Arguments[3] -like '*/requested_reviewers' })
                if ($scenario -eq 'code-review-prs' -or $scenario -eq 'code-review-no-clone') {
                    Assert ($rest.Count -eq 0) 'Used the REST fallback although gh pr edit succeeded.'
                }
                else {
                    Assert ($rest.Count -eq 3) 'REST fallback was not used for every review-requested PR.'
                    Assert ($rest[0].Arguments[3] -eq "repos/$fullName/pulls/1/requested_reviewers") "Wrong fallback endpoint '$($rest[0].Arguments[3])'."
                    Assert ($rest[0].Arguments -contains 'reviewers[]=copilot-pull-request-reviewer[bot]') 'Fallback did not request the Copilot reviewer bot.'
                }
                Assert (-not ($rest | Where-Object { $_.Arguments[3] -like '*/pulls/4/*' })) 'Requested a review on the live-review PR.'
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
            if ($scenario -like 'ai-security*') {
                $fullName = $create.Arguments[2]
                $hasScan = $scenario -ne 'ai-security-autofix-only'
                $hasAutofix = $scenario -notin @('ai-security-scan-only', 'ai-security-not-enabled')
                Assert ($fullName -like 'octobooth-demos/ai-security-*') "$scenario created '$fullName'."
                Assert ((Find-Calls 'gh' 'api').Where({ ($_.Arguments -join ' ').Contains('default-setup') }).Count -eq 0) 'Enabled CodeQL default setup alongside the advanced workflow.'
                Assert ((Find-Calls 'gh' 'api').Where({ $_.Arguments -contains 'PUT' }).Count -eq 0) "$scenario enabled unrelated security features."
                $ghas = @(Find-Calls 'gh' "api repos/$fullName -X PATCH")
                Assert ($ghas.Count -eq 1 -and ($ghas[0].Arguments -join ' ').Contains('advanced_security][status]=enabled')) 'Advanced Security was not enabled.'
                $aiScan = @(Find-Calls 'gh' "api --method PATCH repos/$fullName/code-scanning/ai-scan")
                $analyses = @((Find-Calls 'gh' 'api').Where({ $_.Arguments[1] -like '*/code-scanning/analyses?*' }))
                $seedPush = @(Find-Calls 'git' 'push origin trunk')
                $dispatch = @(Find-Calls 'gh' 'workflow run codeql-advanced.yml')
                $runList = @((Find-Calls 'gh' 'run list').Where({ $_.Arguments -contains 'codeql-advanced.yml' }))
                $assign = @((Find-Calls 'gh' 'api --method PATCH').Where({ $_.Arguments[3] -like '*/code-scanning/alerts/*' }))
                $prCalls = @(Find-Calls 'gh' 'pr create')
                $pull = @((Find-Calls 'git' '-C').Where({ ($_.Arguments -join ' ').Contains('pull --quiet origin trunk') }))
                Assert ($pull.Count -eq ([int]($scenario -ne 'ai-security-no-clone'))) 'Local clone was not updated (or was touched with -NoClone).'
                Assert ($testState.Opened -contains "https://github.com/$fullName/pulls") 'Pull request list was not opened.'
                if ($hasScan) {
                    Assert ($aiScan.Count -eq 1) 'AI Scan was not enabled.'
                    Assert ($aiScan[0].Arguments -contains 'X-GitHub-Api-Version: 2026-03-10' -and $aiScan[0].Arguments -contains 'pr_scan=enabled') "Wrong AI Scan call '$($aiScan[0].Arguments -join ' ')'."
                    Assert ($prCalls.Count -eq 1) 'Expected one AI Scan PR.'
                    $expectedPolls = if ($scenario -eq 'ai-security-not-enabled') { 90 } elseif ($hasAutofix) { 0 } else { 1 }
                    Assert ($analyses.Count -eq $expectedPolls) "Polled code scanning $($analyses.Count) times (want $expectedPolls)."
                    if ($analyses.Count -gt 0) {
                        Assert ($testState.Calls.IndexOf($analyses[-1]) -lt $testState.Calls.IndexOf($prCalls[0])) 'Opened the AI Scan PR before code scanning was on.'
                    }
                    $a = $prCalls[0].Arguments
                    Assert ($a[[array]::IndexOf($a, '--head') + 1] -eq 'feature/containerize-supplier-portal' -and $a[[array]::IndexOf($a, '--base') + 1] -eq 'trunk') 'AI Scan PR has the wrong head or base.'
                }
                else {
                    Assert ($aiScan.Count -eq 0) 'Changed the AI Scan setting without "ai_scan": true.'
                    Assert ($prCalls.Count -eq 0 -and $analyses.Count -eq 0) 'Opened a PR without prs[].'
                }
                if ($hasAutofix) {
                    if ($scenario -eq 'ai-security-no-seed') {
                        Assert ($seedPush.Count -eq 0) 'Pushed to the default branch without a seed.'
                        Assert ($dispatch.Count -eq 1 -and $dispatch[0].Arguments -contains 'trunk') 'CodeQL was not started on the default branch.'
                        Assert (($runList[0].Arguments -join ' ') -like '*--event workflow_dispatch*') 'CodeQL wait could pick up the earlier push run instead of the dispatched one.'
                    }
                    else {
                        Assert ($seedPush.Count -eq 1) 'Seed commit was not pushed to the default branch.'
                        Assert ($dispatch.Count -eq 0) 'Dispatched CodeQL although the seed push starts it.'
                        Assert ($runList[0].Arguments -notcontains '--event') 'Filtered the seed push run by event.'
                    }
                    Assert ($runList.Count -ge 1 -and $runList[0].Arguments -contains 'abc1234') 'Did not wait for CodeQL on the pushed commit.'
                    $expectedAssignees = if ($scenario -in @('ai-security-assign-fallback', 'ai-security-assign-failure')) {
                        'assignees[]=github-agentic-autofix[bot],assignees[]=copilot-swe-agent[bot]'
                    } else { 'assignees[]=github-agentic-autofix[bot]' }
                    $actualAssignees = @($assign | ForEach-Object { @($_.Arguments | Where-Object { $_ -like 'assignees`[`]=*' })[0] }) -join ','
                    Assert ($actualAssignees -eq $expectedAssignees) "Assignment attempts were '$actualAssignees'."
                    Assert (@($assign | Where-Object { $_.Arguments[3] -ne "repos/$fullName/code-scanning/alerts/4" }).Count -eq 0) 'The preassign_rule alert was not the one assigned.'
                    Assert ($testState.Calls.IndexOf($runList[0]) -lt $testState.Calls.IndexOf($assign[0])) 'Assigned an alert before CodeQL finished.'
                    if ($hasScan) {
                        Assert ($testState.Calls.IndexOf($assign[-1]) -lt $testState.Calls.IndexOf($prCalls[0])) 'Opened the AI Scan PR before the CodeQL wait and assignment.'
                    }
                    Assert ($testState.Opened -contains "https://github.com/$fullName/security/code-scanning") 'Code scanning alerts were not opened.'
                }
                else {
                    Assert ($seedPush.Count -eq 0 -and $dispatch.Count -eq 0 -and $runList.Count -eq 0 -and $assign.Count -eq 0) 'Waited for CodeQL or assigned Copilot without "autofix".'
                    Assert ($testState.Opened -notcontains "https://github.com/$fullName/security/code-scanning") 'Opened the alert list without "autofix".'
                }
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
