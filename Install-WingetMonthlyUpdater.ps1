#requires -Version 5.1
<#
.SYNOPSIS
    Installs (or reconfigures / uninstalls) the Winget Monthly Updater: copies runtime
    scripts to C:\ProgramData\WingetMonthlyUpdater and creates the scheduled tasks.

.DESCRIPTION
    Architecture (see README.md for details):
      - "Monthly Prompt" and "Retry Prompt" scheduled tasks run in the signed-in user's
        own interactive session (principal = BUILTIN\Users, Limited) and only show a
        confirmation popup. They never run elevated.
      - "Elevated Update" scheduled task runs as SYSTEM with highest privileges and
        performs the actual winget upgrade. It has no trigger of its own; it is only
        ever started on-demand (Start-ScheduledTask) once the user confirms in the
        popup. Its security descriptor is relaxed so a standard user is allowed to
        start it, without being allowed to run it AS an admin themselves.

.PARAMETER Day
    Day of month (1-28) the monthly prompt should run on. Default: 1.

.PARAMETER Time
    Time of day (HH:mm, 24h) the monthly prompt should run at. Default: 16:00.

.PARAMETER Uninstall
    Removes the scheduled tasks and all installed files/state/logs.

.EXAMPLE
    .\Install-WingetMonthlyUpdater.ps1
    Interactive install using the defaults (day 1, 16:00).

.EXAMPLE
    .\Install-WingetMonthlyUpdater.ps1 -Day 15 -Time 09:30
    Unattended install/reconfigure for day 15 at 09:30.

.EXAMPLE
    .\Install-WingetMonthlyUpdater.ps1 -Uninstall
    Removes everything that was installed.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 28)]
    [int] $Day,

    [string] $Time,

    [switch] $Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallRoot  = 'C:\ProgramData\WingetMonthlyUpdater'
$ScriptsDir   = Join-Path $InstallRoot 'Scripts'
$LogsDir      = Join-Path $InstallRoot 'Logs'
$StateDir     = Join-Path $InstallRoot 'State'
$StateFile    = Join-Path $StateDir 'state.json'
$TaskFolder   = '\WingetMonthlyUpdater\'
$MonthlyTask  = 'Monthly Prompt'
$RetryTask    = 'Retry Prompt'
$UpdateTask   = 'Elevated Update'

