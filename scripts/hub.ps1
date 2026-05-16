# hub.ps1 - Claudio Hub. One tray app owns the mic/STT/TTS and routes voice to
# many Claude CLIs. Each CLI registers (by its terminal window) and YOU name it
# with /claudio:name <name>; the hub then listens for "hey <name>" and types
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
    Write-Output 'Claudio Hub stopped.'
    return
}

Add-Type -AssemblyName System.Speech
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'win-async.ps1')

# Speech privacy consent (WinRT dictation hard-requires it)
$accepted = $false
try { $accepted = ((Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' -Name HasAccepted -EA Stop).HasAccepted -eq 1) } catch { }
if (-not $accepted) {
    Write-VoiceLog 'FATAL hub: speech privacy not accepted' 'hub'
    Write-Output "Enable Settings > Privacy & security > Speech > Online speech recognition, then retry."
    return
}

Set-Content -Path $hubJson -Value (@{ port = $port; pid = $PID } | ConvertTo-Json) -Encoding UTF8
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
    try { $listener.Start() } catch { return }
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
                    $k = [string]$body.hwnd
                    if ($k) {
                        if (-not $sync.clis.ContainsKey($k)) {
                            $sync.clis[$k] = @{ hwnd = $k; cwd = $body.cwd; name = $null; wake = @(); seen = (Get-Date) }
                        } else { $sync.clis[$k].seen = (Get-Date); $sync.clis[$k].cwd = $body.cwd }
                        $out.named = [bool]$sync.clis[$k].name
                    }
                }
                '*/name' {
                    # The caller deliberately picked/focused the target window,
                    # so just map name -> that window (overwrite freely).
                    $k = [string]$body.hwnd; $n = ([string]$body.name).Trim().ToLower()
                    if ($k -and $n) {
                        if (-not $sync.clis.ContainsKey($k)) { $sync.clis[$k] = @{ hwnd = $k; seen = (Get-Date) } }
                        # drop any other entry that had this name (re-point it)
                        foreach ($ok in @($sync.clis.Keys)) {
                            if ($ok -ne $k -and $sync.clis[$ok].name -eq $n) { $sync.clis.Remove($ok) }
                        }
                        $sync.clis[$k].name = $n
                        $sync.clis[$k].wake = @("hey $n", "okay $n")
                        $sync.clis[$k].cwd  = $body.cwd
                        $sync.clis[$k].seen = (Get-Date)
                        $sync.grammarDirty  = $true
                        $out.name = $n; $out.wake = $sync.clis[$k].wake; $out.hwnd = $k; $out.cwd = $body.cwd
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
        try {
            $script:hrec.Timeouts.InitialSilenceTimeout = [TimeSpan]::FromSeconds(0.4)
            $null = Wait-WinRtOp $script:hrec.RecognizeAsync() $script:WV_SR_Result 15000
        } catch { }
    }
}

function Get-HubCommand {
    $rcg = $script:hrec
    [console]::Beep(988, 150)
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
            if (-not $rebuilt) { try { Initialize-HubRec; $rcg = $script:hrec; $rebuilt = $true; continue } catch { break } }
            break
        }
        $st = $res.Status.ToString(); $cf = [int]$res.Confidence
        $tx = ''; if ($res.Text) { $tx = $res.Text.Trim() }
        if ($st -eq 'Success' -and $tx -and $cf -le 2) {
            [void]$buffer.Append(' ').Append($tx); $first = $false
            continue
        }
        if ($buffer.Length -gt 0) { break }
        $cold++; if ($cold -ge 3) { break }
    }
    return $buffer.ToString().Trim()
}

