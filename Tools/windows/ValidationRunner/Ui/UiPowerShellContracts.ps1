param(
  [Parameter(Mandatory)][string] $RepositoryRoot,
  [Parameter(Mandatory)][string] $ArtifactRoot,
  [Parameter(Mandatory)][string] $AssemblyPath
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$null = [IO.Directory]::CreateDirectory($ArtifactRoot)
& (Join-Path $RepositoryRoot 'Tools\windows\Import-CompiledValidationAssembly.ps1') `
  -AssemblyPath $AssemblyPath -RequiredType 'GraphCodeUiaGateState' | Out-Null
$source = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'Tools\windows\uia-live-gate.ps1'))
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$errors)
if ($errors.Count -ne 0) { throw 'Actual production UIA gate does not parse' }
$results = [Collections.Generic.List[object]]::new()

function Assert-UiContract([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw [InvalidOperationException]::new($Message) }
}
function Invoke-UiCase([string] $Id, [scriptblock] $Assertion) {
  $failure = $null
  try { & $Assertion } catch { $failure = $_ }
  $results.Add([ordered]@{
    id = $Id; status = $(if ($failure) { 'Failed' } else { 'Passed' }); executedCount = 1
    evidence = $(if ($failure) { $failure.ToString() } else { 'Real production PowerShell functions with deliberate PSCustomObject fixture; nativeCalls=0' })
  })
}
function Get-ProductionDefinition([string] $Name) {
  $definitions = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
  }, $true))
  Assert-UiContract ($definitions.Count -eq 1) "Expected one production function: $Name"
  return $definitions[0].Extent.Text
}
function Invoke-IsolatedUiMock([scriptblock] $Action) {
  $name = 'GRAPHCODE_VALIDATION_ROOT'
  $before = [Environment]::GetEnvironmentVariables('Process')
  try {
    if ($before.Contains($name)) { Remove-Item -LiteralPath "Env:\$name" -ErrorAction Stop }
    & $Action 6>&1 | ForEach-Object {
      if ([string]$_ -ceq 'GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven') {
        Write-Host 'UIA_MOCK_RETENTION_SIGNAL=observed'
      } elseif ($_ -is [Management.Automation.InformationRecord]) {
        Write-Host $_.MessageData
      } else { $_ }
    }
  } finally {
    if ($before.Contains($name)) { [Environment]::SetEnvironmentVariable($name, $before[$name], 'Process') }
    elseif (Test-Path -LiteralPath "Env:\$name") { Remove-Item -LiteralPath "Env:\$name" -ErrorAction Stop }
  }
}
$originalEnvironment = [Environment]::GetEnvironmentVariables('Process')
try {
  foreach ($membership in @('absent', 'empty', 'valued')) {
    Invoke-UiCase "ui.mock.isolation.$membership" {
      if ($membership -ceq 'absent') {
        if (Test-Path Env:\GRAPHCODE_VALIDATION_ROOT) { Remove-Item Env:\GRAPHCODE_VALIDATION_ROOT }
      } else {
        [Environment]::SetEnvironmentVariable('GRAPHCODE_VALIDATION_ROOT',
          $(if ($membership -ceq 'empty') { '' } else { $ArtifactRoot }), 'Process')
      }
      $before = [Environment]::GetEnvironmentVariables('Process')
      $messages = @(Invoke-IsolatedUiMock {
        Assert-UiContract (-not [Environment]::GetEnvironmentVariables('Process').Contains('GRAPHCODE_VALIDATION_ROOT')) `
          'Mock retained enclosing validation-root authority'
        Write-Host 'GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven'
        Write-Output 'mock-case-passed'
      } 6>&1 | ForEach-Object { [string]$_ })
      $after = [Environment]::GetEnvironmentVariables('Process')
      Assert-UiContract ($messages -notcontains 'GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven' -and
        $messages -contains 'UIA_MOCK_RETENTION_SIGNAL=observed' -and $messages -contains 'mock-case-passed' -and
        $before.Contains('GRAPHCODE_VALIDATION_ROOT') -eq $after.Contains('GRAPHCODE_VALIDATION_ROOT') -and
        (-not $before.Contains('GRAPHCODE_VALIDATION_ROOT') -or
          [string]$before['GRAPHCODE_VALIDATION_ROOT'] -ceq [string]$after['GRAPHCODE_VALIDATION_ROOT']) -and
        -not (Test-Path -LiteralPath (Join-Path $ArtifactRoot 'ownership-unproven.json'))) `
        "UIA mock fixture leaked retention intent or changed environment membership: $membership"
    }
  }
  Invoke-UiCase 'ui.mock.isolation.failure-identity' {
    $expected = [IO.IOException]::new('real mock assertion failure')
    $failure = $null
    try { Invoke-IsolatedUiMock { throw $expected } } catch { $failure = $_ }
    Assert-UiContract ($failure -and [object]::ReferenceEquals($failure.Exception, $expected)) `
      'UIA mock fixture swallowed or replaced a genuine assertion failure'
  }
  Invoke-UiCase 'ui.mock.isolation.ordinary-diagnostic' {
    $text = 'prefix GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven'
    $output = @(Invoke-IsolatedUiMock { Write-Output $text })
    Assert-UiContract ($output.Count -eq 1 -and $output[0] -ceq $text) 'UIA fixture filtered ordinary diagnostic output'
  }
} finally {
  if ($originalEnvironment.Contains('GRAPHCODE_VALIDATION_ROOT')) {
    [Environment]::SetEnvironmentVariable('GRAPHCODE_VALIDATION_ROOT', $originalEnvironment['GRAPHCODE_VALIDATION_ROOT'], 'Process')
  } elseif (Test-Path Env:\GRAPHCODE_VALIDATION_ROOT) { Remove-Item Env:\GRAPHCODE_VALIDATION_ROOT }
}

