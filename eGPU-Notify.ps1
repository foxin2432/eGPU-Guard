<#
    eGPU-Notify.ps1  -  desktop reminder shown in the interactive user session.

    WHY THIS DOES NOT USE A WINRT TOAST ANY MORE
    --------------------------------------------
    It used to build a ToastNotification and show it through
    ToastNotificationManager.CreateToastNotifier(<AUMID>).Show(). On this machine that logged
    "toast shown" every night at 23:50 and nothing ever appeared on screen - because Show()
    returns success for an AUMID that is not registered as a Start Menu shortcut for the
    current user, and Windows then drops the notification silently. No exception, no error
    code, no way to detect it from the caller.

    So the reminder is now a WPF window that this script draws itself. It needs nothing from
    the notification stack: no AUMID, no registration, no Focus Assist cooperation. If the
    process can show a window in the user's session, the reminder is visible. It is also
    click-through-free, always on top, and positions itself in the bottom-right corner of the
    working area, which is where a reminder is expected to be.

    A sound is played when it appears. The window closes itself after -Seconds, or immediately
    on click or Esc, so it can never be left behind on the desktop.

    Runs under powershell.exe (STA). Reported exit codes: 0 shown, 1 failed.
#>
[CmdletBinding()]
param(
    [string]$Title = 'eGPU Guard',
    [string]$Body = '23:55 will stop the RTX 4070 SUPER. Save your work / close games now.',
    [string]$Hint = 'Click anywhere to dismiss - or leave it, it closes by itself.',

    # How long the window stays up before closing itself. Short on purpose: the reminder is
    # meant to be noticed, not to sit on the desktop. Raise it with -Seconds if you would
    # rather it stayed longer.
    [int]$Seconds = 5,

    [switch]$NoSound,

    # By default the reminder is SKIPPED when no matching eGPU is attached.
    #
    # Without this the window appears every night regardless, announcing a disconnect that is
    # not going to happen: with no dock attached the 23:55 task finds no device and does
    # nothing, so the reminder and the actual behaviour contradict each other.
    #
    # Skipping is the default rather than something the caller opts into, so the scheduled task
    # needs no extra argument. That also means the behaviour cannot be left half-applied by an
    # unregistered task. Pass -Always to force the window regardless.
    #
    # The presence check is DELEGATED to eGPU-Guard.ps1 -Action Status rather than reimplemented
    # here. That keeps the device matching rule (-MatchDescription / -MatchDeviceId) in exactly
    # one place; a second copy would silently drift the day those parameters change.
    [switch]$Always,

    [string]$LogFile = "$env:ProgramData\eGPU-Guard\eGPU-Guard.log"
)

$ErrorActionPreference = 'Continue'

