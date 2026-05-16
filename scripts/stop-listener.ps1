# stop-listener.ps1 - signal the listener to exit and silence any speech.
. (Join-Path $PSScriptRoot 'common.ps1')

$state = Get-VoiceStateDir
Set-Content -Path (Join-Path $state 'stop.flag') -Value '1'

$killed = @()
foreach ($name in 'listener.pid', 'speaker.pid') {
    $f = Join-Path $state $name
    if (Test-Path $f) {
        $procId = (Get-Content $f -Raw).Trim()
        if ($procId) {
            try { Stop-Process -Id ([int]$procId) -Force -ErrorAction SilentlyContinue; $killed += "$name=$procId" } catch { }
        }
        Remove-Item $f -Force -ErrorAction SilentlyContinue
    }
}
Write-Output ("Voice stopped. " + ($(if ($killed) { "Terminated: $($killed -join ', ')." } else { "Nothing was running." })))
