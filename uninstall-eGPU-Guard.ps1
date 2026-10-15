<#
    uninstall-eGPU-Guard.ps1  -  remove every task this kit registered.

    The script never touches the registry or the device state, so removal is complete.

    By default the state directory (C:\ProgramData\eGPU-Guard, i.e. the log and the lock
    files) is deleted as well. Pass -KeepLogs to leave it in place for later inspection.
#>
[CmdletBinding()]
param(
    [switch]$KeepLogs
)

$ErrorActionPreference = 'Stop'
$prefix = 'eGPU-Guard'

$tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "$prefix*" }
if (-not $tasks) {
    Write-Host 'nothing to remove: no eGPU-Guard tasks found'
} else {
    foreach ($t in $tasks) {
        try {
            Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false
            Write-Host ("removed task: {0}" -f $t.TaskName) -ForegroundColor Green
        } catch {
            Write-Host ("failed to remove {0}: {1}" -f $t.TaskName, $_.Exception.Message) -ForegroundColor Red
        }
    }
}

# Stop a resident watcher, if any.
# Two guards are essential here: the match must exclude this very process (its own command
# line contains "eGPU-Watch.ps1", so a naive filter makes the script kill itself), and it
# must require the "-File" argument so unrelated shells that merely mention the name are
# left alone.
$self = $PID
$watchers = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessId -ne $self -and
        $_.CommandLine -like '*-File*eGPU-Watch.ps1*'
    })
if ($watchers.Count -eq 0) {
    Write-Host 'no resident watcher process found'
} else {
    foreach ($w in $watchers) {
        try {
            Stop-Process -Id $w.ProcessId -Force -ErrorAction Stop
            Write-Host ("stopped watcher pid {0}" -f $w.ProcessId) -ForegroundColor Green
        } catch {
            Write-Host ("could not stop watcher pid {0}: {1}" -f $w.ProcessId, $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}

if (-not $KeepLogs) {
    $logDir = Join-Path $env:ProgramData 'eGPU-Guard'
    if (Test-Path $logDir) {
        Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host ("removed log dir: {0}" -f $logDir)
    }
}

Write-Host ''
Write-Host 'Done. The GPU device itself was never modified by the installer - only by the'
Write-Host 'Disable action you ran manually. Check it in Device Manager if in doubt.'
