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
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
}
"@
}

function Get-ForegroundWindowHandle { [WinVoiceNative]::GetForegroundWindow() }

function Set-ActiveWindow {
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) { return $false }
    if (-not [WinVoiceNative]::IsWindow($Handle)) { return $false }
    [WinVoiceNative]::ShowWindow($Handle, 9) | Out-Null   # SW_RESTORE
    return [WinVoiceNative]::SetForegroundWindow($Handle)
}
