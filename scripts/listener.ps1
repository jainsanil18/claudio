# listener.ps1 - background wake-word voice input. Runs detached/hidden.
#
#   WAKE WORD : System.Speech (SAPI) fixed-grammar - proven reliable.
#   COMMAND   : sttEngine = 'winrt' -> Windows.Media.SpeechRecognition
#                            'sapi'  -> legacy SAPI dictation (fallback)
#
# State machine is synchronous for determinism. Stops on stop.flag / kill.

. (Join-Path $PSScriptRoot 'common.ps1')

$state    = Get-VoiceStateDir
$stopFlag = Join-Path $state 'stop.flag'
$pidFile  = Join-Path $state 'listener.pid'
Set-Content -Path $pidFile -Value $PID
if (Test-Path $stopFlag) { Remove-Item $stopFlag -Force -ErrorAction SilentlyContinue }

$cfg = Get-VoiceConfig
Write-VoiceLog "listener starting (pid $PID), sttEngine=$($cfg.sttEngine)" 'listener'

Add-Type -AssemblyName System.Speech
Add-Type -AssemblyName System.Windows.Forms

function Get-TargetHandle {
    $f = Join-Path $state 'target.hwnd'
    if (Test-Path $f) { try { return [IntPtr][int64]((Get-Content $f -Raw).Trim()) } catch { } }
    return [IntPtr]::Zero
}

function Test-TtsSpeaking {
    # True while a detached speaker process is actually talking.
    $f = Join-Path $state 'speaker.pid'
    if (-not (Test-Path $f)) { return $false }
    try { return [bool](Get-Process -Id ([int](Get-Content $f -Raw).Trim()) -ErrorAction SilentlyContinue) }
    catch { return $false }
}

