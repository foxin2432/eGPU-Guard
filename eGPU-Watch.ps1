<#
    eGPU-Watch.ps1  -  resident watcher: bring the eGPU up as soon as Windows sees it.

    Design rules (each one exists because an earlier version violated it):
      1. No child processes. Every action is an in-process pnputil call. Spawning
         powershell.exe per attempt is what made boot feel heavy while the device sat in a
         retry loop.
      2. Absence costs one registry read. Nothing else runs while no eGPU is attached, so on
         a machine without the dock this process is effectively asleep.
      3. One instance, enforced by an exclusive file handle. A PID-checked lock file is not
         enough: PIDs get reused, and a stale one then blocks the watcher forever. The handle
         is released by the kernel on process death, so it can never go stale.
      4. No overlapping actions. Recovery is serialised through a lock file shared with the
         Boot-Enable task, and each (state, attempt) pair fires at most once.
      5. The watcher only ever ENABLES - it never removes a device node. A remove + rescan was
         tried for Problem 43 and was actively harmful: it deleted the node while the USB4
         tunnel was still training, and the GPU then stayed missing for the rest of the boot
         (2026-10-15 09:50). Enabling is safe and reversible; a node is never destroyed. When a
         device genuinely failed to start, the fix is a physical dock power cycle, so the
         watcher just waits and leaves the node alone.
      6. Transient states are waited out, not judged. Disconnected/Unknown only mean the USB4
         tunnel has not finished coming up; they usually clear within seconds.
      7. Retries escalate (5/10/20/30/60 s) instead of one flat 10-minute nap, so a device that
         becomes usable shortly after is still picked up promptly.
#>
[CmdletBinding()]
param(
    [int]$IntervalSeconds = 4,          # steady-state poll once the device is up
    [int]$BurstSeconds = 120,           # fast poll window right after this process starts
    [int]$IdleIntervalSeconds = 20,     # poll cadence while no eGPU is attached
    [int]$AbsentScanSeconds = 300,      # how rarely to ask the bus to re-enumerate when absent
    [int]$ProblemBackoffSeconds = 60,   # cap for the escalating give-up delay
    [int]$StateRetries = 1,             # recovery attempts per state change before giving up

    # Escalating delay after a failed recovery, instead of one flat 10-minute nap.
    # A flat 600 s backoff was the actual cause of "connecting takes forever": the log shows
    # a single failed attempt at 15:45:30, then nothing until 15:55:34 - 9m41s of sleeping
    # while the GPU had long since become usable.
    [int[]]$BackoffSeconds = @(5, 10, 20, 30, 60),

    # How long a device may sit in a transient state (Disconnected/Unknown, i.e. the USB4
    # tunnel has not finished coming up) before the log points out that it needs a physical
    # dock power cycle. Purely informational: the watcher never removes a node, it keeps
    # polling at the plan's cadence and enables the device the moment it becomes usable.
    [int]$TransientGraceSeconds = 45,

    [string]$LogFile = (Join-Path $env:ProgramData 'eGPU-Guard\eGPU-Guard.log'),
    [switch]$Once,                      # evaluate one tick and exit (testing)
    [switch]$SimulateAbsent,            # behave as if no eGPU were attached (testing)

    # Exit as soon as the device is up instead of staying resident forever.
    #
    # Once the GPU is Started this process has nothing left to do: the 23:55 task performs the
    # scheduled disconnect, and `-Action Enable` is available by hand. Staying resident only
    # costs a pnputil spawn per tick (measured: 0.083 % of a core, ~72 s of CPU per day, plus
    # process churn). Default ON, because idle cost with no benefit is wasted cost.
    [switch]$StopWhenRunning,

    # Hard upper bound on the wait, so a dock that never appears (or a device stuck in a
    # Problem state, which no software action fixes) cannot leave a process resident forever.
    [int]$IdleExitMinutes = 30
)

