<#
    eGPU-Notify.ps1  -  desktop toast reminder, run in the interactive user session.

    Reads the companion eGPU-Guard.ps1 -Action Status output so the text matches reality.
    Default text: 5 minute warning before the nightly disconnect.
#>
[CmdletBinding()]
param(
    [string]$Title = 'eGPU Guard',
    [string]$Body = '23:55 will stop the RTX 4070 SUPER. Save your work / close games now.',
    [string]$LogFile = "$env:ProgramData\eGPU-Guard\eGPU-Guard.log"
)

$ErrorActionPreference = 'Continue'

function Write-Log {
    param([string]$Message)
    $line = '{0} [INFO] Notify {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try {
        $dir = Split-Path -Parent $LogFile
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

try {
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

    $template = @"
<toast duration="long" scenario="reminder">
  <visual>
    <binding template="ToastGeneric">
      <text>$Title</text>
      <text>$Body</text>
    </binding>
  </visual>
  <audio src="ms-winsoundevent:Notification.Reminder" />
</toast>
"@

    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml($template)
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xml

    # AppId of Windows PowerShell: works without installing any extra module,
    # the toast shows up as coming from PowerShell (acceptable for a reminder).
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    Write-Log "toast shown: $Body"
    exit 0
} catch {
    Write-Log "toast failed: $($_.Exception.Message)"
    exit 1
}
