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
using System.Runtime.InteropServices;
using System.Windows.Automation;
public static class GraphCodeUiaGateState {
  public static volatile bool LiveObserved;
  public static volatile bool NamePropertyObserved;
  public static volatile bool FocusObserved;
  public static int LiveEvents;
  public static int NamePropertyEvents;
  public static int SelectedEvents;
  public static int AddedEvents;
  public static int RemovedEvents;
  public static int TogglePropertyEvents;
  public static string LiveSourceAutomationId;
  public static string LiveSourceName;
  public static string LiveSourceRuntimeId;
  public static string NamePropertySourceAutomationId;
  public static string FocusSourceAutomationId;
  public static string SelectionSourceAutomationId;
  public static string TogglePropertySourceAutomationId;
  public static readonly AutomationEventHandler LiveHandler = HandleLive;
  public static readonly AutomationPropertyChangedEventHandler NamePropertyHandler = HandleNameProperty;
  public static readonly AutomationFocusChangedEventHandler FocusHandler = HandleFocus;
  public static readonly AutomationEventHandler SelectedHandler = HandleSelected;
  public static readonly AutomationEventHandler AddedHandler = HandleAdded;
  public static readonly AutomationEventHandler RemovedHandler = HandleRemoved;
  public static readonly AutomationPropertyChangedEventHandler TogglePropertyHandler = HandleToggleProperty;
  private static void HandleLive(object sender, AutomationEventArgs eventArgs) {
    var element = sender as AutomationElement;
    if (element == null) return;
    LiveSourceAutomationId = element.Current.AutomationId;
    LiveSourceName = element.Current.Name;
    LiveSourceRuntimeId = String.Join(",", element.GetRuntimeId());
    LiveEvents++;
    LiveObserved = true;
  }
  private static void HandleNameProperty(object sender, AutomationPropertyChangedEventArgs eventArgs) {
    var element = sender as AutomationElement;
    if (element != null) NamePropertySourceAutomationId = element.Current.AutomationId;
    NamePropertyEvents++;
    NamePropertyObserved = true;
  }
  private static void HandleFocus(object sender, AutomationFocusChangedEventArgs eventArgs) {
    var element = sender as AutomationElement;
    if (element != null) FocusSourceAutomationId = element.Current.AutomationId;
    FocusObserved = true;
  }
  private static void HandleSelected(object sender, AutomationEventArgs eventArgs) {
    var element = sender as AutomationElement;
    if (element != null) SelectionSourceAutomationId = element.Current.AutomationId;
    SelectedEvents++;
  }
  private static void HandleAdded(object sender, AutomationEventArgs eventArgs) {
    var element = sender as AutomationElement;
    if (element != null) SelectionSourceAutomationId = element.Current.AutomationId;
    AddedEvents++;
  }
  private static void HandleRemoved(object sender, AutomationEventArgs eventArgs) {
    var element = sender as AutomationElement;
    if (element != null) SelectionSourceAutomationId = element.Current.AutomationId;
    RemovedEvents++;
  }
  private static void HandleToggleProperty(object sender, AutomationPropertyChangedEventArgs eventArgs) {
    var element = sender as AutomationElement;
    if (element != null) TogglePropertySourceAutomationId = element.Current.AutomationId;
    TogglePropertyEvents++;
  }
  [DllImport("user32.dll", SetLastError = true)]
  private static extern bool PostMessage(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")]
  private static extern IntPtr SendMessage(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string windowName);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern bool SetWindowText(IntPtr window, string text);
  public static bool PostFixtureMutation(IntPtr window, uint mutation) {
    return PostMessage(window, 0x802A, (UIntPtr)mutation, IntPtr.Zero);
  }
  public static bool PostTaggedExitCollision(IntPtr window) {
    return PostMessage(window, 0x0111, new UIntPtr(0x8000000000001008UL), IntPtr.Zero);
  }
  public static bool PostKeyboard(IntPtr window, uint key) {
    return PostMessage(window, 0x0100, (UIntPtr)key, IntPtr.Zero);
  }
  public static bool SendReturn(IntPtr window) {
    if (window == IntPtr.Zero) return false;
    SendMessage(window, 0x0100, (UIntPtr)0x0D, IntPtr.Zero);
    return true;
  }
  public static bool PostMouseClick(IntPtr window) {
    return PostMessage(window, 0x0201, UIntPtr.Zero, IntPtr.Zero);
  }
  public static bool PostCommand(IntPtr window, uint command) {
    return PostMessage(window, 0x0111, (UIntPtr)command, IntPtr.Zero);
  }
  public static bool PostClose(IntPtr window) {
    return PostMessage(window, 0x0010, UIntPtr.Zero, IntPtr.Zero);
  }
  public static bool SetFirstEditText(IntPtr parent, string text) {
    var edit = FindWindowEx(parent, IntPtr.Zero, "Edit", null);
    return edit != IntPtr.Zero && SetWindowText(edit, text);
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
  Require (@($actual).Count -eq @($expected).Count) "$label count expected $($expected.Count) but found $($actual.Count): $($actual -join ',')"
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
  $allChildren = @(Get-DirectChildren $parent $walker)
  $allowedNativeIds = if ($label -match "root$") { @("4601", "4602") } else { @() }
  $unexpectedIds = @($allChildren | ForEach-Object { $_.Current.AutomationId } |
    Where-Object { $_ -and $_ -notin $expectedIds -and $_ -notin $allowedNativeIds })
  Require ($unexpectedIds.Count -eq 0) "$label exposed unexpected children: $($unexpectedIds -join ',')"
  $children = @($allChildren | Where-Object { $_.Current.AutomationId -in $expectedIds })
  $ids = @($children | ForEach-Object { $_.Current.AutomationId })
  Assert-Ids $ids $expectedIds "$label direct children"
  for ($i = 0; $i -lt $children.Count; $i++) {
    $child = $children[$i]
    Require ($walker.GetParent($child).Current.AutomationId -eq $parent.Current.AutomationId) "$label parent mismatch for $($ids[$i])"
    $previous = $walker.GetPreviousSibling($child)
    $next = $walker.GetNextSibling($child)
    while ($null -ne $previous -and $previous.Current.AutomationId -notin $expectedIds) {
      $previous = $walker.GetPreviousSibling($previous)
    }
    while ($null -ne $next -and $next.Current.AutomationId -notin $expectedIds) {
      $next = $walker.GetNextSibling($next)
    }
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
$oldDaemonPipe = [Environment]::GetEnvironmentVariable("GRAPHCODE_DAEMON_PIPE")
$process = $null
$status = $null
$liveRegionEvent = $null
$eventHandler = $null
$propertyHandler = $null
$focusHandler = $null
$liveEventRegistered = $false
$propertyEventRegistered = $false
$focusEventRegistered = $false
$stressJob = $null
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
  $env:GRAPHCODE_DAEMON_PIPE = "\\.\pipe\graphcode-uia-gate-$PID"
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

  $projects = Find-FragmentById $root "projects" $rawWalker
  $loops = Find-FragmentById $root "loops" $rawWalker
  $graph = Find-FragmentById $root "graph" $rawWalker
  Require (($null -ne $projects) -and ($null -ne $loops) -and ($null -ne $graph)) "missing Projects, Loops, or Graph fragments"
  $navigationIds = @("overview-destination", "quick-chats-destination")
  $canvasActionIds = @("canvas-primary-action", "zoom-out", "actual-size", "zoom-in", "fit-canvas")
  $projectRows = @(Get-DirectChildren $projects $rawWalker | Where-Object { $_.Current.AutomationId -match '^project-row-' })
  $graphDestination = Find-FragmentById $root "overview-destination" $rawWalker
  Require (($null -ne $graphDestination) -and ($graphDestination.Current.Name -eq "Graph")) `
    "global sidebar destination did not expose the pinned Graph identity"
  Require ($projectRows.Count -eq 3) "Projects did not expose grouped recent rows and the open project row"
  Require ((@($projectRows | ForEach-Object { $_.Current.Name }) -join "|") -eq "Fixture local|Fixture remote|UIA project") "dynamic project row names were not synchronized"
  foreach ($projectRow in $projectRows) {
    Require (($projectRow.Current.BoundingRectangle.Width -gt 0) -and
             ($projectRow.Current.BoundingRectangle.Height -gt 0)) "dynamic project row has empty bounds"
  }
  $null = $projects.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
  $null = $projectRows[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
  $projectRowInvoke = $projectRows[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  $projectRowIds = @($projectRows | ForEach-Object { $_.Current.AutomationId })
  $projectChildIds = $projectRowIds + $navigationIds
  $null = Assert-FragmentLinks $projects $rawWalker $projectChildIds "RawView Projects"
  $null = Assert-FragmentLinks $projects $controlWalker $projectChildIds "ControlView Projects"
  $loopRows = @(Get-DirectChildren $loops $rawWalker)
  Require (($loopRows.Count -eq 2) -and
           ((@($loopRows | ForEach-Object { $_.Current.Name }) -join "|") -eq "UIA loop A|UIA loop B")) "Loops did not expose synchronized dynamic rows"
  $loopIds = @($loopRows | ForEach-Object { $_.Current.AutomationId })
  $null = $loops.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
  foreach ($row in $loopRows) {
    $null = $row.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $null = $row.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  }
  $null = Assert-FragmentLinks $loops $rawWalker $loopIds "RawView Loops"
  $null = Assert-FragmentLinks $loops $controlWalker $loopIds "ControlView Loops"
  $projectCards = @(Get-DirectChildren $graph $rawWalker | Where-Object { $_.Current.AutomationId -match '^canvas-card-' })
  Require (($projectCards.Count -eq 2) -and
           ((@($projectCards | ForEach-Object { $_.Current.Name }) -join "|") -eq "UIA loop A|UIA loop B")) "Graph did not expose synchronized project cards"
  foreach ($card in $projectCards) {
    Require (($card.Current.BoundingRectangle.Width -gt 0) -and
             ($card.Current.BoundingRectangle.Height -gt 0)) "dynamic project card has empty bounds"
    $null = $card.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $null = $card.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
  }
  $projectCardIds = @($projectCards | ForEach-Object { $_.Current.AutomationId })
  $graphChildIds = @($projectCardIds + $canvasActionIds)
  $null = Assert-FragmentLinks $graph $rawWalker $graphChildIds "RawView Graph"
  $null = Assert-FragmentLinks $graph $controlWalker $graphChildIds "ControlView Graph"
  $projectCards[1].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150
  $compositeChildren = @(Get-DirectChildren $graph $rawWalker | Where-Object { $_.Current.AutomationId -match '^canvas-card-' })
  $nestedCards = @($compositeChildren | Where-Object { $_.Current.Name -match '^UIA nested ' })
  Require (($nestedCards.Count -eq 2) -and
           ((@($nestedCards | ForEach-Object { $_.Current.Name }) -join "|") -eq "UIA nested A|UIA nested B")) `
    "Open Group did not expose the nested composite canvas"
  $compositeBack = @($compositeChildren | Where-Object { $_.Current.Name -eq "Back to UIA project" })
  Require ($compositeBack.Count -eq 1) `
    "Composite canvas did not expose its Back breadcrumb: $(@($compositeChildren | ForEach-Object { $_.Current.Name }) -join '|')"
  Require (($compositeBack[0].Current.BoundingRectangle.Width -gt 0) -and
           ($compositeBack[0].Current.BoundingRectangle.Height -gt 0)) "Composite Back breadcrumb has empty bounds"
  $compositeBack[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150
  $restoredProjectCards = @(Get-DirectChildren $graph $rawWalker | Where-Object {
      $_.Current.AutomationId -match '^canvas-card-' -and $_.Current.Name -match '^UIA loop '
    })
  Require (($restoredProjectCards.Count -eq 2) -and
           ((@($restoredProjectCards | ForEach-Object { $_.Current.Name }) -join "|") -eq "UIA loop A|UIA loop B")) `
    "Composite Back did not restore the parent project canvas"
  $surfaceActionPatterns = @{}
  foreach ($id in @($navigationIds + $canvasActionIds)) {
    $element = Find-FragmentById $root $id $rawWalker
    Require ($null -ne $element) "missing $id fragment"
    Require (($element.Current.BoundingRectangle.Width -gt 0) -and
             ($element.Current.BoundingRectangle.Height -gt 0)) "$id has empty bounds"
    $surfaceActionPatterns[$id] = $element.GetCurrentPattern(
      [System.Windows.Automation.InvokePattern]::Pattern)
  }
  $surfaceActionPatterns["overview-destination"].Invoke()
  Start-Sleep -Milliseconds 150
  $overviewCards = @(Get-DirectChildren $graph $rawWalker | Where-Object { $_.Current.AutomationId -match '^canvas-card-' })
  Require (($overviewCards.Count -eq 2) -and
           ((@($overviewCards | ForEach-Object { $_.Current.Name }) -join "|") -eq "UIA loop A|UIA loop B")) "Overview did not expose synchronized cards"
  $surfaceActionPatterns["quick-chats-destination"].Invoke()
  Start-Sleep -Milliseconds 150
  $quickChatCards = @(Get-DirectChildren $graph $rawWalker | Where-Object { $_.Current.AutomationId -match '^canvas-card-' })
  Require (($quickChatCards.Count -eq 2) -and
           ((@($quickChatCards | ForEach-Object { $_.Current.Name }) -join "|") -eq "UIA chat A|UIA chat B")) "Quick Chats did not expose synchronized cards: $(@($quickChatCards | ForEach-Object { $_.Current.Name }) -join '|')"
  $quickChatCardIds = @($quickChatCards | ForEach-Object { $_.Current.AutomationId })
  $quickChatCards[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150
  Require ((Find-FragmentById $root "status" $rawWalker).Current.Name -eq "Opening quick chat...") `
    "Quick Chat invocation did not perform its expected action"
  $surfaceActionPatterns["zoom-in"].Invoke()
  $surfaceActionPatterns["actual-size"].Invoke()
  $surfaceActionPatterns["zoom-out"].Invoke()
  $surfaceActionPatterns["fit-canvas"].Invoke()
  Start-Sleep -Milliseconds 250
  $process.Refresh()
  Require (-not $process.HasExited) "surface UIA actions terminated the shell"
  $projectRowInvoke.Invoke()
  $loopRows[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 250
  $process.Refresh()
  Require (-not $process.HasExited) "dynamic project or loop invocation terminated the shell"
  $workspaceCards = @(Get-DirectChildren $graph $rawWalker | Where-Object { $_.Current.AutomationId -match '^canvas-card-' })
  Require (($workspaceCards.Count -eq 2) -and
           ((@($workspaceCards | ForEach-Object { $_.Current.Name }) -join "|") -eq "UIA loop A|UIA loop B") -and
           $workspaceCards[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected) `
    "loop invocation did not transition to the selected workspace loop"
  $surfaceActionPatterns["overview-destination"].Invoke()
  Start-Sleep -Milliseconds 150
  Require ([GraphCodeUiaGateState]::PostTaggedExitCollision($process.MainWindowHandle)) `
    "tagged command collision message was rejected"
  Start-Sleep -Milliseconds 150
  $process.Refresh()
  Require (-not $process.HasExited) "tagged UIA payload fell through to the Exit menu command"

  $worktrees = Find-FragmentById $root "worktrees" $rawWalker
  Require ($null -ne $worktrees) "missing Worktrees fragment"
  $initialRowIds = @()
  for ($attempt = 0; $attempt -lt 50; $attempt++) {
    $initialRowIds = @(Get-DirectChildren $worktrees $rawWalker |
      ForEach-Object { $_.Current.AutomationId } |
      Where-Object { $_ })
    if ($initialRowIds.Count -eq 2) { break }
    Start-Sleep -Milliseconds 100
  }
  Require (($initialRowIds.Count -eq 2) -and
           ($initialRowIds | ForEach-Object { $_ -match '^worktree-row-[0-9]+$' } | Where-Object { -not $_ }).Count -eq 0) `
    "Worktrees did not expose two stable dynamic row IDs: $($initialRowIds -join ','); status=$((Find-FragmentById $root 'status' $rawWalker).Current.Name)"
  $rawRows = @(Assert-FragmentLinks $worktrees $rawWalker $initialRowIds "RawView Worktrees")
  $controlRows = @(Assert-FragmentLinks $worktrees $controlWalker $initialRowIds "ControlView Worktrees")
  Require ((@($rawRows | ForEach-Object { $_.Current.Name }) -join "|") -eq
           "C:\fixture-safe|C:\fixture-unsafe") "fixture worktree names were not ordered as expected"

  $selection = $worktrees.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
  $safeRow = @($rawRows | Where-Object { $_.Current.Name -eq "C:\fixture-safe" })[0]
  $unsafeRow = @($rawRows | Where-Object { $_.Current.Name -eq "C:\fixture-unsafe" })[0]
  $safeFocusRow = @($controlRows | Where-Object { $_.Current.Name -eq "C:\fixture-safe" })[0]
  Require (($null -ne $safeRow) -and ($null -ne $unsafeRow) -and ($null -ne $safeFocusRow)) "missing fixture worktree rows"
  $safeRowId = $safeRow.Current.AutomationId
  $safeRowRuntimeId = Get-RuntimeIdentity $safeRow
  $safeSelection = $safeRow.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
  $unsafeSelection = $unsafeRow.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
  [GraphCodeUiaGateState]::SelectedEvents = 0
  [GraphCodeUiaGateState]::AddedEvents = 0
  [GraphCodeUiaGateState]::RemovedEvents = 0
  [GraphCodeUiaGateState]::SelectionSourceAutomationId = $null
  $selectedEvent = [System.Windows.Automation.SelectionItemPattern]::ElementSelectedEvent
  $addedEvent = [System.Windows.Automation.SelectionItemPattern]::ElementAddedToSelectionEvent
  $removedEvent = [System.Windows.Automation.SelectionItemPattern]::ElementRemovedFromSelectionEvent
  $selectedHandler = [GraphCodeUiaGateState]::SelectedHandler
  $addedHandler = [GraphCodeUiaGateState]::AddedHandler
  $removedHandler = [GraphCodeUiaGateState]::RemovedHandler
  [System.Windows.Automation.Automation]::AddAutomationEventHandler(
    $selectedEvent, $safeRow, [System.Windows.Automation.TreeScope]::Element, $selectedHandler
  )
  [System.Windows.Automation.Automation]::AddAutomationEventHandler(
    $addedEvent, $safeRow, [System.Windows.Automation.TreeScope]::Element, $addedHandler
  )
  [System.Windows.Automation.Automation]::AddAutomationEventHandler(
    $removedEvent, $safeRow, [System.Windows.Automation.TreeScope]::Element, $removedHandler
  )
  try {
    $safeSelection.Select()
    for ($index = 0; $index -lt 20 -and [GraphCodeUiaGateState]::SelectedEvents -lt 1; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require (($safeSelection.Current.IsSelected) -and
             ([GraphCodeUiaGateState]::SelectedEvents -eq 1)) "Select did not raise ElementSelected exactly once"
    $safeSelection.Select()
    Start-Sleep -Milliseconds 150
    Require ([GraphCodeUiaGateState]::SelectedEvents -eq 1) "idempotent Select raised a duplicate event"
    $unsafeRejected = $false
    try { $unsafeSelection.Select() } catch { $unsafeRejected = $true }
    Require $unsafeRejected "unsafe SelectionItem.Select was accepted"
    $safeSelection.RemoveFromSelection()
    for ($index = 0; $index -lt 20 -and [GraphCodeUiaGateState]::RemovedEvents -lt 1; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require (($selection.Current.GetSelection().Count -eq 0) -and
             ([GraphCodeUiaGateState]::RemovedEvents -eq 1)) "RemoveFromSelection did not raise ElementRemovedFromSelection"
    $safeSelection.RemoveFromSelection()
    Start-Sleep -Milliseconds 150
    Require ([GraphCodeUiaGateState]::RemovedEvents -eq 1) "idempotent RemoveFromSelection raised a duplicate event"
    $safeSelection.AddToSelection()
    for ($index = 0; $index -lt 20 -and [GraphCodeUiaGateState]::AddedEvents -lt 1; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require ([GraphCodeUiaGateState]::AddedEvents -eq 1) "AddToSelection did not raise ElementAddedToSelection"
    $safeSelection.AddToSelection()
    Start-Sleep -Milliseconds 150
    Require ([GraphCodeUiaGateState]::AddedEvents -eq 1) "idempotent AddToSelection raised a duplicate event"
    $safeSelection.RemoveFromSelection()
    for ($index = 0; $index -lt 20 -and [GraphCodeUiaGateState]::RemovedEvents -lt 2; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require ([GraphCodeUiaGateState]::RemovedEvents -eq 2) "second RemoveFromSelection did not raise an event"
    Require ([GraphCodeUiaGateState]::PostKeyboard($process.MainWindowHandle, 0x28)) "keyboard selection message was rejected"
    for ($index = 0; $index -lt 20 -and [GraphCodeUiaGateState]::SelectedEvents -lt 2; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require ([GraphCodeUiaGateState]::SelectedEvents -eq 2) "App keyboard selection did not raise ElementSelected"
    Require ([GraphCodeUiaGateState]::PostMouseClick($process.MainWindowHandle)) "mouse selection message was rejected"
    for ($index = 0; $index -lt 20 -and [GraphCodeUiaGateState]::RemovedEvents -lt 3; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require ([GraphCodeUiaGateState]::RemovedEvents -eq 3) "App mouse selection did not raise ElementRemovedFromSelection"
    Require ([GraphCodeUiaGateState]::SelectionSourceAutomationId -eq $safeRowId) "selection event source identity changed"
  } finally {
    [System.Windows.Automation.Automation]::RemoveAutomationEventHandler($selectedEvent, $safeRow, $selectedHandler)
    [System.Windows.Automation.Automation]::RemoveAutomationEventHandler($addedEvent, $safeRow, $addedHandler)
    [System.Windows.Automation.Automation]::RemoveAutomationEventHandler($removedEvent, $safeRow, $removedHandler)
  }
  $selectionEventEvidence = @{
    selected = [GraphCodeUiaGateState]::SelectedEvents
    added = [GraphCodeUiaGateState]::AddedEvents
    removed = [GraphCodeUiaGateState]::RemovedEvents
    source = [GraphCodeUiaGateState]::SelectionSourceAutomationId
  }

  $actions = @{}
  foreach ($actionId in @("inspect-worktrees", "reclaim-worktrees", "reveal-worktree",
                          "edit-worktree-policy", "save-worktree-policy",
                          "allow-reclaim", "confirm-each-reclaim")) {
    $action = Find-FragmentById $root $actionId $rawWalker
    Require ($null -ne $action) "missing action $actionId"
    $actions[$actionId] = $action.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  }
  $allowReclaim = Find-FragmentById $root "allow-reclaim" $controlWalker
  $confirmReclaim = Find-FragmentById $root "confirm-each-reclaim" $controlWalker
  Require (($null -ne $allowReclaim) -and ($null -ne $confirmReclaim)) "missing worktree policy toggles"
  $allowToggle = $allowReclaim.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
  $confirmToggle = $confirmReclaim.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
  [GraphCodeUiaGateState]::TogglePropertyEvents = 0
  [GraphCodeUiaGateState]::TogglePropertySourceAutomationId = $null
  $togglePropertyHandler = [GraphCodeUiaGateState]::TogglePropertyHandler
  [System.Windows.Automation.Automation]::AddAutomationPropertyChangedEventHandler(
    $allowReclaim, [System.Windows.Automation.TreeScope]::Element, $togglePropertyHandler,
    [System.Windows.Automation.TogglePattern]::ToggleStateProperty
  )
  [System.Windows.Automation.Automation]::AddAutomationPropertyChangedEventHandler(
    $confirmReclaim, [System.Windows.Automation.TreeScope]::Element, $togglePropertyHandler,
    [System.Windows.Automation.TogglePattern]::ToggleStateProperty
  )
  try {
    $allowToggle.Toggle()
    for ($index = 0; $index -lt 20 -and [GraphCodeUiaGateState]::TogglePropertyEvents -lt 1; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require (([GraphCodeUiaGateState]::TogglePropertyEvents -eq 1) -and
             ([GraphCodeUiaGateState]::TogglePropertySourceAutomationId -eq "allow-reclaim")) "allow reclaim did not raise ToggleState property change"
    $confirmToggle.Toggle()
    for ($index = 0; $index -lt 20 -and [GraphCodeUiaGateState]::TogglePropertyEvents -lt 2; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require (([GraphCodeUiaGateState]::TogglePropertyEvents -eq 2) -and
             ([GraphCodeUiaGateState]::TogglePropertySourceAutomationId -eq "confirm-each-reclaim")) "confirm reclaim did not raise ToggleState property change"
  } finally {
    [System.Windows.Automation.Automation]::RemoveAutomationPropertyChangedEventHandler(
      $allowReclaim, $togglePropertyHandler
    )
    [System.Windows.Automation.Automation]::RemoveAutomationPropertyChangedEventHandler(
      $confirmReclaim, $togglePropertyHandler
    )
  }

  $status = Find-FragmentById $root "status" $controlWalker
  Require ($null -ne $status) "missing status element"
  $initialStatus = $status.Current.Name
  $statusRuntimeId = Get-RuntimeIdentity $status
  [GraphCodeUiaGateState]::LiveObserved = $false
  [GraphCodeUiaGateState]::NamePropertyObserved = $false
  [GraphCodeUiaGateState]::LiveEvents = 0
  [GraphCodeUiaGateState]::NamePropertyEvents = 0
  [GraphCodeUiaGateState]::LiveSourceAutomationId = $null
  [GraphCodeUiaGateState]::LiveSourceName = $null
  [GraphCodeUiaGateState]::LiveSourceRuntimeId = $null
  [GraphCodeUiaGateState]::NamePropertySourceAutomationId = $null
  [GraphCodeUiaGateState]::FocusObserved = $false
  [GraphCodeUiaGateState]::FocusSourceAutomationId = $null
  $eventHandler = [GraphCodeUiaGateState]::LiveHandler
  $liveRegionEvent = [System.Windows.Automation.AutomationEvent]::LookupById(20024)
  $propertyHandler = [GraphCodeUiaGateState]::NamePropertyHandler
  $focusHandler = [GraphCodeUiaGateState]::FocusHandler
  [System.Windows.Automation.Automation]::AddAutomationEventHandler(
    $liveRegionEvent, $status, [System.Windows.Automation.TreeScope]::Element, $eventHandler
  )
  $liveEventRegistered = $true
  [System.Windows.Automation.Automation]::AddAutomationPropertyChangedEventHandler(
    $status, [System.Windows.Automation.TreeScope]::Element, $propertyHandler,
    [System.Windows.Automation.AutomationElement]::NameProperty
  )
  $propertyEventRegistered = $true
  [System.Windows.Automation.Automation]::AddAutomationFocusChangedEventHandler($focusHandler)
  $focusEventRegistered = $true
  try {
    Require ([GraphCodeUiaGateState]::PostKeyboard($process.MainWindowHandle, 0x28)) "negative keyboard selection message was rejected"
    Start-Sleep -Milliseconds 150
    Require ([GraphCodeUiaGateState]::PostMouseClick($process.MainWindowHandle)) "negative mouse selection message was rejected"
    Start-Sleep -Milliseconds 150

    Require ([GraphCodeUiaGateState]::PostFixtureMutation($process.MainWindowHandle, 1)) "negative fixture reorder message was rejected"
    Start-Sleep -Milliseconds 150
    Assert-Ids @((Get-DirectChildren $worktrees $rawWalker | ForEach-Object { $_.Current.AutomationId })) `
      @($initialRowIds[1], $initialRowIds[0]) "negative reordered Worktrees"
    Require ([GraphCodeUiaGateState]::PostFixtureMutation($process.MainWindowHandle, 1)) "fixture reorder restore message was rejected"
    Start-Sleep -Milliseconds 150
    Assert-Ids @((Get-DirectChildren $worktrees $rawWalker | ForEach-Object { $_.Current.AutomationId })) `
      $initialRowIds "restored Worktrees"

    Require ([GraphCodeUiaGateState]::PostFixtureMutation($process.MainWindowHandle, 3)) "eligibility mutation message was rejected"
    Start-Sleep -Milliseconds 150
    $unsafeSelection.Select()
    Start-Sleep -Milliseconds 150
    Require $unsafeSelection.Current.IsSelected "eligibility-only sync did not make the fixture row selectable"

    $allowStateBefore = $allowToggle.Current.ToggleState
    Require ([GraphCodeUiaGateState]::PostFixtureMutation($process.MainWindowHandle, 4)) "allow policy sync message was rejected"
    for ($index = 0; $index -lt 20 -and $allowToggle.Current.ToggleState -eq $allowStateBefore; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require ($allowToggle.Current.ToggleState -ne $allowStateBefore) "allow policy-only sync was not observed"
    $confirmStateBefore = $confirmToggle.Current.ToggleState
    Require ([GraphCodeUiaGateState]::PostFixtureMutation($process.MainWindowHandle, 5)) "confirm policy sync message was rejected"
    for ($index = 0; $index -lt 20 -and $confirmToggle.Current.ToggleState -eq $confirmStateBefore; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require ($confirmToggle.Current.ToggleState -ne $confirmStateBefore) "confirm policy-only sync was not observed"

    Start-Sleep -Milliseconds 250
    $statusNoChangeLiveEvents = [GraphCodeUiaGateState]::LiveEvents
    $statusNoChangeNameEvents = [GraphCodeUiaGateState]::NamePropertyEvents
    Require ($status.Current.Name -eq $initialStatus) "non-status sync changed status text from '$initialStatus' to '$($status.Current.Name)'"
    Require ($statusNoChangeLiveEvents -eq 0) "non-status sync raised LiveRegionChanged"
    Require ($statusNoChangeNameEvents -eq 0) "non-status sync raised a status Name property change"

    $actions["save-worktree-policy"].Invoke()
    for ($i = 0; $i -lt 40 -and [GraphCodeUiaGateState]::LiveEvents -lt 1; $i++) {
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
  Require ([GraphCodeUiaGateState]::LiveEvents -eq 1) "status change did not raise exactly one LiveRegionChanged event"
  Require ([GraphCodeUiaGateState]::LiveSourceAutomationId -eq "status") "LiveRegionChanged source was not status"
  Require ([GraphCodeUiaGateState]::LiveSourceRuntimeId -eq $statusRuntimeId) "LiveRegionChanged source identity changed"
  Require ([GraphCodeUiaGateState]::NamePropertyObserved) "status Name property change was not delivered"
  Require ([GraphCodeUiaGateState]::NamePropertyEvents -eq 1) "status change did not raise exactly one Name property change"
  Require ([GraphCodeUiaGateState]::NamePropertySourceAutomationId -eq "status") "status Name property source was not status"
  Require (($statusTextAfter -ne $initialStatus) -and
           ([GraphCodeUiaGateState]::LiveSourceName -eq $statusTextAfter)) "status LiveRegionChanged did not expose updated text"

  $currentRowsBeforeFocus = @(Get-DirectChildren $worktrees $rawWalker)
  $currentSafe = @($currentRowsBeforeFocus | Where-Object { $_.Current.Name -eq "C:\fixture-safe" })[0]
  Require ($null -ne $currentSafe) "safe worktree row disappeared before focus: $(@($currentRowsBeforeFocus | ForEach-Object { $_.Current.AutomationId }) -join ',')"
  Require ($currentSafe.Current.AutomationId -eq $safeRowId) "safe worktree identity changed before focus: $safeRowId -> $($currentSafe.Current.AutomationId)"
  Require ($safeFocusRow.Current.Name -eq "C:\fixture-safe") "safe worktree provider became unavailable before focus"
  $focused = $null
  for ($index = 0; $index -lt 20; $index++) {
    $safeFocusRow.SetFocus()
    Start-Sleep -Milliseconds 50
    $candidate = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($candidate.Current.AutomationId -eq $safeRowId) {
      $focused = $candidate
      break
    }
  }
  Require ($null -ne $focused) "worktree row could not retain focus against concurrent desktop focus changes"
  Require ($focused.Current.AutomationId -eq $safeRowId) "focus source identity was '$($focused.Current.AutomationId)', expected '$safeRowId'"
  Require ((Get-RuntimeIdentity $focused) -eq (Get-RuntimeIdentity $safeFocusRow)) "focus runtime identity changed"
  for ($index = 0; $index -lt 20 -and -not [GraphCodeUiaGateState]::FocusObserved; $index++) {
    Start-Sleep -Milliseconds 50
  }
  Require ([GraphCodeUiaGateState]::FocusObserved) "FocusChanged was not delivered"
  Require ([GraphCodeUiaGateState]::FocusSourceAutomationId -eq $safeRowId) "FocusChanged source identity changed"
  $initialFocusSource = [GraphCodeUiaGateState]::FocusSourceAutomationId

  $stressJob = Start-Job -ArgumentList ([int64]$process.MainWindowHandle) -ScriptBlock {
    param([int64] $window)
    $ErrorActionPreference = "Stop"
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $element = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$window)
    for ($index = 0; $index -lt 100; $index++) {
      $null = $element.Current.Name
      Start-Sleep -Milliseconds 5
    }
  }
  Require ([GraphCodeUiaGateState]::PostFixtureMutation($process.MainWindowHandle, 1)) "fixture reorder message was rejected"
  Start-Sleep -Milliseconds 150
  $reorderedRows = @(Get-DirectChildren $worktrees $rawWalker)
  $reorderedRowIds = @($reorderedRows | ForEach-Object { $_.Current.AutomationId })
  Assert-Ids $reorderedRowIds @($initialRowIds[1], $initialRowIds[0]) "reordered Worktrees"
  $reorderedSafe = Find-FragmentById $root $safeRowId $rawWalker
  Require (($null -ne $reorderedSafe) -and
           ((Get-RuntimeIdentity $reorderedSafe) -eq $safeRowRuntimeId)) "reordered safe row lost its identity"
  Require ($rawWalker.GetParent($reorderedSafe).Current.AutomationId -eq "worktrees") "reordered safe row lost its parent"

  Require ([GraphCodeUiaGateState]::PostFixtureMutation($process.MainWindowHandle, 2)) "fixture removal message was rejected"
  Start-Sleep -Milliseconds 150
  $null = Wait-Job -Job $stressJob -Timeout 10
  $stressErrors = @()
  Receive-Job -Job $stressJob -ErrorAction SilentlyContinue -ErrorVariable +stressErrors | Out-Null
  Require ($stressJob.State -eq "Completed") "UIA read stress did not finish: $($stressJob.State) $($stressErrors -join '; ')"
  Remove-Job -Job $stressJob -Force
  $remainingRows = @(Get-DirectChildren $worktrees $rawWalker)
  $remainingRowIds = @($remainingRows | ForEach-Object { $_.Current.AutomationId })
  Assert-Ids $remainingRowIds @($unsafeRow.Current.AutomationId) "removed Worktrees"
  $removedProviderUnavailable = $false
  try {
    $null = $safeRow.GetCurrentPropertyValue([System.Windows.Automation.AutomationElement]::NameProperty)
  } catch [System.Windows.Automation.ElementNotAvailableException] {
    $removedProviderUnavailable = $true
  }
  Require $removedProviderUnavailable "removed worktree provider remained available"
  for ($index = 0; $index -lt 20 -and
       [GraphCodeUiaGateState]::FocusSourceAutomationId -ne "graphcode-root"; $index++) {
    Start-Sleep -Milliseconds 50
  }
  Require ([GraphCodeUiaGateState]::FocusSourceAutomationId -eq "graphcode-root") "removed focus did not fall back to the root"
  [System.Windows.Automation.Automation]::RemoveAutomationFocusChangedEventHandler($focusHandler)
  $focusEventRegistered = $false

  $rootName = $root.Current.Name
  $rootAutomationId = $root.Current.AutomationId
  $rootControlType = $root.Current.ControlType.ProgrammaticName
  $rawRootChildIds = @($rawRootChildren | ForEach-Object { $_.Current.AutomationId })
  $controlRootChildIds = @($controlRootChildren | ForEach-Object { $_.Current.AutomationId })
  $rawWorktreeRowIds = $initialRowIds
  $controlWorktreeRowIds = $initialRowIds
  $focusIdentity = $safeRowId

  $shellWindow = $process.MainWindowHandle
  Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 7)) "Rename Loop fixture command was rejected"
  $renameDialog = $null
  $desktop = [System.Windows.Automation.AutomationElement]::RootElement
  $renameWindowCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Rename Loop"
    )),
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Window
    ))
  )
  $renameCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id
    )),
    $renameWindowCondition
  )
  for ($index = 0; $index -lt 40 -and $null -eq $renameDialog; $index++) {
    Start-Sleep -Milliseconds 50
    $renameDialog = $desktop.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $renameCondition
    )
  }
  Require ($null -ne $renameDialog) "Rename Loop command did not open its native dialog"
  $renameElements = @($renameDialog.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  ))
  $renameContent = @($renameElements | ForEach-Object { $_.Current.Name }) -join "`n"
  Require ($renameContent -match "Choose the title shown") "Rename Loop dialog omitted its explanation"
  Require ($renameContent -match "(?m)^Title$") "Rename Loop dialog omitted its Title field label"
  Require ($renameContent -match "UIA loop A") "Rename Loop dialog did not populate the current title"
  Require ([GraphCodeUiaGateState]::SetFirstEditText(
    [IntPtr]$renameDialog.Current.NativeWindowHandle, "UIA renamed loop"
  )) "Rename Loop dialog omitted its native editable title field"
  Require ([GraphCodeUiaGateState]::SendReturn(
    [IntPtr]$renameDialog.Current.NativeWindowHandle
  )) "Rename Loop dialog rejected Return"
  for ($index = 0; $index -lt 40; $index++) {
    Start-Sleep -Milliseconds 50
    $remainingRename = $desktop.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $renameCondition
    )
    if ($null -eq $remainingRename) { break }
  }
  Require ($null -eq $remainingRename) "Return did not submit and close the Rename Loop dialog"

  Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 8)) "inline ingress-error fixture command was rejected"
  $inlineError = $null
  $inlineErrorCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::NameProperty, "Folder could not be opened"
  )
  for ($index = 0; $index -lt 40 -and $null -eq $inlineError; $index++) {
    Start-Sleep -Milliseconds 50
    $inlineError = $root.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $inlineErrorCondition
    )
  }
  Require ($null -ne $inlineError) "canvas did not expose the scoped ingress error"
  Require (($inlineError.Current.BoundingRectangle.Width -gt 0) -and
           ($inlineError.Current.BoundingRectangle.Height -gt 0)) `
    "inline ingress error had empty canvas bounds"

  Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 9)) "empty overview fixture command was rejected"
  Start-Sleep -Milliseconds 200
  $openFolderButton = Find-FragmentById $root "4601" $rawWalker
  $emptyOverviewLoopButton = Find-FragmentById $root "4602" $rawWalker
  Require (($null -ne $openFolderButton) -and ($openFolderButton.Current.Name -eq "Open Folder...")) `
    "empty global graph omitted its Open Folder action"
  Require (($null -ne $emptyOverviewLoopButton) -and ($emptyOverviewLoopButton.Current.Name -eq "New Loop")) `
    "empty global graph omitted its New Loop action"
  Require ((-not $openFolderButton.Current.IsOffscreen) -and
           (-not $emptyOverviewLoopButton.Current.IsOffscreen)) `
    "empty global graph actions were not visible"
  Require ([GraphCodeUiaGateState]::PostCommand($shellWindow, 4602)) `
    "empty global New Loop command was rejected"
  $nodeForm = $null
  $nodeFormWindowCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Create or edit node"
    )),
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Window
    ))
  )
  $nodeFormCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id
    )),
    $nodeFormWindowCondition
  )
  for ($index = 0; $index -lt 40 -and $null -eq $nodeForm; $index++) {
    Start-Sleep -Milliseconds 50
    $nodeForm = $desktop.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $nodeFormCondition
    )
  }
  Require ($null -ne $nodeForm) "empty global New Loop did not open the node form"
  Require ([GraphCodeUiaGateState]::PostClose(
    [IntPtr]$nodeForm.Current.NativeWindowHandle
  )) "empty global node form rejected cancellation"
  Start-Sleep -Milliseconds 200

  Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 10)) "empty project fixture command was rejected"
  Start-Sleep -Milliseconds 200
  $emptyProjectLoopButton = Find-FragmentById $root "4602" $rawWalker
  Require (($null -ne $emptyProjectLoopButton) -and
           ($emptyProjectLoopButton.Current.Name -eq "New Loop") -and
           (-not $emptyProjectLoopButton.Current.IsOffscreen)) `
    "empty project canvas omitted its visible New Loop action"
  Require ([GraphCodeUiaGateState]::PostCommand($shellWindow, 4602)) `
    "empty project New Loop command was rejected"
  $projectNodeForm = $null
  for ($index = 0; $index -lt 40 -and $null -eq $projectNodeForm; $index++) {
    Start-Sleep -Milliseconds 50
    $projectNodeForm = $desktop.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $nodeFormCondition
    )
  }
  Require ($null -ne $projectNodeForm) "empty project New Loop did not open the node form"
  Require ([GraphCodeUiaGateState]::PostClose(
    [IntPtr]$projectNodeForm.Current.NativeWindowHandle
  )) "empty project node form rejected cancellation"
  Start-Sleep -Milliseconds 200

  Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 6)) "About dialog fixture command was rejected"
  $aboutDialog = $null
  $aboutWindowCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, "About GraphCode"
    )),
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Window
    ))
  )
  $aboutCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id
    )),
    $aboutWindowCondition
  )
  for ($index = 0; $index -lt 40 -and $null -eq $aboutDialog; $index++) {
    Start-Sleep -Milliseconds 50
    $aboutDialog = $desktop.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $aboutCondition
    )
  }
  if ($null -eq $aboutDialog) {
    $processWindowCondition = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id
    )
    $windowNames = @($desktop.FindAll(
      [System.Windows.Automation.TreeScope]::Descendants,
      $processWindowCondition
    ) | ForEach-Object { $_.Current.Name })
    throw "About command did not open the native About GraphCode dialog; process windows: $($windowNames -join ', '); status: $($status.Current.Name)"
  }
  $aboutElements = @($aboutDialog.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  ))
  $aboutContent = @($aboutElements | ForEach-Object { $_.Current.Name }) -join "`n"
  $aboutDescendants = @($aboutElements | ForEach-Object { "$($_.Current.ControlType.ProgrammaticName):$($_.Current.Name)" })
  Require ($aboutContent -match "GraphCode\s+for Windows") "About dialog omitted the product identity: $($aboutDescendants -join ' | ')"
  Require ($aboutContent -match "Version\s+\S+") "About dialog omitted the application version: $($aboutDescendants -join ' | ')"
  $aboutOk = $aboutDialog.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty,
      "OK"
    ))
  )
  Require ($null -ne $aboutOk) "About dialog omitted its OK action"
  Require ([GraphCodeUiaGateState]::PostClose(
    [IntPtr]$aboutDialog.Current.NativeWindowHandle
  )) "About dialog rejected its close command"
  Start-Sleep -Milliseconds 250

  Require $process.CloseMainWindow() "shell refused caption close"
  Start-Sleep -Milliseconds 250
  $process.Refresh()
  Require (-not $process.HasExited) "caption close terminated the tray-resident shell"
  Require ([GraphCodeUiaGateState]::PostCommand($shellWindow, 0x5002)) "tray Exit command was rejected"
  Require $process.WaitForExit(5000) "shell did not exit after the tray Exit command"
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
    reorderedWorktreeRows = $reorderedRowIds
    remainingWorktreeRows = $remainingRowIds
    removedProviderUnavailable = $removedProviderUnavailable
    concurrencyStressPassed = $true
    selectionPattern = $true
    fixtureRows = 2
    unsafeSelectionRejected = $unsafeRejected
    repeatedSelectionObserved = $true
    selectionEvents = $selectionEventEvidence
    togglePropertyEvents = [GraphCodeUiaGateState]::TogglePropertyEvents
    togglePropertySource = [GraphCodeUiaGateState]::TogglePropertySourceAutomationId
    actionPatterns = @($actions.Keys | Sort-Object)
    surfaceActionPatterns = @($surfaceActionPatterns.Keys | Sort-Object)
    dynamicProjectRows = $projectRowIds
    dynamicLoopRows = $loopIds
    dynamicProjectCards = $projectCardIds
    dynamicQuickChatCards = $quickChatCardIds
    dynamicInvocationsPassed = $true
    compositeNavigationPassed = $true
    renameDialogPassed = $true
    inlineIngressErrorPassed = $true
    emptyOverviewPassed = $true
    emptyProjectPassed = $true
    aboutDialogPassed = $true
    statusText = $statusTextAfter
    statusChanged = ($statusTextAfter -ne $initialStatus)
    statusNoChangeLiveEvents = $statusNoChangeLiveEvents
    statusNoChangeNameEvents = $statusNoChangeNameEvents
    statusLiveEvents = [GraphCodeUiaGateState]::LiveEvents
    statusNamePropertyEvents = [GraphCodeUiaGateState]::NamePropertyEvents
    statusEventObserved = $statusEventObserved
    statusNamePropertyObserved = [GraphCodeUiaGateState]::NamePropertyObserved
    statusNamePropertySource = [GraphCodeUiaGateState]::NamePropertySourceAutomationId
    statusEventSource = [GraphCodeUiaGateState]::LiveSourceAutomationId
    statusEventText = [GraphCodeUiaGateState]::LiveSourceName
    focusIdentity = $focusIdentity
    focusEventObserved = [GraphCodeUiaGateState]::FocusObserved
    initialFocusEventSource = $initialFocusSource
    focusFallbackSource = [GraphCodeUiaGateState]::FocusSourceAutomationId
    providerTeardownSafe = $retainedProviderSafe
  } | ConvertTo-Json -Compress
} finally {
  if ($stressJob) {
    Remove-Job -Job $stressJob -Force -ErrorAction SilentlyContinue
  }
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
  if ($focusEventRegistered) {
    [System.Windows.Automation.Automation]::RemoveAutomationFocusChangedEventHandler($focusHandler)
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
  if ($null -eq $oldDaemonPipe) { Remove-Item Env:GRAPHCODE_DAEMON_PIPE -ErrorAction SilentlyContinue }
  else { $env:GRAPHCODE_DAEMON_PIPE = $oldDaemonPipe }
}
