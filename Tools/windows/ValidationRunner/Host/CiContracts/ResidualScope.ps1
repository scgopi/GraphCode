param([Parameter(Mandatory)] [string] $RepositoryRoot,
  [Parameter(Mandatory)] [string] $ArtifactRoot, [string] $AssemblyPath)
. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')

function Read-ResidualTree([string] $Source) {
  $tokens = $null
  $errors = $null
  $tree = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
  Assert-Root ($errors.Count -eq 0) 'Production wiring source does not parse'
  return $tree
}

function Get-ResidualTaskClause($Tree, [string] $Name) {
  $switches = @($Tree.FindAll({
    param($node)
    $node -is [Management.Automation.Language.SwitchStatementAst]
  }, $true))
  $matches = @($switches.Clauses | Where-Object { $_.Item1.Value -ceq $Name })
  Assert-Root ($matches.Count -eq 1) "Expected exactly one $Name task clause"
  return $matches[0].Item2
}

function Get-ResidualGuard($Clause, [string] $ExcludedPart) {
  $expected = '$PackagingPart -ne "' + $ExcludedPart + '"'
  $guards = @($Clause.FindAll({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
      $node.Clauses.Count -eq 1 -and $node.Clauses[0].Item1.Extent.Text -ceq $expected
  }, $true))
  Assert-Root ($guards.Count -eq 1) "Missing unique packaging part guard excluding $ExcludedPart"
  return $guards[0].Clauses[0].Item2
}

function Get-ResidualScriptCall($Tree, [string] $RelativePath) {
  $expected = '(Join-Path $repoRoot "' + $RelativePath + '")'
  $calls = @($Tree.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
      $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand -and
      $node.CommandElements[0].Extent.Text -ceq $expected
  }, $true))
  Assert-Root ($calls.Count -eq 1) "Missing or duplicated actual script invocation: $RelativePath"
  return $calls[0]
}

function Assert-ResidualPackagingContract($Tree, [string] $File) {
  $clause = Get-ResidualTaskClause $Tree 'packaging'
  $contracts = Get-ResidualGuard $clause 'real'
  $real = Get-ResidualGuard $clause 'contracts'
  $contract = Get-ResidualScriptCall $contracts "Tools\windows\Tests\$File"
  $package = Get-ResidualScriptCall $real 'Tools\windows\Tests\Packaging.Tests.ps1'
  Assert-Root ($contract.Parent.Parent -eq $contracts -and
    $contract.Extent.EndOffset -lt $package.Extent.StartOffset) 'Packaging contract must be a direct part-guarded invocation before real packaging'
}

function Assert-ResidualRealPackaging($Tree) {
  $clause = Get-ResidualTaskClause $Tree 'packaging'
  $real = Get-ResidualGuard $clause 'contracts'
  $initializers = @($real.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Initialize-PackagingInputs'
  }, $true))
  $package = Get-ResidualScriptCall $real 'Tools\windows\Tests\Packaging.Tests.ps1'
  Assert-Root ($initializers.Count -eq 1 -and $initializers[0].Parent.Parent -eq $real -and
    $package.Parent.Parent -eq $real -and $initializers[0].Extent.EndOffset -lt $package.Extent.StartOffset) `
    'Real packaging must initialize its own inputs before its actual test invocation'
}

function Assert-ResidualMutation([string] $Source, [string] $Before, [string] $After, [scriptblock] $Predicate) {
  $mutant = $Source.Replace($Before, $After)
  Assert-Root ($mutant -cne $Source) 'Residual source mutation did not apply'
  $rejected = $false
  try { & $Predicate (Read-ResidualTree $mutant) } catch { $rejected = $true }
  Assert-Root $rejected 'Residual source wiring guard accepted a deliberate negative control'
}

$runnerSource = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'Tools\windows\validate.ps1') -Raw
$runnerTree = Read-ResidualTree $runnerSource
$contracts = [ordered]@{
  signing = 'Packaging.Signing.Tests.ps1'
  rollback = 'Packaging.Rollback.Tests.ps1'
  standalone = 'Packaging.Standalone.Tests.ps1'
  script_signing = 'Packaging.ScriptSigning.Tests.ps1'
  scheduler = 'Packaging.Scheduler.Tests.ps1'
  uninstall = 'Packaging.Uninstall.Tests.ps1'
}
foreach ($entry in $contracts.GetEnumerator()) {
  Test-RootCase "source.packaging.$($entry.Key)" { Assert-ResidualPackagingContract $runnerTree $entry.Value }
  Test-RootCase "control.packaging.$($entry.Key).missing-call" {
    Assert-ResidualMutation $runnerSource $entry.Value ('Disabled.' + $entry.Value) {
      param($tree)
      Assert-ResidualPackagingContract $tree $entry.Value
    }
  }
}
Test-RootCase 'source.packaging.real-input-order' { Assert-ResidualRealPackaging $runnerTree }
Test-RootCase 'control.packaging.real-missing-initialization' {
  Assert-ResidualMutation $runnerSource 'Initialize-PackagingInputs' 'Disabled-PackagingInputs' {
    param($tree)
    Assert-ResidualRealPackaging $tree
  }
}
Test-RootCase 'control.packaging.wrong-part-guard' {
  Assert-ResidualMutation $runnerSource '$PackagingPart -ne "real"' '$PackagingPart -eq "real"' {
    param($tree)
    Assert-ResidualPackagingContract $tree 'Packaging.Signing.Tests.ps1'
  }
}
Test-RootCase 'control.packaging.comment-is-not-invocation' {
  $call = '& (Join-Path $repoRoot "Tools\windows\Tests\Packaging.Signing.Tests.ps1")'
  Assert-ResidualMutation $runnerSource $call ("# " + $call) {
    param($tree)
    Assert-ResidualPackagingContract $tree 'Packaging.Signing.Tests.ps1'
  }
}
Write-RootSummary 'host.root-source-scope-mock-environment-error-streams'