function Send-ToWindow {
    param([IntPtr]$Handle, [string]$Text)
    if (-not (Set-ActiveWindow -Handle $Handle)) { Write-VoiceLog "win not focusable: $Handle" 'hub'; [console]::Beep(220, 250); return }
    Start-Sleep -Milliseconds 200
    $esc = New-Object System.Text.StringBuilder
    foreach ($ch in ($Text -replace "[\r\n]+", ' ').ToCharArray()) {
        if ('+^%~(){}[]'.IndexOf($ch) -ge 0) { [void]$esc.Append('{').Append($ch).Append('}') } else { [void]$esc.Append($ch) }
    }
    [console]::Beep(740, 110)
    [System.Windows.Forms.SendKeys]::SendWait($esc.ToString())
    Start-Sleep -Milliseconds 120
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
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
    foreach ($e in $sync.clis.Values) {
        if (-not $e.name) { continue }
        foreach ($w in $e.wake) { $choices.Add([string]$w); $script:wakeMap[[string]$w] = $e.hwnd; $any = $true }
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
$ni.Text = 'Claudio Hub'
$ni.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$ni.ContextMenuStrip = $menu
function Rebuild-Menu {
    $menu.Items.Clear()
    $h = $menu.Items.Add('Claudio Hub'); $h.Enabled = $false
    $menu.Items.Add('-') | Out-Null
    $named = @($sync.clis.Values | Where-Object { $_.name })
    if ($named.Count) {
        foreach ($e in $named) { $mi = $menu.Items.Add("  $($e.name)  -  $([System.IO.Path]::GetFileName([string]$e.cwd))"); $mi.Enabled = $false }
    } else {
        $mi = $menu.Items.Add('  (no named CLIs - run /claudio:name <name>)'); $mi.Enabled = $false
    }
    $menu.Items.Add('-') | Out-Null
    $log = $menu.Items.Add('Open log'); $log.add_Click({ Start-Process notepad (Join-Path (Get-VoiceStateDir) 'voice.log') })
    $q = $menu.Items.Add('Quit Claudio Hub'); $q.add_Click({ $sync.quit = $true })
}

Write-VoiceLog 'warming hub recognizer...' 'hub'
Initialize-HubRec -Warm
Rebuild-Menu
[console]::Beep(880, 120); [console]::Beep(1040, 120)
$ni.ShowBalloonTip(2500, 'Claudio Hub', 'Running. Name a CLI with /claudio:name <name>.', 'Info')
Write-VoiceLog 'hub ready' 'hub'

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
$isHalf = ($cfg.duplex -eq 'half')
while (-not $sync.quit) {
    [System.Windows.Forms.Application]::DoEvents()

    # prune dead windows
    $dead = @()
    foreach ($k in @($sync.clis.Keys)) {
        if (-not [WinVoiceNative]::IsWindow([IntPtr][int64]$k)) { $dead += $k }
    }
    if ($dead.Count) { foreach ($k in $dead) { $sync.clis.Remove($k) }; $sync.grammarDirty = $true }

    if ($sync.grammarDirty) { Rebuild-Grammar; Rebuild-Menu; $sync.grammarDirty = $false }

    # speak queued replies (half-duplex: not listening while speaking)
    if ($sync.tts.Count -gt 0) {
        $item = $sync.tts.Dequeue()
        Speak-Reply $item.name $item.text
        Start-Sleep -Milliseconds ([int]$cfg.ttsTailMs)
        try { Initialize-HubRec -Warm } catch { }   # refresh after TTS (proven fix)
        continue
    }

    if ($script:wakeMap.Count -eq 0) { Start-Sleep -Milliseconds 400; continue }

    $r = $wakeEng.Recognize([TimeSpan]::FromSeconds(1.0))
    if (-not $r) { continue }
    if ($r.Grammar.Name -ne 'wake' -or $r.Confidence -lt [double]$cfg.wakeConfidence) { continue }
    $phrase = $r.Text.ToLower()
    if (-not $script:wakeMap.ContainsKey($phrase)) { continue }
    $hwndKey = $script:wakeMap[$phrase]
    if (-not $sync.clis.ContainsKey($hwndKey)) { continue }
    $cli = $sync.clis[$hwndKey]
    Write-VoiceLog "wake '$phrase' -> $($cli.name) conf=$([math]::Round($r.Confidence,2))" 'hub'
    [console]::Beep(988, 150)
    $cmd = Get-HubCommand
    if ($cmd) {
        Send-ToWindow -Handle ([IntPtr][int64]$hwndKey) -Text $cmd
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
