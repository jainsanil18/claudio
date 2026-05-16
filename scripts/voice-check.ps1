# voice-check.ps1 - verify the WinRT speech stack is usable on this machine.
# Constructs the recognizer and compiles the dictation constraint (no mic /
# no speaking needed), then reports languages + actionable next steps.
. (Join-Path $PSScriptRoot 'common.ps1')

$ok = $true
Write-Output "OS            : $((Get-CimInstance Win32_OperatingSystem).Caption) build $([System.Environment]::OSVersion.Version.Build)"
Write-Output "UI culture    : $([System.Globalization.CultureInfo]::CurrentUICulture.Name)"

# 1. Speech privacy consent. RecognizeAsync() with the dictation/topic
#    constraint HARD-REQUIRES this, even when processing is on-device.
$consent = $false
try {
    $k = 'HKCU:\SOFTWARE\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'
    $v = (Get-ItemProperty -Path $k -Name HasAccepted -ErrorAction Stop).HasAccepted
    $consent = ($v -eq 1)
} catch { $consent = $false }
if ($consent) {
    Write-Output "Speech consent: ACCEPTED"
} else {
    $ok = $false
    Write-Output "Speech consent: NOT ACCEPTED  <-- this blocks WinRT dictation"
    Write-Output "  Fix: Settings > Privacy & security > Speech > turn ON 'Online speech recognition'."
}

# 2. WinRT recognizer construction + constraint compile
try {
    . (Join-Path $PSScriptRoot 'win-async.ps1')
    $r = New-Object Windows.Media.SpeechRecognition.SpeechRecognizer
    Write-Output "Recognizer    : constructed OK"
    Write-Output "Current lang  : $($r.CurrentLanguage.DisplayName) [$($r.CurrentLanguage.LanguageTag)]"
    try {
        $topic = [Windows.Media.SpeechRecognition.SpeechRecognizer]::SupportedTopicLanguages
        Write-Output "Dictation langs: $((@($topic) | ForEach-Object { $_.LanguageTag }) -join ', ')"
    } catch { Write-Output "Dictation langs: (could not enumerate: $($_.Exception.Message))" }

    $comp = Wait-WinRtOp $r.CompileConstraintsAsync() $script:WV_SR_Compile 20000
    if ($comp.Status.ToString() -eq 'Success') {
        Write-Output "Constraints   : COMPILED OK  ->  WinRT dictation is ready to use"
    } else {
        $ok = $false
        Write-Output "Constraints   : FAILED (status = $($comp.Status))"
        Write-Output "  Fix: Settings > Time & language > Speech > add/repair the speech pack for your language."
    }
}
catch {
    $ok = $false
    Write-Output "Recognizer    : FAILED - $($_.Exception.Message)"
    Write-Output "  Most likely the on-device speech language pack is missing."
    Write-Output "  Fix: Settings > Time & language > Speech > 'Speech recognition' > add your language,"
    Write-Output "       then also enable Settings > Privacy & security > Speech (online speech)."
}

Write-Output ""
Write-Output $(if ($ok) { "RESULT: WinRT engine OK. Run /windows-voice:voice-listen and speak normally." }
               else      { "RESULT: WinRT not ready. Either fix the speech pack above, or set sttEngine to 'sapi' in $(Join-Path (Get-VoiceStateDir) 'config.json') for the legacy fallback." })
