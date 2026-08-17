[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Shell,
  [string] $Zmx = "",
  [string[]] $ArgumentList = @()
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$oldZmx = [Environment]::GetEnvironmentVariable("GRAPHCODE_ZMX")
$oldCwd = [Environment]::GetEnvironmentVariable("GRAPHCODE_GATE_CWD")
$oldGate = [Environment]::GetEnvironmentVariable("GRAPHCODE_UIA_GATE")
$oldUser = [Environment]::GetEnvironmentVariable("USERNAME")
$process = $null
try {
  if ($Zmx) { $env:GRAPHCODE_ZMX = $Zmx }
  $env:GRAPHCODE_GATE_CWD = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
  $env:GRAPHCODE_UIA_GATE = "1"
  $env:USERNAME = "GraphCodeUIAGate"
  if ($ArgumentList.Count -gt 0) {
    $process = Start-Process -FilePath $Shell -ArgumentList $ArgumentList -PassThru -WindowStyle Normal
  } else {
    $process = Start-Process -FilePath $Shell -PassThru -WindowStyle Normal
  }
  $root = $null
  for ($i = 0; $i -lt 160; $i++) {
    Start-Sleep -Milliseconds 250
    $process.Refresh()
    if ($process.HasExited) { throw "shell exited with code $($process.ExitCode)" }
    if ($process.MainWindowHandle -ne 0) {
      $candidate = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
      if ($candidate.Current.AutomationId -eq "graphcode-root") {
        $root = $candidate
        break
      }
    }
  }
  if ($null -eq $root) { throw "shell did not expose graphcode-root through WM_GETOBJECT" }

  $children = $root.FindAll(
    [System.Windows.Automation.TreeScope]::Children,
    [System.Windows.Automation.Condition]::TrueCondition
  )
  $childNames = @($children | ForEach-Object { $_.Current.Name })
  $descendants = $root.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  )
  $treeNames = @($descendants | ForEach-Object { $_.Current.Name })
  foreach ($required in @("Projects", "Loops", "Worktrees", "Inspect worktrees",
                          "Reclaim selected worktrees", "Reveal in Explorer")) {
    if ($treeNames -notcontains $required) {
      throw "UIA tree missing required child: $required"
    }
  }

  $worktrees = $root.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "worktrees"
    ))
  )
  $selection = $worktrees.GetCurrentPattern(
    [System.Windows.Automation.SelectionPattern]::Pattern
  )
  $actions = @{}
  foreach ($actionId in @("inspect-worktrees", "reclaim-worktrees", "reveal-worktree")) {
    $action = $root.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $actionId
      ))
    )
    if ($null -eq $action) { throw "missing action $actionId" }
    $actions[$actionId] = $action.GetCurrentPattern(
      [System.Windows.Automation.InvokePattern]::Pattern
    )
  }
  $status = $root.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "status"
    ))
  )
  if ($null -eq $status) { throw "missing status element" }
  $actions["inspect-worktrees"].Invoke()
  $actions["reveal-worktree"].Invoke()
  $root.SetFocus()
  $focused = [System.Windows.Automation.AutomationElement]::FocusedElement

  [pscustomobject]@{
    name = $root.Current.Name
    automationId = $root.Current.AutomationId
    controlType = $root.Current.ControlType.ProgrammaticName
    childCount = $children.Count
    children = $childNames
    selectionPattern = $true
    actionPatterns = @($actions.Keys)
    statusText = $status.Current.Name
    focusObserved = ($null -ne $focused)
  } | ConvertTo-Json -Compress
} finally {
  if ($process -and -not $process.HasExited) {
    $process.Kill()
    $process.WaitForExit()
  }
  if ($null -eq $oldZmx) { Remove-Item Env:GRAPHCODE_ZMX -ErrorAction SilentlyContinue }
  else { $env:GRAPHCODE_ZMX = $oldZmx }
  if ($null -eq $oldCwd) { Remove-Item Env:GRAPHCODE_GATE_CWD -ErrorAction SilentlyContinue }
  else { $env:GRAPHCODE_GATE_CWD = $oldCwd }
  if ($null -eq $oldGate) { Remove-Item Env:GRAPHCODE_UIA_GATE -ErrorAction SilentlyContinue }
  else { $env:GRAPHCODE_UIA_GATE = $oldGate }
  if ($null -eq $oldUser) { Remove-Item Env:USERNAME -ErrorAction SilentlyContinue }
  else { $env:USERNAME = $oldUser }
}
