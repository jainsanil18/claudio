# voice-name.ps1 - name a Claude CLI. You deliberately pick the window: focus
# the CLI you want during the 5s grab; the hub maps "hey <name>" -> that exact
# window and focuses it when routing. No guessing from whatever was foreground.
param([string]$Name)
. (Join-Path $PSScriptRoot 'common.ps1')

$Name = ($Name -replace '[^A-Za-z0-9 ]', '').Trim()
if (-not $Name) { Write-Output "Usage: /claudio:name <name>   (e.g. /claudio:name atlas)"; return }

Write-Output "Naming this CLI '$Name'."
Write-Output "Click / focus the Claude window you want to be '$Name' -- capturing in 5 seconds..."
Start-Sleep -Seconds 5
$hwnd = [string][int64](Get-ForegroundWindowHandle)

$resp = Invoke-Hub 'name' @{ hwnd = $hwnd; name = $Name; cwd = (Get-Location).Path }
if (-not $resp) {
    Write-Output "Claudio Hub isn't running. Start it with /claudio:hub then run /claudio:name $Name again."
    return
}
if ($resp.ok) {
    Write-Output "Mapped '$($resp.name)' -> window $hwnd."
    Write-Output "Say:  $($resp.wake -join '   /   ')   then your command."
    Write-Output "(Re-run /claudio:name $Name if it grabbed the wrong window.)"
} else {
    Write-Output "Hub error: $($resp.error)"
}
