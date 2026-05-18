# hub.ps1 - Vox Hub. One tray app owns the mic/STT/TTS and routes voice to
# many Claude CLIs. Each CLI registers (by its terminal window) and YOU name it
# with /vox:name <name>; the hub then listens for "hey <name>" and types
# into that CLI's window. Replies come back via /speak, queued + name-prefixed.
#
# Reuses the proven engine: SAPI wake word + persistent self-healing WinRT
# dictation + half-duplex. Run hidden; quit from the tray.
param([switch]$Stop)

. (Join-Path $PSScriptRoot 'common.ps1')

$state   = Get-VoiceStateDir
$cfg     = Get-VoiceConfig
$port    = [int]$cfg.hubPort
$hubJson = Join-Path $state 'hub.json'

if ($Stop) {
    if (Test-Path $hubJson) {
        try { Stop-Process -Id ([int]((Get-Content $hubJson -Raw | ConvertFrom-Json).pid)) -Force -EA SilentlyContinue } catch { }
        Remove-Item $hubJson -Force -EA SilentlyContinue
    }
    Write-Output 'Vox Hub stopped.'
    return
}

Add-Type -AssemblyName System.Speech
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'win-async.ps1')
. (Join-Path $PSScriptRoot 'uia.ps1')

# Speech privacy consent (WinRT dictation hard-requires it)
$accepted = $false
try { $accepted = ((Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' -Name HasAccepted -EA Stop).HasAccepted -eq 1) } catch { }
if (-not $accepted) {
    Write-VoiceLog 'FATAL hub: speech privacy not accepted' 'hub'
    Write-Output "Enable Settings > Privacy & security > Speech > Online speech recognition, then retry."
    return
}

# SINGLE HUB: kill every other hub.ps1 process. hub.json-based stop orphans
# older hubs (its pid gets overwritten each start); a stale hub keeps serving
# OLD code on the port while new ones run headless. This guarantees exactly
# one hub, always the latest code.
try {
    # Match ONLY processes whose -File arg is ...\hub.ps1 (not voice-hub.ps1,
    # not launchers/harnesses that merely mention the path in -Command).
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '-File\s+"?[^"]*\\hub\.ps1' } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue } catch { } }
    Start-Sleep -Milliseconds 800
} catch { }

# One mic: the single-CLI listener and the hub cannot coexist. Stop any
# running listener so it doesn't contend for the microphone.
$lpf = Join-Path $state 'listener.pid'
if (Test-Path $lpf) {
    Set-Content -Path (Join-Path $state 'stop.flag') -Value '1'
    try { Stop-Process -Id ([int]((Get-Content $lpf -Raw).Trim())) -Force -EA SilentlyContinue } catch { }
    Remove-Item $lpf -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 600
    Remove-Item (Join-Path $state 'stop.flag') -Force -EA SilentlyContinue
    Write-VoiceLog 'stopped single-CLI listener (hub owns the mic)' 'hub'
}

Set-Content -Path $hubJson -Value (@{ port = $port; pid = $PID } | ConvertTo-Json) -Encoding UTF8
Clear-VoiceCmds   # fresh hub session = clean voiced-command slate
Write-VoiceLog "hub starting (pid $PID, port $port)" 'hub'

# ---- shared state across the HTTP runspace and the main loop ----
$sync = [hashtable]::Synchronized(@{})
$sync.clis         = [hashtable]::Synchronized(@{})   # key = hwnd string
$sync.tts          = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
$sync.quit         = $false
$sync.grammarDirty = $true
$sync.port         = $port

