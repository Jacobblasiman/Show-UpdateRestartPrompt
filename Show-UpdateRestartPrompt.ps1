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

    The built-in engaged dialog always opens in the center and cannot be moved, so this script
    does not launch it. The card is placed at the bottom-right before it is shown. Schedule
    restart opens the native picker and turns the card into a closeable corner guide. The
    restart must be at a time when the PC will be on, awake, and online. It cannot be scheduled
    during downtime.

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

function Open-SettingsPage([string]$Uri) {
    Start-Process $Uri | Out-Null
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Restart required" Width="460" SizeToContent="Height"
        WindowStartupLocation="Manual" WindowStyle="None" ResizeMode="NoResize"
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
                CornerRadius="0,0,7,7" Padding="16,14,20,14">
          <WrapPanel HorizontalAlignment="Right" Orientation="Horizontal">
            <Button x:Name="NowBtn" Content="Restart now" Style="{StaticResource AccentButton}" Margin="0,4,0,0"/>
            <Button x:Name="ScheduleBtn" Content="Schedule restart" Style="{StaticResource DialogButton}" Margin="8,4,0,0"/>
            <Button x:Name="CloseBtn" Content="Close" Style="{StaticResource DialogButton}" Margin="8,4,0,0" IsCancel="True"/>
          </WrapPanel>
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
    # Do not launch MusNotificationUx. That dialog is centered and cannot be moved,
    # so the corner card would never appear on machines where it still opens.
    if ($Preview) {
        Write-Output 'Preview: showing the corner restart prompt'
    } else {
        Write-Output ('Showing the corner restart prompt ({0})' -f $restartReason)
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
    $ui.BodyText.Text = 'To finish installing updates, this device needs to restart. Restart now, or schedule it for a time when this PC will be on, awake, and online.'

    $script:Choice = $null
    $script:OpenedPicker = $false
    $script:PinCorner = $true
    $script:MovingWindow = $false

    function Move-ToBottomRight {
        if (-not $script:PinCorner -or $script:MovingWindow) { return }
        $script:MovingWindow = $true
        try {
            $window.UpdateLayout()
            $area = [System.Windows.SystemParameters]::WorkArea
            $width = $window.ActualWidth
            $height = $window.ActualHeight
            if ($width -lt 1) { $width = $window.Width + 40 }
            if ($height -lt 1) { $height = 220 }
            $window.Left = [Math]::Max($area.Left, $area.Right - $width - 16)
            $window.Top = [Math]::Max($area.Top, $area.Bottom - $height - 16)
        } finally {
            $script:MovingWindow = $false
        }
    }

    function Show-DialogError([string]$Message) {
        $ui.ErrorText.Text = $Message
        $ui.ErrorText.Visibility = 'Visible'
        $window.Dispatcher.BeginInvoke([Action]{ Move-ToBottomRight }, [Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
    }

    function Show-ScheduleGuide {
        $ui.TitleText.Text = 'How to use the picker'
        $ui.SubtitleText.Text = 'Close this when you are done. It stays in the corner so you can still use the picker.'
        $ui.BodyText.Text = @(
            'The schedule picker is open.'
            ''
            '1. Turn on Schedule a time if that switch is off.'
            '2. Select Pick a day and choose the day.'
            '3. Select Pick a time and choose the time.'
            '4. Select Schedule restart if that button is shown. If it is not, the time is saved when both lists are set. Windows Update then shows the time you picked.'
            ''
            'Pick a time when this PC will be powered on, awake, and online. The restart cannot be scheduled during downtime. If the PC will be shut down, asleep, or unavailable, Windows will not finish the update then.'
            ''
            'If those lists are not on the page, select the arrow beside Restart now, then select Schedule restart, and follow the steps above.'
        ) -join [Environment]::NewLine
        $ui.ScheduleBtn.Content = 'Show picker again'
        $ui.ScheduleBtn.IsEnabled = $true
        $ui.NowBtn.IsEnabled = $true
        $ui.CloseBtn.IsEnabled = $true
        $script:OpenedPicker = $true
        # Stay in the corner, above the desktop, without taking over the picker.
        $window.Topmost = $true
        $window.Dispatcher.BeginInvoke([Action]{ Move-ToBottomRight }, [Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
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
        $ui.ErrorText.Visibility = 'Collapsed'
        try {
            Open-SettingsPage 'ms-settings:windowsupdate-restartoptions'
        } catch {
            try { Open-SettingsPage 'ms-settings:windowsupdate' } catch { }
            Show-DialogError 'The schedule picker could not be opened directly. Use the arrow beside Restart now.'
        }
        Show-ScheduleGuide
    })

    $ui.CloseBtn.Add_Click({
        $script:Choice = 'Close'
        $window.Close()
    })

    $window.Add_MouseLeftButtonDown({
        $script:PinCorner = $false
        try { $window.DragMove() } catch { }
    })
    $window.Add_SizeChanged({ Move-ToBottomRight })
    $window.Add_Loaded({
        Move-ToBottomRight
        [void]$window.Activate()
        [void]$ui.CloseBtn.Focus()
    })
    $window.Add_ContentRendered({
        Move-ToBottomRight
        # SizeToContent recenters a Manual window after the first layout. Pin the corner, then allow height to follow the text.
        $window.Dispatcher.BeginInvoke([Action]{
            Move-ToBottomRight
        }, [Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
    })

    # First frame is already in the corner. Unset Left/Top makes WPF choose the center.
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $window.Left = [Math]::Max($workArea.Left, $workArea.Right - ($window.Width + 40) - 16)
    $window.Top = [Math]::Max($workArea.Top, $workArea.Bottom - 240 - 16)
    $window.Add_Closing({ if (-not $script:Choice) { $script:Choice = 'Close' } })

    [void]$window.ShowDialog()

    switch ($script:Choice) {
        'RestartNow' {
            if ($Preview) { Write-Output 'Preview: Restart now was clicked. The device was not restarted.' }
            else { Write-Output 'Restart now: the user restarted to finish installing updates' }
        }
        'Close' {
            if ($script:OpenedPicker) {
                Write-Output 'Schedule restart: opened the picker. The corner guide was then closed.'
            } else {
                Write-Output 'Closed: the user dismissed the prompt. It will show again on the next run while a restart is still required.'
            }
        }
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
