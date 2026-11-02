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
[IO.File]::WriteAllText((Join-Path $ArtifactRoot 'ui-delete-results.json'), ($results | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
foreach ($result in $results) { Write-Output ('UI_CASE_RESULT=' + ($result | ConvertTo-Json -Compress -Depth 8)) }
if (@($results | Where-Object status -cne 'Passed').Count -ne 0) { exit 1 }