# ---------------------------------------------------------------------------
# HTTP IPC server (own runspace; mutates $sync)
# ---------------------------------------------------------------------------
$httpScript = {
    param($sync)
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://127.0.0.1:$($sync.port)/")
    try { $listener.Start() } catch { $sync.httpFailed = $true; return }
    $sync.httpUp = $true
    while (-not $sync.quit) {
        try { $ctx = $listener.GetContext() } catch { break }
        try {
            $path = $ctx.Request.Url.AbsolutePath.ToLower()
            $body = $null
            if ($ctx.Request.HasEntityBody) {
                $sr = New-Object System.IO.StreamReader $ctx.Request.InputStream
                $raw = $sr.ReadToEnd(); $sr.Close()
                if ($raw) { try { $body = $raw | ConvertFrom-Json } catch { } }
            }
            $out = @{ ok = $true }
            switch -Wildcard ($path) {
                '*/ping' { $out.port = $sync.port }
                '*/register' {
                    # Only the window hwnd here - tabs/panes share it, so this
                    # is just a cosmetic pending entry. Real identity comes
                    # from /name (which carries tab/pane RuntimeIds).
                    $hw = [string]$body.hwnd
                    if ($hw) {
                        $k = "win:$hw"
                        if (-not $sync.clis.ContainsKey($k)) {
                            $sync.clis[$k] = @{ hwnd = $hw; cwd = $body.cwd; name = $null; wake = @(); seen = (Get-Date) }
                        } else { $sync.clis[$k].seen = (Get-Date) }
                    }
                }
                '*/name' {
                    # Key by the CLI's UNIQUE identity (pane > tab > window) so
                    # multiple tabs/panes in ONE Terminal window don't collide
                    # on the shared hwnd and overwrite each other.
                    $hw = [string]$body.hwnd; $n = ([string]$body.name).Trim().ToLower()
                    $k = if ($body.pane) { "pane:$($body.pane)" }
                         elseif ($body.tab) { "tab:$($body.tab)" }
                         else { "win:$hw" }
                    if ($hw -and $n) {
                        if (-not $sync.clis.ContainsKey($k)) { $sync.clis[$k] = @{ seen = (Get-Date) } }
                        # drop any OTHER entry already using this name (re-point)
                        foreach ($ok in @($sync.clis.Keys)) {
                            if ($ok -ne $k -and $sync.clis[$ok].name -eq $n) { $sync.clis.Remove($ok) }
                        }
                        # also drop the cosmetic win: pending entry for this window
                        if ($k -ne "win:$hw" -and $sync.clis.ContainsKey("win:$hw") -and -not $sync.clis["win:$hw"].name) { $sync.clis.Remove("win:$hw") }
                        $sync.clis[$k].hwnd    = $hw
                        $sync.clis[$k].name    = $n
                        $sync.clis[$k].wake    = @("hey $n", "okay $n")
                        $sync.clis[$k].cwd     = $body.cwd
                        $sync.clis[$k].tab     = $body.tab
                        $sync.clis[$k].tabName = $body.tabName
                        $sync.clis[$k].pane    = $body.pane
                        $sync.clis[$k].seen    = (Get-Date)
                        $sync.grammarDirty     = $true
                        $out.name = $n; $out.wake = $sync.clis[$k].wake; $out.hwnd = $hw; $out.cwd = $body.cwd
                    } else { $out.ok = $false; $out.error = 'need hwnd+name' }
                }
                '*/speak' {
                    $k = [string]$body.hwnd
                    $nm = $null
                    if ($k -and $sync.clis.ContainsKey($k)) { $nm = $sync.clis[$k].name }
                    if (-not $nm -and $body.cwd) {
                        foreach ($e in $sync.clis.Values) { if ($e.cwd -eq $body.cwd -and $e.name) { $nm = $e.name; break } }
                    }
                    $sync.tts.Enqueue(@{ name = $nm; text = [string]$body.text })
                }
                '*/deregister' {
                    $k = [string]$body.hwnd
                    if ($k -and $sync.clis.ContainsKey($k)) { $sync.clis.Remove($k); $sync.grammarDirty = $true }
                }
                '*/status' {
                    $out.clis = @($sync.clis.Values | ForEach-Object { @{ name = $_.name; cwd = $_.cwd; hwnd = $_.hwnd } })
                }
                default { $out.ok = $false; $out.error = 'unknown' }
            }
            $bytes = [Text.Encoding]::UTF8.GetBytes(($out | ConvertTo-Json -Depth 6 -Compress))
            $ctx.Response.ContentType = 'application/json'
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } catch { }
        finally { try { $ctx.Response.Close() } catch { } }
    }
    try { $listener.Stop() } catch { }
}
$rs = [runspacefactory]::CreateRunspace(); $rs.Open()
$rs.SessionStateProxy.SetVariable('sync', $sync)
$httpPs = [powershell]::Create(); $httpPs.Runspace = $rs
[void]$httpPs.AddScript($httpScript).AddArgument($sync)
[void]$httpPs.BeginInvoke()

