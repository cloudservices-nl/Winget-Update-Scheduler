#requires -Version 5.1
<#
.SYNOPSIS
    Shared helpers for the Winget Monthly Updater (state, logging, locking, task management).
    Dot-sourced by Show-UpdatePrompt.ps1 and Invoke-WingetUpdate.ps1. Never run directly.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Fixed, machine-wide locations. Must match the layout created by the installer.
# ---------------------------------------------------------------------------
$Script:InstallRoot = 'C:\ProgramData\WingetMonthlyUpdater'
$Script:ScriptsDir  = Join-Path $Script:InstallRoot 'Scripts'
$Script:LogsDir     = Join-Path $Script:InstallRoot 'Logs'
$Script:StateDir    = Join-Path $Script:InstallRoot 'State'
$Script:StateFile   = Join-Path $Script:StateDir 'state.json'

$Script:TaskFolder        = '\WingetMonthlyUpdater\'
$Script:MonthlyPromptTask = 'Monthly Prompt'
$Script:RetryPromptTask   = 'Retry Prompt'
$Script:UpdateTask        = 'Elevated Update'

function Initialize-UpdaterDirectories {
    <# Creates the ProgramData folder layout if it does not already exist. #>
    foreach ($dir in @($Script:InstallRoot, $Script:ScriptsDir, $Script:LogsDir, $Script:StateDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

function Write-UpdaterLog {
    <#
    .SYNOPSIS
        Appends a timestamped line to a named log file under the Logs directory.
    #>
    param(
        [Parameter(Mandatory)] [string] $Message,
        [Parameter(Mandatory)] [string] $LogName,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO'
    )
    Initialize-UpdaterDirectories
    $logPath = Join-Path $Script:LogsDir $LogName
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function New-TimestampedLogName {
    param([Parameter(Mandatory)] [string] $Prefix)
    return '{0}_{1}.log' -f $Prefix, (Get-Date -Format 'yyyy-MM-dd_HHmmss')
}

function Get-CurrentMonthKey {
    return (Get-Date).ToString('yyyy-MM')
}

function Get-UpdaterState {
    <# Returns the persisted state, or sensible defaults if the file is missing/corrupt. #>
    $default = [pscustomobject]@{
        ScheduleDay     = 1
        ScheduleTime    = '16:00'
        SkipUntilMonth  = $null
    }
    if (-not (Test-Path -LiteralPath $Script:StateFile)) {
        return $default
    }
    try {
        $raw = Get-Content -LiteralPath $Script:StateFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $default }
        $state = $raw | ConvertFrom-Json -ErrorAction Stop
        # Backfill any properties missing from an older state file.
        foreach ($prop in $default.PSObject.Properties.Name) {
            if (-not ($state.PSObject.Properties.Name -contains $prop)) {
                $state | Add-Member -NotePropertyName $prop -NotePropertyValue $default.$prop
            }
        }
        return $state
    }
    catch {
        Write-UpdaterLog -LogName 'Common.log' -Level 'WARN' -Message "State file unreadable, using defaults. $_"
        return $default
    }
}

function Set-UpdaterState {
    param([Parameter(Mandatory)] [pscustomobject] $State)
    Initialize-UpdaterDirectories
    ($State | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $Script:StateFile -Encoding UTF8
}

function Enter-SingleInstanceLock {
    <#
    .SYNOPSIS
        Attempts to acquire a named mutex without blocking. Returns the Mutex object on
        success (caller must call ReleaseMutex/Dispose), or $null if already held elsewhere.
    #>
    param([Parameter(Mandatory)] [string] $Name)
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($false, $Name, [ref] $createdNew)
    try {
        if ($mutex.WaitOne(0)) {
            return $mutex
        }
        $mutex.Dispose()
        return $null
    }
    catch [System.Threading.AbandonedMutexException] {
        # Previous owner terminated without releasing - we still got ownership.
        return $mutex
    }
}

function Exit-SingleInstanceLock {
    param([Parameter(Mandatory)] [System.Threading.Mutex] $Mutex)
    try { $Mutex.ReleaseMutex() } catch { }
    $Mutex.Dispose()
}

function Get-RetryPromptTask {
    Get-ScheduledTask -TaskName $Script:RetryPromptTask -TaskPath $Script:TaskFolder -ErrorAction SilentlyContinue
}

function Remove-RetryTrigger {
    <#
    .SYNOPSIS
        Disables the Retry Prompt task and strips its trigger so it will not fire again
        until a new postpone explicitly re-arms it.
    #>
    param([string] $LogName = 'Common.log')
    $task = Get-RetryPromptTask
    if ($null -eq $task) { return }
    try {
        Set-ScheduledTask -TaskName $Script:RetryPromptTask -TaskPath $Script:TaskFolder -Trigger @() | Out-Null
        Disable-ScheduledTask -TaskName $Script:RetryPromptTask -TaskPath $Script:TaskFolder | Out-Null
        Write-UpdaterLog -LogName $LogName -Message 'Retry prompt task cleared and disabled.'
    }
    catch {
        Write-UpdaterLog -LogName $LogName -Level 'WARN' -Message "Could not clear retry prompt task: $_"
    }
}

function Set-RetryTrigger {
    <#
    .SYNOPSIS
        (Re)arms the Retry Prompt task with a single one-time trigger for the given time.
    #>
    param(
        [Parameter(Mandatory)] [datetime] $At,
        [string] $LogName = 'Common.log'
    )
    $task = Get-RetryPromptTask
    if ($null -eq $task) {
        Write-UpdaterLog -LogName $LogName -Level 'ERROR' -Message 'Retry prompt task is missing; cannot arm postpone. Re-run the installer.'
        return
    }
    $trigger = New-ScheduledTaskTrigger -Once -At $At
    Set-ScheduledTask -TaskName $Script:RetryPromptTask -TaskPath $Script:TaskFolder -Trigger $trigger | Out-Null
    Enable-ScheduledTask -TaskName $Script:RetryPromptTask -TaskPath $Script:TaskFolder | Out-Null
    Write-UpdaterLog -LogName $LogName -Message "Retry prompt task armed for $($At.ToString('yyyy-MM-dd HH:mm'))."
}

function Start-ElevatedUpdateTask {
    param([string] $LogName = 'Common.log')
    Start-ScheduledTask -TaskName $Script:UpdateTask -TaskPath $Script:TaskFolder
    Write-UpdaterLog -LogName $LogName -Message 'Elevated update task started.'
}

function Clear-PendingRetryState {
    <# Called after a successful update or a month skip: removes any dangling retry schedule. #>
    param([string] $LogName = 'Common.log')
    Remove-RetryTrigger -LogName $LogName
}

function Find-WinGetPath {
    <#
    .SYNOPSIS
        Locates winget.exe reliably, including from a SYSTEM/Task Scheduler context where
        the interactive user's PATH and App Execution Alias are not available.
    #>
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
