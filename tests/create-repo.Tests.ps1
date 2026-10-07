#Requires -Version 5.1

# Standalone integration tests: no Pester, network calls, or real repositories.
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path $PSScriptRoot -Parent
$testRoot = Microsoft.PowerShell.Management\Join-Path ([IO.Path]::GetTempPath()) ("setup tests " + [guid]::NewGuid())
$fixtureRoot = Microsoft.PowerShell.Management\Join-Path $testRoot 'script'
$homeRepos = Microsoft.PowerShell.Management\Join-Path $testRoot 'repos'
$originalLocation = Get-Location
$testState = [pscustomobject]@{ Answers = $null; Calls = $null; NeedsLogin = $false; Failure = $null }

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
    if ($arguments[0] -eq 'api' -and $arguments[1] -eq 'user') {
        return 'demo-user'
    }
    if ($arguments[0] -eq 'api' -and $arguments[-1] -eq '.default_branch') {
        return 'trunk'
    }
    if ($arguments[0] -eq 'repo' -and $arguments[1] -eq 'clone') {
        $clonePath = $arguments[3]
        New-Item -ItemType Directory -Path (Join-Path $clonePath 'api/src') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $clonePath 'api/src/existing.txt') -Value 'preserve me'
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
    if ($arguments[0] -eq 'commit') {
        Assert (Test-Path -LiteralPath './api/src/existing.txt') 'Copying resources removed an existing file.'
        Assert (-not (Test-Path -LiteralPath './pr-body.md')) 'PR body would be committed.'
        Assert (-not (Test-Path -LiteralPath './metadata/body.md')) 'Nested PR body would be committed.'
        if ($arguments[2] -eq 'feat: Adds terms of services download') {
            Assert (Test-Path -LiteralPath './api/src/routes/legal.ts') 'TypeScript resources were not copied.'
            Assert (Test-Path -LiteralPath './api/documents/legal/en/terms_v2.1.pdf') 'Binary resources were not copied.'
        }
        else {
            Assert (Test-Path -LiteralPath './php/src/Controllers/NoteController.php') 'PHP resources were not copied.'
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
        'create-failure', 'push-failure', 'login-failure'
    )) {
        $config = $originalConfig | ConvertFrom-Json
        $config.repos += $branchRepo
        $selection = '1'
        $testState.NeedsLogin = $false
        $testState.Failure = $null
        $expectedFailure = $null
        switch ($scenario) {
            'security-prs' { $selection = '2' }
            'issue-codespace' { $selection = '3' }
            'branch-codespace' { $selection = '5' }
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
            'push-failure' { $selection = '2'; $testState.Failure = 'git push'; $expectedFailure = 'exit code 42' }
            'login-failure' { $testState.NeedsLogin = $true; $testState.Failure = 'auth login'; $expectedFailure = 'exit code 42' }
        }
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath
        if ($scenario -eq 'invalid-json') { Set-Content -LiteralPath $configPath -Value '{' }
        $testState.Answers = New-Object 'System.Collections.Generic.Queue[string]'
        if ($scenario -eq 'invalid-selection') {
            foreach ($answer in @('text', '0', '999999999999999999999', '6', '1')) { $testState.Answers.Enqueue($answer) }
        }
        else { $testState.Answers.Enqueue($selection) }
        $testState.Calls = New-Object 'System.Collections.Generic.List[object]'
        $caught = $null
        try { & $scriptPath }
        catch { $caught = $_.Exception.Message }

        Assert ((Get-Location).Path -eq $originalLocation.Path) "$scenario did not restore location."
        if ($expectedFailure) {
            Assert ($null -ne $caught -and $caught.Contains($expectedFailure)) "$scenario expected '$expectedFailure', got '$caught'."
            if ($scenario -notin @('create-failure', 'push-failure', 'login-failure')) {
                Assert ($testState.Calls.Count -eq 0) "$scenario invoked a remote command before validation."
            }
            if ($scenario -eq 'push-failure') {
                Assert ((Find-Calls 'gh' 'pr create').Count -eq 0) 'Created a PR after push failed.'
            }
            if ($scenario -eq 'create-failure') {
                Assert ((Find-Calls 'gh' 'repo clone').Count -eq 0) 'Cloned after repository creation failed.'
            }
        }
        else {
            Assert ($null -eq $caught) "$scenario failed: $caught"
            $create = @(Find-Calls 'gh' 'repo create')[0]
            Assert ($create.Arguments[2] -match '^octobooth-demos/[a-z-]+-[a-z0-9]{4}$') 'Invalid repository name.'
            Assert ($create.Arguments -contains '--private') 'Repository is not private.'
            if ($selection -eq '1') {
                Assert ($create.Arguments -contains '--template=github-samples/securing-your-code') 'Template org override was ignored.'
            }
            else {
                Assert (($create.Arguments -join ' ').Contains('--template=octobooth-demos/')) 'Template org fallback was ignored.'
            }
            if ($selection -eq '2') {
                Assert ((Find-Calls 'gh' 'pr create').Count -eq 2) 'Expected two PRs.'
                Assert ((Find-Calls 'gh' 'api repos/').Count -eq 4) 'Expected default branch lookup and three security API calls.'
                foreach ($prCall in (Find-Calls 'gh' 'pr create')) {
                    Assert ($prCall.Arguments -contains 'trunk') 'PR did not use the default branch.'
                }
            }
            if ($selection -in @('3', '5')) {
                $codespace = @(Find-Calls 'gh' 'codespace create')[0]
                Assert (($codespace.Arguments -contains '--machine') -eq ($scenario -ne 'no-machine')) 'Wrong machine arguments.'
                Assert (($codespace.Arguments -contains '--branch') -eq ($selection -eq '5')) 'Wrong branch arguments.'
            }
            if ($selection -eq '3') {
                $issue = @(Find-Calls 'gh' 'issue create')[0]
                Assert ($issue.Arguments -contains '@copilot') 'Issue assignee was not preserved.'
            }
            if ($selection -eq '5') {
                Assert ((Find-Calls 'git' 'checkout trunk').Count -eq 1) 'Branch workflow did not checkout default branch.'
                Assert ((Find-Calls 'git' 'push -u origin feature/demo').Count -eq 1) 'Branch was not pushed.'
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
