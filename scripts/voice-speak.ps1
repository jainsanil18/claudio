# voice-speak.ps1 - toggle TTS readback on/off. Arg: on | off | toggle | status
param([string]$Action = 'toggle')
. (Join-Path $PSScriptRoot 'common.ps1')

$flag = Join-Path (Get-VoiceStateDir) 'speak.enabled'
$Action = $Action.ToLower().Trim()
if ($Action -eq 'toggle') { $Action = if (Test-Path $flag) { 'off' } else { 'on' } }

switch ($Action) {
    'on'  { Set-Content -Path $flag -Value '1'; Write-Output 'TTS readback: ON. Claude will speak each reply aloud (Windows SAPI). Run a quick test with /windows-voice:voice-test.' }
    'off' { Remove-Item $flag -Force -ErrorAction SilentlyContinue; Write-Output 'TTS readback: OFF.' }
    'status' { Write-Output ("TTS readback is currently " + $(if (Test-Path $flag) { 'ON' } else { 'OFF' }) + '.') }
    default  { Write-Output "Unknown action '$Action'. Use: on | off | toggle | status." }
}
