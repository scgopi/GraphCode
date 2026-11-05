param(
  [Parameter(Mandatory)][string] $RepositoryRoot,
  [Parameter(Mandatory)][string] $ArtifactRoot,
  [Parameter(Mandatory)][string] $AssemblyPath
)
$ErrorActionPreference = 'Stop'
$null = [IO.Directory]::CreateDirectory($ArtifactRoot)
$source = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'Tools\windows\uia-live-gate.ps1'))
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'Delete Select source does not parse' }
$results = [Collections.Generic.List[object]]::new()
function Assert-Delete([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw [InvalidOperationException]::new("Delete Select contract: $Message") }
}
function Invoke-DeleteCase([string] $Id, [scriptblock] $Assertion) {
  $failure = $null
  try { & $Assertion } catch { $failure = $_ }
  $results.Add([ordered]@{
    id = $Id; status = $(if ($failure) { 'Failed' } else { 'Passed' }); executedCount = 1
    evidence = $(if ($failure) { $failure.ToString() } else { 'Production PS AST/scope/ScriptProperty/ErrorRecord and receipt contract; nativeCalls=0' })
  })
}
function Confirm-DeleteVisibility([string] $Text) {
  $start = $Text.IndexOf('$deleteLoopTitle =', [StringComparison]::Ordinal)
  $end = if ($start -ge 0) {
    $Text.IndexOf('$deleteTarget = Find-FragmentByIdWithRetry $root $renameGraphIdentity $rawWalker', $start, [StringComparison]::Ordinal)
  } else { -1 }
  if ($start -lt 0 -or $end -le $start) { return $false }
  $region = $Text.Substring($start, $end - $start)
  $normalized = [regex]::Replace($region, '\s+', ' ')
  $offset = 0
  foreach ($required in @(
    '$fitDeleteCanvas = Find-FragmentByIdWithRetry $root "fit-canvas" $rawWalker',
    '$fitDeleteCanvas.Current.ProcessId -eq $process.Id',
    '$fitDeleteCanvas.Current.Name -ceq "Fit canvas"',
    '$fitDeleteCanvas.GetCurrentPattern( [System.Windows.Automation.InvokePattern]::Pattern ).Invoke()',
    '$root = Wait-ForRootReconnect $process @($rawWalker, $controlWalker)',
    'for ($deleteVisibilityAttempt = 0; $deleteVisibilityAttempt -lt 40; $deleteVisibilityAttempt++)',
    '$deleteTargetVisible = $false',
    '$deleteCandidate = Find-FragmentById $root $renameGraphIdentity $rawWalker',
    '$deleteGraph = Find-FragmentById $root "graph" $rawWalker',
    '$deleteCandidate.Current.ProcessId -eq $process.Id',
    '$deleteCandidate.Current.AutomationId -ceq $renameGraphIdentity',
    '$deleteGraph.Current.ProcessId -eq $process.Id',
    '$deleteTargetOffscreen = $deleteCandidate.Current.IsOffscreen',
    'if (-not $deleteTargetOffscreen) {',
    '$deleteTargetBounds = $deleteCandidate.Current.BoundingRectangle',
    '$deleteGraphBounds = $deleteGraph.Current.BoundingRectangle',
    '$deleteTargetVisible = -not $deleteTargetOffscreen -and',
    '-not $deleteTargetBounds.IsEmpty -and',
    '$deleteTargetBounds.Width -gt 0 -and $deleteTargetBounds.Height -gt 0 -and',
    '-not $deleteGraphBounds.IsEmpty -and',
    '$deleteTargetBounds.Left -ge $deleteGraphBounds.Left -and',
    '$deleteTargetBounds.Top -ge $deleteGraphBounds.Top -and',
    '$deleteTargetBounds.Right -le $deleteGraphBounds.Right -and',
    '$deleteTargetBounds.Bottom -le $deleteGraphBounds.Bottom',
    'if ($deleteTargetVisible) { break }',
    'Start-Sleep -Milliseconds 100',
    '$root = Wait-ForRootReconnect $process @($rawWalker, $controlWalker)',
    'Require ($deleteTargetVisible)',
    'UIA_DELETE_TARGET_VISIBLE='
  )) {
    $next = $normalized.IndexOf($required, $offset, [StringComparison]::Ordinal)
    if ($next -lt 0) { return $false }
    $offset = $next + $required.Length
  }
  $parseErrors = $null
  $regionAst = [Management.Automation.Language.Parser]::ParseInput($region, [ref]$null, [ref]$parseErrors)
  if ($parseErrors.Count) { return $false }
  $guards = @($regionAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses.Count -eq 1 -and
      [regex]::Replace($node.Clauses[0].Item1.Extent.Text, '[\s()]', '') -ceq '-not$deleteTargetOffscreen'
  }, $true))
  if ($guards.Count -ne 1) { return $false }
  $guard = $guards[0].Clauses[0].Item2
  foreach ($assignment in @(
    '$deleteTargetBounds = $deleteCandidate.Current.BoundingRectangle',
    '$deleteGraphBounds = $deleteGraph.Current.BoundingRectangle'
  )) {
    $assignments = @($regionAst.FindAll({
      param($node)
      $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Extent.Text -ceq $assignment
    }, $true))
    if ($assignments.Count -ne 1 -or $assignments[0].Extent.StartOffset -lt $guard.Extent.StartOffset -or
        $assignments[0].Extent.EndOffset -gt $guard.Extent.EndOffset) { return $false }
  }
  return $true
}
$visibilityCases = @(
  @{ name = 'actual'; text = $source; accepted = $true },
  @{ name = 'missing-fit'; text = $source.Replace('$fitDeleteCanvas.GetCurrentPattern(', '$unusedFit.GetCurrentPattern('); accepted = $false },
  @{ name = 'wrong-identity'; text = $source.Replace('$deleteCandidate = Find-FragmentById $root $renameGraphIdentity $rawWalker', '$deleteCandidate = Find-FragmentById $root "other-card" $rawWalker'); accepted = $false },
  @{ name = 'missing-offscreen'; text = $source.Replace('$deleteTargetVisible = -not $deleteTargetOffscreen -and', '$deleteTargetVisible = $true -and'); accepted = $false },
  @{ name = 'ungated-bounds'; text = $source.Replace('if (-not $deleteTargetOffscreen) {', 'if ($true) {'); accepted = $false },
  @{ name = 'escaped-bounds'; text = $source.Replace('if (-not $deleteTargetOffscreen) {', 'if (-not $deleteTargetOffscreen) { } ; if ($true) {'); accepted = $false },
  @{ name = 'stale-visibility'; text = [regex]::new('(\$deleteVisibilityAttempt\+\+\)\s*\{\s*)\$deleteTargetVisible = \$false').Replace($source, '$1', 1); accepted = $false },
  @{ name = 'missing-containment'; text = $source.Replace('$deleteTargetBounds.Right -le $deleteGraphBounds.Right -and', '$true -and'); accepted = $false },
  @{ name = 'missing-require'; text = $source.Replace('Require ($deleteTargetVisible)', '$null = ($deleteTargetVisible)'); accepted = $false }
)
foreach ($case in $visibilityCases) {
  Invoke-DeleteCase "ui.delete.visibility.$($case.name)" {
    Assert-Delete ((Confirm-DeleteVisibility $case.text) -eq $case.accepted) `
      "$($case.name) must prove the same owned card visible inside graph bounds before Select reacquisition"
  }
}

$definitions = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -cin @('Get-DeleteTargetDiagnosticValue', 'Get-DeleteTargetIdentityHash', 'Write-DeleteTargetSelectFailure')
}, $true))
Assert-Delete ($definitions.Count -eq 3) 'Expected all three actual diagnostic helpers'
foreach ($definition in $definitions) {
  Assert-Delete ($definition.Extent.Text -notmatch 'FromHandle|Add-Type|Start-Process|New-Item|FindAll|FindFirst|System\.Windows|GraphCodeUiaGateState') `
    'Diagnostic helper acquired native or UIA capability'
  . ([scriptblock]::Create($definition.Extent.Text))
}
$selects = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Extent.Text -ceq '$deleteTargetSelection.Select()'
}, $true))
Assert-Delete ($selects.Count -eq 1) 'Expected one actual Select call'
$statement = $selects[0].Parent
while ($statement.Parent -isnot [Management.Automation.Language.StatementBlockAst] -and
    $statement.Parent -isnot [Management.Automation.Language.NamedBlockAst]) { $statement = $statement.Parent }
