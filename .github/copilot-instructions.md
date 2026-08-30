# Winget Monthly Updater instructions

## Development and verification

- This repository targets Windows 11 and Windows PowerShell 5.1. It relies only on built-in PowerShell, Task Scheduler, WPF, and `winget`; there is no automated test suite or repository-configured linter.
- Run the installer from the repository root. It self-elevates when required:

  ```powershell
  .\Install-WingetMonthlyUpdater.ps1
  .\Install-WingetMonthlyUpdater.ps1 -Day 15 -Time 09:30
  .\Install-WingetMonthlyUpdater.ps1 -Uninstall
  ```

- Build the MSI with the .NET 8 SDK and the pinned WiX SDK project. The package must be rebuilt for every release:

  ```powershell
  .\Installer\Build-Msi.ps1 -Version 1.0.0
  ```

- Validate individual behaviors on a Windows 11 machine after installation:

  ```powershell
  Get-ScheduledTask -TaskPath '\WingetMonthlyUpdater\'
  Get-ScheduledTask -TaskPath '\WingetMonthlyUpdater\' | Get-ScheduledTaskInfo
  Start-ScheduledTask -TaskName 'Monthly Prompt' -TaskPath '\WingetMonthlyUpdater\'
  Get-ScheduledTaskInfo -TaskName 'Retry Prompt' -TaskPath '\WingetMonthlyUpdater\'
  Get-ChildItem 'C:\ProgramData\WingetMonthlyUpdater\Logs'
  ```

  Exercise one scenario at a time: install/reconfigure without duplicate tasks, the interactive prompt, Postpone (a retry at the configured time tomorrow), Skip this month, Update now, and uninstall.

## Architecture

- `Install-WingetMonthlyUpdater.ps1` is the deployment and configuration entry point. It creates `C:\ProgramData\WingetMonthlyUpdater\{Scripts,Logs,State}`, copies the `Payload` scripts there, writes `State\state.json`, and creates all scheduled tasks. Runtime changes must be made in `Payload\`; the installer must copy any added runtime file.
- `Installer\` builds an MSI that embeds the root installer and payload scripts, then invokes that same installer using elevated MSI custom actions. Keep its file list synchronized with the installer payload copy list. Existing source-file changes are embedded automatically whenever `Build-Msi.ps1` runs.
- The application deliberately separates interaction from privilege:
  - `Monthly Prompt` and `Retry Prompt` run as `BUILTIN\Users` at limited privilege in the signed-in user's session and execute `Show-UpdatePrompt.ps1`.
  - `Elevated Update` runs as `SYSTEM` with highest privileges and has no trigger. The prompt starts it on demand after confirmation. Its SDDL grants authenticated users read/start access, not administrative execution.
- `Show-UpdatePrompt.ps1` owns the WPF dialog and user decisions. Update now starts the elevated task; Postpone enables and schedules the one-time retry task for tomorrow; Skip persists the current month and removes any retry trigger. A timeout, closed dialog, or unavailable WPF is treated as Postpone.
- `Invoke-WingetUpdate.ps1` is the SYSTEM-side worker. It finds `winget.exe` in a non-interactive/SYSTEM-safe way, runs `winget upgrade --all --include-unknown --silent`, logs all output, and clears a pending retry only for exit code `0` or `-1977319852` (no applicable updates).
- `Payload\Common.ps1` is dot-sourced by both runtime scripts. It centralizes the fixed ProgramData paths, JSON state, timestamped logging, cross-session mutexes, retry-task manipulation, launching the elevated task, and SYSTEM-safe `winget` discovery.

## Repository conventions

- Use PowerShell 5.1-compatible syntax and retain `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` in executable scripts.
- Keep deployment constants in the installer and runtime constants in `Payload\Common.ps1` synchronized: install root, task folder, task names, and copied payload file names.
- Treat scheduled-task security and principals as functional requirements. Do not move the prompt to SYSTEM/elevation, add a trigger to `Elevated Update`, or broaden the task ACL beyond the ability for standard users to start that task.
- Scheduled task cmdlets cannot reliably construct the monthly trigger used here. `Set-MonthlyCalendarTrigger` exports the registered task XML, injects `CalendarTrigger`, and re-registers it; preserve this approach when changing the monthly schedule.
- Runtime scripts log user-visible failures and recoverable state/task problems using `Write-UpdaterLog`; prompt failures must remain non-elevated and default to postponing rather than performing updates.
- `state.json` is intentionally backward-compatible: `Get-UpdaterState` supplies defaults and adds newly introduced properties. Add new persisted state through the default object and installer-written state together.
