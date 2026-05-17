# voice-hub.ps1 - start / stop / status the Vox Hub tray app.
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
        if (Test-HubAlive) { Write-Output 'Vox Hub already running. Name this CLI with /vox:name <name>.'; return }
        Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', (Join-Path $PSScriptRoot 'hub.ps1')
        ) | Out-Null
        Start-Sleep -Seconds 14
        if (Test-HubAlive) {
            Write-Output 'Vox Hub started (tray, two rising beeps = ready).'
            Write-Output 'Now in EACH Claude CLI run:  /vox:name <name>   (e.g. atlas, nova).'
            Write-Output 'Then say:  "hey <name>"  -> wait for the high beep -> speak.'
        } else {
            Write-Output "Hub failed to stay up. Check $(Join-Path $state 'voice.log') (likely speech-privacy consent)."
        }
    }
    'stop' {
        $killed = @()
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -match '-File\s+"?[^"]*\\hub\.ps1' } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue; $killed += $_.ProcessId } catch { } }
        Remove-Item $hubJson -Force -EA SilentlyContinue
        Write-Output ("Vox Hub stopped. " + $(if ($killed.Count) { "Killed: $($killed -join ', ')." } else { "Nothing was running." }))
    }
    'status' {
        if (-not (Test-HubAlive)) { Write-Output 'Vox Hub: NOT running. Start with /vox:hub.'; return }
        $st = Invoke-Hub 'status' @{}
        $named = @($st.clis | Where-Object { $_.name })
        Write-Output "Vox Hub: RUNNING (port $((Get-VoiceConfig).hubPort))."
        if ($named.Count) {
            Write-Output 'Registered CLIs:'
            foreach ($c in $st.clis) { Write-Output ("  {0,-10} {1}" -f ($(if($c.name){$c.name}else{'(unnamed)'}), $c.cwd)) }
        } else { Write-Output 'No named CLIs yet. Run /vox:name <name> in each Claude CLI.' }
    }
    default { Write-Output "Usage: /vox:hub [start|stop|status]" }
}
