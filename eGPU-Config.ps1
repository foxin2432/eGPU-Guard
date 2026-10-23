<#
    eGPU-Config.ps1  -  load, validate and save the one settings file.

    WHY A SEPARATE FILE
    -------------------
    Times, nights and the device match used to live in the defaults of five different scripts
    plus the installer's parameter list. Changing "23:58" meant either passing flags (which only
    affects tasks registered by that one command) or editing several files and hoping they
    stayed in step. A single file that every process reads is the only version where the
    installed schedule cannot disagree with itself.

    Precedence, highest first:
      1. an explicit command-line parameter  (e.g. install-eGPU-Guard.ps1 -DisableTime 22:30)
      2. a value in eGPU-Guard.config.psd1
      3. the built-in default in this file

    A missing or unreadable config is not an error: the built-in defaults are used, so the kit
    still works when the file is absent. A file with a bad value is treated the same way for
    that one key, and the reason is reported - a typo must never take the schedule down.
#>

function Get-GuardConfigPath {
    param([string]$Root)
    if (-not $Root) { $Root = $PSScriptRoot }
    if (-not $Root -and $PSCommandPath) { $Root = Split-Path -Parent $PSCommandPath }
    return (Join-Path $Root 'eGPU-Guard.config.psd1')
}

function Get-GuardConfigDefaults {
    # The defaults are duplicated in the shipped .psd1 on purpose: the file is a convenience for
    # the user, this table is what the code falls back to when the file is missing or damaged.
    [ordered]@{
        DisableTime      = '23:58'
        NotifyTime       = '23:53'
        Days             = @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday')
        MatchDescription = '4070 SUPER'
        MatchVendorId    = '10DE'
        MatchDeviceId    = 'DEV_2783'
        NotifySeconds    = 5
        NotifySound      = $true
        MaxLogBytes      = 1048576
        KeepLogLines     = 500
    }
}

function Test-GuardConfig {
    # Returns a list of human-readable problems. Empty means the config is usable.
    param([Parameter(Mandatory)]$Config)

    $problems = @()
    foreach ($key in @('DisableTime', 'NotifyTime')) {
        $v = [string]$Config[$key]
        if ($v -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') {
            $problems += "$key must look like HH:mm (24-hour), got '$v'"
        }
    }
    if ($problems.Count -eq 0) {
        # A reminder at or after the disconnect would announce something that already happened.
        $n = [datetime]::ParseExact([string]$Config.NotifyTime, 'HH:mm', $null)
        $d = [datetime]::ParseExact([string]$Config.DisableTime, 'HH:mm', $null)
        if ($n -ge $d) { $problems += "NotifyTime ($($Config.NotifyTime)) must be earlier than DisableTime ($($Config.DisableTime))" }
    }

    $validDays = @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')
    $days = @($Config.Days)
    if ($days.Count -eq 0) {
        $problems += 'Days must list at least one night'
    } else {
        foreach ($d in $days) {
            if ($validDays -notcontains [string]$d) { $problems += "Days contains '$d' (use English day names, e.g. Monday)" }
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$Config.MatchDescription)) {
        $problems += 'MatchDescription must not be empty'
    }
    if ([string]$Config.MatchVendorId -notmatch '^[0-9A-Fa-f]{4}$') {
        $problems += "MatchVendorId must be the 4-hex vendor id, e.g. 10DE (NVIDIA) or 1002 (AMD), got '$($Config.MatchVendorId)'"
    }
    if ([string]$Config.MatchDeviceId -notmatch '^DEV_[0-9A-Fa-f]{4}$') {
        $problems += "MatchDeviceId must look like DEV_2783, got '$($Config.MatchDeviceId)'"
    }
    if ([int]$Config.NotifySeconds -lt 1 -or [int]$Config.NotifySeconds -gt 60) {
        $problems += 'NotifySeconds must be between 1 and 60'
    }
    if ([int]$Config.MaxLogBytes -lt 0) { $problems += 'MaxLogBytes must be 0 or more (0 disables trimming)' }
    if ([int]$Config.KeepLogLines -lt 1) { $problems += 'KeepLogLines must be at least 1' }

    return $problems
}

