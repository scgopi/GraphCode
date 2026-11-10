[CmdletBinding()]
param(
  [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path,
  [Parameter(Mandatory)][string] $ArtifactRoot,
  [string] $AssemblyPath
)

$ErrorActionPreference = "Stop"
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $RepositoryRoot "Tools\windows\uia-live-gate.ps1"), [ref]$null, [ref]$errors)
if ($errors.Count) { throw "Navigation gate must parse" }
foreach ($name in @("Test-UiaCanonicalNavigationId", "Assert-UiaNavigationSelectionSnapshot")) {
  $definitions = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
  }, $true))
  if ($definitions.Count -ne 1) { throw "Missing unique navigation observation oracle: $name" }
  if ($definitions[0].Extent.Text -match "System.Windows.Automation|GraphCodeUiaGateState|GetCurrentPattern|Invoke\(") {
    throw "Headless navigation oracle must not bind native UIA or input"
  }
  . ([scriptblock]::Create($definitions[0].Extent.Text))
}
$cases = @("graph", "quick-chats", "project", "loop", "chat", "no-selected",
  "two-selected", "empty-container-selection", "duplicate-container-selection",
  "wrong-container-selection", "sibling-container", "foreign-row", "duplicate-id",
  "duplicate-runtime", "missing-fixed", "foreign-container-selection", "multiple-selection",
  "alias", "wrong-container-runtime", "selected-runtime-drift", "foreign-root",
  "wrong-root-id", "invalid-selected-type")
$results = [Collections.Generic.List[object]]::new()
foreach ($case in $cases) {
  $root = [pscustomobject]@{ id = "graphcode-root"; runtime = "42,0"; process = 42; multiple = $false }
  $ids = @("overview-destination", "quick-chats-destination", "open-project-1", "loop-row-2", "quick-chat-row-3")
  $expectedIndex = switch ($case) { "quick-chats" { 1 } "project" { 2 } "loop" { 3 } "chat" { 4 } default { 0 } }
  $expected = $ids[$expectedIndex]
  $rows = @(for ($index = 0; $index -lt $ids.Count; $index++) {
    [pscustomobject]@{
      id = $ids[$index]; runtime = "42,$($index + 1)"; process = 42; selected = $index -eq $expectedIndex
      containerId = "graphcode-root"; containerRuntime = "42,0"; containerProcess = 42
    }
  })
  $selected = @([pscustomobject]@{ id = $expected; runtime = $rows[$expectedIndex].runtime; process = 42 })
  switch ($case) {
    "no-selected" { $rows[0].selected = $false }
    "two-selected" { $rows[2].selected = $true }
    "empty-container-selection" { $selected = @() }
    "duplicate-container-selection" { $selected += $selected[0] }
    "wrong-container-selection" { $selected[0].id = "open-project-1" }
    "sibling-container" { $rows[3].containerId = "projects" }
    "foreign-row" { $rows[3].process = 99 }
    "duplicate-id" { $rows += $rows[0] }
    "duplicate-runtime" { $rows[1].runtime = $rows[0].runtime }
    "missing-fixed" { $rows = @($rows | Where-Object id -cne "quick-chats-destination") }
    "foreign-container-selection" { $selected[0].process = 99 }
    "multiple-selection" { $root.multiple = $true }
    "alias" { $rows[3].id = "needs-you-row-2" }
    "wrong-container-runtime" { $rows[3].containerRuntime = "42,99" }
    "selected-runtime-drift" { $selected[0].runtime = "42,99" }
    "foreign-root" { $root.process = 99 }
    "wrong-root-id" { $root.id = "projects" }
    "invalid-selected-type" { $rows[0].selected = "true" }
  }
  $failure = $null
  try { Assert-UiaNavigationSelectionSnapshot $root $rows $selected 42 $expected } catch { $failure = $_ }
  $positive = $case -cin @("graph", "quick-chats", "project", "loop", "chat")
  $passed = ($null -eq $failure) -eq $positive
  if ($failure -and $failure.Exception.Message -notlike "Navigation selection:*") { $passed = $false }
  $results.Add([pscustomobject]@{
    name = $case; passed = $passed
    error = $(if (-not $passed) { [string]$failure } else { "" })
  })
}
$wrappers = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq "Assert-UiaSingleNavigationSelection"
}, $true))
if ($wrappers.Count -ne 1) { throw "Missing unique live navigation readback wrapper" }
$calls = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -ceq "Assert-UiaSingleNavigationSelection"
}, $true))
if ($calls.Count -ne 6) { throw "Live gate must check five navigation destinations and each event transition readback" }
$derivedAst = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $RepositoryRoot "Tools\windows\ValidationRunner\Ui\UiDerivedContracts.ps1"),
  [ref]$null, [ref]$errors)
