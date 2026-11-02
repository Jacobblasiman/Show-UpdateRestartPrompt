<#
.SYNOPSIS
    Shows the Windows Update engaged-restart prompt when a restart is required to finish installing updates.

.DESCRIPTION
    Does nothing unless Windows Update itself is waiting on a restart. PendingFileRenameOperations
    and RunOnce are ignored on purpose: Edge and OneDrive set those after routine cleanup, and they
    are not an update restart.

    First it tries the built-in engaged-restart dialog, the one Update Orchestrator used to raise
    itself (MusNotificationUx.exe Dialog_EnhancedEngagedRebootReminder / Dialog_EngagedFourthReminder).
    Current Windows 11 builds usually will not raise that dialog on demand. When it does not appear,
    this script shows a close copy with Restart now, Schedule restart, and Close.

    Schedule restart opens the native scheduler (ms-settings:windowsupdate-restartoptions) when that
    page is actually the day/time picker. Otherwise it opens Windows Update and tells the user to
    open the arrow (caret) beside Restart now and choose Schedule restart.

    Run in the signed-in user's session. Intune: "Run this script using the logged-on credentials" = Yes
    and "Run script in 64-bit PowerShell" = Yes. A restart happens only if the user clicks Restart now.

.PARAMETER Preview
    Shows the recreated dialog even when no update restart is pending. Does not restart the device.
    Intune must not pass this switch.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Show-UpdateRestartPrompt.ps1

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Show-UpdateRestartPrompt.ps1 -Preview
#>
param([switch]$Preview)

$ErrorActionPreference = 'Stop'

# Relaunch into 64-bit Windows PowerShell on an STA thread. WPF needs STA, and a 32-bit host
# would look for MusNotificationUx.exe under SysWOW64, where it does not exist.
if (-not $PSCommandPath) {
    Write-Output 'Error: run this script with -File so it can relaunch itself'
    exit 1
}

$isWindowsPowerShell = ($PSVersionTable.PSEdition -eq 'Desktop')
$isWow64 = [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess
$needSta = [Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA
if (-not $env:UPDATE_RESTART_PROMPT_RELAUNCHED -and (-not $isWindowsPowerShell -or $isWow64 -or $needSta)) {
    $systemRoot = if ($isWow64) { Join-Path $env:SystemRoot 'Sysnative' } else { Join-Path $env:SystemRoot 'System32' }
    $powershell = Join-Path $systemRoot 'WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell)) {
        Write-Output 'Error: 64-bit Windows PowerShell was not found'
        exit 1
    }
    $env:UPDATE_RESTART_PROMPT_RELAUNCHED = '1'
    $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Preview) { $argList += '-Preview' }
    try {
        $child = Start-Process -FilePath $powershell -ArgumentList $argList -Wait -PassThru -WindowStyle Hidden
    } catch {
        Remove-Item Env:\UPDATE_RESTART_PROMPT_RELAUNCHED -ErrorAction SilentlyContinue
        Write-Output ('Error: could not relaunch in 64-bit Windows PowerShell ({0})' -f $_.Exception.Message)
        exit 1
    }
    exit $child.ExitCode
}
if ($needSta) {
    Write-Output 'Error: the dialog needs an STA thread (Windows PowerShell 5.1 with -STA)'
    exit 1
}

function Test-InteractiveUser {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.IsSystem) { return $false }
    return [Environment]::UserInteractive
}

function Get-UpdateRestartReason {
    # Windows Update's own answer only. Do not treat PendingFileRenameOperations, RunOnce,
    # or a CBS reboot key by itself as an update restart.
    $rebootKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    if (Test-Path -LiteralPath $rebootKey) {
        return 'Windows Update RebootRequired registry key is present'
    }
    try {
        $systemInfo = New-Object -ComObject Microsoft.Update.SystemInfo
        if ($systemInfo.RebootRequired) {
            return 'Windows Update reports a restart is required to finish installing updates'
        }
    } catch {
        return $null
    }
    return $null
}