function Write-Log {
    param([string]$Level = 'INFO', [string]$Message)
    $line = '{0} [{1}] Notify {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try {
        $dir = Split-Path -Parent $LogFile
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

function Start-ReminderSound {
    # Prefer the system notification wav; fall back to the built-in Exclamation sound. Both are
    # played asynchronously so a slow or missing audio device cannot delay the window.
    # The player is kept in a script-scope variable on purpose: Play() is asynchronous and a
    # collected SoundPlayer cuts the sound off mid-way.
    $script:SoundPlayer = $null
    try {
        $wav = Join-Path $env:SystemRoot 'Media\Windows Notify System Generic.wav'
        if (Test-Path -LiteralPath $wav) {
            $script:SoundPlayer = New-Object System.Media.SoundPlayer $wav
            $script:SoundPlayer.Play()
            return 'wav'
        }
    } catch { }
    try {
        [System.Media.SystemSounds]::Exclamation.Play()
        return 'system'
    } catch { }
    return 'none'
}

if (-not $Always) {
    # Tonight's disconnect may have been skipped with `eGPU-Guard.ps1 -Action Pause`. Reminding
    # about something that is not going to happen is the exact contradiction this check exists
    # to prevent, so the pause marker is honoured here as well.
    #
    # Same file and same one-line date format as eGPU-Guard.ps1 (state\pause). If that format
    # ever changes, both read sites must change together.
    $pausePath = Join-Path (Split-Path -Parent $LogFile) 'state\pause'
    if (Test-Path -LiteralPath $pausePath) {
        $stamp = $null
        try { $stamp = (Get-Content -LiteralPath $pausePath -Raw -ErrorAction Stop).Trim() } catch { }
        if ($stamp -eq (Get-Date).ToString('yyyy-MM-dd')) {
            Write-Log -Message 'tonight is paused (-Action Pause) - reminder skipped'
            exit 0
        }
    }

    $base = $PSScriptRoot
    if (-not $base -and $PSCommandPath) { $base = Split-Path -Parent $PSCommandPath }
    $guard = if ($base) { Join-Path $base 'eGPU-Guard.ps1' } else { $null }

    if (-not $guard -or -not (Test-Path -LiteralPath $guard)) {
        # Fail OPEN: a missing helper must not silently cancel the reminder.
        Write-Log -Level 'WARN' -Message 'cannot check for the eGPU (eGPU-Guard.ps1 not found) - showing the reminder anyway'
    } else {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        # Double quotes are required: Windows strips " but not ', so a single-quoted path would
        # be taken literally, apostrophes included, and the child would fail to start.
        $argLine = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action Status' -f $guard
        $rc = $null
        try {
            $proc = Start-Process -FilePath $ps -WindowStyle Hidden -Wait -PassThru -ArgumentList $argLine
            $rc = $proc.ExitCode
        } catch {
            Write-Log -Level 'WARN' -Message "device check failed ($($_.Exception.Message)) - showing the reminder anyway"
        }
        # eGPU-Guard.ps1 -Action Status: 0 = the eGPU is present, 2 = it is not.
        # Any other outcome (crash, timeout, unexpected code) fails open as well.
        if ($rc -eq 2) {
            Write-Log -Message 'no eGPU attached - reminder skipped (pass -Always to show it anyway)'
            exit 0
        }
    }
}

Write-Log -Message 'reminder starting'

# A window can only appear in an interactive session. If this somehow runs in session 0
# (SYSTEM), say so instead of pretending the user was reminded.
if ($null -ne $env:SESSIONNAME -and $env:SESSIONNAME -eq 'Services') {
    Write-Log -Level 'ERROR' -Message 'no interactive desktop (session 0) - a window cannot be shown here'
    exit 1
}

if ($NoSound) {
    Write-Log -Message 'sound disabled by -NoSound'
} else {
    $how = Start-ReminderSound
    if ($how -eq 'none') { Write-Log -Level 'WARN' -Message 'could not play a sound' }
    else { Write-Log -Message "sound played ($how)" }
}

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop

    $window = New-Object Windows.Window
    $window.Title = $Title
    $window.WindowStyle = 'None'
    $window.ResizeMode = 'NoResize'
    $window.AllowsTransparency = $true
    $window.Background = [Windows.Media.Brushes]::Transparent
    $window.ShowInTaskbar = $false
    $window.Topmost = $true
    $window.Width = 360
    $window.SizeToContent = 'Height'
    $window.WindowStartupLocation = 'Manual'

    $border = New-Object Windows.Controls.Border
    $border.CornerRadius = [Windows.CornerRadius]::new(10)
    $border.BorderThickness = [Windows.Thickness]::new(1)
    $border.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#40FFFFFF')
    $border.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#F2202020')
    $border.Padding = [Windows.Thickness]::new(16, 14, 16, 14)
    $border.Margin = [Windows.Thickness]::new(10)

    $stack = New-Object Windows.Controls.StackPanel

    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Title
    $t.FontSize = 15
    $t.FontWeight = [Windows.FontWeights]::SemiBold
    $t.Foreground = [Windows.Media.Brushes]::White
    $t.TextWrapping = 'Wrap'
    $null = $stack.Children.Add($t)

    $b = New-Object Windows.Controls.TextBlock
    $b.Text = $Body
    $b.FontSize = 12.5
    $b.Margin = [Windows.Thickness]::new(0, 8, 0, 0)
    $b.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFEDEDED')
    $b.TextWrapping = 'Wrap'
    $null = $stack.Children.Add($b)

    $h = New-Object Windows.Controls.TextBlock
    $h.Text = $Hint
    $h.FontSize = 10.5
    $h.Margin = [Windows.Thickness]::new(0, 10, 0, 0)
    $h.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF9A9A9A')
    $h.TextWrapping = 'Wrap'
    $null = $stack.Children.Add($h)

    $border.Child = $stack
    $window.Content = $border

    # Closing on click or Esc. Closing directly is enough: ShowDialog returns to this script.
    $window.Add_MouseLeftButtonUp({ $window.Close() })
    $window.Add_KeyDown({ if ($_.Key -eq 'Escape') { $window.Close() } })

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds([Math]::Max(3, $Seconds))
    $timer.Add_Tick({ $timer.Stop(); $window.Close() })

    # Position once the window has been measured: with SizeToContent the height is only known
    # after layout, and using a guessed height would place it off the bottom edge.
    $window.Add_Loaded({
        $window.UpdateLayout()
        $h_ = $window.ActualHeight
        $w_ = $window.ActualWidth
        $area = [Windows.SystemParameters]::WorkArea
        $left = $area.Right - $w_ - 16
        $top = $area.Bottom - $h_ - 16
        if ($left -lt $area.Left) { $left = $area.Left }
        if ($top -lt $area.Top) { $top = $area.Top }
        $window.Left = $left
        $window.Top = $top
        $timer.Start()
    })

    $null = $window.ShowDialog()
    Write-Log -Message "reminder shown and dismissed: $Body"
    exit 0
} catch {
    Write-Log -Level 'ERROR' -Message "could not show the reminder window: $($_.Exception.Message)"
    exit 1
}
