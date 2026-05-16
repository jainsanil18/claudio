# voice-duplex.ps1 - switch listening mode and hot-restart the listener.
#   half : deaf while Claude speaks (use with SPEAKERS - no self-trigger)
#   full : always listening + voice barge-in (use with HEADPHONES)
# Arg: half | full | toggle | status
param([string]$Action = 'status')
. (Join-Path $PSScriptRoot 'common.ps1')

$state   = Get-VoiceStateDir
$cfgFile = Join-Path $state 'config.json'
$pidFile = Join-Path $state 'listener.pid'

function Test-ListenerRunning {
    if (-not (Test-Path $pidFile)) { return $null }
    $p = (Get-Content $pidFile -Raw).Trim()
    if ($p -and (Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue)) { return [int]$p }
    return $null
}

$current = (Get-VoiceConfig).duplex
$Action  = $Action.ToLower().Trim()
if ($Action -eq 'toggle') { $Action = if ($current -eq 'half') { 'full' } else { 'half' } }

if ($Action -eq 'status') {
    $lp = Test-ListenerRunning
    Write-Output "Duplex mode  : $current  $(if($current -eq 'half'){'(deaf while speaking - speakers)'}else{'(always listening + barge-in - headphones)'})"
    Write-Output "Listener     : $(if($lp){"running (pid $lp)"}else{'stopped'})"
    Write-Output "Switch with  : /windows-voice:voice-duplex full   (headphones)  |  half   (speakers)"
    return
}
if ($Action -ne 'half' -and $Action -ne 'full') {
    Write-Output "Unknown option '$Action'. Use: half | full | toggle | status."
    return
}

# Merge into config.json without clobbering other user settings.
$obj = @{}
if (Test-Path $cfgFile) {
    try {
        $j = Get-Content $cfgFile -Raw | ConvertFrom-Json
        foreach ($pr in $j.PSObject.Properties) { $obj[$pr.Name] = $pr.Value }
    } catch { }
}
$obj['duplex'] = $Action
($obj | ConvertTo-Json -Depth 6) | Set-Content -Path $cfgFile -Encoding UTF8
Write-VoiceLog "duplex set to '$Action' via voice-duplex" 'duplex'

$msg = "Duplex set to '$Action' " + $(if ($Action -eq 'full') { '(headphones: always listening + voice barge-in).' }
                                       else                    { '(speakers: deaf while Claude speaks).' })

# Hot-restart the listener so the change takes effect now, keeping the same
# target window (relaunch listener.ps1 directly - do NOT re-capture focus).
$lp = Test-ListenerRunning
if ($lp) {
    Set-Content -Path (Join-Path $state 'stop.flag') -Value '1'
    Stop-Process -Id $lp -Force -ErrorAction SilentlyContinue
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 600
    Remove-Item (Join-Path $state 'stop.flag') -Force -ErrorAction SilentlyContinue
    $np = Start-Process -FilePath 'powershell' -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', (Join-Path $PSScriptRoot 'listener.ps1')
    )
    Start-Sleep -Milliseconds 1200
    if (Get-Process -Id $np.Id -ErrorAction SilentlyContinue) {
        Write-Output "$msg Listener hot-restarted (pid $($np.Id)), same target window. Ready."
    } else {
        Write-Output "$msg Listener restart FAILED - check $(Join-Path $state 'voice.log'). Try /windows-voice:voice-listen."
    }
} else {
    Write-Output "$msg Listener isn't running - it'll use this mode next /windows-voice:voice-listen."
}