# ---------------------------------------------------------------------------
# 1. Elevation: relaunch under UAC if not already running as Administrator.
# ---------------------------------------------------------------------------
function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    Write-Host 'Administrator privileges are required. Relaunching with elevation...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($PSBoundParameters.ContainsKey('Day'))       { $argList += @('-Day', $Day) }
    if ($PSBoundParameters.ContainsKey('Time'))      { $argList += @('-Time', "`"$Time`"") }
    if ($Uninstall)                                  { $argList += '-Uninstall' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    exit
}

# ---------------------------------------------------------------------------
# Uninstall path
# ---------------------------------------------------------------------------
if ($Uninstall) {
    Write-Host 'Removing Winget Monthly Updater...' -ForegroundColor Cyan
    foreach ($name in @($MonthlyTask, $RetryTask, $UpdateTask)) {
        $t = Get-ScheduledTask -TaskName $name -TaskPath $TaskFolder -ErrorAction SilentlyContinue
        if ($t) {
            Unregister-ScheduledTask -TaskName $name -TaskPath $TaskFolder -Confirm:$false
            Write-Host "  Removed scheduled task '$name'."
        }
    }
    # Remove the (now empty) task folder.
    try {
        $svc = New-Object -ComObject Schedule.Service
        $svc.Connect()
        $root = $svc.GetFolder('\')
        $root.DeleteFolder($TaskFolder.Trim('\'), 0)
    }
    catch { }

    if (Test-Path -LiteralPath $InstallRoot) {
        Remove-Item -LiteralPath $InstallRoot -Recurse -Force
        Write-Host "  Removed $InstallRoot."
    }
    Write-Host 'Uninstall complete.' -ForegroundColor Green
    return
}

# ---------------------------------------------------------------------------
# 2. Verify winget is available.
# ---------------------------------------------------------------------------
function Find-WinGetPathForInstaller {
    $cmd = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $wa = Join-Path $env:ProgramFiles 'WindowsApps'
    if (Test-Path -LiteralPath $wa) {
        $candidate = Get-ChildItem -LiteralPath $wa -Directory -Filter 'Microsoft.DesktopAppInstaller_*_*__8wekyb3d8bbwe' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'winget.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if ($candidate) { return $candidate }
    }
    return $null
}

$wingetPath = Find-WinGetPathForInstaller
if (-not $wingetPath) {
    Write-Error 'Windows Package Manager (winget) was not found. Install "App Installer" from the Microsoft Store, then re-run this installer.'
    exit 1
}
Write-Host "Found winget at: $wingetPath" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3. Ask for schedule (day/time), unless supplied as parameters.
# ---------------------------------------------------------------------------
if (-not $PSBoundParameters.ContainsKey('Day')) {
    $raw = Read-Host 'Day of month to run the update prompt (1-28) [default: 1]'
    if ([string]::IsNullOrWhiteSpace($raw)) { $Day = 1 } else { $Day = [int]$raw }
}
if (-not $PSBoundParameters.ContainsKey('Time')) {
    $raw = Read-Host 'Time of day to run the update prompt, 24h HH:mm [default: 16:00]'
    if ([string]::IsNullOrWhiteSpace($raw)) { $Time = '16:00' } else { $Time = $raw }
}

# ---------------------------------------------------------------------------
# 4. Validate.
# ---------------------------------------------------------------------------
if ($Day -lt 1 -or $Day -gt 28) {
    Write-Error 'Day must be between 1 and 28 (days 29-31 do not exist in every month and would cause missed runs).'
    exit 1
}
$parsedTime = [datetime]::MinValue
if (-not [datetime]::TryParseExact($Time, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref] $parsedTime)) {
    Write-Error "Time '$Time' is not valid. Use 24-hour HH:mm format, e.g. 16:00."
    exit 1
}

Write-Host "Configuring schedule: day $Day of each month at $($parsedTime.ToString('HH:mm'))." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 5. Create ProgramData layout and copy runtime scripts.
# ---------------------------------------------------------------------------
foreach ($dir in @($InstallRoot, $ScriptsDir, $LogsDir, $StateDir)) {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

$payloadDir = Join-Path $PSScriptRoot 'Payload'
if (-not (Test-Path -LiteralPath $payloadDir)) {
    Write-Error "Payload folder not found next to the installer: $payloadDir"
    exit 1
}
foreach ($file in @('Common.ps1', 'Show-UpdatePrompt.ps1', 'Invoke-WingetUpdate.ps1')) {
    Copy-Item -LiteralPath (Join-Path $payloadDir $file) -Destination (Join-Path $ScriptsDir $file) -Force
}
Write-Host "Installed runtime scripts to $ScriptsDir." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 6. Persist schedule/state. Reconfiguring resets any pending skip/retry.
# ---------------------------------------------------------------------------
$state = [pscustomobject]@{
    ScheduleDay    = $Day
    ScheduleTime   = $parsedTime.ToString('HH:mm')
    SkipUntilMonth = $null
}
($state | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $StateFile -Encoding UTF8

# ---------------------------------------------------------------------------
# 7. Register scheduled tasks (idempotent: existing tasks are replaced, never duplicated).
# ---------------------------------------------------------------------------
$promptAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptsDir\Show-UpdatePrompt.ps1`""
$updateAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptsDir\Invoke-WingetUpdate.ps1`""

$interactivePrincipal = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Users' -RunLevel Limited
$systemPrincipal       = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$promptSettings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

$updateSettings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -Hidden `
    -ExecutionTimeLimit (New-TimeSpan -Hours 3)

function Register-OrReplaceTask {
    param(
        [string] $Name,
        [string] $Description,
        $Action,
        $Principal,
        $Settings,
        $Trigger  # $null is allowed (no trigger / on-demand only)
    )
    $existing = Get-ScheduledTask -TaskName $Name -TaskPath $TaskFolder -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $Name -TaskPath $TaskFolder -Confirm:$false
    }
    $params = @{
        TaskName    = $Name
        TaskPath    = $TaskFolder
        Action      = $Action
        Principal   = $Principal
        Settings    = $Settings
        Description = $Description
    }
    if ($Trigger) { $params['Trigger'] = $Trigger }
    Register-ScheduledTask @params | Out-Null
}

# Monthly Prompt: fires every month on the configured day/time, in the signed-in user's session.
$monthlyTrigger = New-ScheduledTaskTrigger -Monthly -DaysOfMonth $Day -At $parsedTime
Register-OrReplaceTask -Name $MonthlyTask -Trigger $monthlyTrigger -Action $promptAction `
    -Principal $interactivePrincipal -Settings $promptSettings `
    -Description 'Shows a monthly popup asking the signed-in user to confirm, postpone, or skip winget application updates.'

# Retry Prompt: created with no trigger; Show-UpdatePrompt.ps1 arms/disarms it when postponing.
Register-OrReplaceTask -Name $RetryTask -Trigger $null -Action $promptAction `
    -Principal $interactivePrincipal -Settings $promptSettings `
    -Description 'One-time follow-up popup created automatically when the user postpones the monthly update prompt.'
Disable-ScheduledTask -TaskName $RetryTask -TaskPath $TaskFolder | Out-Null

# Elevated Update: no trigger of its own; started on demand by the prompt scripts.
Register-OrReplaceTask -Name $UpdateTask -Trigger $null -Action $updateAction `
    -Principal $systemPrincipal -Settings $updateSettings `
    -Description 'Runs "winget upgrade --all" with administrator privileges. Started on demand only, never scheduled directly.'

# Relax the Elevated Update task's security descriptor so a standard user (running the
# prompt task) is allowed to start it on demand, even though it still executes as SYSTEM.
# BA = Builtin Administrators (full control), AU = Authenticated Users (read + execute/start).
try {
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $folder = $svc.GetFolder($TaskFolder.TrimEnd('\'))
    $task = $folder.GetTask($UpdateTask)
    $sddl = 'D:(A;;GA;;;BA)(A;;GRGX;;;AU)(A;;GA;;;SY)'
    $task.SetSecurityDescriptor($sddl, 0) | Out-Null
    Write-Host 'Granted standard users permission to start the elevated update task on demand.' -ForegroundColor Green
}
catch {
    Write-Warning "Could not adjust the Elevated Update task's permissions. 'Update now' may fail for non-admin users: $_"
}

# ---------------------------------------------------------------------------
# 8. Done.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Winget Monthly Updater installed successfully.' -ForegroundColor Green
Write-Host "  Schedule:       Day $Day of every month at $($parsedTime.ToString('HH:mm'))"
Write-Host "  Scheduled tasks (folder $TaskFolder):"
Write-Host "    - $MonthlyTask   (interactive monthly prompt)"
Write-Host "    - $RetryTask     (armed automatically on postpone)"
Write-Host "    - $UpdateTask    (elevated winget upgrade, on-demand only)"
Write-Host "  Installed files: $InstallRoot"
Write-Host "  Logs:            $LogsDir"
Write-Host ''
Write-Host "Re-run this installer at any time to change the schedule. Use -Uninstall to remove everything."