function Get-MusNotificationUxPath {
    $path = Join-Path $env:SystemRoot 'System32\MusNotificationUx.exe'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $full = [IO.Path]::GetFullPath($path)
    $system32 = [IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32'))
    if (-not $full.StartsWith($system32, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $full
    } catch {
        return $null
    }
    if ($signature.Status -ne 'Valid') { return $null }
    $subject = [string]$signature.SignerCertificate.Subject
    if ($subject -notmatch 'O=Microsoft (Corporation|Windows)') { return $null }
    return $full
}

function Stop-StartedProcess($Process) {
    if (-not $Process) { return }
    try {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction Stop
        }
    } catch { }
}

function Test-EngagedWindowTitle([string]$Title) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return $true }
    # A download, EULA, or failure dialog is not the engaged restart prompt. Reject it.
    return $Title -notmatch '(?i)download|eula|agreement|failed|cannot install|can.t install'
}

function Test-VisibleWindow([IntPtr]$Handle) {
    if ($Handle -eq [IntPtr]::Zero) { return $false }
    try {
        if (-not ('UpdateRestartPrompt.User32' -as [type])) {
            Add-Type -Namespace UpdateRestartPrompt -Name User32 -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool IsWindowVisible(IntPtr hWnd);
'@
        }
        return [UpdateRestartPrompt.User32]::IsWindowVisible($Handle)
    } catch {
        # If this check cannot be compiled, a non-zero handle is the best signal available.
        return $true
    }
}

function Test-NativeEngagedDialogVisible {
    param($Process, [datetime]$StartedAt)

    $deadline = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $deadline) {
        try { $Process.Refresh() } catch { return $false }
        if ((Test-VisibleWindow $Process.MainWindowHandle) -and (Test-EngagedWindowTitle $Process.MainWindowTitle)) {
            return $true
        }
        # The UX host sometimes exits after handing the window to a second MusNotificationUx process.
        try {
            $siblings = Get-Process -Name 'MusNotificationUx' -ErrorAction SilentlyContinue
            foreach ($sibling in $siblings) {
                if ($sibling.Id -eq $Process.Id) { continue }
                $started = $null
                try { $started = $sibling.StartTime } catch { continue }
                if ($started -ge $StartedAt.AddSeconds(-2) -and (Test-VisibleWindow $sibling.MainWindowHandle)) {
                    if (Test-EngagedWindowTitle $sibling.MainWindowTitle) { return $true }
                }
            }
        } catch { }
        if ($Process.HasExited) { return $false }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Try-ShowNativeEngagedDialog {
    # Reminder dialogs only. Forced, imminent, and RebootWithUX switches restart the device
    # without asking, so they are not used here.
    $exe = Get-MusNotificationUxPath
    if (-not $exe) { return $false }

    $dialogs = @(
        'Dialog_EnhancedEngagedRebootReminder',
        'Dialog_EngagedFourthReminder'
    )
    foreach ($name in $dialogs) {
        $startedAt = Get-Date
        try {
            $process = Start-Process -FilePath $exe -ArgumentList @($name, '0') -PassThru -WindowStyle Normal
        } catch {
            continue
        }
        if (Test-NativeEngagedDialogVisible -Process $process -StartedAt $startedAt) {
            return $true
        }
        Stop-StartedProcess $process
    }
    return $false
}

function Test-SettingsSchedulePicker {
    # Looks for the native "Schedule the restart" page (Pick a day + Pick a time, or Schedule a time).
    # Runs off the UI thread. A miss is treated as "the picker is not open".
    $probe = [powershell]::Create()
    [void]$probe.AddScript({
        Add-Type -AssemblyName UIAutomationClient
        function Get-SettingsLabels {
            $root = [System.Windows.Automation.AutomationElement]::RootElement
            $windowCondition = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::NameProperty, 'Settings')
            $window = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $windowCondition)
            if (-not $window) { return @() }
            $text = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Text)
            $combo = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::ComboBox)
            $either = New-Object System.Windows.Automation.OrCondition($text, $combo)
            $elements = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $either)
            $labels = New-Object System.Collections.Generic.List[string]
            foreach ($element in $elements) {
                try {
                    $name = [string]$element.Current.Name
                    if ($name) { $labels.Add($name.Trim().ToLowerInvariant()) }
                } catch { }
            }
            return $labels
        }

        foreach ($waitMs in 1500, 2000) {
            Start-Sleep -Milliseconds $waitMs
            $labels = @(Get-SettingsLabels)
            $hasTime = $labels -contains 'pick a time'
            $hasDay = $labels -contains 'pick a day'
            $hasToggle = $labels -contains 'schedule a time'
            if (($hasTime -and $hasDay) -or $hasToggle) { return $true }
        }
        return $false
    })

    $handle = $probe.BeginInvoke()
    if (-not $handle.AsyncWaitHandle.WaitOne(8000)) {
        try { $probe.Stop() } catch { }
        $probe.Dispose()
        return $false
    }
    $found = $false
    try { $found = [bool]($probe.EndInvoke($handle) | Select-Object -Last 1) } catch { $found = $false }
    $probe.Dispose()
    return $found
}

