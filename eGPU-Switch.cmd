@echo off
rem Double-click launcher for eGPU-Switch.ps1 (the nightly-disconnect switch).
rem Kept as a .cmd so it can be started from Explorer without a PowerShell prompt.
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0eGPU-Switch.ps1"
if errorlevel 1 (
    echo.
    echo The switch exited with an error. See %ProgramData%\eGPU-Guard\eGPU-Guard.log
    pause
)
endlocal
