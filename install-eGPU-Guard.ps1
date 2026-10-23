<#
    install-eGPU-Guard.ps1  -  register the scheduled tasks (needs an elevated shell).

    Tasks created (all prefixed "eGPU-Guard"):

      eGPU-Guard-Watch        at startup (+3s) and at logon (+3s), as SYSTEM, highest privileges
                              -> boot-time helper: enables the eGPU as soon as Windows lets it,
                                 then EXITS. Gives up after 30 min if the dock never appears.
                                 With no dock attached that is one registry read per poll, so a
                                 machine without the GPU sees no measurable load.
      eGPU-Guard-Boot-Enable  at startup (+2 min) and at logon (+2 min), as SYSTEM
                              -> one-shot fallback, only meaningful if Watch never ran
      eGPU-Guard-HHmm-Disable Sun..Thu at DisableTime, as SYSTEM, highest privileges
                              -> pnputil /disable-device on the matched GPU
      eGPU-Guard-HHmm-Notify  Sun..Thu at NotifyTime, as the interactive user
                              -> bottom-right reminder window with a sound

    Times, nights and the device match come from eGPU-Guard.config.psd1 (or the parameters
    below, which win). Task names carry the time they fire, and re-running this installer
    removes any eGPU-Guard-* task that is no longer part of the schedule - so retiming can
    never leave an old task behind to fire twice.

    Usage
      .\install-eGPU-Guard.ps1                    # notify + disable + boot-enable + watcher
      .\install-eGPU-Guard.ps1 -NotifyTime 22:30 -DisableTime 22:35
      .\install-eGPU-Guard.ps1 -NoWatcherProcess  # keep the startup watcher task but idle its loop
      .\install-eGPU-Guard.ps1 -ShowStatus        # show what is registered right now
      .\uninstall-eGPU-Guard.ps1                  # rollback

    (Parameter names deliberately avoid -Watch/-Status: a script-scope parameter variable
     is read-only, so reusing those names for the Path variables below breaks parameter
     binding with a misleading "Cannot convert String to SwitchParameter" error.)
#>
[CmdletBinding()]
param(
    # NOTE: these parameter names must not collide with the variables used further down.
    # A script-scope parameter variable is read-only, so a later "$Watch = Join-Path ..."
    # fails parameter binding with a very misleading "Cannot convert String to
    # SwitchParameter" error. Hence -RegisterWatcher / -ShowStatus.
    [switch]$NoWatcherProcess,
    [switch]$ShowStatus,
    [string]$NotifyTime = '23:53',
    [string]$DisableTime = '23:58',
    # Sunday..Thursday -> the five nights that precede a power cut
    [System.DayOfWeek[]]$Days = @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday')
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty in a few hosting scenarios; fall back to the invoked path.
$here = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $null }
if (-not $here -or -not (Test-Path (Join-Path $here 'eGPU-Guard.ps1'))) {
    Write-Host 'cannot locate the companion scripts (eGPU-Guard.ps1) next to this installer' -ForegroundColor Red
    exit 1
}
$guardScript = Join-Path $here 'eGPU-Guard.ps1'
$notifyScript = Join-Path $here 'eGPU-Notify.ps1'
$watchScript = Join-Path $here 'eGPU-Watch.ps1'
$prefix = 'eGPU-Guard'

# Times and nights default to eGPU-Guard.config.psd1, which is the file a user is expected to
# edit (or the switch menu edits for them). An explicit parameter still wins, so a one-off test
# install does not have to rewrite shared configuration.
. (Join-Path $here 'eGPU-Config.ps1')
$config = Get-GuardConfig -Path (Join-Path $here 'eGPU-Guard.config.psd1')
if (-not $PSBoundParameters.ContainsKey('NotifyTime')) { $NotifyTime = $config.NotifyTime }
if (-not $PSBoundParameters.ContainsKey('DisableTime')) { $DisableTime = $config.DisableTime }
if (-not $PSBoundParameters.ContainsKey('Days')) { $Days = @($config.Days) }