if ($statement.Parent.Parent -is [Management.Automation.Language.TryStatementAst] -and $statement.Parent.Statements.Count -eq 1) {
  $statement = $statement.Parent.Parent
}
$expectedWrapper = @'
try {
    $deleteTargetSelection.Select()
  } catch {
    try {
      try {
        Write-DeleteTargetSelectFailure $deleteTarget $deleteTargetSelection $renameGraphIdentity `
          $process.Id $shellWindow $_ $DeleteSelectFailureReceipt
      } catch {
        Write-Host ("UIA_DELETE_TARGET_SELECT_TELEMETRY_FAILURE=hresult:{0}" -f $_.Exception.HResult)
      }
    } finally {
      throw
    }
  }
'@
Assert-Delete ($statement.Extent.Text.Replace("`r`n", "`n") -ceq $expectedWrapper.Replace("`r`n", "`n")) 'Unsafe production Select wrapper'
$invokeSelect = [scriptblock]::Create($statement.Extent.Text)
function Assert-MockBindings($Target, $Selection, [hashtable] $State) {
  foreach ($value in @($Target, $Selection)) {
    Assert-Delete ($value.GetType() -eq [Management.Automation.PSCustomObject] -and
      $value.PSObject.Properties['Current'] -is [Management.Automation.PSScriptProperty] -and
      $value.PSObject.Properties['State'] -is [Management.Automation.PSNoteProperty] -and
      [object]::ReferenceEquals($value.PSObject.Properties['State'].Value, $State)) 'Unbound mock Current or State'
  }
  Assert-Delete ($Target.PSObject.Methods['GetRuntimeId'] -is [Management.Automation.PSScriptMethod] -and
    $Selection.PSObject.Methods['Select'] -is [Management.Automation.PSScriptMethod]) 'Non-script mock method'
}
$selectCases = @('rejection', 'success', 'unavailable', 'foreign-pid', 'identity-drift',
  'zero-bounds', 'offscreen', 'disabled', 'selected', 'runtime-unavailable', 'parent-unavailable',
  'telemetry-write-failure', 'receipt-exists', 'receipt-unconfigured', 'deadline', 'long-identity',
  'long-runtime', 'invalid-boolean', 'nonfinite-bounds', 'exception-chain', 'foreign-parent')
foreach ($case in $selectCases) {
  Invoke-DeleteCase "ui.delete.select.$case" {
    $state = @{ case = $case; selects = 0; reads = 0; original = [InvalidOperationException]::new('PRIVATE_EXCEPTION_SENTINEL') }
    if ($case -ceq 'exception-chain') {
      for ($index = 0; $index -lt 6; $index++) {
        $state.original = [InvalidOperationException]::new('PRIVATE_CHAIN_SENTINEL', $state.original)
      }
    }
    $deleteTarget = [pscustomobject]@{ State = $state }
    $deleteTarget | Add-Member ScriptProperty Current {
      $this.State.reads++
      if ($this.State.case -ceq 'unavailable') { throw 'PRIVATE_PROPERTY_SENTINEL' }
      [pscustomobject]@{
        AutomationId = $(if ($this.State.case -ceq 'identity-drift') { 'PRIVATE_OTHER_ID' }
          elseif ($this.State.case -ceq 'long-identity') { 'x' * 4097 } else { 'PRIVATE_TARGET_ID' })
        ProcessId = $(if ($this.State.case -ceq 'foreign-pid') { 7777 } else { 4242 })
        BoundingRectangle = [pscustomobject]@{
          Left = $(if ($this.State.case -ceq 'nonfinite-bounds') { [double]::NaN } else { 10.0 }); Top = 20.0
          Width = $(if ($this.State.case -ceq 'zero-bounds') { 0.0 } else { 30.0 })
          Height = $(if ($this.State.case -ceq 'zero-bounds') { 0.0 } else { 40.0 })
        }
        IsOffscreen = ($this.State.case -ceq 'offscreen')
        IsEnabled = $(if ($this.State.case -ceq 'invalid-boolean') { 'PRIVATE_BOOLEAN' } else { $this.State.case -cne 'disabled' })
        Name = 'PRIVATE_NAME_SENTINEL'; Value = 'PRIVATE_VALUE_SENTINEL'
      }
    }
    $deleteTarget | Add-Member ScriptMethod GetRuntimeId {
      $this.State.reads++
      if ($this.State.case -cin @('unavailable', 'runtime-unavailable')) { throw 'PRIVATE_RUNTIME_SENTINEL' }
      if ($this.State.case -ceq 'deadline') { [Threading.Thread]::Sleep(550) }
      if ($this.State.case -ceq 'long-runtime') { return [int[]](1..65) }
      return [int[]]@(42, 7, 9)
    }
    $deleteTargetSelection = [pscustomobject]@{ State = $state }
    $deleteTargetSelection | Add-Member ScriptMethod Select {
      $this.State.selects++
      if ($this.State.case -cne 'success') { throw $this.State.original }
    }
    $deleteTargetSelection | Add-Member ScriptProperty Current {
      $this.State.reads++
      if ($this.State.case -ceq 'unavailable') { throw 'PRIVATE_PATTERN_SENTINEL' }
      $container = [pscustomobject]@{ State = $this.State }
      $container | Add-Member ScriptProperty Current {
        $this.State.reads++
        if ($this.State.case -ceq 'parent-unavailable') { throw 'PRIVATE_PARENT_SENTINEL' }
        [pscustomobject]@{
          ProcessId = $(if ($this.State.case -ceq 'foreign-parent') { 7777 } else { 4242 })
          ControlType = [pscustomobject]@{ Id = 50033 }; ClassName = 'PRIVATE_CLASS_SENTINEL'; Name = 'PRIVATE_PARENT_SENTINEL'
        }
      }
      [pscustomobject]@{ IsSelected = ($this.State.case -ceq 'selected'); SelectionContainer = $container }
    }
    $process = [pscustomobject]@{ Id = 4242 }
    $shellWindow = [IntPtr]42
    $renameGraphIdentity = 'PRIVATE_TARGET_ID'
    $ownedDirectory = Join-Path $ArtifactRoot ("delete-select-" + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($ownedDirectory)
    try {
      $directory = if ($case -ceq 'telemetry-write-failure') { Join-Path $ownedDirectory 'absent' } else { $ownedDirectory }
      $DeleteSelectFailureReceipt = Join-Path $directory 'delete-target-select-failure.json'
      if ($case -ceq 'receipt-exists') { [IO.File]::WriteAllText($DeleteSelectFailureReceipt, 'preserved') }
      if ($case -ceq 'receipt-unconfigured') { $DeleteSelectFailureReceipt = '' }
      Assert-MockBindings $deleteTarget $deleteTargetSelection $state
      $original = $null
      try { $deleteTargetSelection.Select() } catch { $original = $_ }
      $state.selects = 0
      Assert-MockBindings $deleteTarget $deleteTargetSelection $state
      $output = @(& { try { & $invokeSelect } catch { $_ } } 6>&1)
      $failures = @($output | Where-Object { $_ -is [Management.Automation.ErrorRecord] })
      $logs = @($output | Where-Object { $_ -is [Management.Automation.InformationRecord] })
      Assert-Delete ($state.selects -eq 1) "$case changed Select count"
      if ($case -ceq 'success') {
        Assert-Delete ($output.Count -eq 0 -and $state.reads -eq 0) 'Success emitted telemetry or sampled properties'
      } else {
        Assert-Delete ($failures.Count -eq 1 -and $failures[0].Exception.GetType() -eq $original.Exception.GetType() -and
          $failures[0].Exception.Message -ceq $original.Exception.Message -and
          $failures[0].Exception.HResult -eq $original.Exception.HResult -and
          $failures[0].FullyQualifiedErrorId -ceq $original.FullyQualifiedErrorId -and
          [object]::ReferenceEquals($failures[0].Exception.GetBaseException(), $state.original.GetBaseException())) `
          "$case changed the original exception"
        $receiptLogs = @($logs | Where-Object { ([string]$_.MessageData).StartsWith('UIA_DELETE_TARGET_SELECT_FAILURE=') })
        Assert-Delete ($receiptLogs.Count -eq 1) "$case missing failure-only receipt"
        $json = ([string]$receiptLogs[0].MessageData).Substring('UIA_DELETE_TARGET_SELECT_FAILURE='.Length)
        Assert-Delete (-not $json.Contains('PRIVATE_')) "$case leaked private values"
        $receipt = $json | ConvertFrom-Json
        Assert-Delete ($receipt.expectedProcessId -eq 4242 -and $receipt.expectedWindow -eq 42) "$case lost owned context"
        Assert-Delete ($state.reads -gt 0 -and $state.reads -le 16) "$case exceeded bounded reads"
        switch -CaseSensitive ($case) {
          unavailable { Assert-Delete ($receipt.processId.state -ceq 'unavailable' -and $receipt.bounds.state -ceq 'unavailable' -and $receipt.selected.state -ceq 'unavailable') 'Unavailable became success' }
          foreign-pid { Assert-Delete ($receipt.processId.value -eq 7777 -and -not $receipt.ownedProcess) 'Foreign PID lost' }
          identity-drift { Assert-Delete (-not $receipt.identityMatches) 'Identity drift lost' }
          runtime-unavailable { Assert-Delete ($receipt.runtimeIdHash.state -ceq 'unavailable') 'Runtime unavailability lost' }
          parent-unavailable { Assert-Delete ($receipt.parent.processId.state -ceq 'unavailable') 'Parent unavailability lost' }
          zero-bounds { Assert-Delete ($receipt.bounds.value.width -eq 0 -and $receipt.bounds.value.height -eq 0) 'Zero bounds lost' }
          offscreen { Assert-Delete ($receipt.offscreen.value -eq $true) 'Offscreen lost' }
          disabled { Assert-Delete ($receipt.enabled.value -eq $false) 'Disabled lost' }
          selected { Assert-Delete ($receipt.selected.value -eq $true) 'Selected state lost' }
          deadline { Assert-Delete ($receipt.runtimeIdHash.state -ceq 'unavailable' -and $receipt.bounds.reason -ceq 'diagnostic-budget' -and $receipt.readCount -eq 3) 'Deadline allowed more reads' }
          long-identity { Assert-Delete ($receipt.automationIdHash.state -ceq 'unavailable' -and $receipt.readCount -eq 2) 'Long identity allowed dependent reads' }
          long-runtime { Assert-Delete ($receipt.runtimeIdHash.state -ceq 'unavailable') 'Long runtime accepted' }
          invalid-boolean { Assert-Delete ($receipt.enabled.state -ceq 'unavailable') 'Invalid boolean accepted' }
          nonfinite-bounds { Assert-Delete ($receipt.bounds.state -ceq 'unavailable') 'Nonfinite bounds accepted' }
          exception-chain { Assert-Delete ($receipt.exceptionChainTruncated -and $receipt.exceptionHResults.Count -eq 4) 'Exception chain not capped' }
          foreign-parent { Assert-Delete ($receipt.parent.processId.value -eq 7777 -and $receipt.parent.controlTypeId.reason -ceq 'untrusted-identity' -and $receipt.readCount -eq 9) 'Foreign parent allowed dependent reads' }
        }
        Assert-Delete ($receipt.readCount -le 11 -and $receipt.readLimit -eq 11 -and $receipt.budgetMilliseconds -eq 500 -and
          $json.Length -le 8192 -and $receipt.exceptionHResults.Count -ge 1 -and $receipt.exceptionHResults.Count -le 4) "$case lost explicit bounds"
        if ($case -cin @('foreign-pid', 'identity-drift', 'unavailable')) {
          Assert-Delete ($receipt.bounds.reason -ceq 'untrusted-identity' -and $receipt.readCount -le 2) "$case sampled dependent state"
        }
        foreach ($unavailable in @('retired', 'active', 'invokable', 'providerBranch')) {
          Assert-Delete ($receipt.$unavailable.state -ceq 'unavailable') 'Private provider state inferred'
        }
        $path = Join-Path $directory 'delete-target-select-failure.json'
        if ($case -cin @('telemetry-write-failure', 'receipt-exists', 'receipt-unconfigured')) {
          Assert-Delete (@($logs | Where-Object { ([string]$_.MessageData).StartsWith('UIA_DELETE_TARGET_SELECT_TELEMETRY_FAILURE=') }).Count -eq 1) 'Receipt write failure hidden'
          if ($case -ceq 'receipt-exists') { Assert-Delete ([IO.File]::ReadAllText($path) -ceq 'preserved') 'Existing receipt overwritten' }
        } else { Assert-Delete ([IO.File]::ReadAllText($path) -ceq $json) 'Raw receipt differs' }
      }
    } finally { [IO.Directory]::Delete($ownedDirectory, $true) }
  }
}
Assert-Delete ($visibilityCases.Count -eq 9 -and $selectCases.Count -eq 21 -and $results.Count -eq 30) 'Wrong positive case count'
Invoke-DeleteCase 'ui.delete.restore.source-order' {
  $restoreDefinitions = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Restore-DeleteLoopCanvas'
  }, $true))
  Assert-Delete ($restoreDefinitions.Count -eq 1) 'Expected one actual Delete canvas restoration helper'
  $selection = $source.IndexOf('$deleteTargetSelection.Select()', [StringComparison]::Ordinal)
  $selected = $source.IndexOf('Require $deleteTargetSelection.Current.IsSelected', $selection, [StringComparison]::Ordinal)
  $restore = $source.IndexOf('Restore-DeleteLoopCanvas $process $root $shellWindow', $selected, [StringComparison]::Ordinal)
  $menu = $source.IndexOf('$deleteLoopPopup = Open-CanvasCardContextMenu', $selected, [StringComparison]::Ordinal)
  Assert-Delete ($selection -ge 0 -and $selected -gt $selection -and $restore -gt $selected -and $menu -gt $restore) `
    'Delete must restore the canvas after the unchanged Select assertion and before the owned pointer route'
  $calls = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Restore-DeleteLoopCanvas'
  }, $true))
  Assert-Delete ($calls.Count -eq 1 -and $calls[0].Extent.Text -match '\$renameGraphIdentity \$rawWalker') `
    'Delete restoration must bind the same renamed card identity and walker exactly once'
}
$restoreCases = @(
  @{ name = 'owned-navigation'; failure = $null; order = 'foreground,wait-route,show,reconnect,lookup:canvas-card-owned,lookup:fit-canvas,fit,wait-card,selected,reconnect' },
  @{ name = 'foreground-refused'; failure = 'Delete Loop could not acquire its owned foreground before Show in Graph'; order = 'foreground' },
  @{ name = 'missing-route'; failure = 'controlled route publication missing'; order = 'foreground,wait-route' },
  @{ name = 'foreign-route'; failure = 'Delete Loop omitted its visible owned Show in Graph action'; order = 'foreground,wait-route' },
  @{ name = 'offscreen-route'; failure = 'Delete Loop omitted its visible owned Show in Graph action'; order = 'foreground,wait-route' },
  @{ name = 'missing-card'; failure = 'Delete Loop lost its same owned card after Show in Graph'; order = 'foreground,wait-route,show,reconnect,lookup:canvas-card-owned' },
  @{ name = 'wrong-card-id'; failure = 'Delete Loop lost its same owned card after Show in Graph'; order = 'foreground,wait-route,show,reconnect,lookup:canvas-card-owned' },
  @{ name = 'foreign-card'; failure = 'Delete Loop lost its same owned card after Show in Graph'; order = 'foreground,wait-route,show,reconnect,lookup:canvas-card-owned' },
  @{ name = 'wrong-fit-id'; failure = 'Delete Loop graph reentry omitted the exact owned Fit Canvas action'; order = 'foreground,wait-route,show,reconnect,lookup:canvas-card-owned,lookup:fit-canvas' },
  @{ name = 'foreign-fit'; failure = 'Delete Loop graph reentry omitted the exact owned Fit Canvas action'; order = 'foreground,wait-route,show,reconnect,lookup:canvas-card-owned,lookup:fit-canvas' },
  @{ name = 'retained-workspace'; failure = 'controlled restored card publication missing'; order = 'foreground,wait-route,show,reconnect,lookup:canvas-card-owned,lookup:fit-canvas,fit,wait-card' },
  @{ name = 'wrong-final-id'; failure = 'controlled restored card publication missing'; order = 'foreground,wait-route,show,reconnect,lookup:canvas-card-owned,lookup:fit-canvas,fit,wait-card' },
  @{ name = 'foreign-final-card'; failure = 'controlled restored card publication missing'; order = 'foreground,wait-route,show,reconnect,lookup:canvas-card-owned,lookup:fit-canvas,fit,wait-card' },
  @{ name = 'offscreen-final-card'; failure = 'controlled restored card publication missing'; order = 'foreground,wait-route,show,reconnect,lookup:canvas-card-owned,lookup:fit-canvas,fit,wait-card' },
  @{ name = 'foreign-final-graph'; failure = 'Delete Loop same card did not return to its visible canvas after Show in Graph and Fit Canvas'; order = 'foreground,wait-route,show,reconnect,lookup:canvas-card-owned,lookup:fit-canvas,fit,wait-card' },
  @{ name = 'lost-selection'; failure = 'Delete Loop Show in Graph changed the selected card identity'; order = 'foreground,wait-route,show,reconnect,lookup:canvas-card-owned,lookup:fit-canvas,fit,wait-card,selected' }
)
foreach ($test in $restoreCases) {
  Invoke-DeleteCase "ui.delete.restore.$($test.name)" {
    $definition = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Restore-DeleteLoopCanvas'
    }, $true))
    Assert-Delete ($definition.Count -eq 1) 'Expected one actual Delete canvas restoration helper'
    & (Join-Path $RepositoryRoot 'Tools\windows\Import-CompiledValidationAssembly.ps1') `
      -AssemblyPath $AssemblyPath -RequiredType 'GraphCodeUiaGateState' | Out-Null
    Assert-Delete ($definition[0].Extent.Text -notmatch '\[GraphCode[^\]]*\]::|SendInput|PostMouse|Start-Process|Add-Type') `
      'Restoration fixture must exercise the production route without direct native effects'
    . ([scriptblock]::Create($definition[0].Extent.Text))
    $state = @{ name = $test.name; order = [Collections.Generic.List[string]]::new(); waits = 0; reconnects = 0 }
    $process = [pscustomobject]@{ Id = 4242 }
    $initialRoot = [pscustomobject]@{ label = 'workspace-root' }
    $restoredRoot = [pscustomobject]@{ label = 'restored-root' }
    $finalRoot = [pscustomobject]@{ label = 'final-root' }
    $ownedWalker = [pscustomobject]@{ fixture = 'owned-walker' }
    function Require([bool] $condition, [string] $message) { if (-not $condition) { throw [InvalidOperationException]::new($message) } }
    function New-RestoreElement([string] $Kind) {
      $id = switch ($Kind) { route { 'workspace-show-graph-owned' } fit { 'fit-canvas' } graph { 'graph' } default { 'canvas-card-owned' } }
      if (($Kind -ceq 'card' -and $state.name -ceq 'wrong-card-id') -or
          ($Kind -ceq 'final-card' -and $state.name -ceq 'wrong-final-id')) { $id = 'canvas-card-foreign' }
      if ($Kind -ceq 'fit' -and $state.name -ceq 'wrong-fit-id') { $id = 'fit-foreign' }
      $owner = if (($Kind -ceq 'route' -and $state.name -ceq 'foreign-route') -or
        ($Kind -ceq 'card' -and $state.name -ceq 'foreign-card') -or
        ($Kind -ceq 'fit' -and $state.name -ceq 'foreign-fit') -or
        ($Kind -ceq 'final-card' -and $state.name -ceq 'foreign-final-card') -or
        ($Kind -ceq 'graph' -and $state.name -ceq 'foreign-final-graph')) { 7777 } else { 4242 }
      $label = switch ($Kind) { route { 'Show in Graph' } fit { 'Fit canvas' } default { 'fixture' } }
      $element = [pscustomobject]@{
        Kind = $Kind; State = $state
        Current = [pscustomobject]@{
          AutomationId = $id; Name = $label; ProcessId = $owner
          IsOffscreen = ($Kind -ceq 'route' -and $state.name -ceq 'offscreen-route') -or
            ($Kind -ceq 'final-card' -and $state.name -ceq 'offscreen-final-card')
        }
      }
      $element | Add-Member ScriptMethod GetCurrentPattern {
        param($pattern)
        if ($this.Kind -cin @('route','fit')) {
          if ($pattern -ne [System.Windows.Automation.InvokePattern]::Pattern) { throw 'Unexpected route pattern' }
          $invoke = [pscustomobject]@{ Kind = $this.Kind; State = $this.State }
          $invoke | Add-Member ScriptMethod Invoke {
            $this.State.order.Add($(if ($this.Kind -ceq 'route') { 'show' } else { 'fit' }))
          }
          return $invoke
        }
        if ($pattern -ne [System.Windows.Automation.SelectionItemPattern]::Pattern -or $this.Kind -cne 'final-card') {
          throw 'Unexpected selection pattern'
        }
        $this.State.order.Add('selected')
        return [pscustomobject]@{ Current = [pscustomobject]@{ IsSelected = $this.State.name -cne 'lost-selection' } }
      }
      return $element
    }
    function Ensure-ShellForeground($Owner, $Label) {
      Assert-Delete ($Owner -eq [IntPtr]42 -and $Label -ceq 'Delete Loop Show in Graph') 'Wrong foreground authority'
      $state.order.Add('foreground')
      return $state.name -cne 'foreground-refused'
    }
    function Wait-ForRootReconnect($Process, $Walkers) {
      Assert-Delete ($Process.Id -eq 4242 -and $Walkers.Count -eq 1 -and [object]::ReferenceEquals($Walkers[0],$ownedWalker)) 'Wrong reconnect authority'
      $state.order.Add('reconnect'); $state.reconnects++
      if ($state.reconnects -eq 1) { return $restoredRoot }
      return $finalRoot
    }
    function Find-FragmentByIdWithRetry($Root, [string] $Id, $Walker) {
      Assert-Delete ([object]::ReferenceEquals($Root,$restoredRoot) -and [object]::ReferenceEquals($Walker,$ownedWalker)) 'Lookup used a stale workspace root'
      $state.order.Add("lookup:$Id")
      if ($Id -ceq 'canvas-card-owned') {
        if ($state.name -ceq 'missing-card') { return $null }
        return New-RestoreElement card
      }
      Assert-Delete ($Id -ceq 'fit-canvas') 'Lookup changed the selected card identity'
      return New-RestoreElement fit
    }
    function Wait-ForGraphChildren($Root, $Walker, [scriptblock] $Filter, [scriptblock] $Ready) {
      Assert-Delete ([object]::ReferenceEquals($Walker,$ownedWalker)) 'Graph wait changed walker'
      $state.waits++
      if ($state.waits -eq 1) {
        Assert-Delete ([object]::ReferenceEquals($Root,$initialRoot)) 'Route wait did not use selected workspace root'
        $state.order.Add('wait-route')
        $children = if ($state.name -ceq 'missing-route') { @() } else { @(New-RestoreElement route) }
        $items = @($children | Where-Object $Filter)
        if (-not (& $Ready $items)) { throw [InvalidOperationException]::new('controlled route publication missing') }
      } else {
        Assert-Delete ($state.waits -eq 2 -and [object]::ReferenceEquals($Root,$restoredRoot)) 'Card wait did not use reconnected graph root'
        $state.order.Add('wait-card')
        $children = @(New-RestoreElement final-card)
        if ($state.name -ceq 'retained-workspace') { $children += New-RestoreElement route }
        $items = @($children | Where-Object $Filter)
        if (-not (& $Ready $items)) { throw [InvalidOperationException]::new('controlled restored card publication missing') }
      }
      return [pscustomobject]@{ Graph = (New-RestoreElement graph); Items = $items; Children = $children }
    }
    $caught = $null
    $actualRoot = $null
    try { $actualRoot = Restore-DeleteLoopCanvas $process $initialRoot ([IntPtr]42) 'canvas-card-owned' $ownedWalker }
    catch { $caught = $_ }
    Assert-Delete (($state.order -join ',') -ceq $test.order) "Restoration observation/action order differs: $($state.order -join ',')"
    if ($null -eq $test.failure) {
      Assert-Delete ($null -eq $caught -and [object]::ReferenceEquals($actualRoot,$finalRoot)) 'Restoration did not return the final freshly reconnected root'
    } else {
      Assert-Delete ($caught -and $caught.Exception.Message -ceq $test.failure -and $null -eq $actualRoot) `
        "Restoration refusal changed: $($caught.Exception.Message)"
    }
  }
}
$stressRemoval = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Remove-Job' -and
    @($node.CommandElements | Where-Object { $_.Extent.Text -ceq '$stressJob' }).Count -eq 1
}, $true) | Sort-Object { $_.Extent.StartOffset })
function Get-StressReleaseStatements {
  Assert-Delete ($stressRemoval.Count -eq 2) 'Expected primary and final owned stress-job removal'
  $remove = $stressRemoval[0].Parent
  while ($remove.Parent -isnot [Management.Automation.Language.StatementBlockAst]) { $remove = $remove.Parent }
  $siblings = @($remove.Parent.Statements)
  $position = [Array]::IndexOf($siblings, $remove)
  Assert-Delete ($position -ge 0 -and $position + 1 -lt $siblings.Count) 'Primary stress removal has no following ownership update'
  $clear = $siblings[$position + 1]
  Assert-Delete ($clear -is [Management.Automation.Language.AssignmentStatementAst] -and
    $clear.Left.Extent.Text -ceq '$stressJob' -and $clear.Right.Extent.Text -ceq '$null') `
    'Successful stress removal must immediately clear its retained job reference'
  return @($remove, $clear)
}
Invoke-DeleteCase 'ui.delete.cleanup.source-order' {
  $statements = @(Get-StressReleaseStatements)
  $guard = $stressRemoval[1].Parent
  while ($null -ne $guard -and $guard -isnot [Management.Automation.Language.IfStatementAst]) { $guard = $guard.Parent }
  Assert-Delete ($stressRemoval[1].Extent.Text -match '-ErrorAction Stop' -and
    $null -ne $guard -and $guard.Clauses.Count -eq 1 -and
    $guard.Clauses[0].Item1.Extent.Text -ceq '$stressJob') 'Final cleanup must retain its live-reference guard and terminating removal'
  Assert-Delete ($statements.Count -eq 2) 'Stress release source statement count changed'
}
foreach ($removalFails in @($false, $true)) {
  $id = if ($removalFails) { 'ui.delete.cleanup.failed-removal-retains' } else { 'ui.delete.cleanup.success-clears' }
  Invoke-DeleteCase $id {
    $statements = @(Get-StressReleaseStatements)
    $state = @{ calls = 0; fail = $removalFails; original = [IO.IOException]::new('controlled stress removal failure') }
    $ownedJob = [pscustomobject]@{ fixture = 'owned-stress-job' }
    $stressJob = $ownedJob
    function Remove-Job {
      param($Job, [switch] $Force)
      Assert-Delete ([object]::ReferenceEquals($Job, $ownedJob) -and $Force) 'Removal did not target the retained owned job'
      $state.calls++
      if ($state.fail) { throw $state.original }
    }
    $caught = $null
    try { . ([scriptblock]::Create(($statements | ForEach-Object { $_.Extent.Text }) -join "`n")) } catch { $caught = $_ }
    Assert-Delete ($state.calls -eq 1) 'Stress removal replayed or was skipped'
    if ($removalFails) {
      Assert-Delete ($caught -and [object]::ReferenceEquals($caught.Exception, $state.original) -and
        [object]::ReferenceEquals($stressJob, $ownedJob)) 'Failed stress removal cleared authority or replaced its original failure'
    } else {
      Assert-Delete ($null -eq $caught -and $null -eq $stressJob) 'Successful stress removal left a stale reference'
    }
  }
}
Assert-Delete ($restoreCases.Count -eq 16 -and $results.Count -eq 50) `
  "Delete restoration and cleanup require twenty additional cases without replacing the original thirty: scenarios=$($restoreCases.Count) results=$($results.Count)"
[IO.File]::WriteAllText((Join-Path $ArtifactRoot 'ui-delete-results.json'), ($results | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
foreach ($result in $results) { Write-Output ('UI_CASE_RESULT=' + ($result | ConvertTo-Json -Compress -Depth 8)) }
if (@($results | Where-Object status -cne 'Passed').Count -ne 0) { exit 1 }
