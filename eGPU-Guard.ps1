<#
    eGPU-Guard.ps1  -  schedule-driven disable / auto-enable for an external NVIDIA GPU
    (ThinkBook 14+ 2024 TGX + Minisforum DEG1 + RTX 4070 SUPER)

    Actions
      -Action Disable   stop the eGPU (pnputil /disable-device) and open a "stay down"
                        window, so the watcher does not immediately undo it
      -Action Enable    bring it back up if present and not started (scan + enable + verify)
                        and close the "stay down" window
      -Action Resume    close the "stay down" window and start the eGPU now, without a reboot
      -Action Restart   remove + rescan, for Error 22/43 style states
      -Action Status    print current state, is a monitor attached, why it is not restartable
      -Action Pause     skip TONIGHT's scheduled disconnect only (no admin needed; the marker
                        expires by itself at midnight)
      -Action Unpause   cancel a pending skip
      -Action Off       disable every eGPU-Guard scheduled task (needs admin; reversible)
      -Action On        re-enable them (needs admin)

    Common switches
      -Force            waive the "an external display is attached" warning (the separate
                        "this is the only active display adapter" guard is NOT waivable)
      -StayDown         keep the device down until the next boot (used by the nightly task)
      -Toast            show a desktop toast with the result
      -LogFile <path>   override log location

    Exit codes
      0 ok / nothing to do
      2 device not present
      3 device already in the requested state
      4 operation failed
      5 refused (safety checks, e.g. a display is attached and -Force was not given)
      6 needs administrator rights but they were refused
#>
[CmdletBinding()]
param(
    [ValidateSet('Disable', 'Enable', 'Resume', 'Restart', 'Status', 'Pause', 'Unpause', 'Off', 'On')]
    [string]$Action = 'Status',

    [string]$LogFile = "$env:ProgramData\eGPU-Guard\eGPU-Guard.log",
    [string]$MatchDescription = '4070 SUPER',
    [string]$MatchVendorId = '10DE',
    [string]$MatchDeviceId = 'DEV_2783',
    [switch]$Force,
    [switch]$Toast,

    # Only the scheduled nightly task passes this. It opens the "stay down" window so the
    # watcher does not immediately undo the disconnect. A manual `-Action Disable` does NOT
    # stay down: the GPU should come back by itself if it is plugged in again.
    [switch]$StayDown,

    # Log housekeeping. Checked once per process at startup, so the cost is one stat per run
    # rather than one per log line. 0 disables trimming; the file is otherwise bounded to the
    # last KeepLogLines entries once it passes MaxLogBytes.
    [int]$MaxLogBytes = 1048576,
    [int]$KeepLogLines = 500
)

$ErrorActionPreference = 'Continue'

# Every knob below can also live in eGPU-Guard.config.psd1, which is what the switch menu edits
# and what an open-source user is expected to change. A parameter given on the command line wins,
# because a one-off override must not rewrite shared configuration. Read before anything else
# uses these values.
. (Join-Path $PSScriptRoot 'eGPU-Config.ps1')
$config = Get-GuardConfig
if (-not $PSBoundParameters.ContainsKey('MatchDescription')) { $MatchDescription = $config.MatchDescription }
if (-not $PSBoundParameters.ContainsKey('MatchVendorId')) { $MatchVendorId = $config.MatchVendorId }
if (-not $PSBoundParameters.ContainsKey('MatchDeviceId')) { $MatchDeviceId = $config.MatchDeviceId }
if (-not $PSBoundParameters.ContainsKey('MaxLogBytes')) { $MaxLogBytes = [int]$config.MaxLogBytes }
if (-not $PSBoundParameters.ContainsKey('KeepLogLines')) { $KeepLogLines = [int]$config.KeepLogLines }

# Child keys under ...\Enum\PCI are named "VEN_10DE&DEV_xxxx&..." (no leading "PCI\")
$script:DeviceIdPrefix = "VEN_$MatchVendorId&$MatchDeviceId&"

# ----------------------------------------------------------------- helpers ---

function Get-BootTime {
    # Used to tell "the user deliberately stopped the GPU" from "we are booting". Anything
    # that survives a reboot must not survive it: a fresh boot may deliberately start the
    # GPU, so the stay-down window is keyed to the boot time it was created in.
    try {
        return (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    } catch {
        return $null
    }
}

function Get-StayDownPath {
    Join-Path (Split-Path -Parent $LogFile) 'state\stay-down'
}

function Test-StayDown {
    # True when the eGPU was deliberately stopped during this same boot session.
    $path = Get-StayDownPath
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $boot = Get-BootTime
    if (-not $boot) { return $true }          # cannot prove a reboot happened: stay conservative
    $stamp = $null
    try { $stamp = [datetime]::Parse((Get-Content -LiteralPath $path -Raw -ErrorAction Stop).Trim()) } catch { }
    if (-not $stamp) { return $true }
    # A different boot time means the machine rebooted after the marker was written, so the
    # marker is stale and must be ignored (and cleaned up).
    if ([math]::Abs(($stamp - $boot).TotalSeconds) -gt 60) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        return $false
    }
    return $true
}

