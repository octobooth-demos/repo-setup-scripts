# Run the standalone Demo Launcher (standalone-launcher/server.mjs) as a Windows logon task, so
# http://127.0.0.1:4747/ is always up in any browser, with or without the Copilot app.
# Safe to re-run: it replaces the scheduled task and restarts it.
#
#   pwsh standalone-launcher/install-service.ps1 [-Port 4747]
#   pwsh standalone-launcher/install-service.ps1 -Uninstall
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = $(if ($env:DEMO_LAUNCHER_PORT) { [int]$env:DEMO_LAUNCHER_PORT } else { 4747 }),
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'

$TaskName = 'Demo Launcher'

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Error 'This installer supports Windows only. On macOS use standalone-launcher/install-service.sh; elsewhere run: node standalone-launcher/server.mjs'
}

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

if ($Uninstall) {
    Write-Host "✅ Removed the '$TaskName' scheduled task."
    return
}

$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { Write-Error 'node not found. Install Node.js 18+ first.' }
$nodeMajor = [int](& $node -p 'process.versions.node.split(".")[0]')
if ($nodeMajor -lt 18) { Write-Error "Node.js 18+ is required (found $(& $node --version))." }

# Prefer the main checkout over a temporary worktree, which may be deleted later.
$launcherDir = $PSScriptRoot
$commonDir = git -C $launcherDir rev-parse --path-format=absolute --git-common-dir 2>$null
if ($LASTEXITCODE -eq 0 -and $commonDir) {
    $mainDir = Join-Path (Split-Path $commonDir -Parent) 'standalone-launcher'
    if ((Resolve-Path $mainDir -ErrorAction SilentlyContinue).Path -ne (Resolve-Path $launcherDir).Path) {
        if (Test-Path (Join-Path $mainDir 'server.mjs')) {
            $launcherDir = $mainDir
        } else {
            Write-Warning "The main checkout doesn't have standalone-launcher/server.mjs yet; using this worktree. Re-run from the main checkout after merging."
        }
    }
}
$repoDir = Split-Path $launcherDir -Parent
$server = Join-Path $launcherDir 'server.mjs'
$logDir = Join-Path $env:LOCALAPPDATA 'demo-launcher'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'server.log'

# Hidden PowerShell wrapper so no console window stays open at logon.
$command = "& '$($node -replace "'", "''")' '$($server -replace "'", "''")' --port $Port *>> '$($logFile -replace "'", "''")'"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$command`"" `
    -WorkingDirectory $repoDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description 'Standalone Demo Launcher (repo-setup-scripts/standalone-launcher/server.mjs)' | Out-Null
Start-ScheduledTask -TaskName $TaskName

$url = "http://127.0.0.1:$Port/"
for ($i = 0; $i -lt 10; $i++) {
    try {
        Invoke-WebRequest -Uri "${url}api/state" -UseBasicParsing -TimeoutSec 2 | Out-Null
        Write-Host "✅ Demo Launcher running at $url (from $launcherDir)"
        Write-Host "   Starts at logon. Logs: $logFile"
        return
    } catch {
        Start-Sleep -Seconds 1
    }
}
Write-Error "The Demo Launcher didn't respond at $url. Check $logFile"
