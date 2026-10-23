<#
    eGPU-Switch.ps1  -  a menu around the schedule: opt out, or change the settings.

    1  Skip tonight           pause once; expires by itself at midnight
    2  Cancel the skip        tonight runs as scheduled again
    3  Turn everything off    disables all scheduled tasks (asks for admin once)
    4  Turn everything on     re-enables them (asks for admin once)
    5  Show status
    7  Settings               edit times, nights and the GPU match, then re-register
    Q  Quit

    This script holds no rules of its own: behaviour lives in eGPU-Guard.ps1 (called here) and
    the values live in eGPU-Guard.config.psd1 (edited here via eGPU-Config.ps1). The pause state
    is read back from `-Action Status` rather than re-derived, so the "expires at midnight" rule
    exists in exactly one place, and the times shown come from the config file rather than a
    hard-coded string.
#>

$ErrorActionPreference = 'Stop'

$base = $PSScriptRoot
if (-not $base -and $PSCommandPath) { $base = Split-Path -Parent $PSCommandPath }
$guard = Join-Path $base 'eGPU-Guard.ps1'
$installer = Join-Path $base 'install-eGPU-Guard.ps1'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path -LiteralPath $guard)) {
    Write-Host "eGPU-Guard.ps1 not found next to this script ($base)" -ForegroundColor Red
    exit 1
}

# The settings file is the single source of truth for times, nights and the device match, so the
# menu reads it instead of hard-coding "23:58" into its own labels.
. (Join-Path $base 'eGPU-Config.ps1')
$configPath = Get-GuardConfigPath -Root $base

function Invoke-Guard {
    param([string]$Action)
    # Out-Host, not a bare call: a native command's stdout becomes part of THIS function's
    # output stream, so a caller that captures the return value ("$null = Invoke-Guard Status")
    # would silently swallow everything the action printed. Out-Host writes straight to the
    # console and leaves the exit code as the function's only pipeline output.
    & $ps -NoProfile -ExecutionPolicy Bypass -File $guard -Action $Action | Out-Host
    return $LASTEXITCODE
}

function Get-TonightState {
    # Delegated on purpose (see the header): parse the one line Status already computes.
    $out = & $ps -NoProfile -ExecutionPolicy Bypass -File $guard -Action Status 2>&1
    $line = @($out | Where-Object { $_ -match 'pausedTonight=(\w+)' }) | Select-Object -First 1
    if ($line -and $line -match 'pausedTonight=(\w+)') {
        if ($Matches[1] -eq 'True') { return 'PAUSED - nothing happens tonight' }
        $c = Get-GuardConfig -Path $configPath -Quiet
        return ('will run at {0} ({1})' -f $c.DisableTime, (@($c.Days) -join ','))
    }
    return 'unknown'
}

function Read-Days {
    # Accepts 3-letter or full English names, comma separated; empty means "keep as is".
    param($Current)
    $default = (@($Current) -join ',')
    $raw = Read-Host ("  Nights (comma separated) [{0}]" -f $default)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @($Current) }
    $map = @{ sun = 'Sunday'; mon = 'Monday'; tue = 'Tuesday'; wed = 'Wednesday'; thu = 'Thursday'; fri = 'Friday'; sat = 'Saturday' }
    $out = @()
    foreach ($part in ($raw -split ',')) {
        $t = $part.Trim().ToLower()
        if ($t.Length -ge 3 -and $map.ContainsKey($t.Substring(0, 3))) { $out += $map[$t.Substring(0, 3)] }
        elseif ($t.Length -gt 0) { Write-Host ("  ignoring '{0}'" -f $part.Trim()) -ForegroundColor Red }
    }
    if ($out.Count -eq 0) { return @($Current) }
    return @($out | Select-Object -Unique)
}

function Read-Value {
    # Empty input keeps the current value. A wrong value is reported and the old one kept, so a
    # typo can never be written into the file.
    param([string]$Label, $Current, [string]$Pattern, [string]$Example, [scriptblock]$Convert)
    $shown = if ($Current -is [bool]) { if ($Current) { 'yes' } else { 'no' } } else { [string]$Current }
    while ($true) {
        $v = Read-Host ("  {0} [{1}]" -f $Label, $shown)
        if ([string]::IsNullOrWhiteSpace($v)) { return $Current }
        $v = $v.Trim()
        if ($Pattern -and $v -notmatch $Pattern) {
            Write-Host ("    expected {0}, e.g. {1}" -f $Label, $Example) -ForegroundColor Red
            continue
        }
        if ($Convert) { return (& $Convert $v) }
        return $v
    }
}

