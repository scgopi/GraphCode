[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Shell,
  [string] $Zmx = "",
  [string[]] $ArgumentList = @()
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @"
public static class GraphCodeUiaGateState {
  public static volatile bool Observed;
}
"@
$oldZmx = [Environment]::GetEnvironmentVariable("GRAPHCODE_ZMX")
$oldCwd = [Environment]::GetEnvironmentVariable("GRAPHCODE_GATE_CWD")
$oldGate = [Environment]::GetEnvironmentVariable("GRAPHCODE_UIA_GATE")
$oldUser = [Environment]::GetEnvironmentVariable("USERNAME")
$oldFixture = [Environment]::GetEnvironmentVariable("GRAPHCODE_UIA_FIXTURE_ROWS")
$process = $null
try {
  if ($Zmx) { $env:GRAPHCODE_ZMX = $Zmx }
  $env:GRAPHCODE_GATE_CWD = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
  $env:GRAPHCODE_UIA_GATE = "1"
  $env:USERNAME = "GraphCodeUIAGate"
  $env:GRAPHCODE_UIA_FIXTURE_ROWS = "C:\fixture-safe|safe,C:\fixture-unsafe|unsafe"
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
                          "Reclaim selected worktrees", "Reveal in Explorer",
                          "Edit worktree policy", "Save worktree policy",
                          "Allow reclaim", "Confirm each reclaim")) {
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
  $safeRow = $root.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "worktree-row-0"
    ))
  )
  $unsafeRow = $root.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "worktree-row-1"
    ))
  )
  $safeSelection = $safeRow.GetCurrentPattern(
    [System.Windows.Automation.SelectionItemPattern]::Pattern
  )
  $unsafeSelection = $unsafeRow.GetCurrentPattern(
    [System.Windows.Automation.SelectionItemPattern]::Pattern
  )
  $safeSelection.Select()
  $unsafeRejected = $false
  try { $unsafeSelection.Select() } catch { $unsafeRejected = $true }
  if (-not $unsafeRejected) { throw "unsafe SelectionItem.Select was accepted" }
  $safeSelection.RemoveFromSelection()
  if ($selection.Current.GetSelection().Count -ne 0) { throw "selection removal was not observed" }
  $actions = @{}
  foreach ($actionId in @("inspect-worktrees", "reclaim-worktrees", "reveal-worktree",
                          "edit-worktree-policy", "save-worktree-policy",
                          "allow-reclaim", "confirm-each-reclaim")) {
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
  $initialStatus = $status.Current.Name
  $eventHandler = [System.Windows.Automation.AutomationEventHandler]{
    param($sender, $eventArgs)
    [GraphCodeUiaGateState]::Observed = $true
  }
  $propertyHandler = [System.Windows.Automation.AutomationPropertyChangedEventHandler]{
    param($sender, $eventArgs)
    [GraphCodeUiaGateState]::Observed = $true
  }
  $liveRegionEvent = [System.Windows.Automation.AutomationEvent]::LookupById(20024)
  [System.Windows.Automation.Automation]::AddAutomationEventHandler(
    $liveRegionEvent,
    $status,
    [System.Windows.Automation.TreeScope]::Element,
    $eventHandler
  )
  [System.Windows.Automation.Automation]::AddAutomationPropertyChangedEventHandler(
    $status,
    [System.Windows.Automation.TreeScope]::Element,
    $propertyHandler,
    [System.Windows.Automation.AutomationElement]::NameProperty
  )
  $actions["inspect-worktrees"].Invoke()
  $actions["reveal-worktree"].Invoke()
  $actions["edit-worktree-policy"].Invoke()
  $actions["allow-reclaim"].Invoke()
  $actions["confirm-each-reclaim"].Invoke()
  $actions["save-worktree-policy"].Invoke()
  Start-Sleep -Milliseconds 250
  $statusAfter = $root.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "status"
    ))
  )
  $statusTextAfter = [string]$statusAfter.GetCurrentPropertyValue(
    [System.Windows.Automation.AutomationElement]::NameProperty
  )
  [System.Windows.Automation.Automation]::RemoveAutomationEventHandler(
    $liveRegionEvent,
    $status,
    $eventHandler
  )
  [System.Windows.Automation.Automation]::RemoveAutomationPropertyChangedEventHandler(
    $status,
    $propertyHandler
  )
  $statusEventObserved = [GraphCodeUiaGateState]::Observed
  $root.SetFocus()
  $focused = [System.Windows.Automation.AutomationElement]::FocusedElement

  [pscustomobject]@{
    name = $root.Current.Name
    automationId = $root.Current.AutomationId
    controlType = $root.Current.ControlType.ProgrammaticName
    childCount = $children.Count
    children = $childNames
    hierarchy = $treeNames
    selectionPattern = $true
    fixtureRows = 2
    unsafeSelectionRejected = $unsafeRejected
    actionPatterns = @($actions.Keys)
    statusText = $statusTextAfter
    statusChanged = ($statusTextAfter -ne $initialStatus)
    statusEventObserved = $statusEventObserved
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
  if ($null -eq $oldFixture) { Remove-Item Env:GRAPHCODE_UIA_FIXTURE_ROWS -ErrorAction SilentlyContinue }
  else { $env:GRAPHCODE_UIA_FIXTURE_ROWS = $oldFixture }
}
