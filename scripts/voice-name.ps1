# voice-name.ps1 - name a Claude CLI. You deliberately pick the window: focus
# the CLI you want during the 5s grab; the hub maps "hey <name>" -> that exact
# window and focuses it when routing. No guessing from whatever was foreground.
param([string]$Name)
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'uia.ps1')

$Name = ($Name -replace '[^A-Za-z0-9 ]', '').Trim()
if (-not $Name) { Write-Output "Usage: /vox:name <name>   (e.g. /vox:name atlas)"; return }

Write-Output "Naming this CLI '$Name'."
Write-Output "CLICK inside the Claude PANE you want as '$Name' and LEAVE the mouse there -- capturing in 5 seconds..."
Start-Sleep -Seconds 5
$h     = Get-ForegroundWindowHandle
$hwnd  = [string][int64]$h
$cls   = Get-WindowClass -Handle $h
$ti    = Get-ActiveTab -Hwnd $h          # selected tab's stable RuntimeId + name
$tabId = $null; $tabName = $null
if ($ti) { $tabId = $ti.id; $tabName = $ti.name }
# Pane identity = WHERE you clicked. UIA FocusedElement was flaky and when it
# returned null the key fell back to the tab id, which is SHARED by every
# split pane in a tab -> the next /vox:name silently overwrote the previous.
# A screen point is unique per pane and rock-solid.
$cur    = [WinVoiceNative]::GetCursor()
$paneId = "pt:$($cur.X),$($cur.Y)"
$pane   = Get-ActivePane -Hwnd $h
$paneNm = if ($pane) { $pane.name } else { '' }

# Validate we actually captured a terminal, not the editor / a browser / etc.
$termClasses = @('CASCADIA_HOSTING_WINDOW_CLASS', 'ConsoleWindowClass', 'PseudoConsoleWindow')
$isTerm = ($termClasses -contains $cls) -or ($cls -like 'VirtualConsole*')
if (-not $isTerm) {
    Write-Output "Captured window class '$cls' (hwnd $hwnd) -- that is NOT a terminal."
    Write-Output "Nothing registered. Re-run /vox:name $Name and during the countdown"
    Write-Output "click the actual Claude TERMINAL tab/window (Windows Terminal / console)."
    return
}
if ($cls -eq 'CASCADIA_HOSTING_WINDOW_CLASS' -and -not $tabId -and -not $paneId) {
    Write-Output "That's a Windows Terminal window but no tab/pane was detected (hwnd $hwnd)."
    Write-Output "Click directly in the Claude pane you want, then re-run /vox:name $Name."
    return
}

$resp = Invoke-Hub 'name' @{ hwnd = $hwnd; name = $Name; cwd = (Get-Location).Path; tab = $tabId; tabName = $tabName; pane = $paneId; cls = $cls }
if (-not $resp) {
    Write-Output "Vox Hub isn't running. Start it with /vox:hub then run /vox:name $Name again."
    return
}
if ($resp.ok) {
    Write-Output "Mapped '$($resp.name)' -> window $hwnd."
    if ($paneId) { Write-Output "PANE routing ON - 'hey $Name' clicks this exact split pane." }
    elseif ($tabId) { Write-Output "Tab routing ON - re-selects this tab by identity." }
    else { Write-Output "Window focus only (separate window)." }
    Write-Output "Say:  $($resp.wake -join '   /   ')   then your command."
    Write-Output "(Re-run /vox:name $Name if it grabbed the wrong tab/window.)"
} else {
    Write-Output "Hub error: $($resp.error)"
}
