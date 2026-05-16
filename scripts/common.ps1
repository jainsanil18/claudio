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
        maxChars           = 100000    # effectively uncapped - speak the full answer (use /windows-voice:hush to cut a long one)
        speakCodeBlocks    = $false
        wakeWords          = @('hey claude', 'okay claude')   # bare 'claude' self-triggers on TTS
        endWords           = @('over', 'send it', 'go ahead', 'that is all', 'send')
        duplex             = 'half'    # 'half' = deaf while Claude speaks (speakers); 'full' = always listen (headset)
        ttsTailMs          = 300       # echo-settle pause after TTS ends before listening resumes
        hubPort            = 51789     # Claudio Hub localhost IPC port
        wakeConfidence     = 0.40      # SAPI wake-word floor (0..1)
        commandConfidence  = 0.30      # SAPI command floor (only if sttEngine=sapi)
        silenceGapSec      = 2.5       # quiet time that ends a command
        maxCommandSec      = 30        # hard cap on one command
        sttEngine          = 'winrt'   # 'winrt' (modern, accurate) | 'sapi' (legacy fallback)
        winrtMinConfidence = 'Low'     # accept High|Medium|Low ; 'Rejected' is always dropped
        winrtInitialSilenceSec = 5     # how long to wait for you to start talking
        winrtEndSilenceSec     = 2.0   # silence ending ONE utterance (WinRT dictation max ~2s)
        winrtContinueSilenceSec = 2.5  # extra quiet AFTER you've spoken before it sends (think-pause grace)
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
    # POST JSON to the Claudio Hub. Returns the parsed reply, or $null if the
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

# --- Win32 window helpers (load once) ---
if (-not ('WinVoiceNative' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
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
        // nudge an ALT keypress - releases the foreground lock on modern Windows
        keybd_event(0x12, 0, 0, IntPtr.Zero);
        keybd_event(0x12, 0, 2, IntPtr.Zero);
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
