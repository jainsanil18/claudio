# register.ps1 - SessionStart hook. Tells the Claudio Hub this CLI exists
# (keyed by its terminal window). No-op if the hub isn't running. The user
# still has to name it with /claudio:name <name> to make it voice-addressable.
. (Join-Path $PSScriptRoot 'common.ps1')
try {
    $cwd = $null
    try { $cwd = ([Console]::In.ReadToEnd() | ConvertFrom-Json).cwd } catch { }
    if (-not $cwd) { $cwd = (Get-Location).Path }
    $null = Invoke-Hub 'register' @{ hwnd = [string][int64](Get-ForegroundWindowHandle); cwd = $cwd }
} catch { }
exit 0
