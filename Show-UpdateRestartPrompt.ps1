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

$ScriptVersion = '1.9'

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

function Test-RegistryKey([string]$Path) {
    return (Test-Path -LiteralPath $Path)
}

function Test-NonZeroDword([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item -or ($item.PSObject.Properties.Name -notcontains $Name)) { return $false }
    return ([int]$item.$Name) -ne 0
}

function Get-UpdateRestartReason {
    # Shows as soon as Windows is waiting on a restart, including before the Intune deadline.
    # The deadline is only displayed on the card. PendingFileRenameOperations and RunOnce are
    # ignored: Edge and OneDrive set those without a Windows Update restart.
    # The legacy RebootRequired key and SystemInfo.RebootRequired miss some Windows 11 restarts
    # that servicing and Update Orchestrator record elsewhere, so every update-servicing signal is checked.
    $checks = @(
        @{ Label = 'Windows Update RebootRequired registry key'; Test = { Test-RegistryKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' } }
        @{ Label = 'Windows Update agent RebootRequired'; Test = {
            try { return [bool](New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired } catch { return $false }
        } }
        @{ Label = 'component servicing RebootPending'; Test = { Test-RegistryKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' } }
        @{ Label = 'component servicing PackagesPending'; Test = { Test-RegistryKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending' } }
        @{ Label = 'Windows Update servicing pending'; Test = { Test-RegistryKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Services\Pending' } }
        @{ Label = 'update installer volatile reboot flag'; Test = { Test-NonZeroDword 'HKLM:\SOFTWARE\Microsoft\Updates\UpdateExeVolatile' 'Flags' } }
        @{ Label = 'Update Orchestrator reboot marker'; Test = { Test-RegistryKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\RebootRequired' } }
        @{ Label = 'Windows Update UX reboot flag'; Test = { Test-NonZeroDword 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'RebootRequired' } }
    )
    foreach ($check in $checks) {
        if (& $check.Test) { return $check.Label }
    }

    $ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    if (Test-Path -LiteralPath $ux) {
        $item = Get-ItemProperty -LiteralPath $ux -ErrorAction SilentlyContinue
        if ($item -and ($item.PSObject.Properties.Name -contains 'PendingRebootStartTime')) {
            $pendingSince = ConvertTo-LocalDate $item.PendingRebootStartTime
            $boot = $null
            try { $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { }
            if ($pendingSince -and ((-not $boot) -or ($pendingSince -gt $boot))) {
                return 'Windows Update recorded PendingRebootStartTime for this boot'
            }
        }
    }

    try {
        $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'
            Id = 21, 22
            StartTime = $boot
        } -ErrorAction Stop)
        if ($events.Count -gt 0) { return 'Windows Update logged a restart-required event since the last boot' }
    } catch { }

    try {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $result = $searcher.Search('RebootRequired=1')
        if ($result.Updates.Count -gt 0) { return 'Windows Update lists an update whose installation needs a restart' }
    } catch { }

    return $null
}

function Get-EnforcedDword([string]$Name) {
    # Intune writes the winning value under PolicyManager. A value counts only when a provider owns it.
    # Group Policy writes the same names under the WindowsUpdate policy key. If those two disagree,
    # there is no single enforced number.
    $mdmPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update'
    $gpoPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $mdm = $null
    $provider = $null
    if (Test-Path -LiteralPath $mdmPath) {
        $item = Get-ItemProperty -LiteralPath $mdmPath
        if ($item.PSObject.Properties.Name -contains $Name) {
            $mdm = [int]$item.$Name
            $providerName = $Name + '_WinningProvider'
            if ($item.PSObject.Properties.Name -contains $providerName) {
                $provider = [string]$item.$providerName
            }
        }
    }
    $gpo = $null
    if (Test-Path -LiteralPath $gpoPath) {
        $item = Get-ItemProperty -LiteralPath $gpoPath
        if ($item.PSObject.Properties.Name -contains $Name) { $gpo = [int]$item.$Name }
    }
    $mdmEnforced = ($null -ne $mdm -and -not [string]::IsNullOrWhiteSpace($provider))
    if ($mdmEnforced -and $null -ne $gpo -and $gpo -ne $mdm) {
        return @{ Conflict = $true }
    }
    if ($mdmEnforced) { return @{ Conflict = $false; Value = $mdm; Source = 'Intune' } }
    if ($null -ne $gpo) { return @{ Conflict = $false; Value = $gpo; Source = 'Group Policy' } }
    return $null
}

function ConvertTo-LocalDate($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        $date = $Value
    } elseif ($Value -is [byte[]]) {
        return $null
    } else {
        $number = 0L
        if ([int64]::TryParse([string]$Value, [ref]$number) -and $number -gt 10000000000000000) {
            try { return [datetime]::FromFileTime($number) } catch { return $null }
        }
        $parsed = [datetime]::MinValue
        $styles = [Globalization.DateTimeStyles]::RoundtripKind -bor [Globalization.DateTimeStyles]::AllowWhiteSpaces
        if (-not [datetime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
            return $null
        }
        $date = $parsed
    }
    if ($date.Year -lt 2020 -or $date.Year -gt 2100) { return $null }
    if ($date.Kind -eq [DateTimeKind]::Utc) { return $date.ToLocalTime() }
    return $date
}

function Format-Duration([TimeSpan]$Span) {
    if ($Span.TotalSeconds -lt 0) { $Span = [TimeSpan]::Zero }
    if ($Span.TotalMinutes -lt 1) { return 'less than a minute' }
    $days = [int][Math]::Floor($Span.TotalDays)
    $hours = $Span.Hours
    $minutes = $Span.Minutes
    $parts = @()
    if ($days -eq 1) { $parts += '1 day' } elseif ($days -gt 1) { $parts += "$days days" }
    if ($hours -eq 1) { $parts += '1 hour' } elseif ($hours -gt 1) { $parts += "$hours hours" }
    if ($days -eq 0 -and $minutes -gt 0) {
        if ($minutes -eq 1) { $parts += '1 minute' } else { $parts += "$minutes minutes" }
    }
    if ($parts.Count -eq 0) { return 'less than a minute' }
    return ($parts -join ' ')
}

function Get-RebootRequiredUpdates {
    $updates = @()
    try {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        foreach ($criteria in @('IsInstalled=1 and RebootRequired=1', 'IsInstalled=0 and RebootRequired=1')) {
            try {
                $result = $searcher.Search($criteria)
                foreach ($update in $result.Updates) { $updates += $update }
            } catch { }
        }
    } catch { }
    if ($updates.Count -gt 0) { return $updates }

    # The agent often will not list the update even though it logged that a restart is required.
    # The event text names the KB, which is enough to tell a quality update from a feature update.
    try {
        $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'
            Id = 21, 22
            StartTime = $boot
        } -ErrorAction Stop)
    } catch {
        return @()
    }
    foreach ($event in $events) {
        $message = [string]$event.Message
        $ids = @()
        foreach ($match in [regex]::Matches($message, 'KB(\d{6,8})')) { $ids += $match.Groups[1].Value }
        $title = ($message -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -First 1)
        if (-not $title) { $title = 'Windows Update' }
        $updates += [pscustomobject]@{ Title = [string]$title; KBArticleIDs = $ids; Categories = @() }
    }
    return $updates
}

function Get-UpdateKind($Update) {
    $names = @()
    try { foreach ($category in $Update.Categories) { $names += [string]$category.Name } } catch { }
    $title = [string]$Update.Title
    if (($names -contains 'Upgrades') -or ($names -contains 'Feature Packs') -or ($title -match '^Feature update')) { return 'Feature' }
    if (($names -contains 'Drivers') -or ($title -match 'driver')) { return 'Driver' }
    if (($names -contains 'Security Updates') -or ($names -contains 'Critical Updates') -or ($names -contains 'Update Rollups') -or ($names -contains 'Updates') -or ($title -match 'Cumulative|\.NET')) { return 'Quality' }
    return 'Other'
}

function ConvertFrom-UnixMilliseconds($Value) {
    if ($null -eq $Value -or [string]$Value -eq '') { return $null }
    $number = 0L
    if (-not [int64]::TryParse(([string]$Value).Trim(), [ref]$number)) { return $null }
    # Windows stores these UX times as Unix milliseconds, not FILETIME.
    if ($number -lt 1000000000000) { return $null }
    try { return [DateTimeOffset]::FromUnixTimeMilliseconds($number).LocalDateTime } catch { return $null }
}

function Get-WindowsRebootState {
    # Windows records the current pending restart here. IsCurrentRebootFeature 0 is a quality update.
    $path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\StateVariables'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $state = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
    if (-not $state -or ($state.PSObject.Properties.Name -notcontains 'CurrentRebootRecognitionTime')) { return $null }
    $recognized = ConvertFrom-UnixMilliseconds $state.CurrentRebootRecognitionTime
    if (-not $recognized) { return $null }
    $kind = 'Quality'
    if ($state.PSObject.Properties.Name -contains 'IsCurrentRebootFeature' -and [int]$state.IsCurrentRebootFeature -ne 0) {
        $kind = 'Feature'
    }
    return @{ Recognized = $recognized; Kind = $kind }
}

function Get-PendingRestartTime {
    # The Update session stores the real start of this pending restart. Prefer that over any estimate.
    $windowsState = Get-WindowsRebootState
    if ($windowsState) {
        return @{
            Time = $windowsState.Recognized
            SpreadMinutes = 0
            Note = $null
            Authoritative = $true
            Kind = $windowsState.Kind
        }
    }
    # Grace starts when the restart became pending. A reboot that did not clear the pending
    # state must not throw away the earlier timestamp, or the cutoff cannot be calculated.
    $boot = $null
    try { $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { }
    $explicit = @()
    $ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    if (Test-Path -LiteralPath $ux) {
        $item = Get-ItemProperty -LiteralPath $ux -ErrorAction SilentlyContinue
        if ($item -and ($item.PSObject.Properties.Name -contains 'PendingRebootStartTime')) {
            $parsed = ConvertTo-LocalDate $item.PendingRebootStartTime
            if ($parsed) { $explicit += $parsed }
        }
    }
    $markers = @()
    foreach ($path in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Services\Pending'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\RebootRequired'
        'HKLM:\SOFTWARE\Microsoft\Updates\UpdateExeVolatile'
    )) {
        if (Test-Path -LiteralPath $path) { $markers += (Get-Item -LiteralPath $path).LastWriteTime }
    }
    $events = @()
    try {
        $found = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'
            Id = 21, 22
            StartTime = (Get-Date).AddDays(-45)
        } -ErrorAction Stop)
        foreach ($event in $found) { $events += $event.TimeCreated }
    } catch { }

    $afterBoot = @()
    $beforeBoot = @()
    foreach ($time in @($explicit + $markers + $events)) {
        if (-not $time) { continue }
        if ($boot -and $time -lt $boot.AddMinutes(-5)) { $beforeBoot += $time } else { $afterBoot += $time }
    }
    if ($afterBoot.Count -gt 0) {
        $sorted = @($afterBoot | Sort-Object)
        return @{ Time = $sorted[0]; SpreadMinutes = ($sorted[$sorted.Count - 1] - $sorted[0]).TotalMinutes; Note = $null }
    }
    if ($explicit.Count -gt 0) {
        $start = @($explicit | Sort-Object)[0]
        return @{ Time = $start; SpreadMinutes = 0; Note = ' This restart stayed pending through the last boot, so the cutoff is counted from when Windows first recorded it.' }
    }
    if ($markers.Count -gt 0) {
        $sorted = @($markers | Sort-Object)
        return @{ Time = $sorted[0]; SpreadMinutes = ($sorted[$sorted.Count - 1] - $sorted[0]).TotalMinutes; Note = ' This restart stayed pending through the last boot, so the cutoff is counted from when Windows wrote the pending-restart marker.' }
    }
    if ($beforeBoot.Count -gt 0) {
        $start = @($beforeBoot | Sort-Object)[-1]
        return @{ Time = $start; SpreadMinutes = 0; Note = ' The cutoff is counted from the last time Windows logged that a restart was required.' }
    }
    if ($boot) {
        return @{ Time = $boot; SpreadMinutes = 0; Note = ' Windows did not record when the restart became pending, so the cutoff is counted from the last boot. If it became pending earlier, Windows can force the restart sooner.' }
    }
    return $null
}

function Get-EarliestOfferTime([datetime]$RestartTime, [int]$DeadlineDays) {
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'
            StartTime = $RestartTime.AddDays(-1 * ([Math]::Max($DeadlineDays, 1) + 14))
        } -ErrorAction Stop)
    } catch {
        return $null
    }
    $found = @()
    foreach ($event in $events) {
        if ($event.Id -in 19, 20, 21, 22, 43) { continue }
        if ([string]$event.Message -notmatch '(?i)found|detected|offered|available') { continue }
        if ($event.TimeCreated -le $RestartTime.AddMinutes(5)) { $found += $event.TimeCreated }
    }
    if ($found.Count -eq 0) { return $null }
    return ($found | Sort-Object | Select-Object -First 1)
}

function Get-UpdateOfferTime($Update, [datetime]$RestartTime) {
    $needles = @()
    try { foreach ($kb in $Update.KBArticleIDs) { if ($kb) { $needles += [string]$kb } } } catch { }
    if ($needles.Count -eq 0) { return $null }
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'
            StartTime = $RestartTime.AddDays(-45)
        } -ErrorAction Stop)
    } catch {
        return $null
    }
    $found = @()
    foreach ($event in $events) {
        if ($event.Id -in 19, 20, 21, 22, 43) { continue }
        $message = [string]$event.Message
        if ($message -notmatch '(?i)found|detected|offered|available') { continue }
        $hit = $false
        foreach ($needle in $needles) {
            if ($message.Contains($needle)) { $hit = $true; break }
        }
        if ($hit -and $event.TimeCreated -le $RestartTime.AddMinutes(5)) { $found += $event.TimeCreated }
    }
    if ($found.Count -eq 0) { return $null }
    return ($found | Sort-Object | Select-Object -First 1)
}