function New-StayDown {
    $path = Get-StayDownPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $boot = Get-BootTime
    $stamp = if ($boot) { $boot.ToString('o') } else { (Get-Date).ToString('o') }
    Set-Content -LiteralPath $path -Value $stamp -Encoding ascii -Force
    Write-Log "stay-down window opened until the next boot (recorded boot time $stamp)"
}

function Clear-StayDown {
    $path = Get-StayDownPath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Write-Log 'stay-down window closed'
    }
}

function Limit-LogFile {
    # Keeps the log from growing without bound. Called ONCE per process, at startup, before the
    # first line is written: checking on every write would put a stat call in the hot path to
    # save a few kilobytes a year, and since every process re-checks at startup the file cannot
    # outgrow the limit by more than one session's worth of lines.
    #
    # Trimming is by whole lines, never by bytes. The log is one event per line, so a byte cut
    # would leave a torn entry that no reader could parse.
    if ($MaxLogBytes -le 0) { return }              # 0 disables trimming entirely
    if ($KeepLogLines -lt 1) { return }
    try {
        if (-not (Test-Path -LiteralPath $LogFile)) { return }
        $size = (Get-Item -LiteralPath $LogFile -ErrorAction Stop).Length
        if ($size -le $MaxLogBytes) { return }

        $all = @(Get-Content -LiteralPath $LogFile -Encoding UTF8 -ErrorAction Stop)
        $total = @($all).Count
        if ($total -le $KeepLogLines) { return }
        $keep = @(@($all)[($total - $KeepLogLines)..($total - 1)])

        $tmp = "$LogFile.trim"
        $header = '# log trimmed: kept the last {0} of {1} lines (was {2} KB)' -f $keep.Count, $total, [math]::Round($size / 1KB)
        Set-Content -LiteralPath $tmp -Value (@($header) + $keep) -Encoding UTF8 -Force -ErrorAction Stop
        try {
            # Atomic on NTFS: a concurrent reader sees either the whole old file or the whole
            # new one, never a half-written log.
            [System.IO.File]::Replace($tmp, $LogFile, $null)
        } catch {
            Move-Item -LiteralPath $tmp -Destination $LogFile -Force -ErrorAction Stop
        }
        Write-Log ("log trimmed: kept the last {0} of {1} lines" -f $keep.Count, $total)
    } catch {
        # Housekeeping must never break an action: the log is diagnostics, not state.
        Write-Log "could not trim the log: $($_.Exception.Message)" 'WARN'
        Remove-Item -LiteralPath "$LogFile.trim" -Force -ErrorAction SilentlyContinue
    }
}

function Get-PausePath {
    # Shares the state directory with stay-down, but means something different: stay-down says
    # "this boot was deliberately stopped", pause says "do not run TONIGHT's disconnect".
    Join-Path (Split-Path -Parent $LogFile) 'state\pause'
}

function Test-Pause {
    # True when tonight's scheduled disconnect was skipped with -Action Pause.
    #
    # Keyed to a DATE, never to a boot: it has to expire by itself, or a one-night skip quietly
    # turns into a permanent one, which is the worst possible failure for this setting. A marker
    # from any other day is stale, so it is ignored and removed.
    $path = Get-PausePath
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $stamp = $null
    try { $stamp = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop).Trim() } catch { }
    if ($stamp -ne (Get-Date).ToString('yyyy-MM-dd')) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        return $false
    }
    return $true
}

function New-Pause {
    $path = Get-PausePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    Set-Content -LiteralPath $path -Value $today -Encoding ascii -Force
    Write-Log "tonight's disconnect is paused (marker for $today - it expires by itself at midnight)"
}