if ($errors.Count) { throw "Derived UI source contracts must parse" }
foreach ($name in @("Assert-Derived", "Get-Region")) {
  $found = @($derivedAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
  }, $true))
  if ($found.Count -ne 1) { throw "Missing coupled source-boundary evaluator: $name" }
  . ([scriptblock]::Create($found[0].Extent.Text))
}
$gateSource = [IO.File]::ReadAllText((Join-Path $RepositoryRoot "Tools\windows\uia-live-gate.ps1"))
$caption = Get-Region $gateSource '$laneProjectId = Get-MultiProjectAutomationId "overview-project" $fixtureProjectPath' `
  '$quickChatNavigation = Find-FragmentById $root "quick-chats-destination" $rawWalker'
if (-not $caption.Contains('UIA_LANE_NO_WORKTREE_CHIP_EVIDENCE=')) { throw "Coupled caption source region lost its evidence boundary" }
$definition = $wrappers[0].Extent.Text
foreach ($token in @(
  '[System.Windows.Automation.SelectionPattern]::Pattern',
  '[System.Windows.Automation.SelectionItemPattern]::Pattern'
)) {
  if ([regex]::Matches($definition, [regex]::Escape($token)).Count -ne 1) { throw "Unexpected native pattern binding: $token" }
}
$definition = $definition.Replace('[System.Windows.Automation.SelectionPattern]::Pattern', '10').
  Replace('[System.Windows.Automation.SelectionItemPattern]::Pattern', '20')
if ($definition -match "System.Windows.Automation|GraphCodeUiaGateState|\.Select\(|\.Invoke\(") {
  throw "Unsubstituted native binding or input in the read-only wrapper"
}
. ([scriptblock]::Create($definition))
function Require([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Start-Sleep([int] $Milliseconds) {
  if ($Milliseconds -ne 50) { throw "Unexpected wrapper observation delay" }
  $binding.sleeps++
}
function Find-FragmentById($Root, [string] $Id, $Walker) {
  if ($Id -cnotin @("projects", "loops")) { throw "Unexpected wrapper fragment" }
  return [pscustomobject]@{ Id = $Id }
}
function Get-SidebarNavigationChildren($Root, $Projects, $Walker) { return $binding.elements }
function Get-DirectChildren($Parent, $Walker) { return @() }
foreach ($case in @("live-binding", "live-alias-exclusion", "live-delayed-selection", "live-timeout")) {
  $failure = $null
  $binding = @{
    reads = 0; sleeps = 0; items = 0
    root = [pscustomobject]@{ Current = [pscustomobject]@{ AutomationId = "graphcode-root"; ProcessId = 42 } }
    elements = @()
  }
  $binding.root | Add-Member ScriptMethod GetRuntimeId { return @(42, 0) }
  foreach ($index in 0..4) {
    $element = [pscustomobject]@{
      Current = [pscustomobject]@{ AutomationId = $ids[$index]; ProcessId = 42 }
      Runtime = @(42, ($index + 1))
    }
    $element | Add-Member ScriptMethod GetRuntimeId { return $this.Runtime }
    $element | Add-Member ScriptMethod GetCurrentPattern {
      param($Pattern)
      if ($Pattern -ne 20 -or -not (Test-UiaCanonicalNavigationId $this.Current.AutomationId)) { throw "Unexpected row pattern/alias read" }
      $binding.items++
      return [pscustomobject]@{ Current = [pscustomobject]@{
        IsSelected = $this.Current.AutomationId -ceq "overview-destination"
        SelectionContainer = $binding.root
      } }
    }
    $binding.elements += $element
  }
  $current = [pscustomobject]@{ CanSelectMultiple = $false }
  $current | Add-Member ScriptMethod GetSelection {
    $binding.reads++
    if ($case -ceq "live-timeout" -or ($case -ceq "live-delayed-selection" -and $binding.reads -lt 3)) { return @() }
    return @($binding.elements[0])
  }
  $binding.selection = [pscustomobject]@{ Current = $current }
  $binding.root | Add-Member ScriptMethod GetCurrentPattern {
    param($Pattern)
    if ($Pattern -ne 10) { throw "Unexpected root selection binding" }
    return $binding.selection
  }
  if ($case -ceq "live-alias-exclusion") {
    $binding.elements += [pscustomobject]@{ Current = [pscustomobject]@{
      AutomationId = "needs-you-row-2"; ProcessId = 42
    } }
  }
  try { Assert-UiaSingleNavigationSelection $binding.root $null "overview-destination" 42 } catch { $failure = $_ }
  $expectedReads = switch ($case) { "live-timeout" { 60 } "live-delayed-selection" { 3 } default { 1 } }
  $expectedSleeps = switch ($case) { "live-timeout" { 60 } "live-delayed-selection" { 2 } default { 0 } }
  $passed = (($null -eq $failure) -eq ($case -cne "live-timeout")) -and
    $binding.reads -eq $expectedReads -and $binding.sleeps -eq $expectedSleeps -and $binding.items -eq 5
  if ($failure -and $failure.Exception.Message -notlike "Navigation selection:*") { $passed = $false }
  $results.Add([pscustomobject]@{ name = $case; passed = $passed; error = $(if (-not $passed) { [string]$failure } else { "" }) })
}
$failed = @($results | Where-Object { -not $_.passed })
$eventResults = [Collections.Generic.List[object]]::new()
$eventDefinition = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq "Assert-UiaNavigationSelectionEventReceipt"
}, $true))
if ($eventDefinition.Count -ne 1) { throw "Missing unique navigation event receipt oracle" }
. ([scriptblock]::Create($eventDefinition[0].Extent.Text))
foreach ($case in @("graph", "quick-chats", "project", "loop", "chat",
    "zero", "duplicate", "wrong-id", "wrong-runtime", "foreign", "alias", "empty-runtime")) {
  $index = switch ($case) { "quick-chats" { 1 } "project" { 2 } "loop" { 3 } "chat" { 4 } default { 0 } }
  $expected = $ids[$index]
  $receipt = [pscustomobject]@{ count = 1; id = $expected; runtime = "42,1"; process = 42 }
  switch ($case) {
    "zero" { $receipt.count = 0 }
    "duplicate" { $receipt.count = 2 }
    "wrong-id" { $receipt.id = "loop-row-99" }
    "wrong-runtime" { $receipt.runtime = "42,99" }
    "foreign" { $receipt.process = 99 }
    "alias" { $receipt.id = "needs-you-row-1"; $expected = $receipt.id }
    "empty-runtime" { $receipt.runtime = "" }
  }
  $failure = $null
  try { Assert-UiaNavigationSelectionEventReceipt $receipt $expected "42,1" 42 } catch { $failure = $_ }
  $passed = ($null -eq $failure) -eq ($case -cin @("graph", "quick-chats", "project", "loop", "chat"))
  if ($failure -and $failure.Exception.Message -notlike "Navigation event:*") { $passed = $false }
  $eventResults.Add([pscustomobject]@{ name = $case; passed = $passed })
}
$bindingSource = [IO.File]::ReadAllText((Join-Path $RepositoryRoot "Tools\windows\ValidationRunner\Ui\Production\GraphCodeUiaGateState.cs"))
if ($bindingSource -notmatch '(?s)private static void HandleSelected\(.*?SelectionSourceProcessId = element.Current.ProcessId;.*?SelectedEvents\+\+;') {
  throw "Navigation event process receipt must come from the actual UIA event sender before count publication"
}
$eventWrappers = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq "Assert-UiaNavigationSelectionEvents"
}, $true))
if ($eventWrappers.Count -ne 1 -or
    $eventWrappers[0].Extent.Text -notmatch 'AddAutomationEventHandler' -or
    $eventWrappers[0].Extent.Text -notmatch 'RemoveAutomationEventHandler' -or
    $eventWrappers[0].Extent.Text -notmatch 'Assert-UiaSingleNavigationSelection' -or
    $gateSource -notmatch 'Assert-UiaNavigationSelectionEvents \$root \$rawWalker @\("overview-destination", "quick-chats-destination", \$dynamicInvokedProjectRow, \$dynamicInvokedLoopRow, \$firstQuickRowId\)') {
  throw "Live navigation event subscription/readback must cover all five canonical destinations"
}
$eventComplete = $eventResults.Count -eq 12 -and @($eventResults | Where-Object { -not $_.passed }).Count -eq 0
$complete = $results.Count -eq 27 -and @($results.name | Sort-Object -Unique).Count -eq 27 -and $failed.Count -eq 0
$null = New-Item -ItemType Directory -Force -Path $ArtifactRoot
$resultPath = Join-Path $ArtifactRoot ("navigation-oracle-" + [guid]::NewGuid().ToString("N") + ".json")
[IO.File]::WriteAllText($resultPath, ($results | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
Write-Host "Navigation selection oracle: $($results.Count) cases, $($failed.Count) failures (nativeCalls=0)"
foreach ($failure in $failed) { Write-Host "$($failure.name): $($failure.error)" }
Write-Output ("UI_CASE_RESULT=" + ([ordered]@{
  id = "ui.navigation.selection-snapshot-controls"; status = $(if ($complete) { "Passed" } else { "Failed" })
  executedCount = $results.Count; groups = @($results | Where-Object passed | ForEach-Object name)
  evidence = "Actual shared navigation snapshot oracle; source-derived in-memory observations; no UIA import or native calls"
} | ConvertTo-Json -Compress))
Write-Output ("UI_CASE_RESULT=" + ([ordered]@{
  id = "ui.navigation.selection-event-controls"; status = $(if ($eventComplete) { "Passed" } else { "Failed" })
  executedCount = $eventResults.Count; groups = @($eventResults | Where-Object passed | ForEach-Object name)
  evidence = "Actual navigation event receipt predicate and source-bound real handler wiring; nativeCalls=0"
} | ConvertTo-Json -Compress))
if (-not $complete -or -not $eventComplete) { exit 1 }
