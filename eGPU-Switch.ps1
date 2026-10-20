<#
    eGPU-Switch.ps1  -  a menu around the two ways to opt out of the nightly disconnect.

    1  Skip tonight      pause once; expires by itself at midnight
    2  Cancel the skip   tonight runs as scheduled again
    3  Turn everything off   disables all scheduled tasks (asks for admin once)
    4  Turn everything on    re-enables them (asks for admin once)
    5  Show status
    Q  Quit

    This script holds no rules of its own: every line of behaviour lives in eGPU-Guard.ps1, which
    it calls. In particular the pause state is read back from `-Action Status` instead of
    re-deriving the date, so the "expires at midnight" rule exists in exactly one place.
#>

$ErrorActionPreference = 'Stop'

$base = $PSScriptRoot
if (-not $base -and $PSCommandPath) { $base = Split-Path -Parent $PSCommandPath }
$guard = Join-Path $base 'eGPU-Guard.ps1'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path -LiteralPath $guard)) {
    Write-Host "eGPU-Guard.ps1 not found next to this script ($base)" -ForegroundColor Red
    exit 1
}

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
        return 'will run at 23:55'
    }
    return 'unknown'
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
    Write-Host '  Q  Quit'
    Write-Host ''
    $choice = Read-Host '  Choose'

    switch ($choice.Trim()) {
        '1' {
            $null = Invoke-Guard 'Pause'
            Write-Host ''
            Write-Host '  Done: tonight will be skipped. The reminder at 23:50 is skipped too.' -ForegroundColor Green
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
        'Q' { return }
        'q' { return }
        default { Write-Host '  Unknown choice.' -ForegroundColor Red }
    }

    Write-Host ''
    $null = Read-Host '  Press Enter to go back'
}