function ConvertTo-SendKeys {
    param([string]$s)
    $s = $s -replace "[\r\n]+", ' '
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ('+^%~(){}[]'.IndexOf($ch) -ge 0) { [void]$sb.Append('{').Append($ch).Append('}') }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Send-ToClaude {
    param([string]$text)
    $h = Get-TargetHandle
    if (-not (Set-ActiveWindow -Handle $h)) {
        Write-VoiceLog "target window not focusable (hwnd=$h) - dropping: $text" 'listener'
        [console]::Beep(220, 250); return
    }
    [console]::Beep(740, 110)        # "got it - typing now" (before keystrokes)
    Start-Sleep -Milliseconds 200
    [System.Windows.Forms.SendKeys]::SendWait((ConvertTo-SendKeys $text))
    Start-Sleep -Milliseconds 120
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Write-VoiceLog "sent: $text" 'listener'
    [console]::Beep(660, 120)        # "sent + entered"
}

function Test-EndWord {
    # Returns @{ Ended=bool; Text=trimmed-without-endword }
    param([string]$phrase, [string[]]$endWords)
    $lower = $phrase.ToLower().Trim()
    foreach ($e in $endWords) {
        if ($lower -eq $e -or $lower.EndsWith(' ' + $e)) {
            return @{ Ended = $true; Text = $phrase.Substring(0, $phrase.Length - $e.Length).Trim() }
        }
    }
    return @{ Ended = $false; Text = $phrase }
}

$endWords = @($cfg.endWords | ForEach-Object { $_.ToString().ToLower().Trim() })

# ---------------------------------------------------------------------------
# WinRT command engine
# ---------------------------------------------------------------------------
$winrtReady = $false
if ($cfg.sttEngine -eq 'winrt') {
    try {
        # Fail fast & clearly if the speech privacy policy isn't accepted -
        # otherwise every RecognizeAsync throws a cryptic error per utterance.
        $accepted = $false
        try { $accepted = ((Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' -Name HasAccepted -ErrorAction Stop).HasAccepted -eq 1) } catch { }
        if (-not $accepted) {
            throw "Speech privacy policy not accepted. Enable Settings > Privacy & security > Speech > 'Online speech recognition', or set sttEngine='sapi' in config.json."
        }
        . (Join-Path $PSScriptRoot 'win-async.ps1')
        # ONE persistent recognizer, compiled + warmed HERE at startup. The
        # cold ~11s first-capture happens once now (nobody is waiting on a
        # command), so every real command afterward is instant.
        $script:winrec = New-Object Windows.Media.SpeechRecognition.SpeechRecognizer
        try { $script:winrec.Timeouts.EndSilenceTimeout = [TimeSpan]::FromSeconds([double]$cfg.winrtEndSilenceSec) } catch { }
        $comp = Wait-WinRtOp $script:winrec.CompileConstraintsAsync() $script:WV_SR_Compile 20000
        if ($comp.Status.ToString() -ne 'Success') {
            throw "CompileConstraints status = $($comp.Status). Install the on-device speech language pack: Settings > Time & language > Speech > Speech recognition."
        }
        $lang = $script:winrec.CurrentLanguage.LanguageTag
        Write-VoiceLog "warming WinRT audio pipeline (one-time cold start)..." 'listener'
        try {
            $script:winrec.Timeouts.InitialSilenceTimeout = [TimeSpan]::FromSeconds(0.4)
            $null = Wait-WinRtOp $script:winrec.RecognizeAsync() $script:WV_SR_Result 20000   # absorb cold init
        } catch { Write-VoiceLog "warm-up note: $($_.Exception.Message)" 'listener' }
        $winrtReady = $true
        Write-VoiceLog "WinRT warm & ready (lang $lang) - persistent recognizer" 'listener'
    }
    catch {
        Write-VoiceLog "FATAL WinRT init: $($_.Exception.Message)" 'listener'
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        exit 2
    }
}

$confMap = @{ 'High' = 0; 'Medium' = 1; 'Low' = 2 }
$maxConf = $confMap[[string]$cfg.winrtMinConfidence]; if ($null -eq $maxConf) { $maxConf = 2 }

function Get-Command-WinRT {
    # Uses the ONE persistent recognizer warmed at startup - no per-command
    # construct/compile, so no cold ~11s first-capture. It's already listening
    # the instant we beep.
    $rcg = $script:winrec
    try {
        [console]::Beep(988, 150)
        Write-VoiceLog 'listening for command (speak now)' 'listener'

        # ACCUMULATE across pauses so a think-pause doesn't cut you off:
        #  - 1st RecognizeAsync waits winrtInitialSilenceSec for you to START.
        #  - Each captured utterance is appended; we then listen again with a
        #    SHORT continuation window (winrtContinueSilenceSec). Keep talking
        #    within it -> appended. Go quiet past it -> that's "done", send.
        #  - No flaky end-word needed; an end-word still finishes fast if heard.
        $buffer  = New-Object System.Text.StringBuilder
        $start   = Get-Date
        $first   = $true
        $coldTries = 0
        while ($true) {
            if (Test-Path $stopFlag) { break }
            if (((Get-Date) - $start).TotalSeconds -ge [double]$cfg.maxCommandSec) {
                Write-VoiceLog 'command time cap reached' 'listener'; break
            }
            $silSec = if ($first) { [double]$cfg.winrtInitialSilenceSec } else { [double]$cfg.winrtContinueSilenceSec }
            try { $rcg.Timeouts.InitialSilenceTimeout = [TimeSpan]::FromSeconds($silSec) } catch { }
            try {
                $res = Wait-WinRtOp $rcg.RecognizeAsync() $script:WV_SR_Result (([int]$cfg.maxCommandSec + 15) * 1000)
            }
            catch { Write-VoiceLog "RecognizeAsync error: $($_.Exception.Message)" 'listener'; break }

            $status = $res.Status.ToString()
            $conf   = [int]$res.Confidence            # High0 Medium1 Low2 Rejected3
            $txt    = ''
            if ($res.Text) { $txt = $res.Text.Trim() }

            if ($status -eq 'Success' -and $txt -and $conf -le $maxConf) {
                $r = Test-EndWord -phrase $txt -endWords $endWords
                if ($r.Text) { [void]$buffer.Append(' ').Append($r.Text) }
                Write-VoiceLog "heard: '$txt' conf=$($res.Confidence)" 'listener'
                $first = $false
                if ($r.Ended) { Write-VoiceLog 'end-word - finishing' 'listener'; break }
                continue                              # keep listening for more
            }

            Write-VoiceLog "pause (status=$status conf=$($res.Confidence))" 'listener'
            if ($buffer.Length -gt 0) { break }       # you finished -> send
            $coldTries++
            if ($coldTries -ge 3) { Write-VoiceLog 'no speech - giving up' 'listener'; break }
            # nothing yet (cold start / not spoken): try again
        }
        return $buffer.ToString().Trim()
    }
    catch { Write-VoiceLog "WinRT capture error: $($_.Exception.Message)" 'listener'; return '' }
}

# ---------------------------------------------------------------------------
# SAPI command engine (fallback)
# ---------------------------------------------------------------------------
function Get-Command-SAPI {
    param($rec, $wakeGrammar, $dictation)
    $wakeGrammar.Enabled = $false
    $dictation.Enabled   = $true
    $buffer    = New-Object System.Text.StringBuilder
    $cmdStart  = Get-Date
    $lastHeard = Get-Date
    while ($true) {
        if (Test-Path $stopFlag) { break }
        if (((Get-Date) - $cmdStart).TotalSeconds -ge [double]$cfg.maxCommandSec) { break }
        $c = $rec.Recognize([TimeSpan]::FromSeconds(1.2))
        if ($c -and $c.Grammar.Name -eq 'dictation' -and $c.Confidence -ge [double]$cfg.commandConfidence) {
            $r = Test-EndWord -phrase $c.Text.Trim() -endWords $endWords
            if ($r.Text) { [void]$buffer.Append(' ').Append($r.Text) }
            $lastHeard = Get-Date
            if ($r.Ended) { break }
        }
        elseif (((Get-Date) - $lastHeard).TotalSeconds -ge [double]$cfg.silenceGapSec -and $buffer.Length -gt 0) { break }
    }
    $dictation.Enabled   = $false
    $wakeGrammar.Enabled = $true
    return $buffer.ToString().Trim()
}

# ---------------------------------------------------------------------------
# Wake-word engine (SAPI) - unchanged, proven
# ---------------------------------------------------------------------------
try {
    $rec = $null
    $culture = [System.Globalization.CultureInfo]::CurrentUICulture
    foreach ($ri in [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers()) {
        if ($ri.Culture.Name -eq $culture.Name) { $rec = New-Object System.Speech.Recognition.SpeechRecognitionEngine $ri; break }
    }
    if (-not $rec) { $rec = New-Object System.Speech.Recognition.SpeechRecognitionEngine }
    $rec.SetInputToDefaultAudioDevice()
}
catch {
    Write-VoiceLog "FATAL: no SAPI recognizer for wake word. $($_.Exception.Message)" 'listener'
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    exit 1
}

$wakeChoices = New-Object System.Speech.Recognition.Choices
foreach ($w in $cfg.wakeWords) { $wakeChoices.Add([string]$w) }
$wakeGB = New-Object System.Speech.Recognition.GrammarBuilder
$wakeGB.Append($wakeChoices)
$wakeGrammar = New-Object System.Speech.Recognition.Grammar $wakeGB
$wakeGrammar.Name = 'wake'
$dictation = New-Object System.Speech.Recognition.DictationGrammar
$dictation.Name = 'dictation'
$rec.LoadGrammar($wakeGrammar)
$rec.LoadGrammar($dictation)
$wakeGrammar.Enabled = $true
$dictation.Enabled   = $false

[console]::Beep(880, 120); [console]::Beep(1040, 120)
Write-VoiceLog "ready. engine=$($cfg.sttEngine). wake: $($cfg.wakeWords -join ', ')" 'listener'

$isHalf      = ($cfg.duplex -eq 'half')
$wasSpeaking = $false

while ($true) {
    if (Test-Path $stopFlag) { Write-VoiceLog 'stop.flag seen - exiting' 'listener'; break }

    # --- Half-duplex: stay deaf while Claude is speaking, so the mic never
    #     hears the TTS and self-triggers the wake word. ---
    if ($isHalf -and (Test-TtsSpeaking)) {
        if (-not $wasSpeaking) { Write-VoiceLog 'TTS speaking - listener paused' 'listener'; $wasSpeaking = $true }
        Start-Sleep -Milliseconds 250
        continue
    }
    if ($wasSpeaking) {
        Start-Sleep -Milliseconds ([int]$cfg.ttsTailMs)   # let room echo settle
        Write-VoiceLog 'TTS ended - listening resumed' 'listener'
        $wasSpeaking = $false
    }

    $r = $rec.Recognize([TimeSpan]::FromSeconds(1.5))
    if (-not $r) { continue }
    if ($r.Grammar.Name -ne 'wake' -or $r.Confidence -lt [double]$cfg.wakeConfidence) { continue }
    if ($isHalf -and (Test-TtsSpeaking)) { continue }   # TTS started mid-recognize

    Write-VoiceLog "wake '$($r.Text)' conf=$([math]::Round($r.Confidence,2))" 'listener'
    [console]::Beep(440, 90)        # low tick = "heard you, preparing" (do NOT speak yet)

    if (-not $isHalf) {                                  # full-duplex: voice barge-in
        $spkPid = Join-Path $state 'speaker.pid'
        if (Test-Path $spkPid) {
            try { Stop-Process -Id ([int](Get-Content $spkPid -Raw).Trim()) -Force -ErrorAction SilentlyContinue } catch { }
        }
    }

    # No SAPI->WinRT mic handoff: SetInputToNull tears down the shared audio
    # device, forcing the fresh recognizer into a ~12s cold re-init on its
    # first RecognizeAsync (returns Unknown, eats your command). Windows mics
    # are shared-mode, so a fresh WinRT recognizer can grab the device while
    # SAPI keeps it warm. The fresh-per-command recognizer is what prevents
    # the stale-instance "could not be found" error we saw earlier.
    if ($cfg.sttEngine -eq 'winrt' -and $winrtReady) {
        $final = Get-Command-WinRT
    } else {
        $final = Get-Command-SAPI -rec $rec -wakeGrammar $wakeGrammar -dictation $dictation
    }

    if ($final) { Send-ToClaude $final }
    else { Write-VoiceLog 'empty command - ignored' 'listener'; [console]::Beep(330, 200) }
}

$rec.Dispose()
if ($script:winrec) { try { $script:winrec.Dispose() } catch { } }
Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
Write-VoiceLog 'listener stopped' 'listener'
