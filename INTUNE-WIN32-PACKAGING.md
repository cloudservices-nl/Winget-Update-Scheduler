# Intune Win32 packaging

Use this file when creating a **Windows app (Win32)** in Microsoft Intune. Package the
repository's installer script and `Payload` folder as an `.intunewin` file; do not use
the MSI for this deployment method.

## Create the `.intunewin` package

Download the Microsoft Win32 Content Prep Tool, then run it from a clean copy of this
repository:

```powershell
IntuneWinAppUtil.exe -c C:\Source\WingetMonthlyUpdater -s Install-WingetMonthlyUpdater.ps1 -o C:\Output
```

Copy the resulting `Install-WingetMonthlyUpdater.intunewin` file to Intune.

## App information

| Intune field | Value |
|---|---|
| Name | `Winget Monthly Updater` |
| Description | `Shows the signed-in user a monthly confirmation prompt, then runs winget application updates as SYSTEM after approval.` |
| Publisher | `Cloudservices.nl` |
| App Version | `1.0.0` |
| Category | `Computer management` |
| Show this as a featured app in the Company Portal | `No` |
| Information URL | `https://github.com/cloudservices-nl/Winget-Update-Scheduler` |
| Privacy URL | Leave blank |
| Owner | Leave blank |
| Notes | `Installs three scheduled tasks under \WingetMonthlyUpdater\ and stores runtime files, state, and logs in C:\ProgramData\WingetMonthlyUpdater.` |
| Logo | Optional; leave blank unless an organization-approved logo is available |
| Scope tags | `Default` unless your Intune RBAC model requires another scope tag |

## Program

| Intune field | Value |
|---|---|
| Install command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-WingetMonthlyUpdater.ps1 -Day 1 -Time 16:00` |
| Uninstall command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-WingetMonthlyUpdater.ps1 -Uninstall` |
| Install behavior | `System` |
| Device restart behavior | `Determine behavior based on return codes` |
| Return code: 0 | `Success` |
| Return code: 3010 | `Soft reboot` |
| Return code: 1641 | `Hard reboot` |
| Return code: 1 | `Failed` |

Change `-Day` (1-28) and `-Time` (`HH:mm`, 24-hour) in the install command to set the
organization's schedule before assigning the app.

## Requirements

| Intune field | Value |
|---|---|
| Operating system architecture | `64-bit` |
| Minimum operating system | `Windows 10 1607` |
| Disk space required (MB) | Leave blank |
| Physical memory required (MB) | Leave blank |
| Minimum number of logical processors | Leave blank |
| Minimum CPU speed required (MHz) | Leave blank |
| Additional requirement rules | None |

Assign only to Windows 11 devices, because the application supports Windows 11.

## Detection rules

Select **Rules format: Manually configure detection rules**, then add this rule:

| Intune field | Value |
|---|---|
| Rule type | `File` |
| Path | `C:\ProgramData\WingetMonthlyUpdater\Scripts` |
| File or folder | `Show-UpdatePrompt.ps1` |
| Detection method | `File or folder exists` |
| Associated with a 32-bit app on 64-bit clients | `No` |

## Dependencies, supersedence, and assignments

| Intune field | Value |
|---|---|
| Dependencies | None |
| Supersedence | None |
| Required assignment | Select the device group that should receive monthly updates |
| Available assignment | Optional; use only if users should choose installation from Company Portal |
| Uninstall assignment | Select the device group from which the updater should be removed |

After deployment, verify the three tasks exist in `\WingetMonthlyUpdater\` and inspect
`C:\ProgramData\WingetMonthlyUpdater\Logs\` for prompt and update activity.