# Don't run headless: if the port couldn't bind, bail loudly instead of
# sitting there useless while a stale hub serves old code.
$waited = 0
while (-not $sync.httpUp -and -not $sync.httpFailed -and $waited -lt 30) { Start-Sleep -Milliseconds 200; $waited++ }
if ($sync.httpFailed -or -not $sync.httpUp) {
    Write-VoiceLog "FATAL hub: port $port already in use (another hub?). Exiting." 'hub'
    Remove-Item $hubJson -Force -EA SilentlyContinue
    return
}
Write-VoiceLog "hub HTTP listening on $port" 'hub'

# ---------------------------------------------------------------------------
# Speech engine (reused, proven): persistent WinRT recognizer + self-heal
# ---------------------------------------------------------------------------
function Initialize-HubRec {
    param([switch]$Warm)
    try { if ($script:hrec) { $script:hrec.Dispose() } } catch { }
    $script:hrec = New-Object Windows.Media.SpeechRecognition.SpeechRecognizer
    try { $script:hrec.Timeouts.EndSilenceTimeout = [TimeSpan]::FromSeconds([double]$cfg.winrtEndSilenceSec) } catch { }
    $c = Wait-WinRtOp $script:hrec.CompileConstraintsAsync() $script:WV_SR_Compile 20000
    if ($c.Status.ToString() -ne 'Success') { throw "compile $($c.Status)" }
    if ($Warm) {
        # A freshly built recognizer's first few real inferences come back
        # Unknown/Rejected (cold). One throwaway pass isn't enough - spend
        # those cold cycles HERE, on silence, so the user's first command
        # lands warm. Per-wake this runs before the "speak now" beep, so the
        # cost is paid while the user watches the pane focus (free time).
        $passes = 3
        try { if ($cfg.warmPrimePasses) { $passes = [int]$cfg.warmPrimePasses } } catch { }
        try {
            $script:hrec.Timeouts.InitialSilenceTimeout = [TimeSpan]::FromSeconds(0.4)
            for ($i = 0; $i -lt $passes; $i++) {
                $null = Wait-WinRtOp $script:hrec.RecognizeAsync() $script:WV_SR_Result 15000
            }
        } catch { }
    }
}

function Get-HubCommand {
    $rcg = $script:hrec
    # (no beep here - the main loop beeps AFTER focusing the CLI)
    $buffer = New-Object System.Text.StringBuilder
    $start = Get-Date; $first = $true; $cold = 0; $rebuilt = $false
    while ($true) {
        if ($sync.quit) { break }
        if (((Get-Date) - $start).TotalSeconds -ge [double]$cfg.maxCommandSec) { break }
        $sil = if ($first) { [double]$cfg.winrtInitialSilenceSec } else { [double]$cfg.winrtContinueSilenceSec }
        try { $rcg.Timeouts.InitialSilenceTimeout = [TimeSpan]::FromSeconds($sil) } catch { }
        $ms = [int](($sil + [double]$cfg.winrtEndSilenceSec + 10) * 1000)
        try { $res = Wait-WinRtOp $rcg.RecognizeAsync() $script:WV_SR_Result $ms }
        catch {
            if (-not $rebuilt) { try { Initialize-HubRec -Warm; $rcg = $script:hrec; $script:lastWarm = Get-Date; $rebuilt = $true; continue } catch { break } }
            break
        }
        $st = $res.Status.ToString(); $cf = [int]$res.Confidence
        $tx = ''; if ($res.Text) { $tx = $res.Text.Trim() }
        if ($st -eq 'Success' -and $tx -and $cf -le 2) {
            Write-VoiceLog "heard: '$tx' conf=$($res.Confidence)" 'hub'
            [void]$buffer.Append(' ').Append($tx); $first = $false
            continue
        }
        Write-VoiceLog "no result (status=$st conf=$($res.Confidence)) cold=$cold" 'hub'
        if ($buffer.Length -gt 0) { break }
        $cold++
        # A stale recognizer returns Unknown/Rejected WITHOUT throwing. But so
        # does plain user silence. With the persistent recognizer kept warm by
        # the idle keep-alive, repeated Rejected almost always means "you
        # didn't speak" - rebuilding then would re-cold a healthy recognizer
        # (the old bug). Only rebuild if it's genuinely stale (keep-alive off,
        # or far past its interval), and warm the replacement.
        if ($cold -eq 2 -and -not $rebuilt) {
            $staleSec = [math]::Round(((Get-Date) - $script:lastWarm).TotalSeconds)
            $kaSec = 20; try { if ($null -ne $cfg.keepAliveSec) { $kaSec = [int]$cfg.keepAliveSec } } catch { }
            if ($kaSec -le 0 -or $staleSec -ge ($kaSec * 2)) {
                Write-VoiceLog "recognizer stale (${staleSec}s since warm) - rebuilding" 'hub'
                try { Initialize-HubRec -Warm; $rcg = $script:hrec; $script:lastWarm = Get-Date; $rebuilt = $true } catch { }
                continue
            }
            Write-VoiceLog "no speech (recognizer warm, ${staleSec}s) - not rebuilding" 'hub'
        }
        if ($cold -ge 4) { break }
    }
    return $buffer.ToString().Trim()
}

