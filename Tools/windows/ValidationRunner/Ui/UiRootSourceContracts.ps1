param(
  [Parameter(Mandatory)][string] $RepositoryRoot,
  [Parameter(Mandatory)][string] $ArtifactRoot,
  [Parameter(Mandatory)][string] $AssemblyPath
)
$ErrorActionPreference = 'Stop'
$uiRoot = Join-Path $RepositoryRoot 'Tools\windows\ValidationRunner\Ui'
$catalogText = [IO.File]::ReadAllText((Join-Path $uiRoot 'source-assertions.json'))
if ($catalogText.Length -gt 1048576) { throw 'UI source assertion data exceeded its size limit' }
$catalog = @($catalogText | ConvertFrom-Json -Depth 100)
if ($catalog.Count -ne 58) { throw 'Root UI declarative source assertion count must remain 58' }
$paths = @{
  gate = 'Tools\windows\uia-live-gate.ps1'
  stub = 'Tools\windows\Stub-Daemon.ps1'
  validation = 'Tools\windows\validate.ps1'
  shellTests = 'Tools\windows\Tests\WindowsShell.Tests.ps1'
  hardening = 'Tools\windows\Tests\Hardening.Tests.ps1'
  workflow = '.github\workflows\windows-hardening.yml'
  designTokens = 'graphcode-windows\src\DesignTokens.zig'
  laneLayout = 'graphcode-windows\src\LaneLayout.zig'
  graphCanvas = 'graphcode-windows\src\GraphCanvas.zig'
}
$resources = @{}
function Read-SourceResource([string] $Name) {
  if (-not $paths.ContainsKey($Name)) { throw "Undeclared UI source resource: $Name" }
  if (-not $resources.ContainsKey($Name)) {
    $text = [IO.File]::ReadAllText((Join-Path $RepositoryRoot $paths[$Name]))
    if ($Name -ceq 'gate') {
      foreach ($component in @('GraphCodeUiaGateState', 'GraphCodeUiaHostInfo', 'GraphCodeUiaAttribution',
          'GraphCodeMultiProjectRenameNative', 'UiaInputSafety')) {
        $text += "`n" + [IO.File]::ReadAllText((Join-Path $uiRoot "Production\$component.cs"))
      }
    }
    $resources[$Name] = $text
  }
  return $resources[$Name]
}
function Get-AssertionValue($Node, [int] $Depth = 0) {
  if ($Depth -gt 96 -or $null -eq $Node) { throw 'UI source assertion tree is missing or exceeds its depth limit' }
  switch -CaseSensitive ($Node.kind) {
    literal { return $Node.value }
    resource { return Read-SourceResource $Node.name }
    not { return -not (Get-AssertionValue $Node.operand ($Depth + 1)) }
    contains {
      return ([string](Get-AssertionValue $Node.source ($Depth + 1))).Contains([string](Get-AssertionValue $Node.needle ($Depth + 1)))
    }
    binary {
      if ($Node.operator -ceq 'And') { return (Get-AssertionValue $Node.left ($Depth + 1)) -and (Get-AssertionValue $Node.right ($Depth + 1)) }
      if ($Node.operator -ceq 'Or') { return (Get-AssertionValue $Node.left ($Depth + 1)) -or (Get-AssertionValue $Node.right ($Depth + 1)) }
      $left = Get-AssertionValue $Node.left ($Depth + 1)
      $right = Get-AssertionValue $Node.right ($Depth + 1)
      switch -CaseSensitive ($Node.operator) {
        Imatch { return $left -match $right }
        Inotmatch { return $left -notmatch $right }
        Cmatch { return $left -cmatch $right }
        Cnotmatch { return $left -cnotmatch $right }
        Ieq { return $left -eq $right }
        Ine { return $left -ne $right }
        Ceq { return $left -ceq $right }
        Cne { return $left -cne $right }
        Igt { return $left -gt $right }
        Ige { return $left -ge $right }
        Ilt { return $left -lt $right }
        Ile { return $left -le $right }
        default { throw "Unknown declarative source assertion operator: $($Node.operator)" }
      }
    }
    default { throw "Unknown declarative source assertion kind: $($Node.kind)" }
  }
}
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$results = [Collections.Generic.List[object]]::new()
function Invoke-EvaluatorControl([string] $Name, [scriptblock] $Assertion) {
  $failure = $null
  try { & $Assertion } catch { $failure = $_ }
  $results.Add([ordered]@{
    id = "ui.root.evaluator.$Name"; status = $(if ($failure) { 'Failed' } else { 'Passed' }); executedCount = 1
    evidence = $(if ($failure) { $failure.ToString() } else { 'Bounded source evaluator negative control; nativeCalls=0' })
  })
}
function Assert-EvaluatorRefusal([scriptblock] $Action) {
  $refused = $false
  try { $null = & $Action } catch { $refused = $true }
  if (-not $refused) { throw 'Malformed source assertion did not fail closed' }
}
Invoke-EvaluatorControl 'unknown-operator' {
  Assert-EvaluatorRefusal { Get-AssertionValue @{ kind = 'binary'; operator = 'execute'; left = @{ kind = 'literal'; value = 1 }; right = @{ kind = 'literal'; value = 1 } } }
}
Invoke-EvaluatorControl 'unknown-resource' {
  Assert-EvaluatorRefusal { Get-AssertionValue @{ kind = 'resource'; name = 'not-a-production-resource' } }
}
Invoke-EvaluatorControl 'missing-file' {
  $paths['missing-control'] = 'Tools\windows\ValidationRunner\.local\absent-source-oracle-control'
  try {
    Assert-EvaluatorRefusal { Get-AssertionValue @{ kind = 'resource'; name = 'missing-control' } }
  } finally { $paths.Remove('missing-control') }
}
Invoke-EvaluatorControl 'malformed-tree' {
  Assert-EvaluatorRefusal { Get-AssertionValue @{ kind = 'binary'; operator = 'Imatch'; left = $null; right = @{ kind = 'literal'; value = 'anything' } } }
}
Invoke-EvaluatorControl 'depth-boundary' {
  $tree = @{ kind = 'literal'; value = $false }
  for ($level = 0; $level -lt 96; $level++) { $tree = @{ kind = 'not'; operand = $tree } }
  if (Get-AssertionValue $tree) { throw 'Allowed-depth assertion changed its boolean result' }
}
Invoke-EvaluatorControl 'depth-overflow' {
  $tree = @{ kind = 'literal'; value = $false }
  for ($level = 0; $level -lt 97; $level++) { $tree = @{ kind = 'not'; operand = $tree } }
  Assert-EvaluatorRefusal { Get-AssertionValue $tree }
}
function Test-OnlyGateResource($Node) {
  switch -CaseSensitive ($Node.kind) {
    resource { return $Node.name -ceq 'gate' }
    literal { return $true }
    binary { return (Test-OnlyGateResource $Node.left) -and (Test-OnlyGateResource $Node.right) }
    not { return Test-OnlyGateResource $Node.operand }
    contains { return (Test-OnlyGateResource $Node.source) -and (Test-OnlyGateResource $Node.needle) }
    default { throw 'Unexpected node in evaluator control' }
  }
}
$control = @($catalog | Where-Object { Test-OnlyGateResource $_.condition })[0]
Invoke-EvaluatorControl 'actual-predicate-false' {
  if ($null -eq $control -or (Get-AssertionValue $control.condition)) { throw 'Actual original production predicate did not evaluate false' }
}
Invoke-EvaluatorControl 'wrong-production-text' {
  $actual = Read-SourceResource 'gate'
  try {
    $resources['gate'] = 'deliberately wrong production source'
    if (-not (Get-AssertionValue $control.condition)) { throw 'Source assertion accepted deliberately wrong production text' }
  } finally { $resources['gate'] = $actual }
}
foreach ($test in $catalog) {
  if (-not $seen.Add($test.id)) { throw "Duplicate source assertion ID: $($test.id)" }
  $failure = $null
  try {
    if (Get-AssertionValue $test.condition) { throw [InvalidOperationException]::new($test.diagnostic) }
  } catch { $failure = $_ }
  $results.Add([ordered]@{
    id = $test.id; status = $(if ($failure) { 'Failed' } else { 'Passed' }); executedCount = 1
    evidence = $(if ($failure) { $failure.ToString() } else { "Actual production source; original PS operators; source lines $($test.sourceLines); nativeCalls=0" })
  })
}
$null = [IO.Directory]::CreateDirectory($ArtifactRoot)
[IO.File]::WriteAllText((Join-Path $ArtifactRoot 'ui-root-source-results.json'),
  ($results | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
foreach ($result in $results) { Write-Output ('UI_CASE_RESULT=' + ($result | ConvertTo-Json -Compress -Depth 8)) }
if (@($results | Where-Object status -cne 'Passed').Count -ne 0) { exit 1 }
