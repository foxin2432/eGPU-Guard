<#
    eGPU-Guard settings.

    Edit this file, then re-run install-eGPU-Guard.ps1 so the scheduled tasks pick the new
    times up. Anything left out falls back to the built-in default.

    Or just double-click eGPU-Switch.cmd and choose "7  Settings" - it edits this file for you.

    DisableTime      when the eGPU is disconnected (24-hour HH:mm)
    NotifyTime       when the reminder window appears; must be earlier than DisableTime
    Days             the nights to act on (English day names)
    MatchDescription part of the GPU name shown by Windows, e.g. 4070 SUPER or RX 7900
    MatchVendorId    the PCI vendor id without VEN_, e.g. 10DE (NVIDIA) or 1002 (AMD)
    MatchDeviceId    the PCI device id, the DEV_xxxx part of the hardware id
    NotifySeconds    how long the reminder stays on screen
    NotifySound      play a sound with the reminder
    MaxLogBytes      trim the log once it passes this size; 0 disables trimming
    KeepLogLines     how many lines to keep when trimming
#>
@{
    DisableTime      = '23:58'
    NotifyTime       = '23:53'
    Days             = @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday')
    MatchDescription = '4070 SUPER'
    MatchVendorId    = '10DE'
    MatchDeviceId    = 'DEV_2783'
    NotifySeconds    = 5
    NotifySound      = $true
    MaxLogBytes      = 1048576
    KeepLogLines     = 500
}