function Focus-Cli {
    # Bring the named CLI forward BEFORE the user speaks.
    #  - window to foreground (best-effort)
    #  - if it's a tab: select it (UIA)
    #  - if it's a split PANE: click that pane's rectangle (the reliable bit)
    #  - else: click client centre
    param([IntPtr]$Handle, [string]$TabId, [string]$TabName, [string]$PaneId)
    $foc = Set-ActiveWindow -Handle $Handle
    Start-Sleep -Milliseconds 120
    $tabSel = $false
    if ($TabId) {
        $tabSel = Select-TabById -Hwnd $Handle -Id $TabId
        if (-not $tabSel) { Write-VoiceLog "tab '$TabName' (id $TabId) not found" 'hub' }
        Start-Sleep -Milliseconds 150
    }
    $paneSel = $false
    if ($PaneId) {
        $paneSel = Focus-PaneById -Hwnd $Handle -Id $PaneId
        if (-not $paneSel) { Write-VoiceLog "pane $PaneId not found - click centre" 'hub'; [void][WinVoiceNative]::ClickClientCenter($Handle) }
    } else {
        [void][WinVoiceNative]::ClickClientCenter($Handle)
    }
    Start-Sleep -Milliseconds 150
    $fg  = [WinVoiceNative]::GetForegroundWindow()
    $match = ([int64]$fg -eq [int64]$Handle)
    Write-VoiceLog "focus -> hwnd=$Handle winFocus=$foc tabSel=$tabSel paneSel=$paneSel fgMatch=$match" 'hub'
    if (-not $match -and -not $paneSel -and -not $tabSel) { return 'FAIL' }
    return 'OK'
}

function Inject-Text {
    # Focus already done by Focus-Cli; re-assert the tab cheaply (in case the
    # active tab drifted while you spoke) then paste via clipboard + Ctrl+V.
    param([IntPtr]$Handle, [string]$Text, [string]$TabId, [string]$PaneId)
    if ($TabId)  { [void](Select-TabById -Hwnd $Handle -Id $TabId); Start-Sleep -Milliseconds 100 }
    if ($PaneId) { if (-not (Focus-PaneById -Hwnd $Handle -Id $PaneId)) { [void][WinVoiceNative]::ClickClientCenter($Handle) } }
    else         { [void][WinVoiceNative]::ClickClientCenter($Handle) }
    Start-Sleep -Milliseconds 120
    $clean = ($Text -replace "[\r\n]+", ' ')
    $pasted = $false
    for ($i = 0; $i -lt 3 -and -not $pasted; $i++) {
        try { [System.Windows.Forms.Clipboard]::SetText($clean); $pasted = $true }
        catch { Start-Sleep -Milliseconds 120 }
    }
    if (-not $pasted) { Write-VoiceLog 'clipboard set failed' 'hub'; [console]::Beep(220, 250); return }
    Start-Sleep -Milliseconds 80
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds 250
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Write-VoiceLog "pasted $($clean.Length) chars -> hwnd=$Handle" 'hub'
    [console]::Beep(660, 120)
}

