[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Shell,
  [string] $Zmx = "",
  [string[]] $ArgumentList = @()
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @"
using System;
using System.Windows.Automation;
public static class GraphCodeUiaGateState {
  public static volatile bool LiveObserved;
  public static volatile bool NamePropertyObserved;
  public static string LiveSourceAutomationId;
  public static string LiveSourceName;
  public static string LiveSourceRuntimeId;
  public static string NamePropertySourceAutomationId;
  public static readonly AutomationEventHandler LiveHandler = HandleLive;
  public static readonly AutomationPropertyChangedEventHandler NamePropertyHandler = HandleNameProperty;
  private static void HandleLive(object sender, AutomationEventArgs eventArgs) {
    var element = sender as AutomationElement;
    if (element == null) return;
    LiveSourceAutomationId = element.Current.AutomationId;
    LiveSourceName = element.Current.Name;
    LiveSourceRuntimeId = String.Join(",", element.GetRuntimeId());
    LiveObserved = true;
  }
  private static void HandleNameProperty(object sender, AutomationPropertyChangedEventArgs eventArgs) {
    var element = sender as AutomationElement;
    if (element != null) NamePropertySourceAutomationId = element.Current.AutomationId;
    NamePropertyObserved = true;
  }
}
"@ -ReferencedAssemblies @(
  [System.Windows.Automation.AutomationElement].Assembly.Location,
  [System.Windows.Automation.AutomationEventArgs].Assembly.Location
)

function Require([bool] $condition, [string] $message) {
  if (-not $condition) { throw $message }
}

function Get-DirectChildren(
  [System.Windows.Automation.AutomationElement] $element,
  [System.Windows.Automation.TreeWalker] $walker
) {
  $children = New-Object System.Collections.Generic.List[System.Windows.Automation.AutomationElement]
  $child = $walker.GetFirstChild($element)
  while ($null -ne $child) {
    $children.Add($child)
    $child = $walker.GetNextSibling($child)
  }
  return @($children.ToArray())
}

function Assert-Ids([string[]] $actual, [string[]] $expected, [string] $label) {
  Require (@($actual).Count -eq @($expected).Count) "$label count expected $($expected.Count) but found $($actual.Count)"
  Require ((@($actual) -join "|") -eq (@($expected) -join "|")) "$label expected $($expected -join ',') but found $($actual -join ',')"
}

function Get-RuntimeIdentity([System.Windows.Automation.AutomationElement] $element) {
  return (@($element.GetRuntimeId()) -join ",")
}

function Find-FragmentById(
  [System.Windows.Automation.AutomationElement] $root,
  [string] $automationId,
  [System.Windows.Automation.TreeWalker] $walker
) {
  $pending = New-Object System.Collections.Generic.Queue[System.Windows.Automation.AutomationElement]
  $pending.Enqueue($root)
  while ($pending.Count -gt 0) {
    $current = $pending.Dequeue()
    foreach ($child in @(Get-DirectChildren $current $walker)) {
      if ($child.Current.AutomationId -eq $automationId) { return $child }
      $pending.Enqueue($child)
    }
  }
  return $null
}

function Assert-FragmentLinks(
  [System.Windows.Automation.AutomationElement] $parent,
  [System.Windows.Automation.TreeWalker] $walker,
  [string[]] $expectedIds,
  [string] $label
) {
  $children = @(Get-DirectChildren $parent $walker)
  $ids = @($children | ForEach-Object { $_.Current.AutomationId })
  Assert-Ids $ids $expectedIds "$label direct children"
  Require ($children[0].Current.AutomationId -eq $walker.GetFirstChild($parent).Current.AutomationId) "$label first child mismatch"
  Require ($children[-1].Current.AutomationId -eq $walker.GetLastChild($parent).Current.AutomationId) "$label last child mismatch"
  for ($i = 0; $i -lt $children.Count; $i++) {
    $child = $children[$i]
    Require ($walker.GetParent($child).Current.AutomationId -eq $parent.Current.AutomationId) "$label parent mismatch for $($ids[$i])"
    $previous = $walker.GetPreviousSibling($child)
    $next = $walker.GetNextSibling($child)
    if ($i -eq 0) {
      Require ($null -eq $previous) "$label first child has a previous sibling"
    } else {
      Require ($previous.Current.AutomationId -eq $ids[$i - 1]) "$label previous sibling mismatch for $($ids[$i])"
    }
    if ($i -eq $children.Count - 1) {
      Require ($null -eq $next) "$label last child has a next sibling"
    } else {
      Require ($next.Current.AutomationId -eq $ids[$i + 1]) "$label next sibling mismatch for $($ids[$i])"
    }
  }
  return $children
}

