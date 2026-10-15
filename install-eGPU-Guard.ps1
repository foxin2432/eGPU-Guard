<#
    install-eGPU-Guard.ps1  -  register the scheduled tasks (needs an elevated shell).

    Tasks created (all prefixed "eGPU-Guard"):

      eGPU-Guard-Watch         at startup (+10s) and at logon, as SYSTEM, highest privileges
                               -> resident loop: enables the eGPU the moment it shows up.
                                  Costs ~0.2% CPU when no eGPU is attached (pure registry
                                  reads, no child processes), so it is invisible on a
                                  machine without the dock.
      eGPU-Guard-Boot-Enable   at startup (+20s) and at logon, as SYSTEM, highest privileges
                               -> one-shot Enable pass, belt-and-braces next to Watch
      eGPU-Guard-2355-Disable  Sun/Mon/Tue/Wed/Thu 23:55, as SYSTEM, highest privileges
                               -> pnputil /disable-device on the 4070 SUPER
      eGPU-Guard-2350-Notify   Sun/Mon/Tue/Wed/Thu 23:50, as the interactive user
                               -> toast reminder "5 minutes left"

    Neither task does anything during boot except run a small script a few seconds in,
    so boot time is unaffected; nothing blocks the logon path.

    Usage
      .\install-eGPU-Guard.ps1                    # notify + disable + boot-enable + resident watcher
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
    [string]$NotifyTime = '23:50',
    [string]$DisableTime = '23:55',
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
# Enable as early as possible: the watcher gets its own startup trigger so the GPU is
# brought up while Windows is still on the lock screen, instead of after logon.
$bootTrigger = New-ScheduledTaskTrigger -AtStartup
$bootTrigger.Delay = 'PT20S'
$watchBootTrigger = New-ScheduledTaskTrigger -AtStartup
$watchBootTrigger.Delay = 'PT10S'
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn
$logonTrigger.Delay = 'PT5S'

# ------------------------------------------------------------------- actions ---
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function New-GuardAction {
    param([string[]]$ScriptArgs)
    $quoted = ($ScriptArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    New-ScheduledTaskAction -Execute $psExe `
        -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" {1}' -f $guardScript, $quoted)
}

$notifyAction = New-ScheduledTaskAction -Execute $psExe `
    -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $notifyScript)
# -Force is REQUIRED here. Without it the preflight sees the monitor that is attached to the
# 4070S (the normal situation at 23:55) and refuses with exit 5, so the nightly disconnect
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
# The watcher task is always registered (it is what makes the GPU come up during boot);
# -NoWatcherProcess only changes whether its resident loop keeps polling after startup.
$watchArgs = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $watchScript
if ($NoWatcherProcess) { $watchArgs += ' -Once' }
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

Write-Host 'Registering scheduled tasks:'

# Registered first on purpose: this is the piece that gets the GPU up during boot.
$result += Register-GuardTask -TaskName "$prefix-Watch" -Action $watchAction `
    -Trigger @($watchBootTrigger, $logonTrigger) -Principal $systemPrincipal -Settings $settWatch `
    -Description 'Resident watcher: enable the eGPU as soon as it appears (runs from startup)'

$result += Register-GuardTask -TaskName "$prefix-Boot-Enable" -Action $enableAction `
    -Trigger @($bootTrigger, $logonTrigger) -Principal $systemPrincipal -Settings $settEnable `
    -Description 'At startup/logon: if the eGPU is present but disabled/not started, enable it'

$result += Register-GuardTask -TaskName "$prefix-2355-Disable" -Action $disableAction `
    -Trigger $disableTrigger -Principal $systemPrincipal -Settings $settDisable `
    -Description 'Stop the RTX 4070 SUPER at 23:55 (Sun-Thu) ahead of the dorm power cut'

$result += Register-GuardTask -TaskName "$prefix-2350-Notify" -Action $notifyAction `
    -Trigger $notifyTrigger -Principal $userPrincipal -Settings $settNotify `
    -Description 'Toast reminder 5 minutes before the nightly eGPU disconnect'

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