function Get-GuardConfig {
    # Always returns a complete, validated table. Never throws: a broken config must not stop the
    # nightly disconnect, so every failure falls back to the built-in value and is reported.
    param([string]$Path, [switch]$Quiet)

    $defaults = Get-GuardConfigDefaults
    $config = [ordered]@{}
    foreach ($k in $defaults.Keys) { $config[$k] = $defaults[$k] }

    if (-not $Path) { $Path = Get-GuardConfigPath }
    if (-not (Test-Path -LiteralPath $Path)) { return $config }

    $loaded = $null
    try {
        $loaded = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
    } catch {
        if (-not $Quiet) { Write-Warning "could not read $Path ($($_.Exception.Message)) - using built-in defaults" }
        return $config
    }
    if ($null -eq $loaded) { return $config }

    foreach ($k in @($loaded.Keys)) {
        if ($defaults.Keys -notcontains $k) {
            if (-not $Quiet) { Write-Warning "unknown setting '$k' in $Path - ignored" }
            continue
        }
        $config[$k] = $loaded[$k]
    }

    $problems = @(Test-GuardConfig -Config $config)
    if ($problems.Count -gt 0) {
        # Revert only the keys that are wrong, keep everything the user got right.
        if (-not $Quiet) {
            foreach ($p in $problems) { Write-Warning "$Path : $p - using the built-in value" }
        }
        foreach ($key in @('DisableTime', 'NotifyTime')) {
            if (([string]$config[$key]) -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { $config[$key] = $defaults[$key] }
        }
        if (@($config.Days).Count -eq 0) { $config.Days = $defaults.Days }
        if ([string]::IsNullOrWhiteSpace([string]$config.MatchDescription)) { $config.MatchDescription = $defaults.MatchDescription }
        if ([string]$config.MatchVendorId -notmatch '^[0-9A-Fa-f]{4}$') { $config.MatchVendorId = $defaults.MatchVendorId }
        if ([string]$config.MatchDeviceId -notmatch '^DEV_[0-9A-Fa-f]{4}$') { $config.MatchDeviceId = $defaults.MatchDeviceId }
        if ([int]$config.NotifySeconds -lt 1 -or [int]$config.NotifySeconds -gt 60) { $config.NotifySeconds = $defaults.NotifySeconds }
        if ([int]$config.MaxLogBytes -lt 0) { $config.MaxLogBytes = $defaults.MaxLogBytes }
        if ([int]$config.KeepLogLines -lt 1) { $config.KeepLogLines = $defaults.KeepLogLines }
    }

    return $config
}

function ConvertTo-GuardConfigText {
    # Writes the file by hand instead of with ConvertTo-Json: this file is meant to be opened and
    # edited by a human, so it keeps its comments, its alignment and its layout on every save.
    param([Parameter(Mandatory)]$Config)

    $q = { param($s) "'" + ([string]$s -replace "'", "''") + "'" }
    $days = (@($Config.Days) | ForEach-Object { & $q $_ }) -join ', '
    $sound = if ([bool]$Config.NotifySound) { '$true' } else { '$false' }

    $lines = @(
        '<#',
        '    eGPU-Guard settings.',
        '',
        '    Edit this file, then re-run install-eGPU-Guard.ps1 so the scheduled tasks pick the new',
        '    times up. Anything left out falls back to the built-in default.',
        '',
        '    Or just double-click eGPU-Switch.cmd and choose "7  Settings" - it edits this file for you.',
        '',
        '    DisableTime      when the eGPU is disconnected (24-hour HH:mm)',
        '    NotifyTime       when the reminder window appears; must be earlier than DisableTime',
        '    Days             the nights to act on (English day names)',
        '    MatchDescription part of the GPU name shown by Windows, e.g. 4070 SUPER or RX 7900',
        '    MatchVendorId    the PCI vendor id without VEN_, e.g. 10DE (NVIDIA) or 1002 (AMD)',
        '    MatchDeviceId    the PCI device id, the DEV_xxxx part of the hardware id',
        '    NotifySeconds    how long the reminder stays on screen',
        '    NotifySound      play a sound with the reminder',
        '    MaxLogBytes      trim the log once it passes this size; 0 disables trimming',
        '    KeepLogLines     how many lines to keep when trimming',
        '#>',
        '@{',
        ('    DisableTime      = {0}' -f (& $q $Config.DisableTime)),
        ('    NotifyTime       = {0}' -f (& $q $Config.NotifyTime)),
        ('    Days             = @({0})' -f $days),
        ('    MatchDescription = {0}' -f (& $q $Config.MatchDescription)),
        ('    MatchVendorId    = {0}' -f (& $q $Config.MatchVendorId)),
        ('    MatchDeviceId    = {0}' -f (& $q $Config.MatchDeviceId)),
        ('    NotifySeconds    = {0}' -f [int]$Config.NotifySeconds),
        ('    NotifySound      = {0}' -f $sound),
        ('    MaxLogBytes      = {0}' -f [int]$Config.MaxLogBytes),
        ('    KeepLogLines     = {0}' -f [int]$Config.KeepLogLines),
        '}'
    )
    return ($lines -join "`r`n") + "`r`n"
}

function Save-GuardConfig {
    # Atomic: a crash mid-write leaves the previous config intact, never half a file that would
    # make every subsequent run fall back to defaults without saying so.
    param([Parameter(Mandatory)]$Config, [string]$Path)

    if (-not $Path) { $Path = Get-GuardConfigPath }
    $text = ConvertTo-GuardConfigText -Config $Config
    $tmp = "$Path.tmp"
    # WriteAllText, not Set-Content: Set-Content appends its own newline to the single value, so
    # every save would grow the file by a blank line. The BOM is kept on purpose - Windows
    # PowerShell 5.1 reads a BOM-less file as ANSI, which mangles any non-ASCII the user typed.
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($tmp, $text, $enc)
    try {
        if (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Replace($tmp, $Path, $null)
        } else {
            Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
        }
    } catch {
        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
    }
    return $Path
}