# Say what is wrong instead of letting Register-ScheduledTask throw something unreadable about a
# trigger it cannot build.
foreach ($pair in @(@('NotifyTime', $NotifyTime), @('DisableTime', $DisableTime))) {
    if ([string]$pair[1] -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') {
        Write-Host ("{0} must look like HH:mm (24-hour), got '{1}'" -f $pair[0], $pair[1]) -ForegroundColor Red
        exit 1
    }
}
foreach ($d in @($Days)) {
    if (@('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday') -notcontains [string]$d) {
        Write-Host ("Days contains '{0}' - use English day names, e.g. Monday" -f $d) -ForegroundColor Red
        exit 1
    }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-Registered {
    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "$prefix*" }
    if (-not $tasks) { Write-Host 'no eGPU-Guard tasks registered'; return }
    foreach ($t in $tasks) {
        $info = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
        $trig = ($t.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ','
        Write-Host ("{0,-26} {1,-9} next={2} last={3} result={4} triggers={5}" -f `
            $t.TaskName, $t.State, $info.NextRunTime, $info.LastRunTime, $info.LastTaskResult, $trig)
    }
}

if ($ShowStatus) { Show-Registered; exit 0 }

if (-not (Test-Admin)) {
    Write-Host 'This installer must run in an ELEVATED PowerShell (Run as administrator).' -ForegroundColor Red
    Write-Host 'Right-click Start -> Terminal (Admin) / Windows PowerShell (Admin), then re-run this file.'
    exit 1
}
foreach ($f in @($guardScript, $notifyScript, $watchScript)) {
    if (-not (Test-Path $f)) { Write-Host "missing script: $f" -ForegroundColor Red; exit 1 }
}

$who = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$script:FailedTasks = @()

# ---------------------------------------------------------------- principal ---
$systemPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$userPrincipal = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Limited

# ------------------------------------------------------------------ triggers ---
$notifyTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Days -At $NotifyTime
$disableTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Days -At $DisableTime
# Two tasks can bring the GPU up, and they must not race at boot.
#
# The WATCHER owns the job: it starts 3 s after the boot trigger fires, polls, retries with a
# 5/10/20/30/60 s backoff, exits when the device is running and gives up after 30 min.
# The single-shot Boot-Enable task is only a FALLBACK for the case where the watcher never
# started at all, so it is deliberately delayed well past the point where the watcher would
# have acted. Running both at boot meant two PowerShell processes and two pnputil calls for
# the same device at the same moment, and the loser logged a spurious "Enable failed" after
# the winner had already brought the device up (observed 2026-10-20 13:27:59).
#
# On the Delay values, measured on the reference machine: a Delay of PT10S produced an actual
# start 23 s after the boot timestamp, because the Delay is counted from when the boot trigger
# FIRES (about 13 s into boot, once the scheduler is ready), not from the boot itself. That
# first ~13 s is not ours to control; the Delay is, so the watcher's is kept small.
#
# Starting early is safe: the watcher never removes a device node, and Disconnected/Unknown/
# Problem are all treated as "wait", so an early start simply observes the tunnel training and
# enables the device the moment it is usable. PT3S keeps a little slack for the PnP service.
$bootTrigger = New-ScheduledTaskTrigger -AtStartup
$bootTrigger.Delay = 'PT2M'
$watchBootTrigger = New-ScheduledTaskTrigger -AtStartup
$watchBootTrigger.Delay = 'PT3S'
# The watcher gets its OWN logon trigger, kept quick: it is a second chance to catch a device
# that the boot attempt missed, and it costs almost nothing when the eGPU is already running
# (it sees Started and exits in well under a second). The fallback enable gets a late one, so
# it cannot race the watcher. Sharing one trigger object between the two tasks is what made a
# single change here silently slow the watcher down as well.
$watchLogonTrigger = New-ScheduledTaskTrigger -AtLogOn
$watchLogonTrigger.Delay = 'PT3S'
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn
$logonTrigger.Delay = 'PT2M'

# ------------------------------------------------------------------- actions ---
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function New-GuardAction {
    param([string[]]$ScriptArgs)
    $quoted = ($ScriptArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    New-ScheduledTaskAction -Execute $psExe `
        -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" {1}' -f $guardScript, $quoted)
}

# No extra argument needed: skipping the reminder when no eGPU is attached is the script's
# default, so the deployed task needs no flag and the behaviour cannot be left half-applied by
# an unregistered task. -Always forces the window regardless.
#
# -Body carries the actual disconnect time. Hard-coding it in the script would let the reminder
# announce one time while the task fires at another - a contradiction that no test would catch,
# because both halves work and only the sentence is wrong.
$notifyBody = '{0} will stop the {1}. Save your work / close games now.' -f $DisableTime, $config.MatchDescription
$notifyAction = New-ScheduledTaskAction -Execute $psExe `
    -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Body "{1}"' -f $notifyScript, $notifyBody)
# -Force is REQUIRED here. Without it the preflight sees the monitor that is attached to the
# 4070S (the normal situation at the disconnect time) and refuses with exit 5, so it
# silently never happens - which is exactly what occurred on 2026-10-12.
# -Force only waives the "external display attached" warning; the separate and far more
# important guard ("refuse if this is the only active display adapter") is NOT waivable, so
# the system can never be left without display output.
# -StayDown is what makes the nightly disconnect stick: it tells the watcher this stop was
# deliberate, so it must not undo it. Without it the watcher re-enables the GPU seconds later
# (observed 2026-10-13 23:55:02, undone in under 3 s, so the screen only flickered).
# The window ends by itself on the next boot, and `-Action Resume` closes it early.
# No -Toast here: this task runs as SYSTEM in session 0, where a toast cannot be shown, so it
# would only add an expected E_ACCESSDENIED line to the log.
$disableAction = New-GuardAction @('-Action', 'Disable', '-Force', '-StayDown')
$enableAction = New-GuardAction @('-Action', 'Enable')
# The watcher task is always registered (it is what makes the GPU come up during boot).
#
# -StopWhenRunning makes it a boot-time helper rather than a permanent resident: it exits as
# soon as the GPU is up. Once the device runs there is nothing left for it to do - the nightly
# task performs the scheduled disconnect - and a resident process would only keep spawning
# pnputil (measured ~72 s of CPU per day, plus a process creation per tick) for no benefit.
# -IdleExitMinutes bounds it further, so a dock that never appears cannot leave it resident.
# -NoWatcherProcess replaces all of that with a single evaluation tick (diagnostics only).
$watchArgs = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $watchScript
if ($NoWatcherProcess) { $watchArgs += ' -Once' } else { $watchArgs += ' -StopWhenRunning' }
$watchAction = New-ScheduledTaskAction -Execute $psExe -Argument $watchArgs

function Register-GuardTask {
    # Registers one task and verifies it really exists afterwards, so a half-finished
    # install cannot silently pass (that happened once: only the first task survived).
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)]$Trigger,
        [Parameter(Mandatory)]$Principal,
        [Parameter(Mandatory)]$Settings,
        [string]$Description = ''
    )
    try {
        $created = Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
            -Principal $Principal -Settings $Settings -Description $Description -Force -ErrorAction Stop
        $check = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        Write-Host ("  OK   {0} ({1})" -f $check.TaskName, $check.State) -ForegroundColor Green
        return $created
    } catch {
        Write-Host ("  FAIL {0}: {1}" -f $TaskName, $_.Exception.Message) -ForegroundColor Red
        $script:FailedTasks += $TaskName
        return $null
    }
}

# ------------------------------------------------------------------ settings ---
$settDisable = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
$settEnable = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$settNotify = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
$settWatch = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

# ------------------------------------------------------------------- register ---
$result = @()

# Task names carry the actual time, so a schedule that no longer matches its name cannot go
# unnoticed (an "-2355-Disable" task firing at 23:58 is a trap for whoever reads the task list
# next). The flip side is that changing the time creates NEW names, so anything left over from
# the previous run has to be removed - otherwise both the old and the new task fire, and the
# nightly disconnect runs twice.
$stamp = { param($t) ($t -replace '[:.]', '') }
$disableName = '{0}-{1}-Disable' -f $prefix, (& $stamp $DisableTime)
$notifyName = '{0}-{1}-Notify' -f $prefix, (& $stamp $NotifyTime)
$keepNames = @("$prefix-Watch", "$prefix-Boot-Enable", $disableName, $notifyName)

Write-Host 'Registering scheduled tasks:'

# Registered first on purpose: this is the piece that gets the GPU up during boot.
$result += Register-GuardTask -TaskName "$prefix-Watch" -Action $watchAction `
    -Trigger @($watchBootTrigger, $watchLogonTrigger) -Principal $systemPrincipal -Settings $settWatch `
    -Description 'Resident watcher: enable the eGPU as soon as it appears (runs from startup)'

$result += Register-GuardTask -TaskName "$prefix-Boot-Enable" -Action $enableAction `
    -Trigger @($bootTrigger, $logonTrigger) -Principal $systemPrincipal -Settings $settEnable `
    -Description 'At startup/logon: if the eGPU is present but disabled/not started, enable it'

$result += Register-GuardTask -TaskName $disableName -Action $disableAction `
    -Trigger $disableTrigger -Principal $systemPrincipal -Settings $settDisable `
    -Description "Stop $($config.MatchDescription) at $DisableTime (Sun-Thu) ahead of the dorm power cut"

$result += Register-GuardTask -TaskName $notifyName -Action $notifyAction `
    -Trigger $notifyTrigger -Principal $userPrincipal -Settings $settNotify `
    -Description "Reminder 5 minutes before the nightly eGPU disconnect at $DisableTime"

# Only after everything above registered: remove tasks this kit owns that are no longer part of
# the schedule (typically a time change). Doing it afterwards means a failed registration can
# never leave the machine with no working task at all.
$stale = @(Get-ScheduledTask -TaskName "$prefix*" -ErrorAction SilentlyContinue |
    Where-Object { $keepNames -notcontains $_.TaskName })
foreach ($t in $stale) {
    try {
        Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false -ErrorAction Stop
        Write-Host ("  DEL  {0} (no longer part of the schedule)" -f $t.TaskName) -ForegroundColor Yellow
    } catch {
        Write-Host ("  WARN could not remove stale task {0}: {1}" -f $t.TaskName, $_.Exception.Message) -ForegroundColor Yellow
    }
}

Write-Host ''
Show-Registered
Write-Host ''
if ($FailedTasks.Count -gt 0) {
    Write-Host ("{0} task(s) FAILED to register: {1}" -f $FailedTasks.Count, ($FailedTasks -join ', ')) -ForegroundColor Red
    Write-Host 'Re-run this installer from an elevated shell; nothing else in the kit was affected.'
    exit 1
}
Write-Host 'All requested tasks registered.' -ForegroundColor Green
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1) check device state:  .\eGPU-Guard.ps1 -Action Status'
Write-Host '  2) test the stop path:  .\eGPU-Guard.ps1 -Action Disable -Force -Toast'
Write-Host '  3) reboot: the external screen should now come up during boot, before logon'
Write-Host '  4) rollback:            .\uninstall-eGPU-Guard.ps1'