function Open-SettingsPage([string]$Uri) {
    Start-Process $Uri | Out-Null
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Restart required" Width="560" SizeToContent="Height"
        WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="NoResize"
        AllowsTransparency="True" Background="Transparent" Topmost="True" ShowInTaskbar="True"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14" Foreground="#1A1A1A"
        UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="DialogButton" TargetType="Button">
      <Setter Property="Background" Value="#FBFBFB"/>
      <Setter Property="Foreground" Value="#1A1A1A"/>
      <Setter Property="BorderBrush" Value="#CCCCCC"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,7"/>
      <Setter Property="MinWidth" Value="120"/>
      <Setter Property="MinHeight" Value="32"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Opacity" Value="0.88"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Chrome" Property="Opacity" Value="0.72"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Chrome" Property="Opacity" Value="0.55"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Chrome" Property="BorderBrush" Value="#1A1A1A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource DialogButton}">
      <Setter Property="Background" Value="#005FB8"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#005FB8"/>
    </Style>
  </Window.Resources>

  <Grid Margin="20">
    <Border x:Name="ShadowBorder" Background="#FFFFFF" CornerRadius="8">
      <Border.Effect>
        <DropShadowEffect BlurRadius="28" ShadowDepth="6" Direction="270" Opacity="0.28"/>
      </Border.Effect>
    </Border>
    <Border x:Name="CardBorder" Background="#FFFFFF" CornerRadius="8" BorderBrush="#E0E0E0" BorderThickness="1">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Margin="28,24,28,22">
          <Grid Margin="0,0,0,14">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="IconGlyph" Grid.Column="0" Text="&#xE895;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"
                       FontSize="30" Foreground="#005FB8" VerticalAlignment="Center" Margin="0,0,16,0"/>
            <StackPanel Grid.Column="1" VerticalAlignment="Center">
              <TextBlock x:Name="TitleText" Text="Restart required" FontSize="20" FontWeight="SemiBold"/>
              <TextBlock x:Name="SubtitleText" Text="Windows Update" FontSize="12" Foreground="#616161" Margin="0,2,0,0"/>
            </StackPanel>
          </Grid>

          <TextBlock x:Name="BodyText" TextWrapping="Wrap" LineHeight="22"/>
          <TextBlock x:Name="ErrorText" Foreground="#C42B1C" TextWrapping="Wrap" Margin="0,12,0,0" Visibility="Collapsed"/>
        </StackPanel>

        <Border x:Name="FooterBorder" Grid.Row="1" Background="#F3F3F3" BorderBrush="#E5E5E5" BorderThickness="0,1,0,0"
                CornerRadius="0,0,7,7" Padding="20,16,28,16">
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="NowBtn" Content="Restart now" Style="{StaticResource AccentButton}" Margin="0"/>
            <Button x:Name="ScheduleBtn" Content="Schedule restart" Style="{StaticResource DialogButton}"/>
            <Button x:Name="CloseBtn" Content="Close" Style="{StaticResource DialogButton}" IsCancel="True"/>
          </StackPanel>
        </Border>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

function Get-AppsUseLightTheme {
    try {
        $value = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop).AppsUseLightTheme
        return ([int]$value -ne 0)
    } catch {
        return $true
    }
}

function Get-AccentColor {
    try {
        $dword = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'AccentColor' -ErrorAction Stop).AccentColor
        $bytes = [BitConverter]::GetBytes([uint32]$dword)
        $alpha = $bytes[3]
        if ($alpha -eq 0) { $alpha = 255 }
        return [System.Windows.Media.Color]::FromArgb($alpha, $bytes[0], $bytes[1], $bytes[2])
    } catch {
        return [System.Windows.Media.Color]::FromRgb(0, 95, 184)
    }
}

