# Winget Monthly Updater

Runs `winget upgrade` automatically once a month, with a confirmation popup shown to
the signed-in user before anything is installed. Windows 11 only. No third-party
dependencies — just built-in PowerShell, Task Scheduler, WPF, and Windows Package
Manager (`winget`).

## How it works

Task Scheduler alone can't show a dialog to the desktop from a SYSTEM/elevated task,
so responsibilities are split across three scheduled tasks (folder `\WingetMonthlyUpdater\`):

| Task              | Runs as                | Trigger                                   | Purpose |
|--------------------|------------------------|--------------------------------------------|---------|
| `Monthly Prompt`   | signed-in user (limited) | Monthly, on your configured day/time      | Shows the confirmation popup |
| `Retry Prompt`     | signed-in user (limited) | One-time, armed automatically on postpone | Shows the popup again the next day |
| `Elevated Update`  | SYSTEM (highest)         | None — started on demand only             | Runs the actual `winget upgrade` |

The popup only ever *starts* the elevated task after you click **Update now** — it
never runs the update itself. **Postpone** re-prompts you at the same time the next
day. **Skip this month** silences prompts until next month's regular schedule (the
monthly schedule itself is never touched). The popup auto-closes after 10 minutes,
which is treated the same as Postpone.

## Install

Run from an elevated or standard PowerShell prompt (it will self-elevate via UAC if needed):

```powershell
.\Install-WingetMonthlyUpdater.ps1
```

You'll be asked for a day of month (1–28) and a time (24h `HH:mm`). Press Enter to
accept the defaults: **day 1, 16:00**.

For unattended/scripted installs, pass the values directly:

```powershell
.\Install-WingetMonthlyUpdater.ps1 -Day 15 -Time 09:30
```

## Changing the schedule

Just re-run the installer with new values. It replaces the existing scheduled tasks
and installed scripts in place — re-running never creates duplicates, and any pending
postpone/skip state is reset along with the new schedule.

## Scheduled tasks created

Folder: `\WingetMonthlyUpdater\`
- `Monthly Prompt`
- `Retry Prompt`
- `Elevated Update`

## Installed files

```
C:\ProgramData\WingetMonthlyUpdater\
  Scripts\   Common.ps1, Show-UpdatePrompt.ps1, Invoke-WingetUpdate.ps1
  State\     state.json (schedule + skip/postpone state)
  Logs\      timestamped Prompt_*.log and Update_*.log files
```

## Logs

`C:\ProgramData\WingetMonthlyUpdater\Logs\` — a new timestamped log file is written
for every prompt shown and every update run, including winget's full output, the exact
command line used, start/end time, and exit code.

## Uninstall

```powershell
.\Install-WingetMonthlyUpdater.ps1 -Uninstall
```

This removes all three scheduled tasks and deletes `C:\ProgramData\WingetMonthlyUpdater`.

## Verifying it works

- **Defaults:** run the installer and press Enter twice; confirm via `Get-ScheduledTask -TaskPath '\WingetMonthlyUpdater\' | Get-ScheduledTaskInfo` that `Monthly Prompt`'s next run is day 1 at 16:00.
- **No duplicates:** run the installer twice in a row; `Get-ScheduledTask -TaskPath '\WingetMonthlyUpdater\'` should still list exactly 3 tasks.
- **Interactive context:** run `Start-ScheduledTask -TaskName 'Monthly Prompt' -TaskPath '\WingetMonthlyUpdater\'` while logged on — the popup should appear on your desktop, not run invisibly.
- **Update now:** click it in the popup, then check `Get-ScheduledTask -TaskName 'Elevated Update' -TaskPath '\WingetMonthlyUpdater\'` state is `Running`, and inspect the new `Update_*.log`.
- **Postpone:** click it, then confirm `Get-ScheduledTaskInfo -TaskName 'Retry Prompt' -TaskPath '\WingetMonthlyUpdater\'` shows a NextRunTime of tomorrow at your configured time.
- **Skip this month:** click it, then re-run `Monthly Prompt` manually — it should exit immediately and log "already skipped" without showing a popup.
