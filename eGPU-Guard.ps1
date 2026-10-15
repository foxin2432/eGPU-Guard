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
#>
[CmdletBinding()]
param(
    [ValidateSet('Disable', 'Enable', 'Resume', 'Restart', 'Status')]
    [string]$Action = 'Status',

    [string]$LogFile = "$env:ProgramData\eGPU-Guard\eGPU-Guard.log",
    [string]$MatchDescription = '4070 SUPER',
    [string]$MatchDeviceId = 'DEV_2783',
    [switch]$Force,
    [switch]$Toast,

    # Only the scheduled nightly task passes this. It opens the "stay down" window so the
    # watcher does not immediately undo the disconnect. A manual `-Action Disable` does NOT
    # stay down: the GPU should come back by itself if it is plugged in again.
    [switch]$StayDown
)

$ErrorActionPreference = 'Continue'
# Child keys under ...\Enum\PCI are named "VEN_10DE&DEV_xxxx&..." (no leading "PCI\")
$script:DeviceIdPrefix = "VEN_10DE&$MatchDeviceId&"

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
    param([string]$Title, [string]$Body)
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $template = @"
<toast duration="long">
  <visual>
    <binding template="ToastGeneric">
      <text>$Title</text>
      <text>$Body</text>
    </binding>
  </visual>
</toast>
"@
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch {
        # Not a WARN: a toast can only be shown by an interactive caller. When the scheduled
        # task runs as SYSTEM (session 0) this always fails with E_ACCESSDENIED, and that is
        # expected - the log line is enough to see it was attempted.
        Write-Log "toast not shown (only interactive callers can): $($_.Exception.Message)"
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
    $gpu = Get-EGpuInstanceId | Select-Object -First 1
    if (-not $gpu) { Write-Log "no $MatchDescription found in the PCI device tree" 'ERROR'; return 2 }

    $state = Get-DeviceState $gpu.InstanceId
    if ($state.Disabled -or $state.Status -eq 'Disabled') {
        Write-Log "already disabled (ConfigFlags=0x$('{0:X}' -f $gpu.ConfigFlags)) - nothing to do"
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
    if (-not $gpu) { Write-Log "no $MatchDescription in the device tree (dock off or not plugged)" 'WARN'; return 2 }

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

function Invoke-Status {
    $gpu = Get-EGpuInstanceId | Select-Object -First 1
    if (-not $gpu) { Write-Log "no $MatchDescription found in the device tree" 'WARN'; return 2 }
    $state = Get-DeviceState $gpu.InstanceId
    $mon = Get-AttachedMonitorOnEGpu
    Write-Log "instance=$($gpu.InstanceId)"
    Write-Log "desc=$($gpu.Desc) present=$($state.Present) status=$($state.Status) problemCode=$($state.ProblemCode) configFlags=0x$('{0:X}' -f $gpu.ConfigFlags) hasDriverNode=$($gpu.HasParams)"
    Write-Log "externalMonitorDetected=$($mon.Attached) (source=$($mon.Source))"
    Write-Log "logfile=$LogFile"
    foreach ($a in @(Get-DisplayAdapters)) { Write-Log ("adapter: {0} [{1}] {2}" -f $a.Name, $a.Status, $a.InstanceId) }
    0
}

# -------------------------------------------------------------------- main ---

Initialize-Console
Write-Log "----- start (pid=$PID, user=$env:USERNAME) -----"

switch ($Action) {
    'Disable' { $code = Invoke-Disable }
    'Enable'  { $code = Invoke-Enable }
    'Resume'  { $code = Invoke-Resume }
    'Restart' { $code = Invoke-Restart }
    'Status'  { $code = Invoke-Status }
}

Write-Log "----- end (exit=$code) -----"
exit $code

