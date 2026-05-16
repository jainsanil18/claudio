# uia.ps1 - UI Automation helpers for Windows Terminal tab routing.
# Win32 can't target a tab (tabs share one window handle), but the WT tab strip
# is exposed via UI Automation as TabItem elements. We snapshot the active
# tab's name when a CLI is named, then re-select that tab before typing.
# Non-tabbed terminals expose no TabItems -> these no-op and we fall back to
# plain window focus.

try {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes  -ErrorAction Stop
    $script:WV_UIA = $true
} catch { $script:WV_UIA = $false }

function Get-ActiveTabName {
    # Name of the currently-selected tab in the window that owns $Hwnd, or $null.
    param([IntPtr]$Hwnd)
    if (-not $script:WV_UIA -or $Hwnd -eq [IntPtr]::Zero) { return $null }
    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
        if (-not $root) { return $null }
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::TabItem)
        $tabs = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
        foreach ($t in $tabs) {
            try {
                $p = $t.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
                if ($p.Current.IsSelected) { return [string]$t.Current.Name }
            } catch { }
        }
    } catch { }
    return $null
}

function Select-TabByName {
    # Activate the tab named $Name in the window that owns $Hwnd. Returns $true
    # only if a matching tab was found and selected.
    param([IntPtr]$Hwnd, [string]$Name)
    if (-not $script:WV_UIA -or -not $Name -or $Hwnd -eq [IntPtr]::Zero) { return $false }
    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
        if (-not $root) { return $false }
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::TabItem)
        $tabs = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
        foreach ($t in $tabs) {
            if ([string]$t.Current.Name -eq $Name) {
                try {
                    $p = $t.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
                    $p.Select()
                    return $true
                } catch { }
            }
        }
    } catch { }
    return $false
}