function Invoke-Settings {
    $c = Get-GuardConfig -Path $configPath -Quiet
    Clear-Host
    Write-Host ''
    Write-Host ('  Settings  ({0})' -f $configPath) -ForegroundColor Cyan
    Write-Host '  --------------------------------------' -ForegroundColor DarkGray
    Write-Host '  Press Enter to keep the value shown in brackets.'
    Write-Host ''
    Write-Host ('  Current: disconnect {0}, reminder {1}, nights {2}' -f $c.DisableTime, $c.NotifyTime, (@($c.Days) -join ','))
    Write-Host ('           GPU "{0}" (VEN_{1}&{2}), reminder {3}s, sound {4}' -f $c.MatchDescription, $c.MatchVendorId, $c.MatchDeviceId, $c.NotifySeconds, $(if ($c.NotifySound) { 'yes' } else { 'no' }))
    Write-Host ''

    $new = [ordered]@{
        DisableTime      = Read-Value 'Disconnect time (HH:mm)' $c.DisableTime '^([01]?\d|2[0-3]):[0-5]\d$' '23:58'
        NotifyTime       = Read-Value 'Reminder time (HH:mm)' $c.NotifyTime '^([01]?\d|2[0-3]):[0-5]\d$' '23:53'
        Days             = Read-Days $c.Days
        MatchDescription = Read-Value 'GPU name substring' $c.MatchDescription $null '4070 SUPER'
        MatchVendorId    = Read-Value 'PCI vendor id (no VEN_)' $c.MatchVendorId '^[0-9A-Fa-f]{4}$' '10DE'
        MatchDeviceId    = Read-Value 'PCI device id' $c.MatchDeviceId '^DEV_[0-9A-Fa-f]{4}$' 'DEV_2783'
        NotifySeconds    = Read-Value 'Reminder seconds' $c.NotifySeconds '^\d+$' '5' { param($v) [int]$v }
        NotifySound      = Read-Value 'Reminder sound (yes/no)' $c.NotifySound '^(yes|no|y|n)$' 'yes' { param($v) $v -match '^(yes|y)$' }
        MaxLogBytes      = $c.MaxLogBytes
        KeepLogLines     = $c.KeepLogLines
    }

    $problems = @(Test-GuardConfig -Config $new)
    if ($problems.Count -gt 0) {
        Write-Host ''
        Write-Host '  Not saved - please fix these:' -ForegroundColor Red
        foreach ($p in $problems) { Write-Host ("    - {0}" -f $p) -ForegroundColor Red }
        return
    }

    $null = Save-GuardConfig -Config $new -Path $configPath
    Write-Host ''
    Write-Host '  Saved.' -ForegroundColor Green

    $apply = Read-Host '  Re-register the scheduled tasks now so the new times take effect? [Y/n]'
    # $null means stdin closed (piped input ran out). Treat that as "no": the one thing this must
    # never do is raise an admin prompt nobody asked for.
    if ($null -eq $apply -or $apply -match '^(n|no)$') {
        Write-Host '  Not applied. Run install-eGPU-Guard.ps1 when you are ready.' -ForegroundColor Yellow
        return
    }
    Write-Host ''
    Write-Host '  Asking for administrator rights (the tasks run as SYSTEM)...' -ForegroundColor DarkGray
    # Double quotes: Windows strips " but not ', so a single-quoted path would arrive literally.
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $installer
    try {
        $p = Start-Process -FilePath $ps -Verb RunAs -Wait -PassThru -ArgumentList $argLine
        if ($p.ExitCode -eq 0) { Write-Host '  Applied: the tasks are registered with the new times.' -ForegroundColor Green }
        else { Write-Host ("  The installer exited with {0} - see the log." -f $p.ExitCode) -ForegroundColor Red }
    } catch {
        Write-Host '  The admin prompt was refused - the file is saved but the tasks were not changed.' -ForegroundColor Red
    }
}

while ($true) {
    Clear-Host
    Write-Host ''
    Write-Host '  eGPU Guard - nightly disconnect switch' -ForegroundColor Cyan
    Write-Host '  --------------------------------------' -ForegroundColor DarkGray
    Write-Host ('  Tonight: {0}' -f (Get-TonightState))
    Write-Host ''
    Write-Host '  1  Skip tonight only        (expires at midnight by itself)'
    Write-Host '  2  Cancel the skip'
    Write-Host '  3  Turn the whole schedule OFF'
    Write-Host '  4  Turn the whole schedule ON'
    Write-Host '  5  Show status'
    Write-Host '  7  Settings                 (times, nights, GPU match)'
    Write-Host '  Q  Quit'
    Write-Host ''
    $choice = Read-Host '  Choose'
    # No input at all (stdin closed) must end the loop instead of throwing on $null.Trim().
    if ($null -eq $choice) { return }

    switch ($choice.Trim()) {
        '1' {
            $null = Invoke-Guard 'Pause'
            $c = Get-GuardConfig -Path $configPath -Quiet
            Write-Host ''
            Write-Host ('  Done: tonight will be skipped. The {0} reminder is skipped too.' -f $c.NotifyTime) -ForegroundColor Green
        }
        '2' {
            $null = Invoke-Guard 'Unpause'
            Write-Host ''
            Write-Host '  Done: tonight runs as scheduled again.' -ForegroundColor Green
        }
        '3' {
            Write-Host ''
            $code = Invoke-Guard 'Off'
            if ($code -eq 0) { Write-Host '  Done: every eGPU-Guard task is disabled.' -ForegroundColor Yellow }
            elseif ($code -eq 6) { Write-Host '  Nothing changed: the admin prompt was refused.' -ForegroundColor Red }
            else { Write-Host "  Failed (exit $code) - see the log." -ForegroundColor Red }
        }
        '4' {
            Write-Host ''
            $code = Invoke-Guard 'On'
            if ($code -eq 0) { Write-Host '  Done: every eGPU-Guard task is enabled again.' -ForegroundColor Green }
            elseif ($code -eq 6) { Write-Host '  Nothing changed: the admin prompt was refused.' -ForegroundColor Red }
            else { Write-Host "  Failed (exit $code) - see the log." -ForegroundColor Red }
        }
        '5' {
            Write-Host ''
            $null = Invoke-Guard 'Status'
        }
        '7' { Invoke-Settings }
        'Q' { return }
        'q' { return }
        default { Write-Host '  Unknown choice.' -ForegroundColor Red }
    }

    Write-Host ''
    $null = Read-Host '  Press Enter to go back'
}
