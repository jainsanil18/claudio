# speak.ps1 - the actual TTS voice. Runs hidden and detached so it never
# blocks Claude Code. Killed by on-stop.ps1 / stop-listener.ps1 to barge in.
param([Parameter(Mandatory = $true)][string]$TextFile)

. (Join-Path $PSScriptRoot 'common.ps1')

try {
    if (-not (Test-Path $TextFile)) { exit 0 }
    $text = Get-Content $TextFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($text)) { exit 0 }

    $cfg = Get-VoiceConfig
    Add-Type -AssemblyName System.Speech
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer

    if ($cfg.voice) {
        try { $synth.SelectVoice([string]$cfg.voice) } catch { Write-VoiceLog "voice '$($cfg.voice)' unavailable, using default" 'speak' }
    }
    $synth.Rate   = [int]$cfg.rate      # -10..10
    $synth.Volume = [int]$cfg.volume    # 0..100
    $synth.Speak($text)                 # synchronous within this hidden process
}
catch {
    Write-VoiceLog "error: $($_.Exception.Message)" 'speak'
}
