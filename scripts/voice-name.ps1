# voice-name.ps1 - name THIS Claude CLI so the hub routes "hey <name>" here.
param([string]$Name)
. (Join-Path $PSScriptRoot 'common.ps1')

$Name = ($Name -replace '[^A-Za-z0-9 ]', '').Trim()
if (-not $Name) { Write-Output "Usage: /claudio:name <name>   (e.g. /claudio:name atlas)"; return }

$hwnd = [string][int64](Get-ForegroundWindowHandle)
$resp = Invoke-Hub 'name' @{ hwnd = $hwnd; name = $Name; cwd = (Get-Location).Path }
if (-not $resp) {
    Write-Output "Claudio Hub isn't running. Start it with /claudio:hub then run /claudio:name $Name again."
    return
}
if ($resp.ok) {
    Write-Output "This CLI is now '$($resp.name)'. Say: $($resp.wake -join '  /  ')  (then your command)."
} else {
    Write-Output "Hub error: $($resp.error)"
}