if (-not $Preview) {
    if (-not (Test-InteractiveUser)) {
        Write-Output 'Error: run this in the signed-in user session so the prompt can be shown'
        exit 1
    }
    $restartReason = Get-UpdateRestartReason
    if (-not $restartReason) {
        Write-Output 'OK: no update restart is pending, so the prompt was not shown'
        exit 0
    }
}

$mutex = [System.Threading.Mutex]::new($false, 'Local\UpdateRestartPrompt')
$haveLock = $false
try { $haveLock = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $haveLock = $true }
if (-not $haveLock) {
    $mutex.Dispose()
    Write-Output 'Skipped: the restart prompt is already open'
    exit 0
}

try {
    if (-not $Preview) {
        if (Try-ShowNativeEngagedDialog) {
            Write-Output 'Shown: native engaged restart dialog'
            exit 0
        }
        Write-Output ('Native engaged restart dialog did not appear ({0}); showing the recreated prompt' -f $restartReason)
    }

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    $window = [Windows.Markup.XamlReader]::Parse($xaml)
    $ui = @{}
    foreach ($name in 'ShadowBorder', 'CardBorder', 'IconGlyph', 'TitleText', 'SubtitleText', 'BodyText', 'ErrorText', 'FooterBorder', 'NowBtn', 'ScheduleBtn', 'CloseBtn') {
        $ui[$name] = $window.FindName($name)
    }

    $light = Get-AppsUseLightTheme
    $accent = Get-AccentColor
    $accentBrush = [System.Windows.Media.SolidColorBrush]::new($accent)
    # Black text on a pale accent, white text on a dark one, matching Windows accent buttons.
    $accentLuma = (0.2126 * $accent.R) + (0.7152 * $accent.G) + (0.0722 * $accent.B)
    $accentText = if ($accentLuma -gt 160) { [System.Windows.Media.Brushes]::Black } else { [System.Windows.Media.Brushes]::White }
    $ui.IconGlyph.Foreground = $accentBrush
    $ui.NowBtn.Background = $accentBrush
    $ui.NowBtn.BorderBrush = $accentBrush
    $ui.NowBtn.Foreground = $accentText

    if (-not $light) {
        $card = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(44, 44, 44))
        $footer = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(32, 32, 32))
        $edge = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(63, 63, 63))
        $button = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(59, 59, 59))
        $text = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(255, 255, 255))
        $muted = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(208, 208, 208))
        $ui.ShadowBorder.Background = $card
        $ui.CardBorder.Background = $card
        $ui.CardBorder.BorderBrush = $edge
        $ui.FooterBorder.Background = $footer
        $ui.FooterBorder.BorderBrush = $edge
        $window.Foreground = $text
        $ui.TitleText.Foreground = $text
        $ui.SubtitleText.Foreground = $muted
        $ui.BodyText.Foreground = $text
        foreach ($buttonName in 'ScheduleBtn', 'CloseBtn') {
            $ui[$buttonName].Background = $button
            $ui[$buttonName].Foreground = $text
            $ui[$buttonName].BorderBrush = $edge
        }
    }

    if ($Preview) {
        $ui.SubtitleText.Text = 'Preview only. Restart now will not restart this device.'
    }
    $ui.BodyText.Text = 'To finish installing updates, this device needs to restart. Restart now, or schedule a restart for a time that works for you.'

    $script:Choice = $null
    $script:ScheduleMode = 'ask'

    function Show-DialogError([string]$Message) {
        $ui.ErrorText.Text = $Message
        $ui.ErrorText.Visibility = 'Visible'
    }

    function Show-ScheduleGuide {
        $ui.TitleText.Text = 'Schedule the restart'
        $ui.BodyText.Text = @(
            'Windows Update is open.'
            ''
            'The day and time picker did not open on its own. Schedule the restart from that page:'
            '1. Select the small arrow (caret) beside Restart now.'
            '2. Select Schedule restart. It may be labeled Pick a time.'
            '3. Choose a day and time, then confirm.'
        ) -join [Environment]::NewLine
        $ui.ScheduleBtn.Content = 'Open Windows Update'
        $script:ScheduleMode = 'guide'
        $window.Topmost = $true
        $window.Dispatcher.BeginInvoke([Action]{
            $window.UpdateLayout()
            $area = [System.Windows.SystemParameters]::WorkArea
            $window.Left = [Math]::Max($area.Left, $area.Right - $window.ActualWidth - 24)
            $window.Top = [Math]::Max($area.Top, $area.Bottom - $window.ActualHeight - 24)
            [void]$window.Activate()
        }, [Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
    }

    function Invoke-ScheduleRestart {
        try {
            try {
                Open-SettingsPage 'ms-settings:windowsupdate-restartoptions'
            } catch {
                Show-DialogError 'Windows could not open restart options. Opening Windows Update instead.'
                try { Open-SettingsPage 'ms-settings:windowsupdate' } catch { }
                Show-ScheduleGuide
                return
            }

            # Both labels together mean the native day/time page is up. Either label alone can
            # appear in ordinary Windows Update text, so that does not count.
            if (Test-SettingsSchedulePicker) {
                $script:Choice = 'NativeSchedule'
                $window.Close()
                return
            }

            try { Open-SettingsPage 'ms-settings:windowsupdate' } catch {
                Show-DialogError 'Windows Update could not be opened. Open Settings, then Windows Update, and use the steps below.'
            }
            Show-ScheduleGuide
        } catch {
            Show-DialogError 'The schedule page could not be opened. Use the arrow beside Restart now on the Windows Update page.'
            Show-ScheduleGuide
        } finally {
            if ($script:ScheduleMode -eq 'guide') { $ui.ScheduleBtn.IsEnabled = $true }
        }
    }

    $ui.NowBtn.Add_Click({
        $ui.ErrorText.Visibility = 'Collapsed'
        if ($Preview) {
            $script:Choice = 'RestartNow'
            $window.Close()
            return
        }
        $ui.NowBtn.IsEnabled = $false
        $ui.NowBtn.Content = 'Restarting...'
        try {
            $shutdown = Join-Path $env:SystemRoot 'System32\shutdown.exe'
            & $shutdown /r /t 0 /d p:2:17 /c 'Restarting to finish installing updates.'
            if ($LASTEXITCODE -ne 0) {
                throw "shutdown.exe exited with $LASTEXITCODE"
            }
        } catch {
            $ui.NowBtn.IsEnabled = $true
            $ui.NowBtn.Content = 'Restart now'
            Show-DialogError ("Windows did not start the restart ({0})." -f $_.Exception.Message)
            return
        }
        $script:Choice = 'RestartNow'
        $window.Close()
    })

    $ui.ScheduleBtn.Add_Click({
        if ($script:ScheduleMode -eq 'guide') {
            try {
                Open-SettingsPage 'ms-settings:windowsupdate'
                $ui.ErrorText.Visibility = 'Collapsed'
            } catch {
                Show-DialogError 'Windows Update could not be opened. Open Settings and select Windows Update.'
            }
            return
        }
        # Paint "Opening..." before the picker check blocks this thread.
        $ui.ErrorText.Visibility = 'Collapsed'
        $ui.ScheduleBtn.IsEnabled = $false
        $ui.ScheduleBtn.Content = 'Opening...'
        $window.Dispatcher.BeginInvoke([Action]{ Invoke-ScheduleRestart }, [Windows.Threading.DispatcherPriority]::Background) | Out-Null
    })

    $ui.CloseBtn.Add_Click({
        $script:Choice = 'Close'
        $window.Close()
    })

    $window.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch { } })
    $window.Add_Loaded({ [void]$window.Activate(); [void]$ui.CloseBtn.Focus() })
    $window.Add_Closing({ if (-not $script:Choice) { $script:Choice = 'Close' } })

    [void]$window.ShowDialog()

    switch ($script:Choice) {
        'RestartNow' {
            if ($Preview) { Write-Output 'Preview: Restart now was clicked. The device was not restarted.' }
            else { Write-Output 'Restart now: the user restarted to finish installing updates' }
        }
        'NativeSchedule' { Write-Output 'Schedule restart: opened the native restart options page' }
        'Close' { Write-Output 'Closed: the user dismissed the prompt. It will show again on the next run while a restart is still required.' }
        default { Write-Output 'Closed: the prompt was dismissed' }
    }
    exit 0
} catch {
    Write-Output ('Error: {0}' -f $_.Exception.Message)
    exit 1
} finally {
    if ($haveLock) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