$recoveryDefinition = Get-ProductionDefinition 'Wait-UiaUnwiredRecoveryVisibility'
$marker = $source.IndexOf('  $unwiredRecoveryChildren = @(Get-DirectChildren $graph $rawWalker)', [StringComparison]::Ordinal)
Assert-UiContract ($marker -ge 0) 'Recovery visibility region missing'
$regionStart = $source.LastIndexOf('  $graph = Find-FragmentByIdWithRetry $root "graph" $rawWalker', $marker, [StringComparison]::Ordinal)
$regionEnd = $source.IndexOf('  $wireAutomationId =', $marker, [StringComparison]::Ordinal)
Assert-UiContract ($regionStart -ge 0 -and $regionEnd -gt $regionStart) 'Recovery visibility region boundary missing'
$visibilityScene = [scriptblock]::Create($source.Substring($regionStart, $regionEnd - $regionStart))

function Require([bool] $condition, [string] $message) { Assert-UiContract $condition $message }
function Start-Sleep { param([int] $Milliseconds) $state.sleeps++ }
function New-RecoveryElement([string] $Kind, [bool] $Initial) {
  $identity = switch ($Kind) { wire { 'wire-node-owned' } mark { 'mark-entry-owned' } graph { 'graph' } fit { 'fit-canvas' } }
  $label = switch ($Kind) { wire { 'Wire it up' } mark { 'Mark as entry' } graph { 'Graph' } fit { 'Fit canvas' } }
  $owner = 4242
  if (($Initial -and $Kind -ceq 'wire' -and $state.name -ceq 'wrong-source-owner') -or
      ($Kind -ceq 'fit' -and $state.name -ceq 'wrong-fit-owner') -or
      (-not $Initial -and $Kind -ceq 'wire' -and $state.name -ceq 'wrong-owner-after-fit')) { $owner = 7777 }
  if (-not $Initial -and $Kind -ceq 'wire' -and $state.name -ceq 'wrong-id-after-fit') { $identity = 'wire-node-foreign' }
  $offscreen = ($Kind -ceq 'fit' -and $state.name -ceq 'fit-offscreen') -or
    ($Kind -cin @('wire', 'mark') -and
      (($Initial -and $state.name -ceq 'initially-offscreen') -or
       (-not $Initial -and $state.name -ceq 'remains-offscreen') -or
       (-not $Initial -and $state.name -ceq 'delayed-visible' -and $state.reconnects -lt 3)))
  $left = if ($Kind -ceq 'mark') { 200 } else { 100 }
  $box = [pscustomobject]@{ Left = $left; Top = 100; Right = $left + 80; Bottom = 130; Width = 80; Height = 30; IsEmpty = $false }
  if ($Kind -ceq 'graph') {
    $box = [pscustomobject]@{ Left = 0; Top = 0; Right = 600; Bottom = 400; Width = 600; Height = 400; IsEmpty = $false }
  } elseif ($Kind -cin @('wire', 'mark')) {
    $empty = ($Initial -and $state.name -cne 'already-visible' -and $state.name -cne 'outside-before-fit' -and
      ($state.name -cne 'mark-only-empty' -or $Kind -ceq 'mark')) -or
      (-not $Initial -and $state.name -ceq 'remains-empty')
    if ($empty) { $box = [pscustomobject]@{ Left = 0; Top = 0; Right = 0; Bottom = 0; Width = 0; Height = 0; IsEmpty = $true } }
    if ($Kind -ceq 'wire' -and (($Initial -and $state.name -ceq 'outside-before-fit') -or
        (-not $Initial -and $state.name -ceq 'outside-after-fit'))) {
      $box = [pscustomobject]@{ Left = -10; Top = 100; Right = 70; Bottom = 130; Width = 80; Height = 30; IsEmpty = $false }
    }
  }
  $current = [pscustomobject]@{
    AutomationId = $identity; Name = $label; ProcessId = $owner; IsOffscreen = $offscreen
    IsEnabled = -not ($Kind -ceq 'fit' -and $state.name -ceq 'fit-disabled')
    ControlType = [System.Windows.Automation.ControlType]::Button; Box = $box; State = $state
  }
  $current | Add-Member ScriptProperty BoundingRectangle {
    if ($this.IsOffscreen) { $this.State.offscreenBoundsReads++; throw 'Offscreen recovery bounds were read' }
    $this.State.boundsReads++
    return $this.Box
  }
  $element = [pscustomobject]@{ Current = $current; State = $state; Kind = $Kind }
  $element | Add-Member ScriptMethod GetCurrentPattern {
    param($pattern)
    if ($pattern -ne [System.Windows.Automation.InvokePattern]::Pattern) { throw 'Unexpected recovery pattern' }
    if ($this.Kind -ceq 'fit') { return $this.State.fitPattern }
    $this.State.patternReads++
    return $this.State.actionPattern
  }
  return $element
}
function Get-DirectChildren($graph, $walker) { @(New-RecoveryElement wire $true; New-RecoveryElement mark $true) }
function Find-FragmentByIdWithRetry($root, [string] $id, $walker) {
  switch -CaseSensitive ($id) { graph { New-RecoveryElement graph $true } fit-canvas { New-RecoveryElement fit $true }
    default { throw "Unexpected initial recovery lookup: $id" } }
}
function Wait-ForRootReconnect($process, $walkers) {
  Assert-UiContract ($process.Id -eq 4242) 'Foreign recovery root reconnect'
  $state.reconnects++
  return $root
}
function Find-FragmentById($root, [string] $id, $walker) {
  if ($id -ceq 'graph') { return New-RecoveryElement graph $false }
  Assert-UiContract ($id -cin @('wire-node-owned', 'mark-entry-owned')) "Recovery reacquisition requested a different ID: $id"
  $state.targetLookups++
  if ($state.name -ceq 'missing-after-fit' -and $id -ceq 'wire-node-owned') { return $null }
  return New-RecoveryElement $(if ($id -ceq 'wire-node-owned') { 'wire' } else { 'mark' }) $false
}
$recoveryCases = @(
  @{ name = 'initially-empty'; expected = $true; fits = 1; reconnects = 1 },
  @{ name = 'initially-offscreen'; expected = $true; fits = 1; reconnects = 1 },
  @{ name = 'already-visible'; expected = $true; fits = 0; reconnects = 0 },
  @{ name = 'mark-only-empty'; expected = $true; fits = 1; reconnects = 1 },
  @{ name = 'delayed-visible'; expected = $true; fits = 1; reconnects = 3 },
  @{ name = 'outside-before-fit'; expected = $true; fits = 1; reconnects = 1 },
  @{ name = 'wrong-source-owner'; expected = $false; fits = 0; reconnects = 0 },
  @{ name = 'wrong-fit-owner'; expected = $false; fits = 0; reconnects = 0 },
  @{ name = 'fit-offscreen'; expected = $false; fits = 0; reconnects = 0 },
  @{ name = 'fit-disabled'; expected = $false; fits = 0; reconnects = 0 },
  @{ name = 'remains-empty'; expected = $false; fits = 1; reconnects = 40 },
  @{ name = 'remains-offscreen'; expected = $false; fits = 1; reconnects = 40 },
  @{ name = 'wrong-id-after-fit'; expected = $false; fits = 1; reconnects = 40 },
  @{ name = 'wrong-owner-after-fit'; expected = $false; fits = 1; reconnects = 40 },
  @{ name = 'outside-after-fit'; expected = $false; fits = 1; reconnects = 40 },
  @{ name = 'missing-after-fit'; expected = $false; fits = 1; reconnects = 40 }
)
function Confirm-RecoveryCase($Case, [string] $Definition) {
  . ([scriptblock]::Create($Definition))
  $state = @{ name = $Case.name; fits = 0; reconnects = 0; targetLookups = 0; patternReads = 0
    boundsReads = 0; offscreenBoundsReads = 0; recoveryInvokes = 0; sleeps = 0 }
  $state.fitPattern = [pscustomobject]@{ State = $state }
  $state.fitPattern | Add-Member ScriptMethod Invoke { $this.State.fits++ }
  $state.actionPattern = [pscustomobject]@{ State = $state }
  $state.actionPattern | Add-Member ScriptMethod Invoke { $this.State.recoveryInvokes++; throw 'Visibility contract must not invoke a recovery action' }
  $process = [pscustomobject]@{ Id = 4242 }
  $root = [pscustomobject]@{ Owner = 4242 }
  $rawWalker = [pscustomobject]@{ Mocked = $true }
  $failure = $null
  try { $null = & $visibilityScene } catch { $failure = $_ }
  $passed = ($null -eq $failure) -eq $Case.expected -and $state.fits -eq $Case.fits -and
    $state.reconnects -eq $Case.reconnects -and $state.offscreenBoundsReads -eq 0 -and $state.recoveryInvokes -eq 0 -and
    $state.patternReads -eq $(if ($Case.expected) { 2 } else { 0 }) -and $state.targetLookups -eq (2 * $Case.reconnects)
  if (-not $Case.expected) {
    $expectedDiagnostic = if ($Case.name -ceq 'wrong-source-owner') {
      'Unwired recovery source controls did not belong to the owned graph'
    } elseif ($Case.fits -eq 0) { 'Unwired recovery could not acquire the owned visible Fit canvas action' }
    else { 'Unwired recovery actions remained unavailable after Fit canvas' }
    $passed = $passed -and $failure -and $failure.Exception.Message -ceq $expectedDiagnostic
  }
  return [pscustomobject]@{
    passed = [bool]$passed
    name = $Case.name
    expectedAccepted = $Case.expected
    actualAccepted = ($null -eq $failure)
    expectedFits = $Case.fits
    expectedReconnects = $Case.reconnects
    actual = [ordered]@{
      fits = $state.fits; reconnects = $state.reconnects; targetLookups = $state.targetLookups
      patternReads = $state.patternReads; boundsReads = $state.boundsReads
      offscreenBoundsReads = $state.offscreenBoundsReads; recoveryInvokes = $state.recoveryInvokes; sleeps = $state.sleeps
    }
    failure = $(if ($failure) { $failure.Exception.ToString() } else { $null })
  }
}
foreach ($case in $recoveryCases) {
  Invoke-UiCase "ui.recovery.visibility.$($case.name)" {
    $observation = Confirm-RecoveryCase $case $recoveryDefinition
    Assert-UiContract $observation.passed ("Recovery visibility behavior differs: " +
      ($observation | ConvertTo-Json -Compress -Depth 6 -EscapeHandling EscapeNonAscii))
  }
}
foreach ($mutant in @(
  @{ name = 'skip-fit'; case = 'initially-empty'; old = ').Invoke()'; replacement = ') | Out-Null' },
  @{ name = 'unsafe-offscreen-bounds'; case = 'initially-offscreen'; old = 'if ($control.Current.IsOffscreen) { return $false }'; replacement = 'if ($false) { return $false }' },
  @{ name = 'wrong-identity-accepted'; case = 'wrong-id-after-fit'; old = '$wire.Current.AutomationId -cne $wireId -or'; replacement = '$false -or' },
  @{ name = 'outside-bounds-accepted'; case = 'outside-after-fit'; old = '$bounds.Left -lt $graphBounds.Left -or'; replacement = '$false -or' }
)) {
  Invoke-UiCase "ui.recovery.visibility.mutant-$($mutant.name)" {
    $case = $recoveryCases | Where-Object name -CEQ $mutant.case
    $baseline = Confirm-RecoveryCase $case $recoveryDefinition
    Assert-UiContract $baseline.passed ("Recovery mutant requires a valid unmodified baseline: " +
      ($baseline | ConvertTo-Json -Compress -Depth 6 -EscapeHandling EscapeNonAscii))
    Assert-UiContract ([regex]::Matches($recoveryDefinition, [regex]::Escape($mutant.old)).Count -eq 1) 'Recovery mutation anchor is not unique'
    $definition = $recoveryDefinition.Replace($mutant.old, $mutant.replacement)
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($definition, [ref]$null, [ref]$parseErrors)
    Assert-UiContract ($parseErrors.Count -eq 0) 'Recovery mutant parser failure'
    $observation = Confirm-RecoveryCase $case $definition
    Assert-UiContract (-not $observation.passed) ("Recovery mutant unexpectedly preserved visibility contract: " +
      ($observation | ConvertTo-Json -Compress -Depth 6 -EscapeHandling EscapeNonAscii))
  }
}
Assert-UiContract ($results.Count -eq 25) 'PowerShell UI fixture requires five isolation and twenty recovery cases'
[IO.File]::WriteAllText((Join-Path $ArtifactRoot 'ui-powershell-results.json'),
  ($results | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
foreach ($result in $results) { Write-Output ('UI_CASE_RESULT=' + ($result | ConvertTo-Json -Compress -Depth 8 -EscapeHandling EscapeNonAscii)) }
if (@($results | Where-Object status -cne 'Passed').Count -ne 0) { exit 1 }