function Get-ForcedRestart {
    # Microsoft's rule for the policies Intune enforces:
    # effective cutoff = the later of (scan discovery + deadline days) and (restart pending + grace days).
    # https://learn.microsoft.com/en-us/windows/deployment/update/wufb-compliancedeadlines
    # A missing policy is not treated as Microsoft's CSP default. An assumed default would not be the enforced value.
    $qualityDeadline = Get-EnforcedDword 'ConfigureDeadlineForQualityUpdates'
    $featureDeadline = Get-EnforcedDword 'ConfigureDeadlineForFeatureUpdates'
    $qualityGrace = Get-EnforcedDword 'ConfigureDeadlineGracePeriod'
    $featureGrace = Get-EnforcedDword 'ConfigureDeadlineGracePeriodForFeatureUpdates'
    $noAutoReboot = Get-EnforcedDword 'ConfigureDeadlineNoAutoReboot'
    foreach ($policy in @($qualityDeadline, $featureDeadline, $qualityGrace, $featureGrace, $noAutoReboot)) {
        if ($policy -and $policy.Conflict) {
            return @{ Text = 'The Intune deadline and the local Windows Update policy do not match, so no forced-restart time is shown.' }
        }
    }
    if (-not $qualityDeadline -and -not $featureDeadline) {
        return @{ Text = 'No deadline policy is enforced on this device, so Windows has not set a forced-restart time.' }
    }

    $restart = Get-PendingRestartTime
    if (-not $restart) {
        return @{ Text = 'Windows did not record when this restart became pending, so the forced-restart time is not shown.' }
    }

    $updates = @()
    $bindings = @()
    $unnamed = $false
    if ($restart.Authoritative) {
        $kind = $restart.Kind
        $deadlinePolicy = if ($kind -eq 'Feature') { $featureDeadline } else { $qualityDeadline }
        $gracePolicy = if ($kind -eq 'Feature') { $featureGrace } else { $qualityGrace }
        if ($deadlinePolicy -and $gracePolicy) {
            $deadlineDays = [int]$deadlinePolicy.Value
            $graceDays = [int]$gracePolicy.Value
            $graceEnd = $restart.Time.AddDays($graceDays)
            $offer = $null
            if ($graceDays -lt $deadlineDays) { $offer = Get-EarliestOfferTime $restart.Time $deadlineDays }
            if ($offer -and $offer.AddDays($deadlineDays) -gt $graceEnd) {
                $bindings += @{ Effective = $offer.AddDays($deadlineDays); Start = $offer; Days = $deadlineDays; Kind = $kind; DeadlineDays = $deadlineDays; GraceDays = $graceDays; Source = $deadlinePolicy.Source; FromWindows = $true }
            } else {
                $bindings += @{ Effective = $graceEnd; Start = $restart.Time; Days = $graceDays; Kind = $kind; DeadlineDays = $deadlineDays; GraceDays = $graceDays; Source = $gracePolicy.Source; FromWindows = $true }
            }
        }
    } else {
        $updates = @(Get-RebootRequiredUpdates)
    }
    foreach ($update in $updates) {
        $kind = Get-UpdateKind $update
        if ($kind -eq 'Driver') { continue }
        if ($kind -ne 'Feature' -and $kind -ne 'Quality') { continue }
        $deadlinePolicy = if ($kind -eq 'Feature') { $featureDeadline } else { $qualityDeadline }
        if (-not $deadlinePolicy) {
            return @{ Text = "The pending $kind update has no enforced deadline, so the forced-restart time is not shown." }
        }
        $gracePolicy = if ($kind -eq 'Feature') { $featureGrace } else { $qualityGrace }
        if (-not $gracePolicy) {
            return @{ Text = "The $kind-update grace period is not set on this device, so the forced-restart time is not shown." }
        }
        $deadlineDays = [int]$deadlinePolicy.Value
        $graceDays = [int]$gracePolicy.Value
        $offer = $null
        if ($graceDays -lt $deadlineDays) {
            $offer = Get-UpdateOfferTime $update $restart.Time
            if (-not $offer) { continue }
        }
        $graceEnd = $restart.Time.AddDays($graceDays)
        if ($null -ne $offer) {
            $offerEnd = $offer.AddDays($deadlineDays)
            if ($offerEnd -gt $graceEnd) {
                $bindings += @{ Effective = $offerEnd; Start = $offer; Days = $deadlineDays; Kind = $kind; DeadlineDays = $deadlineDays; GraceDays = $graceDays; Source = $deadlinePolicy.Source }
                continue
            }
        }
        $bindings += @{ Effective = $graceEnd; Start = $restart.Time; Days = $graceDays; Kind = $kind; DeadlineDays = $deadlineDays; GraceDays = $graceDays; Source = $gracePolicy.Source }
    }

    if ($bindings.Count -eq 0) {
        # The update was not named, or its offer time was not recorded. Calculate each enforced
        # policy and show the soonest cutoff Windows is allowed to use.
        $unnamed = $true
        foreach ($kind in @('Quality', 'Feature')) {
            $deadlinePolicy = if ($kind -eq 'Feature') { $featureDeadline } else { $qualityDeadline }
            $gracePolicy = if ($kind -eq 'Feature') { $featureGrace } else { $qualityGrace }
            if (-not $deadlinePolicy -or -not $gracePolicy) { continue }
            $deadlineDays = [int]$deadlinePolicy.Value
            $graceDays = [int]$gracePolicy.Value
            $graceEnd = $restart.Time.AddDays($graceDays)
            if ($graceDays -ge $deadlineDays) {
                $bindings += @{ Effective = $graceEnd; Start = $restart.Time; Days = $graceDays; Kind = $kind; DeadlineDays = $deadlineDays; GraceDays = $graceDays; Source = $gracePolicy.Source }
                continue
            }
            $offer = Get-EarliestOfferTime $restart.Time $deadlineDays
            if (-not $offer) { continue }
            $offerEnd = $offer.AddDays($deadlineDays)
            if ($offerEnd -gt $graceEnd) {
                $bindings += @{ Effective = $offerEnd; Start = $offer; Days = $deadlineDays; Kind = $kind; DeadlineDays = $deadlineDays; GraceDays = $graceDays; Source = $deadlinePolicy.Source }
            } else {
                $bindings += @{ Effective = $graceEnd; Start = $restart.Time; Days = $graceDays; Kind = $kind; DeadlineDays = $deadlineDays; GraceDays = $graceDays; Source = $gracePolicy.Source }
            }
        }
    }

    if ($bindings.Count -eq 0) {
        return @{ Text = 'A restart is required, but the enforced deadline could not be calculated from the policy on this device.' }
    }
    # Do not pipe the entries. PowerShell enumerates a hashtable, and the date is then null.
    $binding = $null
    foreach ($candidate in $bindings) {
        if (-not $candidate.Effective) { continue }
        if (-not $binding -or $candidate.Effective -lt $binding.Effective) { $binding = $candidate }
    }
    if (-not $binding) {
        return @{ Text = 'A restart is required, but the enforced deadline could not be calculated from the policy on this device.' }
    }
    $now = Get-Date
    $length = $binding.Effective - $binding.Start
    $elapsed = $now - $binding.Start
    $remaining = $binding.Effective - $now
    $fraction = 1.0
    if ($length.TotalSeconds -gt 0) {
        $fraction = [Math]::Min(1.0, [Math]::Max(0.0, $elapsed.TotalSeconds / $length.TotalSeconds))
    }
    $when = '{0} at {1}' -f $binding.Effective.ToString('dddd, MMMM d, yyyy'), $binding.Effective.ToString('t')
    $kindName = if ($binding.Kind -eq 'Feature') { 'feature' } else { 'quality' }
    $policyLine = '{0} is enforcing a {1}-day {2}-update deadline and a {3}-day grace period. The cutoff is the later of those two clocks.' -f $binding.Source, $binding.DeadlineDays, $kindName, $binding.GraceDays
    if ($binding.FromWindows -and $binding.Start -eq $restart.Time) {
        $policyLine = 'Windows recorded this {0}-update restart at {1}. {2} adds a {3}-day grace period. That is the forced-restart time Windows shows.' -f $kindName, $restart.Time.ToString('g'), $binding.Source, $binding.GraceDays
    }
    if ($unnamed) {
        $policyLine += ' The pending update was not named, so this is the soonest cutoff of the enforced policies.'
    }
    if ($restart.Note) { $policyLine += $restart.Note }
    elseif ($restart.SpreadMinutes -gt 2) {
        $policyLine += ' Windows recorded more than one start time; the earlier one is used.'
    }
    if ($noAutoReboot -and [int]$noAutoReboot.Value -eq 0) {
        $policyLine += ' Windows may still restart outside active hours before that cutoff.'
    }
    if ($remaining.TotalSeconds -le 0) {
        $text = "The enforced cutoff was $when. That time has passed, so Windows can force the restart at any time.`r`n$policyLine"
        $fraction = 1.0
    } else {
        $text = @"
Windows will force the restart on $when.
$(Format-Duration $remaining) remaining. $(Format-Duration $elapsed) of the $(Format-Duration $length) enforced window has passed.
$policyLine
"@.Trim()
    }
    return @{ Text = $text; Fraction = $fraction }
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
        Title="Restart required" Width="520" SizeToContent="Height"
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
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="MinHeight" Value="32"/>
      <Setter Property="HorizontalAlignment" Value="Stretch"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
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
          <StackPanel x:Name="DeadlinePanel" Margin="0,14,0,0" Visibility="Collapsed">
            <TextBlock x:Name="DeadlineText" TextWrapping="Wrap" LineHeight="20" FontSize="13"/>
            <Grid x:Name="DeadlineTrack" Height="6" Margin="0,8,0,0">
              <Border x:Name="DeadlineTrackBorder" Background="#E5E5E5" CornerRadius="3"/>
              <Border x:Name="DeadlineFill" HorizontalAlignment="Left" Width="0" Background="#005FB8" CornerRadius="3"/>
            </Grid>
          </StackPanel>
          <TextBlock x:Name="ErrorText" Foreground="#C42B1C" TextWrapping="Wrap" Margin="0,12,0,0" Visibility="Collapsed"/>
        </StackPanel>
        <TextBlock x:Name="VersionText" Grid.Row="0" HorizontalAlignment="Right" VerticalAlignment="Top"
                   Margin="0,12,16,0" FontSize="12" Foreground="#9A9A9A" IsHitTestVisible="False"/>

        <Border x:Name="FooterBorder" Grid.Row="1" Background="#F3F3F3" BorderBrush="#E5E5E5" BorderThickness="0,1,0,0"
                CornerRadius="0,0,7,7" Padding="16,14">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Button x:Name="NowBtn" Grid.Column="0" Content="Restart now" Style="{StaticResource AccentButton}" Margin="0,0,8,0"/>
            <Button x:Name="ScheduleBtn" Grid.Column="1" Content="Schedule restart" Style="{StaticResource DialogButton}" Margin="0,0,8,0"/>
            <Button x:Name="CloseBtn" Grid.Column="2" Content="Close" Style="{StaticResource DialogButton}" Margin="0" IsCancel="True"/>
          </Grid>
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
    foreach ($name in 'ShadowBorder', 'CardBorder', 'IconGlyph', 'TitleText', 'SubtitleText', 'BodyText', 'DeadlinePanel', 'DeadlineText', 'DeadlineTrack', 'DeadlineTrackBorder', 'DeadlineFill', 'ErrorText', 'VersionText', 'FooterBorder', 'NowBtn', 'ScheduleBtn', 'CloseBtn') {
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
    $ui.VersionText.Text = $ScriptVersion
    $ui.VersionText.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(154, 154, 154))

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
        $ui.VersionText.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(184, 184, 184))
        $ui.BodyText.Foreground = $text
        $ui.DeadlineText.Foreground = $text
        $ui.DeadlineTrackBorder.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(63, 63, 63))
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

    $deadline = $null
    if (-not $Preview) { $deadline = Get-ForcedRestart }
    if ($deadline -and $deadline.Text) {
        $ui.DeadlineText.Text = $deadline.Text
        $ui.DeadlinePanel.Visibility = 'Visible'
        $script:DeadlineFraction = $deadline.Fraction
        if ($null -ne $script:DeadlineFraction) {
            $ui.DeadlineFill.Background = $accentBrush
        }
    }

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
        if ($null -ne $script:DeadlineFraction) {
            $ui.DeadlineFill.Width = [Math]::Max(0, $ui.DeadlineTrack.ActualWidth * [double]$script:DeadlineFraction)
        }
        Move-ToBottomRight
        # SizeToContent recenters a Manual window after the first layout. Pin the corner again after the text is measured.
        $window.Dispatcher.BeginInvoke([Action]{
            if ($null -ne $script:DeadlineFraction) {
                $ui.DeadlineFill.Width = [Math]::Max(0, $ui.DeadlineTrack.ActualWidth * [double]$script:DeadlineFraction)
            }
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
