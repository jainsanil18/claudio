# voice-status.ps1 - summarize current voice state + recent log.
. (Join-Path $PSScriptRoot 'common.ps1')

$state = Get-VoiceStateDir
$cfg   = Get-VoiceConfig

$lp = Join-Path $state 'listener.pid'
$listenerOn = $false
if (Test-Path $lp) {
    $procId = (Get-Content $lp -Raw).Trim()
    if ($procId -and (Get-Process -Id $procId -ErrorAction SilentlyContinue)) { $listenerOn = $true }
}

$tgt = if (Test-Path (Join-Path $state 'target.hwnd')) { (Get-Content (Join-Path $state 'target.hwnd') -Raw).Trim() } else { '(none)' }

Write-Output "TTS readback : $(if (Test-SpeakEnabled) { 'ON' } else { 'OFF' })"
Write-Output "Listener     : $(if ($listenerOn) { 'RUNNING' } else { 'stopped' })"
Write-Output "STT engine   : $($cfg.sttEngine)  (wake word always uses SAPI)"
Write-Output "Duplex       : $($cfg.duplex)  $(if($cfg.duplex -eq 'half'){'(deaf while speaking - speakers)'}else{'(always listening - headset)'})"
Write-Output "Target window: $tgt"
Write-Output "Wake words   : $($cfg.wakeWords -join ' / ')"
Write-Output "End words    : $($cfg.endWords -join ' / ')"
Write-Output "Config file  : $(Join-Path $state 'config.json')"
Write-Output ''
Write-Output '--- last 12 log lines ---'
$log = Join-Path $state 'voice.log'
if (Test-Path $log) { Get-Content $log -Tail 12 } else { Write-Output '(no log yet)' }