$oldZmx = [Environment]::GetEnvironmentVariable("GRAPHCODE_ZMX")
$oldCwd = [Environment]::GetEnvironmentVariable("GRAPHCODE_GATE_CWD")
$oldGate = [Environment]::GetEnvironmentVariable("GRAPHCODE_UIA_GATE")
$oldUser = [Environment]::GetEnvironmentVariable("USERNAME")
$oldFixture = [Environment]::GetEnvironmentVariable("GRAPHCODE_UIA_FIXTURE_ROWS")
$process = $null
$status = $null
$liveRegionEvent = $null
$eventHandler = $null
$propertyHandler = $null
$liveEventRegistered = $false
$propertyEventRegistered = $false
$policyDirectory = $null
$policyPath = $null
$policyDirectoryExisted = $false
$policyExisted = $false
$policyContents = $null
try {
  if ($Zmx) { $env:GRAPHCODE_ZMX = $Zmx }
  $env:GRAPHCODE_GATE_CWD = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
  $env:GRAPHCODE_UIA_GATE = "1"
  $env:USERNAME = "GraphCodeUIAGate"
  $env:GRAPHCODE_UIA_FIXTURE_ROWS = "C:\fixture-safe|safe,C:\fixture-unsafe|unsafe"
  $policyDirectory = Join-Path $env:GRAPHCODE_GATE_CWD ".graphcode"
  $policyPath = Join-Path $policyDirectory "worktree-policy.json"
  $policyDirectoryExisted = Test-Path -LiteralPath $policyDirectory
  $policyExisted = Test-Path -LiteralPath $policyPath
  if ($policyExisted) { $policyContents = [IO.File]::ReadAllBytes($policyPath) }
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

  $expectedRootIds = @("projects", "loops", "worktrees", "graph", "actions", "status")
  $rawWalker = [System.Windows.Automation.TreeWalker]::RawViewWalker
  $controlWalker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $rawRootChildren = @(Assert-FragmentLinks $root $rawWalker $expectedRootIds "RawView root")
  $controlRootChildren = @(Assert-FragmentLinks $root $controlWalker $expectedRootIds "ControlView root")

  $worktrees = Find-FragmentById $root "worktrees" $rawWalker
  Require ($null -ne $worktrees) "missing Worktrees fragment"
  $expectedRowIds = @("worktree-row-0", "worktree-row-1")
  $rawRows = @(Assert-FragmentLinks $worktrees $rawWalker $expectedRowIds "RawView Worktrees")
  $controlRows = @(Assert-FragmentLinks $worktrees $controlWalker $expectedRowIds "ControlView Worktrees")

  $selection = $worktrees.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
  $safeRow = Find-FragmentById $root "worktree-row-0" $rawWalker
  $unsafeRow = Find-FragmentById $root "worktree-row-1" $rawWalker
  Require (($null -ne $safeRow) -and ($null -ne $unsafeRow)) "missing fixture worktree rows"
  $safeSelection = $safeRow.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
  $unsafeSelection = $unsafeRow.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
  $safeSelection.Select()
  Start-Sleep -Milliseconds 100
  Require ($safeSelection.Current.IsSelected) "safe SelectionItem.Select was not observed"
  $unsafeRejected = $false
  try { $unsafeSelection.Select() } catch { $unsafeRejected = $true }
  Require $unsafeRejected "unsafe SelectionItem.Select was accepted"
  $safeSelection.RemoveFromSelection()
  Start-Sleep -Milliseconds 100
  Require ($selection.Current.GetSelection().Count -eq 0) "selection removal was not observed"
  $safeSelection.Select()
  Start-Sleep -Milliseconds 100
  Require (($selection.Current.GetSelection().Count -eq 1) -and $safeSelection.Current.IsSelected) "repeated SelectionItem.Select was not observed"

  $actions = @{}
  foreach ($actionId in @("inspect-worktrees", "reclaim-worktrees", "reveal-worktree",
                          "edit-worktree-policy", "save-worktree-policy",
                          "allow-reclaim", "confirm-each-reclaim")) {
    $action = Find-FragmentById $root $actionId $rawWalker
    Require ($null -ne $action) "missing action $actionId"
    $actions[$actionId] = $action.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  }

  $status = Find-FragmentById $root "status" $controlWalker
  Require ($null -ne $status) "missing status element"
  $initialStatus = $status.Current.Name
  $statusRuntimeId = Get-RuntimeIdentity $status
  [GraphCodeUiaGateState]::LiveObserved = $false
  [GraphCodeUiaGateState]::NamePropertyObserved = $false
  [GraphCodeUiaGateState]::LiveSourceAutomationId = $null
  [GraphCodeUiaGateState]::LiveSourceName = $null
  [GraphCodeUiaGateState]::LiveSourceRuntimeId = $null
  [GraphCodeUiaGateState]::NamePropertySourceAutomationId = $null
  $eventHandler = [GraphCodeUiaGateState]::LiveHandler
  $liveRegionEvent = [System.Windows.Automation.AutomationEvent]::LookupById(20024)
  $propertyHandler = [GraphCodeUiaGateState]::NamePropertyHandler
  [System.Windows.Automation.Automation]::AddAutomationEventHandler(
    $liveRegionEvent, $status, [System.Windows.Automation.TreeScope]::Element, $eventHandler
  )
  $liveEventRegistered = $true
  [System.Windows.Automation.Automation]::AddAutomationPropertyChangedEventHandler(
    $status, [System.Windows.Automation.TreeScope]::Element, $propertyHandler,
    [System.Windows.Automation.AutomationElement]::NameProperty
  )
  $propertyEventRegistered = $true
  try {
    $actions["inspect-worktrees"].Invoke()
    $actions["reveal-worktree"].Invoke()
    $actions["edit-worktree-policy"].Invoke()
    $actions["allow-reclaim"].Invoke()
    $actions["confirm-each-reclaim"].Invoke()
    $actions["save-worktree-policy"].Invoke()
    for ($i = 0; $i -lt 40 -and -not [GraphCodeUiaGateState]::LiveObserved; $i++) {
      Start-Sleep -Milliseconds 50
    }
  } finally {
    if ($propertyEventRegistered) {
      [System.Windows.Automation.Automation]::RemoveAutomationPropertyChangedEventHandler(
        $status, $propertyHandler
      )
      $propertyEventRegistered = $false
    }
    if ($liveEventRegistered) {
      [System.Windows.Automation.Automation]::RemoveAutomationEventHandler(
        $liveRegionEvent, $status, $eventHandler
      )
      $liveEventRegistered = $false
    }
  }

  $statusAfter = Find-FragmentById $root "status" $controlWalker
  $statusTextAfter = [string]$statusAfter.Current.Name
  $statusEventObserved = [GraphCodeUiaGateState]::LiveObserved
  Require $statusEventObserved "LiveRegionChanged was not delivered for status"
  Require ([GraphCodeUiaGateState]::LiveSourceAutomationId -eq "status") "LiveRegionChanged source was not status"
  Require ([GraphCodeUiaGateState]::LiveSourceRuntimeId -eq $statusRuntimeId) "LiveRegionChanged source identity changed"
  Require ([GraphCodeUiaGateState]::NamePropertyObserved) "status Name property change was not delivered"
  Require ([GraphCodeUiaGateState]::NamePropertySourceAutomationId -eq "status") "status Name property source was not status"
  Require (($statusTextAfter -ne $initialStatus) -and
           ([GraphCodeUiaGateState]::LiveSourceName -ne $initialStatus)) "status LiveRegionChanged did not expose updated text"

  $safeRow.SetFocus()
  $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
  Require ($focused.Current.AutomationId -eq "worktree-row-0") "focus source identity was not worktree-row-0"
  Require ((Get-RuntimeIdentity $focused) -eq (Get-RuntimeIdentity $safeRow)) "focus runtime identity changed"

  $rootName = $root.Current.Name
  $rootAutomationId = $root.Current.AutomationId
  $rootControlType = $root.Current.ControlType.ProgrammaticName
  $rawRootChildIds = @($rawRootChildren | ForEach-Object { $_.Current.AutomationId })
  $controlRootChildIds = @($controlRootChildren | ForEach-Object { $_.Current.AutomationId })
  $rawWorktreeRowIds = @($rawRows | ForEach-Object { $_.Current.AutomationId })
  $controlWorktreeRowIds = @($controlRows | ForEach-Object { $_.Current.AutomationId })
  $focusIdentity = $focused.Current.AutomationId

  Require $process.CloseMainWindow() "shell refused graceful window teardown"
  Require $process.WaitForExit(5000) "shell did not exit after WM_CLOSE"
  Require ($process.ExitCode -eq 0) "shell exited with code $($process.ExitCode) during provider teardown"
  $retainedProviderSafe = $false
  try {
    $null = $status.Current.Name
    $retainedProviderSafe = $true
  } catch [System.Windows.Automation.ElementNotAvailableException] {
    $retainedProviderSafe = $true
  }
  Require $retainedProviderSafe "retained status provider was unsafe after teardown"

  [pscustomobject]@{
    name = $rootName
    automationId = $rootAutomationId
    controlType = $rootControlType
    rawRootChildren = $rawRootChildIds
    controlRootChildren = $controlRootChildIds
    rawWorktreeRows = $rawWorktreeRowIds
    controlWorktreeRows = $controlWorktreeRowIds
    selectionPattern = $true
    fixtureRows = 2
    unsafeSelectionRejected = $unsafeRejected
    repeatedSelectionObserved = $true
    actionPatterns = @($actions.Keys | Sort-Object)
    statusText = $statusTextAfter
    statusChanged = ($statusTextAfter -ne $initialStatus)
    statusEventObserved = $statusEventObserved
    statusNamePropertyObserved = [GraphCodeUiaGateState]::NamePropertyObserved
    statusNamePropertySource = [GraphCodeUiaGateState]::NamePropertySourceAutomationId
    statusEventSource = [GraphCodeUiaGateState]::LiveSourceAutomationId
    statusEventText = [GraphCodeUiaGateState]::LiveSourceName
    focusIdentity = $focusIdentity
    providerTeardownSafe = $retainedProviderSafe
  } | ConvertTo-Json -Compress
} finally {
  if ($propertyEventRegistered) {
    [System.Windows.Automation.Automation]::RemoveAutomationPropertyChangedEventHandler(
      $status, $propertyHandler
    )
  }
  if ($liveEventRegistered) {
    [System.Windows.Automation.Automation]::RemoveAutomationEventHandler(
      $liveRegionEvent, $status, $eventHandler
    )
  }
  if ($process -and -not $process.HasExited) {
    $process.Kill()
    $process.WaitForExit()
  }
  if ($policyExisted) {
    [IO.File]::WriteAllBytes($policyPath, $policyContents)
  } elseif ($policyPath) {
    Remove-Item -LiteralPath $policyPath -Force -ErrorAction SilentlyContinue
    if (-not $policyDirectoryExisted -and
        -not (Get-ChildItem -LiteralPath $policyDirectory -Force -ErrorAction SilentlyContinue |
          Select-Object -First 1)) {
      Remove-Item -LiteralPath $policyDirectory -Force -ErrorAction SilentlyContinue
    }
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
