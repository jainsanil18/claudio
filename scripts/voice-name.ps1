# voice-name.ps1 - name a Claude CLI. You deliberately pick the window: focus
# the CLI you want during the 5s grab; the hub maps "hey <name>" -> that exact
# window and focuses it when routing. No guessing from whatever was foreground.
param([string]$Name)
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'uia.ps1')

$Name = ($Name -replace '[^A-Za-z0-9 ]', '').Trim()
if (-not $Name) { Write-Output "Usage: /claudio:name <name>   (e.g. /claudio:name atlas)"; return }

Write-Output "Naming this CLI '$Name'."
Write-Output "CLICK YOUR CLAUDE TERMINAL TAB/WINDOW NOW -- capturing in 5 seconds..."
Start-Sleep -Seconds 5
$h     = Get-ForegroundWindowHandle
$hwnd  = [string][int64]$h
$cls   = Get-WindowClass -Handle $h
$ti    = Get-ActiveTab -Hwnd $h          # selected tab's stable RuntimeId + name
$tabId = $null; $tabName = $null
if ($ti) { $tabId = $ti.id; $tabName = $ti.name }

# Validate we actually captured a terminal, not the editor / a browser / etc.
$termClasses = @('CASCADIA_HOSTING_WINDOW_CLASS', 'ConsoleWindowClass', 'PseudoConsoleWindow')
$isTerm = ($termClasses -contains $cls) -or ($cls -like 'VirtualConsole*')
if (-not $isTerm) {
    Write-Output "Captured window class '$cls' (hwnd $hwnd) -- that is NOT a terminal."
    Write-Output "Nothing registered. Re-run /claudio:name $Name and during the countdown"
    Write-Output "click the actual Claude TERMINAL tab/window (Windows Terminal / console)."
    return
}
if ($cls -eq 'CASCADIA_HOSTING_WINDOW_CLASS' -and -not $tabId) {
    Write-Output "That's a Windows Terminal window but no tab was detected (hwnd $hwnd)."
    Write-Output "Click directly on the tab you want, then re-run /claudio:name $Name."
    return
}

$resp = Invoke-Hub 'name' @{ hwnd = $hwnd; name = $Name; cwd = (Get-Location).Path; tab = $tabId; tabName = $tabName; cls = $cls }
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