$ErrorActionPreference = 'Continue'
$DeviceKeyPrefix = 'VEN_10DE&DEV_2783&'
$PnpUtil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
$StateDir = Join-Path $env:ProgramData 'eGPU-Guard'
# Lock files live in their own subdirectory so that a human or a diagnostic run can inspect
# them without elevation. Each lock is only ever opened exclusively by its single owner.
$LockDir = Join-Path $StateDir 'state'
$LockPath = Join-Path $LockDir 'watch.lock'
$ActionLockPath = Join-Path $LockDir 'action.lock'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] Watch {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try {
        if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

# ------------------------------------------------- predecessor / single instance ---
# The lock is an EXCLUSIVE FILE HANDLE held for this process's whole lifetime, not a PID
# written into a file. A PID file is not safe here: PIDs are reused, so a dead watcher's
# number can be taken by an unrelated process and the new watcher then refuses to start
# ("another eGPU watcher is running") - which silently disables recovery for good. With an
# exclusive handle the kernel releases the lock the instant the process dies, so a stale lock
# is impossible and no PID liveness check is needed.
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
if (-not (Test-Path $LockDir)) {
    New-Item -ItemType Directory -Force -Path $LockDir | Out-Null
    # The lock directory holds no secrets and must stay inspectable by a non-elevated
    # diagnostic run, so authenticated users keep Modify on it.
    try {
        $acl = Get-Acl -LiteralPath $LockDir
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            'BUILTIN\Users', 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $LockDir -AclObject $acl
    } catch { }
}
$script:LockStream = $null
try {
    $script:LockStream = [IO.File]::Open($LockPath, 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
    Write-Host 'another eGPU watcher already holds the lock - exiting'
    exit 0
}
# We own the lock: record the owner for diagnostics and drop any stale contents.
$script:LockStream.SetLength(0)
$lockBytes = [Text.Encoding]::ASCII.GetBytes("$PID`n$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n")
$script:LockStream.Write($lockBytes, 0, $lockBytes.Length)
$script:LockStream.Flush()

# --------------------------------------------------------------------- helpers ---
function Get-EGpuNode {
    # Fast path: one registry read. pnputil is only consulted when the node exists.
    # A successful lookup is cached: the instance id only changes when the bus
    # re-enumerates the device, and that is exactly when the cached path stops resolving.
    if ($SimulateAbsent) { return $null }
    if ($script:CachedNode) {
        if (Test-Path -LiteralPath ("HKLM:\SYSTEM\CurrentControlSet\Enum\PCI\" + ($script:CachedNode -replace '^PCI\\', ''))) {
            return $script:CachedNode
        }
        $script:CachedNode = $null
    }
    $parents = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like "$DeviceKeyPrefix*" })
    foreach ($parent in $parents) {
        $inst = @(Get-ChildItem -LiteralPath $parent.PSPath -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($inst.Count -gt 0) {
            $script:CachedNode = "PCI\$($parent.PSChildName)\$($inst[0].PSChildName)"
            return $script:CachedNode
        }
    }
    return $null
}

function Get-LocalizedPnpMap {
    # pnputil localises its text depending on whether a console is attached, so a redirected
    # run can return Chinese where an interactive one returns English. Non-ASCII literals
    # are deliberately avoided in this file (an earlier edit corrupted them and broke
    # parsing), so the localised spellings are built from code points instead.
    if ($script:LocalizedPnpMap) { return $script:LocalizedPnpMap }
    $c = { param([int[]]$Points) -join ($Points | ForEach-Object { [char]$_ }) }
    $script:LocalizedPnpMap = @{
        Values  = @{
            (& $c @(0x5DF2, 0x542F, 0x52A8))         = 'Started'
            (& $c @(0x5DF2, 0x7981, 0x7528))         = 'Disabled'
            (& $c @(0x5DF2, 0x505C, 0x6B62))         = 'Stopped'
            (& $c @(0x65AD, 0x5F00, 0x8FDE, 0x63A5)) = 'Disconnected'
            (& $c @(0x95EE, 0x9898))                 = 'Problem'
            (& $c @(0x672A, 0x77E5))                 = 'Unknown'
        }
        Failure = @(
            (& $c @(0x5931, 0x8D25))
            (& $c @(0x62D2, 0x7EDD, 0x8BBF, 0x95EE))
        )
    }
    $script:LocalizedPnpMap
}

function Get-EGpuState {
    param([Parameter(Mandatory)][string]$InstanceId)
    $text = (@(& $PnpUtil /enum-devices /instanceid $InstanceId 2>&1) | ForEach-Object { "$_" }) -join [Environment]::NewLine
    $state = [pscustomobject]@{
        Present     = [bool]($text -match 'Instance ID:')
        Status      = 'Unknown'
        ProblemCode = $null
    }
    # Status is derived without trusting label text: pnputil keeps the status VALUES in
    # English even when it localises its labels, and a Problem Code line is structural.
    # Localised values are mapped from code points as a fallback.
    $map = Get-LocalizedPnpMap
    foreach ($key in $map.Values.Keys) {
        if ($text.Contains($key)) { $text = $text.Replace($key, $map.Values[$key]) }
    }
    foreach ($line in ($text -split "`r?`n")) {
        foreach ($v in 'Started', 'Disabled', 'Stopped', 'Disconnected', 'Problem', 'Unknown') {
            if ($line -match ('(?:^|\s)' + [regex]::Escape($v) + '(?:\s|$)')) { $state.Status = $v; break }
        }
        if ($line -match '\b(\d+)\s*\(0x[0-9A-Fa-f]+\)') { $state.ProblemCode = [int]$Matches[1] }
    }
    $state
}

function Get-RecoveryPlan {
    # The watcher only ever ENABLES. It must never remove a device node: doing that while the
    # USB4 tunnel is still training makes the GPU disappear for the rest of the boot, which is
    # precisely what happened on 2026-10-15 09:50. A Problem node (43 and friends) means the
    # device reached the bus but failed its own start - no software action fixes that, only a
    # dock power cycle does, so the node is left intact and simply waited on.
    param($State)
    switch ($State.Status) {
        'Started'  { return @{ Action = 'None';   Cadence = 0; Reason = 'running' } }
        'Disabled' { return @{ Action = 'Enable'; Cadence = 0; Reason = 'configuration-disabled' } }
        'Stopped'  { return @{ Action = 'Enable'; Cadence = 0; Reason = 'not started' } }

        # Transient: the node exists but the USB4 tunnel has not finished coming up. The GPU
        # very often becomes usable on its own within seconds, so WAIT. Acting here is worse
        # than useless - see rule 5 above.
        'Disconnected' { return @{ Action = 'Wait'; Cadence = 3; Reason = 'tunnel still coming up' } }
        'Unknown'      { return @{ Action = 'Wait'; Cadence = 3; Reason = 'state not readable yet' } }

        # Not repairable in software. Wait (bounded by the hard deadline) and leave the node
        # alone; a physical dock power cycle is the fix. Polled tighter than a minute because
        # this state is very often transient at boot: on the reference machine "Problem 18"
        # appeared 23 s after boot and had cleared to Started by 54 s, entirely on its own.
        'Problem' { return @{ Action = 'Wait'; Cadence = 5; Reason = "problem $($State.ProblemCode) - needs a dock power cycle" } }

        default { return @{ Action = 'Wait'; Cadence = 10; Reason = "status $($State.Status) - nothing to do" } }
    }
}

function Invoke-Pnp {
    param([string[]]$Arguments)
    $lines = @(& $PnpUtil @Arguments 2>&1)
    $code = $LASTEXITCODE
    $text = ($lines | ForEach-Object { "$_" }) -join [Environment]::NewLine
    # pnputil exits 0 even when it fails, so its text has to be judged too. Localised
    # spellings come from Get-LocalizedPnpMap because this file must stay pure ASCII.
    $failure = ($text -match 'Failed to')
    if (-not $failure) {
        foreach ($token in (Get-LocalizedPnpMap).Failure) { if ($text.Contains($token)) { $failure = $true; break } }
    }
    $ok = ((($null -eq $code) -or ($code -eq 0)) -and (-not $failure))
    [pscustomobject]@{ Ok = $ok; Text = ($text -replace "`r?`n", ' | ').Trim() }
}

$script:ActionLockStream = $null
function Enter-ActionLock {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        try {
            $script:ActionLockStream = [IO.File]::Open($ActionLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
            return $true
        } catch {
            Start-Sleep -Milliseconds 200
        }
    }
    return $false
}

function Exit-ActionLock {
    if ($script:ActionLockStream) {
        $script:ActionLockStream.Close()
        $script:ActionLockStream.Dispose()
        $script:ActionLockStream = $null
    }
    Remove-Item -LiteralPath $ActionLockPath -Force -ErrorAction SilentlyContinue
}

function Invoke-Recovery {
    # Serialised against the Boot-Enable task so the two never act at the same time.
    # NOTE: the parameter is NOT called $Action - $Action is a script-level parameter, and
    # script parameter variables are read-only, so reusing the name silently discards the
    # assignment and collapses the value to a string.
    param([string]$PlanAction, [string]$InstanceId)
    if (-not (Enter-ActionLock)) {
        Write-Log 'another recovery action is running - skipping this tick'
        return $null
    }
    try {
        switch ($PlanAction) {
            'Enable' {
                Write-Log "action: enable [$InstanceId]"
                return Invoke-Pnp @('/enable-device', $InstanceId)
            }
            # The watcher deliberately has NO remove/rescan path. It used to remove a failed
            # node and let the bus re-enumerate it, but that destroyed nodes mid-enumeration
            # and left the GPU missing for the rest of a boot. A manual `-Action Restart`
            # remains available in eGPU-Guard.ps1 when a human decides it is warranted.
            default {
                Write-Log "refusing unsupported action '$PlanAction' - the watcher only enables" 'WARN'
                return [pscustomobject]@{ Ok = $false; Text = "action '$PlanAction' is not performed by the watcher" }
            }
        }
    } finally {
        Exit-ActionLock
    }
}

function Test-StayDown {
    # True while the eGPU was deliberately stopped in THIS boot session.
    #
    # This watcher's purpose is "not started -> start it", which is the exact opposite of what
    # the 23:55 disconnect wants. Without this check the two fight: the scheduled Disable
    # succeeds and the watcher re-enables the GPU seconds later (observed on 2026-10-13 at
    # 23:55:02, undone in under 3 seconds, so the screen only flickered).
    #
    # The marker records the boot time it was written in, so it expires by itself on the next
    # boot and a fresh start can bring the GPU up as usual. `-Action Resume` clears it too.
    $path = Join-Path $StateDir 'state\stay-down'
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $boot = $null
    try { $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { }
    if (-not $boot) { return $true }
    $stamp = $null
    try { $stamp = [datetime]::Parse((Get-Content -LiteralPath $path -Raw -ErrorAction Stop).Trim()) } catch { }
    if (-not $stamp) { return $true }
    if ([math]::Abs(($stamp - $boot).TotalSeconds) -gt 60) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        return $false
    }
    return $true
}

# ------------------------------------------------------------------------ main ---
$startedAt = Get-Date
$lastScan = [datetime]::MinValue
$lastState = $null
$lastActionKey = $null
$attempts = 0
$failStreak = 0
$transientSince = $null
$idleUntil = [datetime]::MinValue
$script:CachedNode = $null
$stayDownLogged = $false
$script:stuckLogged = $false

Write-Log "watcher started (pid=$PID interval=${IntervalSeconds}s idle=${IdleIntervalSeconds}s burst=${BurstSeconds}s retries=$StateRetries backoff=$($BackoffSeconds -join '/')s grace=${TransientGraceSeconds}s)"

try {
    while ($true) {
        $now = Get-Date

        # A deliberate stop outranks this watcher's whole purpose. Checked before the (more
        # expensive) device lookup so a stay-down window costs one file test per tick.
        # Hard deadline. Bounds the process lifetime when the dock never shows up, or when the
        # device sits in a Problem state that no software action can clear - otherwise the
        # process would stay resident forever waiting for something that is not coming.
        if (($now - $startedAt).TotalMinutes -ge $IdleExitMinutes) {
            Write-Log "nothing to do after $IdleExitMinutes min - exiting (a reboot or the Boot-Enable task will try again)"
            exit 0
        }

        if (Test-StayDown) {
            if (-not $stayDownLogged) {
                Write-Log 'stay-down window is open (the eGPU was deliberately stopped) - not re-enabling'
                $stayDownLogged = $true
            }
            $lastState = 'stay-down'; $lastActionKey = $null; $attempts = 0
            if ($Once) { exit 0 }
            Start-Sleep -Seconds $IntervalSeconds
            continue
        }
        $stayDownLogged = $false

        if ($now -lt $idleUntil) {
            if ($Once) { exit 0 }
            $wait = [Math]::Max(1, [Math]::Min($IdleIntervalSeconds, [int]($idleUntil - $now).TotalSeconds))
            Start-Sleep -Seconds $wait
            continue
        }

        $id = Get-EGpuNode

        if (-not $id) {
            if ($lastState -ne 'absent') {
                $lastState = 'absent'; $lastActionKey = $null; $attempts = 0
                $failStreak = 0; $transientSince = $null; $script:stuckLogged = $false
                Write-Log 'eGPU not present - idling'
            }
            # Ask the bus to re-enumerate often at first: at boot the dock is usually already
            # attached and the tunnel finishes training within seconds, so a 5-minute rescan
            # interval would be the dominant delay. It relaxes afterwards to stop the (small
            # but pointless) background cost of scanning forever.
            $sinceStart = ($now - $startedAt).TotalSeconds
            $scanEvery = if ($sinceStart -lt $BurstSeconds) { 5 }
                         elseif ($sinceStart -lt 900) { 20 }
                         else { $AbsentScanSeconds }
            if (($now - $lastScan).TotalSeconds -ge $scanEvery) {
                $lastScan = $now
                $null = Invoke-Pnp @('/scan-devices')
                # A scan can surface the node, so re-read it within the same tick instead of
                # sleeping through another polling interval.
                if (Get-EGpuNode) { continue }
            }
            if ($Once) { exit 1 }
            Start-Sleep -Seconds $(if ($sinceStart -lt $BurstSeconds) { 2 } else { $IdleIntervalSeconds })
            continue
        }

        $state = Get-EGpuState -InstanceId $id
        $plan = Get-RecoveryPlan -State $state

        if ($state.Status -ne $lastState) {
            $suffix = if ($state.ProblemCode) { " (problem $($state.ProblemCode))" } else { '' }
            Write-Log "state -> $($state.Status)$suffix [$id]"
            $lastState = $state.Status
            $lastActionKey = $null
            $attempts = 0
            # A new state ends any wait and clears the failure streak, so a genuine change is
            # never blocked by an earlier backoff.
            $transientSince = $null
            $failStreak = 0
            $script:stuckLogged = $false
        }

        # Nothing to do: the device is running.
        if ($plan.Action -eq 'None') {
            $failStreak = 0
            $transientSince = $null
            # The whole job is done. This is the normal path at boot: the GPU came up, so stop
            # here rather than spawning pnputil every few seconds for the rest of the session.
            if ($StopWhenRunning) {
                $secs = [int]($now - $startedAt).TotalSeconds
                Write-Log "eGPU is running after ${secs}s - exiting (nothing left to do)"
                exit 0
            }
            if ($Once) { exit 0 }
            Start-Sleep -Seconds $IntervalSeconds
            continue
        }

        # Waiting out a state this watcher cannot fix by itself. Formerly one failure triggered
        # a flat 600 s nap, which is why reconnecting felt slow; now the cadence is short and
        # the node is never touched, so the moment the device becomes usable it is enabled.
        #
        # There is deliberately NO escalation to a remove + rescan. That was tried for Problem
        # 43 and caused a real failure: it deleted the node while the USB4 tunnel was still
        # training, and the GPU then stayed missing for the rest of the boot (2026-10-15
        # 09:50). Waiting costs nothing and destroys nothing.
        if ($plan.Action -eq 'Wait') {
            if (-not $transientSince) {
                $transientSince = $now
                Write-Log "$($plan.Reason) - waiting, node left intact"
            }
            $waited = ($now - $transientSince).TotalSeconds
            # Say ONCE, after the grace period, that this is not clearing by itself - without
            # taking any action. A failed start needs a physical dock power cycle.
            if ($waited -ge $TransientGraceSeconds -and -not $script:stuckLogged) {
                Write-Log "still $($state.Status) after $([int]$waited)s - needs a dock power cycle; node left intact" 'WARN'
                $script:stuckLogged = $true
            }
            if ($Once) { exit 0 }
            Start-Sleep -Seconds $plan.Cadence
            continue
        }

        # Enable. Fired at most once per (state, attempt) pair so a device that refuses to
        # start is never hammered.
        $actionKey = "$($state.Status)/$attempts"
        if ($actionKey -ne $lastActionKey) {
            $lastActionKey = $actionKey
            $result = Invoke-Recovery -PlanAction $plan.Action -InstanceId $id
            if ($result -and $result.Ok) {
                Write-Log "$($plan.Action) issued ($($plan.Reason))"
                $attempts = 0
                $failStreak = 0
            } else {
                $attempts++
                $failStreak++
                Write-Log "$($plan.Action) failed: $($result.Text)" 'WARN'
            }
            # Never re-fire immediately: give the bus a moment to present a new state.
            $idleUntil = $now.AddSeconds(4)
            if ($Once) { exit 0 }
            Start-Sleep -Seconds 4
            continue
        }

        # The action already ran for this state and did not succeed. Back off, escalating
        # 5/10/20/30/60 s instead of the old flat 600 s, so the GPU is picked up promptly as
        # soon as it becomes usable.
        $idx = [Math]::Min($failStreak - 1, $BackoffSeconds.Count - 1)
        if ($idx -lt 0) { $idx = 0 }
        $backoff = [Math]::Min($BackoffSeconds[$idx], $ProblemBackoffSeconds)
        if ($failStreak -le 1) {
            Write-Log "retrying $($plan.Action) in ${backoff}s ($($plan.Reason))" 'WARN'
        }
        $idleUntil = $now.AddSeconds($backoff)

        if ($Once) { exit 0 }
        Start-Sleep -Seconds ([Math]::Min($backoff, $IntervalSeconds * 2))
    }
} finally {
    # Release the exclusive handle first, then remove the file. If this process was killed,
    # the kernel already released the handle, so the next watcher can start immediately;
    # the leftover file is harmless and is truncated by the next owner.
    if ($script:LockStream) {
        try { $script:LockStream.Close(); $script:LockStream.Dispose() } catch { }
        $script:LockStream = $null
        Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
    }
}
