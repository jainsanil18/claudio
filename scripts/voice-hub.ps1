# voice-hub.ps1 - start / stop / status the Claudio Hub tray app.
param([string]$Action = 'start')
. (Join-Path $PSScriptRoot 'common.ps1')

$state   = Get-VoiceStateDir
$hubJson = Join-Path $state 'hub.json'
$Action  = $Action.ToLower().Trim()

function Test-HubAlive {
    if (-not (Test-Path $hubJson)) { return $false }
    try { return [bool](Get-Process -Id ([int]((Get-Content $hubJson -Raw | ConvertFrom-Json).pid)) -EA SilentlyContinue) } catch { return $false }
}

switch ($Action) {
    'start' {
        if (Test-HubAlive) { Write-Output 'Claudio Hub already running. Name this CLI with /claudio:name <name>.'; return }
        Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', (Join-Path $PSScriptRoot 'hub.ps1')
        ) | Out-Null
        Start-Sleep -Seconds 14
        if (Test-HubAlive) {
            Write-Output 'Claudio Hub started (tray, two rising beeps = ready).'
            Write-Output 'Now in EACH Claude CLI run:  /claudio:name <name>   (e.g. atlas, nova).'
            Write-Output 'Then say:  "hey <name>"  -> wait for the high beep -> speak.'
        } else {
            Write-Output "Hub failed to stay up. Check $(Join-Path $state 'voice.log') (likely speech-privacy consent)."
        }
    }
    'stop' {
        powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'hub.ps1') -Stop
    }
    'status' {
        if (-not (Test-HubAlive)) { Write-Output 'Claudio Hub: NOT running. Start with /claudio:hub.'; return }
        $st = Invoke-Hub 'status' @{}
        $named = @($st.clis | Where-Object { $_.name })
        Write-Output "Claudio Hub: RUNNING (port $((Get-VoiceConfig).hubPort))."
        if ($named.Count) {
            Write-Output 'Registered CLIs:'
            foreach ($c in $st.clis) { Write-Output ("  {0,-10} {1}" -f ($(if($c.name){$c.name}else{'(unnamed)'}), $c.cwd)) }
        } else { Write-Output 'No named CLIs yet. Run /claudio:name <name> in each Claude CLI.' }
    }
    default { Write-Output "Usage: /claudio:hub [start|stop|status]" }
}
