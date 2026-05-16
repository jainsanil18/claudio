# uia.ps1 - UI Automation helpers for Windows Terminal tab routing.
#
# Win32 can't target a tab (tabs share one window handle). The WT tab strip is
# exposed via UI Automation as TabItem elements. We CANNOT match by tab title:
# Claude Code rewrites it constantly and it's identical across Claude tabs.
# Instead we capture the selected tab's RuntimeId (stable element identity for
# the life of the tab, independent of its title) and re-select by that.

try {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes  -ErrorAction Stop
    $script:WV_UIA = $true
} catch { $script:WV_UIA = $false }

function Get-TabItems {
    param([IntPtr]$Hwnd)
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
    if (-not $root) { return @() }
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::TabItem)
    return $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
}

function Get-ActiveTab {
    # The selected tab in $Hwnd's window: @{ id='1.2.3'; name='...' } or $null.
    param([IntPtr]$Hwnd)
    if (-not $script:WV_UIA -or $Hwnd -eq [IntPtr]::Zero) { return $null }
    try {
        foreach ($t in (Get-TabItems -Hwnd $Hwnd)) {
            try {
                $p = $t.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
                if ($p.Current.IsSelected) {
                    return @{ id = ($t.GetRuntimeId() -join '.'); name = [string]$t.Current.Name }
                }
            } catch { }
        }
    } catch { }
    return $null
}

function Select-TabById {
    # Re-select the tab whose RuntimeId == $Id. Returns $true only on a match.
    param([IntPtr]$Hwnd, [string]$Id)
    if (-not $script:WV_UIA -or -not $Id -or $Hwnd -eq [IntPtr]::Zero) { return $false }
    try {
        foreach ($t in (Get-TabItems -Hwnd $Hwnd)) {
            try {
                if (($t.GetRuntimeId() -join '.') -eq $Id) {
                    $t.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
                    return $true
                }
            } catch { }
        }
    } catch { }
    return $false
}
