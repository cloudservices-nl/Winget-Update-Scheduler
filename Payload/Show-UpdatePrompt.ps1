#requires -Version 5.1
<#
.SYNOPSIS
    Interactive popup shown to the signed-in user, asking whether to run the monthly
    winget upgrade. Invoked by the "Monthly Prompt" and "Retry Prompt" scheduled tasks,
    which run in the interactive user's own desktop session (never as SYSTEM), so this
    script must never require elevation.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

$logName = New-TimestampedLogName -Prefix 'Prompt'

function Invoke-PostponeAction {
    param([pscustomobject] $State)
    $today = Get-Date
    $nextRun = [datetime]::ParseExact($State.ScheduleTime, 'HH:mm', $null)
    $nextRun = $today.Date.AddDays(1).Add($nextRun.TimeOfDay)
    Set-RetryTrigger -At $nextRun -LogName $logName
    Write-UpdaterLog -LogName $logName -Message 'User choice: Postpone (or timeout). Retry scheduled for tomorrow.'
}

function Invoke-SkipMonthAction {
    param([pscustomobject] $State)
    $State.SkipUntilMonth = Get-CurrentMonthKey
    Set-UpdaterState -State $State
    Clear-PendingRetryState -LogName $logName
    Write-UpdaterLog -LogName $logName -Message 'User choice: Skip this month. No further prompts until next scheduled month.'
}

function Invoke-UpdateNowAction {
    param([pscustomobject] $State)
    Clear-PendingRetryState -LogName $logName
    Write-UpdaterLog -LogName $logName -Message 'User choice: Update now. Starting elevated update task.'
    Start-ElevatedUpdateTask -LogName $logName
}

function Show-UpdateConfirmationDialog {
    <#
        Returns one of 'UpdateNow', 'Postpone', 'SkipMonth'. Falls back to $null if WPF
        could not be initialized, in which case the caller must treat this as Postpone.
    #>
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        Add-Type -AssemblyName PresentationCore -ErrorAction Stop
        Add-Type -AssemblyName WindowsBase -ErrorAction Stop
    }
    catch {
        Write-UpdaterLog -LogName $logName -Level 'ERROR' -Message "WPF failed to initialize, defaulting to Postpone. $_"
        return $null
    }

    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Monthly app updates"
        Width="460" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" Topmost="True"
        ShowInTaskbar="True" WindowStyle="SingleBorderWindow">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Monthly app updates" FontSize="18" FontWeight="Bold" Margin="0,0,0,10"/>
        <TextBlock Grid.Row="1" TextWrapping="Wrap" Margin="0,0,0,8"
                   Text="Windows Package Manager (winget) can update your installed applications now."/>
        <TextBlock Grid.Row="2" TextWrapping="Wrap" Margin="0,0,0,16" Foreground="#555555"
                   Text="This may take a few minutes and some applications may need to close or restart. This prompt will automatically postpone in 10 minutes if you don't respond."/>
        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnSkip" Content="Skip this month" Width="120" Height="30" Margin="0,0,10,0"/>
            <Button x:Name="BtnPostpone" Content="Postpone" Width="100" Height="30" Margin="0,0,10,0"/>
            <Button x:Name="BtnUpdate" Content="Update now" Width="110" Height="30" IsDefault="True" FontWeight="Bold"/>
        </StackPanel>
    </Grid>
</Window>
'@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $result = $null
    $btnUpdate = $window.FindName('BtnUpdate')
    $btnPostpone = $window.FindName('BtnPostpone')
    $btnSkip = $window.FindName('BtnSkip')

    $btnUpdate.Add_Click({ $script:result = 'UpdateNow'; $window.Close() })
    $btnPostpone.Add_Click({ $script:result = 'Postpone'; $window.Close() })
    $btnSkip.Add_Click({ $script:result = 'SkipMonth'; $window.Close() })

    # Auto-close after 10 minutes; treated as Postpone by the caller if $result is still $null.
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMinutes(10)
    $timer.Add_Tick({ $timer.Stop(); $window.Close() })
    $window.Add_Loaded({
        $timer.Start()
        $window.Activate()
        $window.Topmost = $true
    })

    $null = $window.ShowDialog()
    return $result
}

try {
    $lock = Enter-SingleInstanceLock -Name 'WingetMonthlyUpdater_Prompt'
    if ($null -eq $lock) {
        Write-UpdaterLog -LogName $logName -Message 'Another prompt instance is already running in this session. Exiting.'
        return
    }

    try {
        $state = Get-UpdaterState
        $currentMonth = Get-CurrentMonthKey

        if ($state.SkipUntilMonth -eq $currentMonth) {
            Write-UpdaterLog -LogName $logName -Message "Month $currentMonth already skipped by user. Suppressing prompt."
            return
        }

        Write-UpdaterLog -LogName $logName -Message "Showing update confirmation dialog to user $env:USERNAME."
        $choice = Show-UpdateConfirmationDialog

        switch ($choice) {
            'UpdateNow'  { Invoke-UpdateNowAction -State $state }
            'SkipMonth'  { Invoke-SkipMonthAction -State $state }
            default      { Invoke-PostponeAction -State $state }  # covers 'Postpone', timeout, and window closed
        }
    }
    finally {
        Exit-SingleInstanceLock -Mutex $lock
    }
}
catch {
    Write-UpdaterLog -LogName $logName -Level 'ERROR' -Message "Unhandled error in prompt script: $_"
}