function Clear-Pause {
    $path = Get-PausePath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Write-Log 'pause cancelled - tonight runs as scheduled again'
    } else {
        Write-Log 'not paused - nothing to cancel'
    }
}

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2} {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Action, $Message
    Write-Host $line
    try {
        $dir = Split-Path -Parent $LogFile
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

function Initialize-Console {
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
}

function Get-EGpuInstanceId {
    # NOTE on registry quirks that cost real debugging time:
    #   * the child of ...\Enum\PCI is a device *type* key, the instance key is one level deeper
    #   * Splitting/Join-Path on registry paths is unsafe: '&' must go through -LiteralPath
    $parents = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like "$script:DeviceIdPrefix*" }
    foreach ($parent in $parents) {
        foreach ($inst in (Get-ChildItem -LiteralPath $parent.PSPath -ErrorAction SilentlyContinue)) {
            $vals = Get-ItemProperty -LiteralPath $inst.PSPath -ErrorAction SilentlyContinue
            if (-not $vals) { continue }
            $desc = ($vals.DeviceDesc -replace '^@[^;]*;', '')
            if ($desc -notlike "*$MatchDescription*") { continue }
            [pscustomobject]@{
                InstanceId  = "PCI\$($parent.PSChildName)\$($inst.PSChildName)"
                RegPath     = $inst.Name
                Desc        = $desc
                ConfigFlags = [int]$vals.ConfigFlags
                HasParams   = Test-Path -LiteralPath "$($inst.Name)\Device Parameters"
            }
        }
    }
}

function Invoke-Pnputil {
    param([string[]]$Arguments)
    $exe = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    if (-not (Test-Path $exe)) { $exe = 'pnputil.exe' }
    # No pipeline on this line: a pipe would overwrite $LASTEXITCODE with the pipe's own
    # exit code and silently turn "Access is denied" into a success.
    $lines = @(& $exe @Arguments 2>&1)
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    [pscustomobject]@{ ExitCode = $code; Output = (($lines | ForEach-Object { "$_" }) -join [Environment]::NewLine) }
}

function Normalize-PnpStatusText {
    # Rewrite localised status values into their English tokens so the rest of the code can
    # match one spelling. Labels are handled separately (see Get-DeviceState).
    param([string]$Text)
    if (-not $Text) { return $Text }
    $map = Get-LocalizedPnpMap
    foreach ($key in $map.Values.Keys) {
        if ($Text.Contains($key)) { $Text = $Text.Replace($key, $map.Values[$key]) }
    }
    $Text
}

function Get-DeviceState {
    # Status is derived without trusting any label text: a "Problem Code: NN (0xNN) [SYMBOL]"
    # line is structural and language independent, and the status VALUES pnputil prints stay
    # in English even when its labels are localised. Localised values are mapped from code
    # points as a fallback for the cases where they are not.
    param([string]$InstanceId)
    $state = [pscustomobject]@{
        InstanceId  = $InstanceId
        Present     = $false
        Status      = 'unknown'
        ProblemCode = $null
        ConfigFlags = $null
        Disabled    = $false
    }
    $r = Invoke-Pnputil @('/enum-devices', '/instanceid', $InstanceId)
    $normalized = Normalize-PnpStatusText -Text $r.Output
    foreach ($line in ($normalized -split "`r?`n")) {
        if ($line -match 'Instance ID:') { $state.Present = $true }
        foreach ($v in 'Started', 'Disabled', 'Stopped', 'Disconnected', 'Problem', 'Unknown') {
            if ($line -match ('(?:^|\s)' + [regex]::Escape($v) + '(?:\s|$)')) { $state.Status = $v; break }
        }
        if ($line -match '\b(\d+)\s*\(0x[0-9A-Fa-f]+\)') { $state.ProblemCode = [int]$Matches[1] }
    }
    $reg = Get-EGpuInstanceId | Where-Object { $_.InstanceId -eq $InstanceId } | Select-Object -First 1
    if ($reg) {
        $state.ConfigFlags = $reg.ConfigFlags
        $state.Disabled = (($reg.ConfigFlags -band 0x1) -eq 0x1)
    }
    $state
}

function Get-AttachedMonitorOnEGpu {
    # System.Windows.Forms.Screen is unreliable here (it reported only one screen while
    # an external monitor was attached), so fall back to WMI and then to the CIM instance
    # of the GPU itself, which carries an "attached monitors" count.
    $screens = $null
    $source = 'none'

    try {
        $screens = @(Get-CimInstance -ClassName Win32_DesktopMonitor -ErrorAction Stop |
            Where-Object { $_.Availability -ne 8 })
        $source = 'WMI'
    } catch {
        $screens = $null
    }

    foreach ($gpu in (Get-EGpuInstanceId)) {
        try {
            $inst = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
                Where-Object { $_.PNPDeviceID -eq $gpu.InstanceId }
            if ($inst) {
                $count = @($inst).Count
                return [pscustomobject]@{
                    Attached = $true
                    Source   = "Win32_VideoController($count instance(s))"
                    Count    = $count
                }
            }
        } catch {
            return [pscustomobject]@{ Attached = $true; Source = 'unknown (WMI restricted)'; Count = -1 }
        }
    }

    if ($null -ne $screens) {
        return [pscustomobject]@{ Attached = ($screens.Count -gt 0); Source = $source; Count = $screens.Count }
    }
    [pscustomobject]@{ Attached = $true; Source = 'unknown (no probe available)'; Count = -1 }
}

function Show-Toast {
    # Delegates to eGPU-Notify.ps1 so there is exactly ONE implementation of "show something
    # to the user", and so it inherits that script's working window.
    #
    # This used to build a WinRT ToastNotification itself and call
    # ToastNotificationManager.CreateToastNotifier(<AUMID>).Show(). That silently does nothing
    # when the AUMID is not a registered Start Menu shortcut for the current user: Show()
    # returns without an error, no toast appears, and the log claims success. Which is exactly
    # what happened every night on the reference machine until 2026-10-20.
    param([string]$Title, [string]$Body, [int]$Seconds = 5)
    # $PSScriptRoot is empty in some hosting contexts, so fall back to $PSCommandPath before
    # giving up. (This is the same trap the installer had to work around.)
    $base = $PSScriptRoot
    if (-not $base -and $PSCommandPath) { $base = Split-Path -Parent $PSCommandPath }
    if (-not $base) { $base = Split-Path -Parent ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
    $notifier = if ($base) { Join-Path $base 'eGPU-Notify.ps1' } else { $null }
    if (-not (Test-Path -LiteralPath $notifier)) {
        # Not a WARN: a window can only be shown by an interactive caller anyway, and when the
        # scheduled task runs as SYSTEM (session 0) there is nothing to show it on. The log
        # line records that it was attempted.
        Write-Log 'no reminder window shown (eGPU-Notify.ps1 not found next to this script)'
        return
    }
    try {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        # Build ONE argument string with explicit quoting. Passing -ArgumentList an array does
        # NOT quote elements that contain spaces: "4070S is up." would arrive as three separate
        # arguments, the notify script would fail to bind them, and - because it is started
        # hidden - the failure would be completely silent. (Found exactly that way.)
        #
        # The quotes must be DOUBLE quotes. Windows command-line parsing strips double quotes;
        # it does not strip single quotes, so -File 'D:\...ps1' would look for a file whose
        # name literally begins with an apostrophe. Embedded double quotes are folded to
        # apostrophes so they cannot break out of the quoting.
        $q = { param($s) '"' + ($s -replace '"', "'") + '"' }
        $argLine = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass ' +
                   ('-File {0} -Title {1} -Body {2} -Seconds {3}' -f (& $q $notifier), (& $q $Title), (& $q $Body), $Seconds)
        # Run it as a separate process on purpose: it needs an STA thread and a message loop,
        # and it must not block the action that is reporting its result.
        Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList $argLine | Out-Null
    } catch {
        Write-Log "reminder window not shown: $($_.Exception.Message)"
    }
}

function Get-LocalizedPnpMap {
    # pnputil localises its text depending on whether a console is attached, so a redirected
    # run can return Chinese where an interactive one returns English. Non-ASCII literals are
    # deliberately avoided in this file (a previous edit corrupted them and broke parsing),
    # so the localised spellings are built from code points instead of being typed out.
    #
    #   U+72B6 U+6001 = status label        U+95EE U+9898 U+4EE3 U+7801 = problem-code label
    #   U+5DF2 U+542F U+52A8 = Started      U+5DF2 U+7981 U+7528 = Disabled
    #   U+5DF2 U+505C U+6B62 = Stopped      U+65AD U+5F00 U+8FDE U+63A5 = Disconnected
    #   U+95EE U+9898 = Problem             U+672A U+77E5 = Unknown
    #   U+5931 U+8D25 = "failed"            U+62D2 U+7EDD U+8BBF U+95EE = "access denied"
    if ($script:LocalizedPnpMap) { return $script:LocalizedPnpMap }
    $c = { param([int[]]$Points) -join ($Points | ForEach-Object { [char]$_ }) }
    $script:LocalizedPnpMap = @{
        Values  = @{
            (& $c @(0x5DF2, 0x542F, 0x52A8))             = 'Started'
            (& $c @(0x5DF2, 0x7981, 0x7528))             = 'Disabled'
            (& $c @(0x5DF2, 0x505C, 0x6B62))             = 'Stopped'
            (& $c @(0x65AD, 0x5F00, 0x8FDE, 0x63A5))     = 'Disconnected'
            (& $c @(0x95EE, 0x9898))                     = 'Problem'
            (& $c @(0x672A, 0x77E5))                     = 'Unknown'
        }
        Labels  = @{
            (& $c @(0x72B6, 0x6001))                     = 'Status'
            (& $c @(0x95EE, 0x9898, 0x4EE3, 0x7801))     = 'Problem Code'
        }
        Failure = @(
            (& $c @(0x5931, 0x8D25))
            (& $c @(0x62D2, 0x7EDD, 0x8BBF, 0x95EE))
        )
    }
    $script:LocalizedPnpMap
}

function Test-PnpOutputFailure {
    # pnputil exits 0 even when it fails, so the text has to be judged as well. This does not
    # decide anything on its own: the caller always verifies the real device state afterwards.
    param([string]$Output)
    if (-not $Output) { return $false }
    if ($Output -match 'Failed to') { return $true }
    $map = Get-LocalizedPnpMap
    foreach ($token in $map.Failure) { if ($Output.Contains($token)) { return $true } }
    $false
}

function Get-DisplayAdapters {
    # pnputil is used instead of Get-PnpDevice so this also works in contexts where
    # the WMI provider is restricted for the caller.
    $r = Invoke-Pnputil @('/enum-devices', '/connected', '/class', 'Display')
    $list = @()
    foreach ($block in ($r.Output -split "(?:\r?\n){2,}")) {
        if ($block -notmatch 'Instance ID:') { continue }
        $name = ''; $status = ''; $id = ''
        foreach ($line in ($block -split "`r?`n")) {
            if ($line -match '^\s*Instance ID:\s*(.+?)\s*$')         { $id = $Matches[1] }
            if ($line -match '^\s*Device Description:\s*(.+?)\s*$')  { $name = $Matches[1] }
            if ($line -match '^\s*Status:\s*(.+?)\s*$')              { $status = $Matches[1] }
        }
        $list += [pscustomobject]@{ Name = $name; Status = $status; InstanceId = $id }
    }
    $list
}

function Test-Preflight {
    param([switch]$Force)
    # Returns $true when it is safe to stop the eGPU, or when -Force overrides.
    $adapters = @(Get-DisplayAdapters)
    if ($adapters.Count -gt 0) {
        $active = @($adapters | Where-Object { $_.Status -eq 'Started' })
        if ($active.Count -le 1) {
            Write-Log 'only one active display adapter: refusing to disable it (the system would lose all display output)' 'ERROR'
            return $false
        }
    }

    $mon = Get-AttachedMonitorOnEGpu
    if ($mon.Attached) {
        $msg = "an external display looks attached (source={0}): disabling will blank it and move the desktop to the iGPU" -f $mon.Source
        if ($Force) { Write-Log $msg 'WARN' }
        else {
            Write-Log $msg 'WARN'
            Write-Log 'refusing without -Force; unplug the monitor from the 4070S or re-run with -Force' 'ERROR'
            return $false
        }
    }
    $true
}

# ----------------------------------------------------------------- actions ---

# Serialisation gate shared with eGPU-Watch.ps1. Without it the scheduled Boot-Enable task
# and the resident watcher can act on the same device simultaneously - visible in the logs
# as two Enable runs inside one second. The path MUST match the watcher's exactly, or the two
# would guard different files and the serialisation would silently do nothing.
$LockDir = Join-Path (Split-Path -Parent $LogFile) 'state'
$ActionLockPath = Join-Path $LockDir 'action.lock'
$script:ActionLockStream = $null

function Initialize-LockDir {
    if (Test-Path -LiteralPath $LockDir) { return }
    New-Item -ItemType Directory -Force -Path $LockDir | Out-Null
    # Keep the lock directory accessible to authenticated users: it holds no secrets, and a
    # non-elevated diagnostic run must be able to read/inspect the locks when troubleshooting.
    try {
        $acl = Get-Acl -LiteralPath $LockDir
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            'BUILTIN\Users', 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $LockDir -AclObject $acl
    } catch {
        Write-Log "could not relax ACL on $LockDir : $($_.Exception.Message)" 'WARN'
    }
}

function Enter-ActionLock {
    param([int]$TimeoutSeconds = 5)
    Initialize-LockDir
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $script:ActionLockStream = [IO.File]::Open($ActionLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
            return $true
        } catch {
            Start-Sleep -Milliseconds 200
        }
    }
    $false
}

function Exit-ActionLock {
    if ($script:ActionLockStream) {
        $script:ActionLockStream.Close()
        $script:ActionLockStream.Dispose()
        $script:ActionLockStream = $null
    }
    Remove-Item -LiteralPath $ActionLockPath -Force -ErrorAction SilentlyContinue
}

function Invoke-Disable {
    # -StayDown is passed by the nightly task and by nothing else, so it is the precise marker
    # for "this is the scheduled run". That is what lets -Action Pause skip the SCHEDULE without
    # blocking a manual -Action Disable, which is an explicit request and must always be honoured.
    if ($StayDown -and (Test-Pause)) {
        Write-Log 'paused for today (-Action Pause) - skipping the scheduled disconnect'
        return 0
    }

    $gpu = Get-EGpuInstanceId | Select-Object -First 1
    # No device is the normal situation when the dock is switched off, not a fault. Logging it
    # as ERROR put a red line in the log on every such night, which is exactly how a log stops
    # being read. Exit code 2 still marks "not found" for callers.
    if (-not $gpu) { Write-Log "no eGPU attached (no $MatchDescription in the device tree) - nothing to disable"; return 2 }

    $state = Get-DeviceState $gpu.InstanceId
    if ($state.Disabled -or $state.Status -eq 'Disabled') {
        Write-Log "already disabled (ConfigFlags=0x$('{0:X}' -f $gpu.ConfigFlags)) - nothing to do"
        return 3
    }

    # A device that is present but not Started is not providing display output, so there is
    # nothing to switch off - and no output to lose. This is the normal case when the user has
    # already stopped the GPU by hand after seeing the reminder, or the USB4 tunnel went down.
    #
    # Letting these through was the actual cause of 2026-10-22 23:55: the GPU had been
    # disconnected by hand minutes earlier, so only the iGPU was active, the "only active display
    # adapter" guard fired, and the log recorded an ERROR with exit 5 for a no-op.
    if ($state.Status -ne 'Started') {
        Write-Log "device is not started (status=$($state.Status)) - nothing to disable"
        return 3
    }

    if (-not (Test-Preflight -Force:$Force)) { return 5 }
    if (-not (Enter-ActionLock)) { Write-Log 'another recovery action is running - aborting' 'ERROR'; return 4 }

    try {
        Write-Log "disabling $($gpu.Desc) [$($gpu.InstanceId)]"
        $r = Invoke-Pnputil @('/disable-device', $gpu.InstanceId)
        $failedText = Test-PnpOutputFailure $r.Output
        Write-Log "pnputil exit=$($r.ExitCode) :: $($r.Output -replace "`r?`n", ' | ')" $(if ($failedText) { 'ERROR' } else { 'INFO' })

        $ok = $false
        $s = $null
        # authoritative check: the disabled bit in the device's registry key
        $attempts = if ($failedText) { 4 } else { 16 }
        for ($i = 0; $i -lt $attempts; $i++) {
            Start-Sleep -Milliseconds 500
            $s = Get-DeviceState $gpu.InstanceId
            if ($s.Disabled -or $s.Status -eq 'Disabled') { $ok = $true; break }
        }

        if ($ok) {
            Write-Log 'eGPU stopped (display output is now on the iGPU)'
            # Only the nightly task stays down. Without this the watcher sees "disabled" and
            # turns the GPU straight back on - observed on 2026-10-13 23:55, undone in under
            # 3 seconds, so the screen only flickered.
            # A manual disable deliberately does NOT stay down, so unplugging and replugging
            # the dock still gets the GPU back automatically.
            if ($StayDown) { New-StayDown }
            else { Write-Log 'manual stop: the watcher will bring the eGPU back if it reappears' }
            if ($Toast) { Show-Toast 'eGPU' '4070S stopped. Ready for the power cut.' }
            return 0
        }
        $lastStatus = if ($s) { $s.Status } else { 'unknown' }
        $lastFlags = if ($s) { '{0:X}' -f [int]$s.ConfigFlags } else { 'n/a' }
        $window = [int]($attempts * 0.5)
        Write-Log "disable did not take effect within ${window}s (last status: $lastStatus, ConfigFlags=0x$lastFlags)" 'ERROR'
        if ($Toast) { Show-Toast 'eGPU' 'Failed to stop the 4070S - check the log.' }
        return 4
    } finally {
        Exit-ActionLock
    }
}

function Invoke-Enable {
    # Deliberately does NOT wait for the device to reach "Started": the watcher re-reads the
    # state on its next tick, and the previous 30-second blocking wait was pure waste (it
    # showed up in the logs as a pointless 13:52:44 -> 13:53:17 stall).
    #
    # Enable is an explicit request to bring the GPU up, so it also closes the stay-down
    # window. That is what makes the intent unambiguous: Disable says "keep it down",
    # Enable says "bring it up", and the watcher simply obeys whichever was said last
    # within the current boot session.
    Clear-StayDown
    $gpu = Get-EGpuInstanceId | Select-Object -First 1
    if (-not $gpu) { Write-Log "no eGPU attached (no $MatchDescription in the device tree) - nothing to enable"; return 2 }

    $state = Get-DeviceState $gpu.InstanceId
    if ($state.Status -eq 'Started') { Write-Log 'already started - nothing to do'; return 3 }
    if ($state.Status -eq 'Problem' -and $state.ProblemCode -eq 43) {
        Write-Log 'device reports Problem 43 (CM_PROB_FAILED_POST_START): it is on the bus but failed its own start - no rescan can fix that, power-cycle the dock' 'ERROR'
        return 4
    }
    if ($state.Status -eq 'Disconnected') {
        Write-Log 'device reports Disconnected - the USB4 tunnel is down; power the dock and plug the cable' 'WARN'
        return 2
    }
    if (-not $state.Present -and -not $gpu.HasParams) {
        Write-Log 'device is not present and has no live driver node: nothing to enable (power the dock first)' 'ERROR'
        return 2
    }
    if (-not (Enter-ActionLock)) { Write-Log 'another recovery action is running - aborting' 'ERROR'; return 4 }

    try {
        Write-Log "enabling (status=$($state.Status), configFlags=0x$('{0:X}' -f $gpu.ConfigFlags))"
        if ($state.Disabled -or $state.Status -eq 'Disabled') {
            $r = Invoke-Pnputil @('/enable-device', $gpu.InstanceId)
            $bad = Test-PnpOutputFailure $r.Output
            Write-Log "pnputil /enable-device exit=$($r.ExitCode) :: $($r.Output -replace "`r?`n", ' | ')" $(if ($bad) { 'ERROR' } else { 'INFO' })
            if ($bad) { return 4 }
        } else {
            # Not flag-disabled: the node exists but never started, so ask the bus to
            # re-enumerate rather than forcing an enable on a node the kernel may not own.
            Write-Log 'device is not flagged disabled: re-scanning the bus instead'
            $r = Invoke-Pnputil @('/scan-devices')
            if (Test-PnpOutputFailure $r.Output) { Write-Log $r.Output 'ERROR'; return 4 }
        }
        # One cheap confirmation; the watcher is responsible for anything beyond this.
        Start-Sleep -Milliseconds 800
        $after = Get-DeviceState $gpu.InstanceId
        if ($after.Status -eq 'Started') {
            Write-Log 'eGPU started'
            if ($Toast) { Show-Toast 'eGPU' '4070S is up.' }
            return 0
        }
        Write-Log "enable issued but status is still '$($after.Status)' - the watcher will re-check" 'WARN'
        return 4
    } finally {
        Exit-ActionLock
    }
}

function Invoke-Restart {
    $gpu = Get-EGpuInstanceId | Select-Object -First 1
    if (-not $gpu) { Write-Log "no $MatchDescription found" 'ERROR'; return 2 }

    # A stale node never comes back by itself; a live tunnel needs the bus to re-enumerate.
    # Repeated attempts are pointless (that is how the GPU ended up sitting at Problem 43),
    # so this runs once, waits briefly, and reports honestly.
    if (-not (Enter-ActionLock)) { Write-Log 'another recovery action is running - aborting' 'ERROR'; return 4 }
    try {
        Write-Log 'removing the device node, then re-scanning the bus'
        $r1 = Invoke-Pnputil @('/remove-device', $gpu.InstanceId)
        Write-Log "pnputil /remove-device exit=$($r1.ExitCode) :: $($r1.Output -replace "`r?`n", ' | ')" $(if (Test-PnpOutputFailure $r1.Output) { 'ERROR' } else { 'INFO' })
        Start-Sleep -Seconds 2
        $r2 = Invoke-Pnputil @('/scan-devices')
        Write-Log "pnputil /scan-devices exit=$($r2.ExitCode) :: $($r2.Output -replace "`r?`n", ' | ')"

        $s = $null
        # A device removed from the bus needs a moment to be re-enumerated by the tunnel.
        for ($i = 0; $i -lt 16; $i++) {
            Start-Sleep -Milliseconds 750
            $s = Get-DeviceState $gpu.InstanceId
            if ($s.Status -eq 'Started') { Write-Log 'eGPU started after restart'; return 0 }
        }
        $last = if ($s) { $s.Status } else { 'unknown' }
        $code = if ($s -and $s.ProblemCode) { " (problem $($s.ProblemCode))" } else { '' }
        Write-Log "device did not come back within 12s (status=$last$code) - the USB4 tunnel needs a real dock power cycle" 'ERROR'
        return 4
    } finally {
        Exit-ActionLock
    }
}

function Invoke-Resume {
    # "The disconnect was intentional, but now I want it back" - without rebooting.
    # Clearing the marker first makes the watcher's next tick a no-op on purpose, and the
    # Enable that follows brings the device up immediately.
    Write-Log 'resume requested: closing the stay-down window and starting the eGPU'
    Clear-StayDown
    Invoke-Enable
}

function Get-GuardTasks {
    # Only useful from an elevated context: a non-elevated process cannot read the SYSTEM tasks
    # at all (schtasks and Get-ScheduledTask both return "Access is denied"), so callers check
    # Test-Admin first rather than mistaking "cannot read" for "does not exist".
    @(Get-ScheduledTask -TaskName 'eGPU-Guard-*' -ErrorAction SilentlyContinue)
}

function Invoke-TasksPower {
    # Turns the whole schedule off or back on. Reversible on purpose: this disables the tasks
    # rather than unregistering them, so every trigger and argument survives for -Action On.
    param([switch]$On)
    $verb = if ($On) { 'On' } else { 'Off' }

    if (-not (Test-Admin)) {
        # Everything else in this script works without admin, so elevation is requested only
        # here, and only to run this one action. The elevated child writes to the same log, so
        # its own account of what happened is kept next to this line.
        Write-Log "changing the tasks needs administrator rights - asking for elevation ($verb)"
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        # Double quotes: Windows strips " but not ', so a single-quoted path arrives verbatim.
        $argLine = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action {1} -LogFile "{2}"' -f $PSCommandPath, $verb, $LogFile
        try {
            $p = Start-Process -FilePath $ps -Verb RunAs -Wait -PassThru -ArgumentList $argLine
            return [int]$p.ExitCode
        } catch {
            Write-Log "elevation was refused or failed: $($_.Exception.Message)" 'ERROR'
            return 6
        }
    }

    $tasks = @(Get-GuardTasks)
    if ($tasks.Count -eq 0) {
        Write-Log 'no eGPU-Guard tasks found - nothing to change' 'ERROR'
        return 2
    }

    $failed = 0
    foreach ($t in $tasks) {
        try {
            if ($On) { $null = Enable-ScheduledTask -TaskName $t.TaskName -ErrorAction Stop }
            else { $null = Disable-ScheduledTask -TaskName $t.TaskName -ErrorAction Stop }
            Write-Log ("task {0} -> {1}" -f $t.TaskName, $(if ($On) { 'enabled' } else { 'disabled' }))
        } catch {
            Write-Log ("could not change {0}: {1}" -f $t.TaskName, $_.Exception.Message) 'ERROR'
            $failed++
        }
    }
    if ($failed -gt 0) { return 4 }
    if ($On) { Write-Log 'all eGPU-Guard tasks are enabled again' }
    else { Write-Log 'all eGPU-Guard tasks are disabled - nothing runs until -Action On' }
    return 0
}

function Invoke-Pause {
    if (Test-Pause) {
        Write-Log 'already paused for today - nothing to do'
        return 3
    }
    New-Pause
    0
}

function Invoke-Unpause {
    Clear-Pause
    0
}

function Invoke-Status {
    # Pause state is reported first: it needs no admin and it changes what tonight will do, so
    # it must be visible even when no device is attached (which returns early below).
    Write-Log "pausedTonight=$(Test-Pause)"

    $gpu = Get-EGpuInstanceId | Select-Object -First 1
    if (-not $gpu) {
        Write-Log "no $MatchDescription found in the device tree" 'WARN'
        if (Test-Admin) {
            foreach ($t in @(Get-GuardTasks)) { Write-Log ("task {0}: {1}" -f $t.TaskName, $t.State) }
        } else {
            Write-Log 'task state: needs administrator rights, not shown'
        }
        return 2
    }
    $state = Get-DeviceState $gpu.InstanceId
    $mon = Get-AttachedMonitorOnEGpu
    Write-Log "instance=$($gpu.InstanceId)"
    Write-Log "desc=$($gpu.Desc) present=$($state.Present) status=$($state.Status) problemCode=$($state.ProblemCode) configFlags=0x$('{0:X}' -f $gpu.ConfigFlags) hasDriverNode=$($gpu.HasParams)"
    Write-Log "externalMonitorDetected=$($mon.Attached) (source=$($mon.Source))"
    Write-Log "logfile=$LogFile"
    foreach ($a in @(Get-DisplayAdapters)) { Write-Log ("adapter: {0} [{1}] {2}" -f $a.Name, $a.Status, $a.InstanceId) }

    if (Test-Admin) {
        foreach ($t in @(Get-GuardTasks)) { Write-Log ("task {0}: {1}" -f $t.TaskName, $t.State) }
    } else {
        Write-Log 'task state: needs administrator rights, not shown'
    }
    0
}

# -------------------------------------------------------------------- main ---

Initialize-Console
Limit-LogFile
Write-Log "----- start (pid=$PID, user=$env:USERNAME) -----"

switch ($Action) {
    'Disable' { $code = Invoke-Disable }
    'Enable'  { $code = Invoke-Enable }
    'Resume'  { $code = Invoke-Resume }
    'Restart' { $code = Invoke-Restart }
    'Status'  { $code = Invoke-Status }
    'Pause'   { $code = Invoke-Pause }
    'Unpause' { $code = Invoke-Unpause }
    'Off'     { $code = Invoke-TasksPower }
    'On'      { $code = Invoke-TasksPower -On }
}

Write-Log "----- end (exit=$code) -----"
exit $code

