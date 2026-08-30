#requires -Version 5.1
<#
.SYNOPSIS
    Runs the actual winget upgrade, non-interactively, with highest privileges.
    Invoked only by the "Elevated Update" scheduled task (runs as SYSTEM), either on
    a schedule-free on-demand basis (started from Show-UpdatePrompt.ps1) or manually.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

$logName = New-TimestampedLogName -Prefix 'Update'

# Winget exit codes that mean "ran fine, nothing to do" rather than a real failure.
# -1977319852 is the signed Int32 form of HRESULT 0x8A150054
# (APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE / "no applicable update found").
$NoUpdatesExitCodes = @(0, -1977319852)

try {
    $lock = Enter-SingleInstanceLock -Name 'Global\WingetMonthlyUpdater_Update'
    if ($null -eq $lock) {
        Write-UpdaterLog -LogName $logName -Message 'An update run is already in progress. Exiting without starting a second one.'
        return
    }

    try {
        $startTime = Get-Date
        Write-UpdaterLog -LogName $logName -Message "Elevated update run starting at $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))."

        $wingetExe = Find-WinGetPath
        if (-not $wingetExe) {
            Write-UpdaterLog -LogName $logName -Level 'ERROR' -Message 'winget.exe could not be located. Ensure "App Installer" is installed from the Microsoft Store, then re-run.'
            exit 1
        }

        $wingetArgs = @(
            'upgrade'
            '--all'
            '--include-unknown'
            '--silent'
            '--accept-package-agreements'
            '--accept-source-agreements'
            '--disable-interactivity'
        )
        $commandLine = "`"$wingetExe`" $($wingetArgs -join ' ')"
        Write-UpdaterLog -LogName $logName -Message "Command: $commandLine"

        $output = & $wingetExe @wingetArgs 2>&1
        $exitCode = $LASTEXITCODE

        foreach ($line in $output) {
            Write-UpdaterLog -LogName $logName -Message "winget> $line"
        }

        $endTime = Get-Date
        $duration = $endTime - $startTime
        $isSuccess = $NoUpdatesExitCodes -contains $exitCode

        Write-UpdaterLog -LogName $logName -Message "Finished at $($endTime.ToString('yyyy-MM-dd HH:mm:ss')) (duration $($duration.ToString('hh\:mm\:ss'))). Exit code: $exitCode. Result: $(if ($isSuccess) {'SUCCESS'} else {'FAILURE'})"

        if ($isSuccess) {
            Clear-PendingRetryState -LogName $logName
        }
        else {
            Write-UpdaterLog -LogName $logName -Level 'ERROR' -Message "winget reported a failure (exit code $exitCode). See winget output above for details."
        }

        exit $exitCode
    }
    finally {
        Exit-SingleInstanceLock -Mutex $lock
    }
}
catch {
    Write-UpdaterLog -LogName $logName -Level 'ERROR' -Message "Unhandled error during elevated update: $_"
    exit 1
}
