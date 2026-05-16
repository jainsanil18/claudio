# voice-retarget.ps1 - re-aim the listener at whatever window you focus next.
# Gives you 5 seconds to click the target terminal.
. (Join-Path $PSScriptRoot 'common.ps1')

$state = Get-VoiceStateDir
Write-Output 'Click the window you want voice input typed into. Capturing the foreground window in 5 seconds...'
Start-Sleep -Seconds 5
$hwnd = Get-ForegroundWindowHandle
Set-Content -Path (Join-Path $state 'target.hwnd') -Value ([int64]$hwnd)
Write-Output "Target window handle set to $([int64]$hwnd). The running listener picks this up immediately."
