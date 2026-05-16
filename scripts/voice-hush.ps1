# voice-hush.ps1 - silence the current spoken reply WITHOUT stopping the
# listener. (voice-stop tears down everything; this just shuts TTS up.)
. (Join-Path $PSScriptRoot 'common.ps1')

$f = Join-Path (Get-VoiceStateDir) 'speaker.pid'
if (Test-Path $f) {
    $procId = (Get-Content $f -Raw).Trim()
    if ($procId -and (Get-Process -Id ([int]$procId) -ErrorAction SilentlyContinue)) {
        Stop-Process -Id ([int]$procId) -Force -ErrorAction SilentlyContinue
        Remove-Item $f -Force -ErrorAction SilentlyContinue
        Write-Output "Hushed (killed speaker $procId). Listener still running - say a wake word when ready."
        return
    }
}
Write-Output "Nothing is speaking right now. Listener unaffected."