$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
try { $synth.Rate = [int]$cfg.rate; $synth.Volume = [int]$cfg.volume } catch { }
function Speak-Reply {
    param($name, $text)
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $t = [regex]::Replace($text, '(?s)```.*?```', ' . code block on screen . ')
    $t = [regex]::Replace($t, '`([^`]+)`', '$1')
    $t = [regex]::Replace($t, '(\*\*|\*|__|_|#|~~)', '')
    $t = [regex]::Replace($t, '\s+', ' ').Trim()
    if ($name) { $t = "$name says: $t" }
    try { $synth.Speak($t) } catch { }
}

# ---------------------------------------------------------------------------
# Wake grammar (combined across all named CLIs) + routing map
# ---------------------------------------------------------------------------
$wakeEng = $null
foreach ($ri in [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers()) {
    if ($ri.Culture.Name -eq [System.Globalization.CultureInfo]::CurrentUICulture.Name) { $wakeEng = New-Object System.Speech.Recognition.SpeechRecognitionEngine $ri; break }
}
if (-not $wakeEng) { $wakeEng = New-Object System.Speech.Recognition.SpeechRecognitionEngine }
$wakeEng.SetInputToDefaultAudioDevice()
$script:wakeMap = @{}

function Rebuild-Grammar {
    $wakeEng.UnloadAllGrammars()
    $script:wakeMap = @{}
    $choices = New-Object System.Speech.Recognition.Choices
    $any = $false
    foreach ($k in @($sync.clis.Keys)) {
        $e = $sync.clis[$k]
        if (-not $e.name) { continue }
        foreach ($w in $e.wake) { $choices.Add([string]$w); $script:wakeMap[[string]$w] = $k; $any = $true }
    }
    if ($any) {
        $gb = New-Object System.Speech.Recognition.GrammarBuilder
        $gb.Append($choices)
        $g = New-Object System.Speech.Recognition.Grammar $gb
        $g.Name = 'wake'
        $wakeEng.LoadGrammar($g)
    }
    Write-VoiceLog "grammar rebuilt: $($script:wakeMap.Keys -join ', ')" 'hub'
}

# ---------------------------------------------------------------------------
# Tray icon
# ---------------------------------------------------------------------------
$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = [System.Drawing.SystemIcons]::Application
$ni.Text = 'Vox Hub'
$ni.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$ni.ContextMenuStrip = $menu
function Rebuild-Menu {
    $menu.Items.Clear()
    $h = $menu.Items.Add('Vox Hub'); $h.Enabled = $false
    $menu.Items.Add('-') | Out-Null
    $named = @($sync.clis.Values | Where-Object { $_.name })
    if ($named.Count) {
        foreach ($e in $named) { $mi = $menu.Items.Add("  $($e.name)  -  $([System.IO.Path]::GetFileName([string]$e.cwd))"); $mi.Enabled = $false }
    } else {
        $mi = $menu.Items.Add('  (no named CLIs - run /vox:name <name>)'); $mi.Enabled = $false
    }
    $menu.Items.Add('-') | Out-Null
    $log = $menu.Items.Add('Open log'); $log.add_Click({ Start-Process notepad (Join-Path (Get-VoiceStateDir) 'voice.log') })
    $q = $menu.Items.Add('Quit Vox Hub'); $q.add_Click({ $sync.quit = $true })
}

Write-VoiceLog 'warming hub recognizer...' 'hub'
Initialize-HubRec -Warm
$script:lastWarm = Get-Date     # last time the recognizer was actually exercised OK
$script:lastKeepAlive = Get-Date  # throttles keep-alive attempts (success or not)
Rebuild-Menu
[console]::Beep(880, 120); [console]::Beep(1040, 120)
$ni.ShowBalloonTip(2500, 'Vox Hub', 'Running. Name a CLI with /vox:name <name>.', 'Info')
Write-VoiceLog 'hub ready' 'hub'

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
$isHalf = ($cfg.duplex -eq 'half')
while (-not $sync.quit) {
    [System.Windows.Forms.Application]::DoEvents()

    # prune entries whose WINDOW is gone (tabs/panes closing inside a live
    # window aren't detectable here - re-naming re-points those).
    $dead = @()
    foreach ($k in @($sync.clis.Keys)) {
        $hwv = 0; [void][int64]::TryParse([string]$sync.clis[$k].hwnd, [ref]$hwv)
        if ($hwv -eq 0 -or -not [WinVoiceNative]::IsWindow([IntPtr]$hwv)) { $dead += $k }
    }
    if ($dead.Count) { foreach ($k in $dead) { $sync.clis.Remove($k) }; $sync.grammarDirty = $true }

    if ($sync.grammarDirty) { Rebuild-Grammar; Rebuild-Menu; $sync.grammarDirty = $false }

    # speak queued replies (half-duplex: not listening while speaking)
    if ($sync.tts.Count -gt 0) {
        $item = $sync.tts.Dequeue()
        Speak-Reply $item.name $item.text
        Start-Sleep -Milliseconds ([int]$cfg.ttsTailMs)
        try { Initialize-HubRec -Warm } catch { }   # refresh after TTS (proven fix)
        $script:lastWarm = Get-Date
        continue
    }

    if ($script:wakeMap.Count -eq 0) { Start-Sleep -Milliseconds 400; continue }

    # NO idle keep-alive. Poking an idle WinRT recognizer with RecognizeAsync
    # every N seconds is exactly what triggers the "could not be found" stale
    # fault + churn. Instead the WinRT recognizer is built FRESH per wake,
    # during the focus pause below (so it is never idle long enough to go
    # stale, and the build cost is hidden behind focusing). "Always listening"
    # is the SAPI wake engine on the next line - it never sleeps.
    $r = $wakeEng.Recognize([TimeSpan]::FromSeconds(1.0))
    if (-not $r) { continue }
    if ($r.Grammar.Name -ne 'wake' -or $r.Confidence -lt [double]$cfg.wakeConfidence) { continue }
    $phrase = $r.Text.ToLower()
    if (-not $script:wakeMap.ContainsKey($phrase)) { continue }
    $key = $script:wakeMap[$phrase]
    if (-not $sync.clis.ContainsKey($key)) { continue }
    $cli = $sync.clis[$key]
    Write-VoiceLog "wake '$phrase' -> $($cli.name) conf=$([math]::Round($r.Confidence,2))" 'hub'
    [console]::Beep(440, 90)        # low tick = "heard you, focusing $($cli.name)"
    $hw = [IntPtr][int64]$cli.hwnd
    # 1) FOCUS the CLI first so you see it land before talking
    $fres = Focus-Cli -Handle $hw -TabId $cli.tab -TabName $cli.tabName -PaneId $cli.pane
    if ($fres -eq 'FAIL') {
        Write-VoiceLog "$($cli.name): could not focus (tab gone + window not foregroundable) - re-run /vox:name" 'hub'
        [console]::Beep(220, 300)
        continue
    }
    # 2) Build the WinRT recognizer FRESH now, during the focus pause. A
    #    just-constructed recognizer is never stale, so there is no keep-alive
    #    and no "could not be found" fault. The mic stays warm (the SAPI wake
    #    engine holds it continuously), so this is ~1-2s, hidden behind focus.
    try { Initialize-HubRec -Warm } catch { Write-VoiceLog "pre-capture build failed: $($_.Exception.Message)" 'hub' }
    # 3) NOW the speak-now beep, 4) capture, 5) paste into the focused CLI
    [console]::Beep(988, 150)
    $cmd = Get-HubCommand
    $script:lastWarm = Get-Date     # just exercised the recognizer = warm
    if ($cmd) {
        Inject-Text -Handle $hw -Text $cmd -TabId $cli.tab -PaneId $cli.pane
        Add-VoiceCmd $cmd    # mark this prompt as VOICED so the Stop hook speaks its reply
        Write-VoiceLog "$($cli.name) <- '$cmd'" 'hub'
    } else { Write-VoiceLog "$($cli.name): empty command" 'hub'; [console]::Beep(330, 200) }
}

# cleanup
try { $ni.Visible = $false; $ni.Dispose() } catch { }
try { $wakeEng.Dispose() } catch { }
try { if ($script:hrec) { $script:hrec.Dispose() } } catch { }
try { $httpPs.Stop() } catch { }
Remove-Item $hubJson -Force -EA SilentlyContinue
Write-VoiceLog 'hub stopped' 'hub'
