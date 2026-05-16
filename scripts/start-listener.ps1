# start-listener.ps1 - capture the Claude Code terminal as the target window,
# then launch listener.ps1 detached & hidden.
. (Join-Path $PSScriptRoot 'common.ps1')

$state   = Get-VoiceStateDir
$pidFile = Join-Path $state 'listener.pid'

# One mic: refuse to start if the multi-CLI hub is running (it owns the mic).
$hubJson = Join-Path $state 'hub.json'
if (Test-Path $hubJson) {
    try {
        $hp = [int]((Get-Content $hubJson -Raw | ConvertFrom-Json).pid)
        if (Get-Process -Id $hp -ErrorAction SilentlyContinue) {
            Write-Output "The Claudio Hub is running (it owns the mic). Use /claudio:name <name> per CLI, or stop the hub with /claudio:hub stop before /claudio:listen."
            exit 0
        }
    } catch { }
}

if (Test-Path $pidFile) {
    $existing = (Get-Content $pidFile -Raw).Trim()
    if ($existing -and (Get-Process -Id $existing -ErrorAction SilentlyContinue)) {
        Write-Output "Listener already running (pid $existing). Use /windows-voice:voice-stop first to restart."
        exit 0
    }
}

# The slash command runs in the Claude Code terminal, so the OS foreground
# window right now IS the terminal we want to type into.
$hwnd = Get-ForegroundWindowHandle
Set-Content -Path (Join-Path $state 'target.hwnd') -Value ([int64]$hwnd)
Remove-Item (Join-Path $state 'stop.flag') -Force -ErrorAction SilentlyContinue

$p = Start-Process -FilePath 'powershell' -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', (Join-Path $PSScriptRoot 'listener.ps1')
)
Start-Sleep -Milliseconds 800
$cfg = Get-VoiceConfig

if (Get-Process -Id $p.Id -ErrorAction SilentlyContinue) {
    Write-Output "Listener started (pid $($p.Id)). Target window handle: $([int64]$hwnd)."
    Write-Output "Flow: say '$($cfg.wakeWords[0])' -> wait for the HIGH beep -> speak -> just STOP talking."
    Write-Output "It sends automatically when you pause (~$($cfg.winrtEndSilenceSec)s). No end-word needed."
    Write-Output "Keep this terminal as the active window, or run /windows-voice:voice-retarget to re-aim. Log: $(Join-Path $state 'voice.log')"
} else {
    Write-Output "Listener failed to stay running. Check the log: $(Join-Path $state 'voice.log')"
    Write-Output "Most common cause: no Windows speech recognizer for your language (Settings > Time & language > Speech)."
}
