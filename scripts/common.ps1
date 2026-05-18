# common.ps1 - shared helpers for windows-voice. Dot-sourced by the other scripts.

$ErrorActionPreference = 'Stop'

function Get-VoiceStateDir {
    $dir = Join-Path $env:USERPROFILE '.claude\windows-voice'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

function Get-VoiceConfig {
    $dir = Get-VoiceStateDir
    $path = Join-Path $dir 'config.json'
    $defaults = [ordered]@{
        voice              = ''        # '' = system default voice
        rate               = 1         # -10..10 (slightly brisk; higher = shorter deaf window)
        volume             = 100       # 0..100
        maxChars           = 100000    # effectively uncapped - speak the full answer (use /vox:hush to cut a long one)
        speakCodeBlocks    = $false
        wakeWords          = @('hey claude', 'okay claude')   # bare 'claude' self-triggers on TTS
        endWords           = @('over', 'send it', 'go ahead', 'that is all', 'send')
        duplex             = 'half'    # 'half' = deaf while Claude speaks (speakers); 'full' = always listen (headset)
        ttsTailMs          = 300       # echo-settle pause after TTS ends before listening resumes
        hubPort            = 51789     # Vox Hub localhost IPC port
        wakeConfidence     = 0.40      # SAPI wake-word floor (0..1)
        commandConfidence  = 0.30      # SAPI command floor (only if sttEngine=sapi)
        silenceGapSec      = 2.5       # quiet time that ends a command
        maxCommandSec      = 30        # hard cap on one command
        sttEngine          = 'winrt'   # 'winrt' (modern, accurate) | 'sapi' (legacy fallback)
        winrtMinConfidence = 'Low'     # accept High|Medium|Low ; 'Rejected' is always dropped
        winrtInitialSilenceSec = 5     # how long to wait for you to start talking
        winrtEndSilenceSec     = 2.0   # silence ending ONE utterance (WinRT dictation max ~2s)
        winrtContinueSilenceSec = 2.5  # extra quiet AFTER you've spoken before it sends (think-pause grace)
        warmPrimePasses    = 3         # startup warm-prime silent passes on a fresh recognizer
        keepAliveSec       = 20        # idle interval to re-warm the persistent recognizer (0 = disable)
        speakVoiceOnly     = $true     # only speak replies to VOICED prompts; stay silent on typed ones
        voiceCmdTtlSec     = 0         # voiced cmd stays matchable until consumed (0 = no expiry)
        voiceCmdRing       = 50        # safety cap on unconsumed voiced commands kept
    }
    if (Test-Path $path) {
        try {
            $user = Get-Content $path -Raw | ConvertFrom-Json
            foreach ($k in $user.PSObject.Properties.Name) { $defaults[$k] = $user.$k }
        } catch { }
    }
    return $defaults
}

function Invoke-Hub {
    # POST JSON to the Vox Hub. Returns the parsed reply, or $null if the
    # hub isn't running (callers fall back gracefully).
    param([string]$Path, [hashtable]$Body)
    try {
        $port = [int](Get-VoiceConfig).hubPort
        return Invoke-RestMethod -Uri "http://127.0.0.1:$port/$Path" -Method Post `
            -Body (($Body | ConvertTo-Json -Compress)) -ContentType 'application/json' -TimeoutSec 3
    } catch { return $null }
}

function Write-VoiceLog {
    param([string]$Message, [string]$Component = 'voice')
    try {
        $dir = Get-VoiceStateDir
        $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Component, $Message
        Add-Content -Path (Join-Path $dir 'voice.log') -Value $line
    } catch { }
}

function Test-SpeakEnabled {
    Test-Path (Join-Path (Get-VoiceStateDir) 'speak.enabled')
}

# --- Voiced-command ring: lets the Stop hook tell a VOICED prompt from a
#     TYPED one. The hub appends every command it pastes; on-stop checks
#     whether the prompt that triggered a reply came through here. ---
function Get-NormText {
    param([string]$Text)
    if (-not $Text) { return '' }
    $t = $Text.ToLowerInvariant()
    $t = [regex]::Replace($t, '\s+', ' ')
    return $t.Trim().Trim([char[]]@('.', '!', '?', ',', ';', ':', '"', "'", '`', ' '))
}

function Add-VoiceCmd {
    param([string]$Text)
    try {
        $n = Get-NormText $Text
        if (-not $n) { return }
        $f   = Join-Path (Get-VoiceStateDir) 'voice-cmds.jsonl'
        $now = [int][double]((Get-Date).ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds
        Add-Content -Path $f -Value (@{ t = $now; x = $n } | ConvertTo-Json -Compress) -Encoding UTF8
        $max = [int](Get-VoiceConfig).voiceCmdRing
        $all = @(Get-Content $f -ErrorAction SilentlyContinue)
        if ($all.Count -gt $max) { Set-Content -Path $f -Value ($all[($all.Count-$max)..($all.Count-1)]) -Encoding UTF8 }
    } catch { }
}

function Test-WasVoiceCmd {
    param([string]$Text)
    try {
        $n = Get-NormText $Text
        if (-not $n) { return $false }
        $f = Join-Path (Get-VoiceStateDir) 'voice-cmds.jsonl'
        if (-not (Test-Path $f)) { return $false }
        $ttl = [double](Get-VoiceConfig).voiceCmdTtlSec
        $now = [double]((Get-Date).ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds
        foreach ($ln in (Get-Content $f -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            try { $o = $ln | ConvertFrom-Json } catch { continue }
            if ($ttl -gt 0 -and ($now - [double]$o.t) -gt $ttl) { continue }
            if ([string]$o.x -eq $n) { return $true }
        }
        return $false
    } catch { return $false }
}

# Consume one voiced command: drop the FIRST matching entry so its reply is
# spoken exactly once and the words can't false-match a later typed prompt.
function Remove-VoiceCmd {
    param([string]$Text)
    try {
        $n = Get-NormText $Text
        if (-not $n) { return }
        $f = Join-Path (Get-VoiceStateDir) 'voice-cmds.jsonl'
        if (-not (Test-Path $f)) { return }
        $kept = New-Object System.Collections.Generic.List[string]
        $dropped = $false
        foreach ($ln in (Get-Content $f -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            if (-not $dropped) {
                try { $o = $ln | ConvertFrom-Json } catch { $o = $null }
                if ($o -and [string]$o.x -eq $n) { $dropped = $true; continue }
            }
            $kept.Add($ln)
        }
        if ($dropped) {
            if ($kept.Count) { Set-Content -Path $f -Value $kept -Encoding UTF8 }
            else { Remove-Item $f -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
}

# Wipe the ring (called on hub start so a fresh session = clean slate).
function Clear-VoiceCmds {
    try { Remove-Item (Join-Path (Get-VoiceStateDir) 'voice-cmds.jsonl') -Force -ErrorAction SilentlyContinue } catch { }
}

# --- Win32 window helpers (load once) ---
if (-not ('WinVoiceNative' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct WVPOINT { public int X; public int Y; }
public struct WVRECT  { public int Left; public int Top; public int Right; public int Bottom; }
public static class WinVoiceNative {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out WVRECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref WVPOINT p);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out WVPOINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);

    public static WVPOINT GetCursor() { WVPOINT p; GetCursorPos(out p); return p; }

    // Click an absolute screen point (used to focus a specific WT split pane).
    // Saves/restores the cursor.
    public static bool ClickPoint(int x, int y) {
        WVPOINT old; GetCursorPos(out old);
        SetCursorPos(x, y);
        mouse_event(0x02, 0, 0, 0, IntPtr.Zero);
        mouse_event(0x04, 0, 0, 0, IntPtr.Zero);
        SetCursorPos(old.X, old.Y);
        return true;
    }

    // Click the centre of the window's client area to give that terminal pane
    // real keyboard focus (UIA tab-select alone leaves focus on the tab strip,
    // so SendKeys goes nowhere). Saves/restores the cursor position.
    public static bool ClickClientCenter(IntPtr h) {
        WVRECT rc; if (!GetClientRect(h, out rc)) return false;
        WVPOINT c; c.X = (rc.Right - rc.Left) / 2; c.Y = (rc.Bottom - rc.Top) / 2;
        if (!ClientToScreen(h, ref c)) return false;
        WVPOINT old; GetCursorPos(out old);
        SetCursorPos(c.X, c.Y);
        mouse_event(0x02, 0, 0, 0, IntPtr.Zero); // LEFTDOWN
        mouse_event(0x04, 0, 0, 0, IntPtr.Zero); // LEFTUP
        SetCursorPos(old.X, old.Y);
        return true;
    }

    // Force a window to the foreground, defeating Windows' foreground-lock by
    // attaching to the current foreground thread's input queue. Works reliably
    // for any top-level WINDOW (not individual terminal TABS - those share one
    // handle and cannot be targeted by Win32).
    public static bool ForceForeground(IntPtr hWnd) {
        if (hWnd == IntPtr.Zero || !IsWindow(hWnd)) return false;
        if (IsIconic(hWnd)) ShowWindow(hWnd, 9); else ShowWindow(hWnd, 5); // RESTORE / SHOW
        IntPtr fg = GetForegroundWindow();
        uint tCur = GetCurrentThreadId();
        uint tFg  = (fg == IntPtr.Zero) ? 0 : GetWindowThreadProcessId(fg, IntPtr.Zero);
        uint tTgt = GetWindowThreadProcessId(hWnd, IntPtr.Zero);
        if (tFg != 0)  AttachThreadInput(tFg, tCur, true);
        if (tTgt != 0) AttachThreadInput(tTgt, tCur, true);
        // NOTE: no ALT keybd_event nudge - it poisons the next SendKeys
        // (Windows Terminal treats following chars as ALT+key shortcuts and
        // nothing types). AttachThreadInput alone defeats the foreground lock.
        bool ok = SetForegroundWindow(hWnd);
        BringWindowToTop(hWnd);
        if (tTgt != 0) AttachThreadInput(tTgt, tCur, false);
        if (tFg != 0)  AttachThreadInput(tFg, tCur, false);
        return ok || GetForegroundWindow() == hWnd;
    }
}
"@
}

function Get-ForegroundWindowHandle { [WinVoiceNative]::GetForegroundWindow() }

function Get-WindowClass {
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) { return '' }
    $sb = New-Object System.Text.StringBuilder 256
    [void][WinVoiceNative]::GetClassName($Handle, $sb, 256)
    return $sb.ToString()
}

function Set-ActiveWindow {
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) { return $false }
    if (-not [WinVoiceNative]::IsWindow($Handle)) { return $false }
    $ok = [WinVoiceNative]::ForceForeground($Handle)
    Start-Sleep -Milliseconds 120
    # confirm it actually came forward; one retry
    if ([WinVoiceNative]::GetForegroundWindow() -ne $Handle) {
        [WinVoiceNative]::ForceForeground($Handle) | Out-Null
        Start-Sleep -Milliseconds 120
    }
    return ([WinVoiceNative]::GetForegroundWindow() -eq $Handle) -or $ok
}
