# voice-name.ps1 - name a Claude CLI. You deliberately pick the window: focus
# the CLI you want during the 5s grab; the hub maps "hey <name>" -> that exact
# window and focuses it when routing. No guessing from whatever was foreground.
param([string]$Name)
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'uia.ps1')

$Name = ($Name -replace '[^A-Za-z0-9 ]', '').Trim()
if (-not $Name) { Write-Output "Usage: /claudio:name <name>   (e.g. /claudio:name atlas)"; return }

Write-Output "Naming this CLI '$Name'."
Write-Output "Click / focus the Claude TAB or window you want to be '$Name' -- capturing in 5 seconds..."
Start-Sleep -Seconds 5
$h    = Get-ForegroundWindowHandle
$hwnd = [string][int64]$h
$ti   = Get-ActiveTab -Hwnd $h          # selected tab's stable RuntimeId + name
$tabId = $null; $tabName = $null
if ($ti) { $tabId = $ti.id; $tabName = $ti.name }

$resp = Invoke-Hub 'name' @{ hwnd = $hwnd; name = $Name; cwd = (Get-Location).Path; tab = $tabId; tabName = $tabName }
if (-not $resp) {
    Write-Output "Claudio Hub isn't running. Start it with /claudio:hub then run /claudio:name $Name again."
    return
}
if ($resp.ok) {
    $where = if ($tabId) { "window $hwnd, tab '$tabName'" } else { "window $hwnd" }
    Write-Output "Mapped '$($resp.name)' -> $where."
    if ($tabId) { Write-Output "Tab routing ON (re-selects this exact tab by identity, title can change)." }
    else        { Write-Output "No tab detected - using window focus (fine for a separate window)." }
    Write-Output "Say:  $($resp.wake -join '   /   ')   then your command."
    Write-Output "(Re-run /claudio:name $Name if it grabbed the wrong tab/window.)"
} else {
    Write-Output "Hub error: $($resp.error)"
}
