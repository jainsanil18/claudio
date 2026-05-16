# voice-test.ps1 - speak a fixed sentence synchronously to prove TTS works.
. (Join-Path $PSScriptRoot 'common.ps1')

try {
    $cfg = Get-VoiceConfig
    Add-Type -AssemblyName System.Speech
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $voices = ($synth.GetInstalledVoices() | Where-Object { $_.Enabled } | ForEach-Object { $_.VoiceInfo.Name }) -join ', '
    if ($cfg.voice) { try { $synth.SelectVoice([string]$cfg.voice) } catch { } }
    $synth.Rate = [int]$cfg.rate; $synth.Volume = [int]$cfg.volume
    $synth.Speak('Windows voice for Claude Code is working. You should hear this sentence.')
    Write-Output "Spoke test sentence OK. Installed voices: $voices"
    Write-Output "Active voice: $($synth.Voice.Name). Edit $(Join-Path (Get-VoiceStateDir) 'config.json') to change voice/rate."
}
catch {
    Write-Output "TTS FAILED: $($_.Exception.Message)"
}
