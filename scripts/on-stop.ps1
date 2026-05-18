# on-stop.ps1 - Claude Code Stop hook. Reads the transcript, cleans the last
# assistant message, and launches a detached speaker. Must return fast and
# never block the session, so all errors are swallowed (logged only).

. (Join-Path $PSScriptRoot 'common.ps1')

try {
    $raw = [Console]::In.ReadToEnd()
    if (-not (Test-SpeakEnabled)) { exit 0 }   # TTS toggled off

    $payload = $raw | ConvertFrom-Json
    $transcript = $payload.transcript_path
    if (-not $transcript -or -not (Test-Path $transcript)) {
        Write-VoiceLog "no transcript: $transcript" 'on-stop'; exit 0
    }

    # Walk the JSONL transcript from the end; find the last assistant turn
    # that contains visible text (skip pure tool-use turns).
    $lines = Get-Content $transcript
    $text = $null
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $ln = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($ln)) { continue }
        try { $o = $ln | ConvertFrom-Json } catch { continue }
        $isAssistant = ($o.type -eq 'assistant') -or ($o.message.role -eq 'assistant')
        if (-not $isAssistant) { continue }
        $content = $o.message.content
        if (-not $content) { continue }
        $sb = New-Object System.Text.StringBuilder
        if ($content -is [string]) {
            [void]$sb.Append($content)
        } else {
            foreach ($block in $content) {
                if ($block.type -eq 'text' -and $block.text) { [void]$sb.AppendLine($block.text) }
            }
        }
        $candidate = $sb.ToString().Trim()
        if ($candidate.Length -gt 0) { $text = $candidate; break }
    }
    if (-not $text) { exit 0 }

    $cfg = Get-VoiceConfig

    # Voice-only gate: only speak if the prompt that triggered this reply came
    # in by voice (the hub recorded it). Typed prompts stay silent. Walk back
    # to the last real user prompt (skip tool_result-only user turns).
    if ($cfg.speakVoiceOnly) {
        $userText = $null
        for ($j = $lines.Count - 1; $j -ge 0; $j--) {
            $uln = $lines[$j]
            if ([string]::IsNullOrWhiteSpace($uln)) { continue }
            try { $uo = $uln | ConvertFrom-Json } catch { continue }
            if (-not (($uo.type -eq 'user') -or ($uo.message.role -eq 'user'))) { continue }
            $uc = $uo.message.content
            if (-not $uc) { continue }
            $usb = New-Object System.Text.StringBuilder
            if ($uc -is [string]) { [void]$usb.Append($uc) }
            else { foreach ($b in $uc) { if ($b.type -eq 'text' -and $b.text) { [void]$usb.AppendLine($b.text) } } }
            $cand = $usb.ToString().Trim()
            if ($cand.Length -gt 0) { $userText = $cand; break }
        }
        if (-not (Test-WasVoiceCmd $userText)) {
            Write-VoiceLog 'skip TTS: last prompt was typed, not voiced' 'on-stop'
            exit 0
        }
    }

    # Dedupe: the Stop hook can fire more than once for the same final message.
    $sha  = [System.Security.Cryptography.SHA1]::Create()
    $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '')
    $hashFile = Join-Path (Get-VoiceStateDir) 'last-hash.txt'
    if ((Test-Path $hashFile) -and ((Get-Content $hashFile -Raw).Trim() -eq $hash)) { exit 0 }
    Set-Content -Path $hashFile -Value $hash

    # Committed to speaking now: consume this voiced command so it stays
    # matchable for arbitrarily long tasks but can't false-match a later
    # typed prompt with the same words.
    if ($cfg.speakVoiceOnly -and $userText) { Remove-VoiceCmd $userText }

    # If the Vox Hub is running, hand the reply to it (queued, name-prefixed,
    # spoken centrally) instead of speaking locally. Falls through if no hub.
    $hubResp = Invoke-Hub 'speak' @{ hwnd = [string][int64](Get-ForegroundWindowHandle); cwd = $payload.cwd; text = $text }
    if ($hubResp) { exit 0 }

    # --- Clean markdown into something pleasant to hear ---
    if (-not $cfg.speakCodeBlocks) {
        $text = [regex]::Replace($text, '(?s)```.*?```', ' . (code block shown on screen) . ')
    }
    $text = [regex]::Replace($text, '`([^`]+)`', '$1')                       # inline code
    $text = [regex]::Replace($text, '!\[[^\]]*\]\([^)]*\)', '')              # images
    $text = [regex]::Replace($text, '\[([^\]]+)\]\([^)]*\)', '$1')           # links -> label
    $text = [regex]::Replace($text, '(?m)^\s{0,3}#{1,6}\s*', '')             # headings
    $text = [regex]::Replace($text, '(?m)^\s*[-*+]\s+', '')                  # bullets
    $text = [regex]::Replace($text, '(\*\*|\*|__|_|~~)', '')                 # emphasis
    $text = [regex]::Replace($text, '\s+', ' ').Trim()

    if ($text.Length -gt $cfg.maxChars) {
        $cut = $text.Substring(0, $cfg.maxChars)
        # Prefer to end on a sentence; fall back to last word boundary.
        $m = [regex]::Match($cut, '(?s)^.*[\.\!\?](?=\s|$)')
        if ($m.Success -and $m.Length -ge ($cfg.maxChars * 0.5)) { $cut = $m.Value }
        elseif ($cut.LastIndexOf(' ') -gt 0) { $cut = $cut.Substring(0, $cut.LastIndexOf(' ')) }
        $text = $cut.Trim() + ' . Full answer is on screen.'
    }
    if ([string]::IsNullOrWhiteSpace($text)) { exit 0 }

    $state = Get-VoiceStateDir

    # Stop any in-progress speech so a new reply supersedes the old one.
    $spkPid = Join-Path $state 'speaker.pid'
    if (Test-Path $spkPid) {
        try { Stop-Process -Id ([int](Get-Content $spkPid -Raw).Trim()) -Force -ErrorAction SilentlyContinue } catch { }
    }

    $tmp = Join-Path $state 'speak.txt'
    Set-Content -Path $tmp -Value $text -Encoding UTF8

    $p = Start-Process -FilePath 'powershell' -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', (Join-Path $PSScriptRoot 'speak.ps1'), '-TextFile', $tmp
    )
    Set-Content -Path $spkPid -Value $p.Id
    Write-VoiceLog "speaking $($text.Length) chars (pid $($p.Id))" 'on-stop'
}
catch {
    Write-VoiceLog "error: $($_.Exception.Message)" 'on-stop'
}
exit 0
