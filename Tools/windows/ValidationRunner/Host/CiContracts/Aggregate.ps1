param([Parameter(Mandatory)] [string] $RepositoryRoot,
  [Parameter(Mandatory)] [string] $ArtifactRoot, [string] $AssemblyPath)
. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')
$gate = Join-Path $RepositoryRoot 'Tools\windows\Assert-CiPartResults.ps1'
$cases = @(
  @{ Id = 'required.success'; Required = 'true'; Changes = 'success'; A = 'success'; B = 'success'; Pass = $true }
  @{ Id = 'required.skipped'; Required = 'true'; Changes = 'success'; A = 'success'; B = 'skipped'; Pass = $false }
  @{ Id = 'required.failure'; Required = 'true'; Changes = 'failure'; A = 'success'; B = 'failure'; Pass = $false }
  @{ Id = 'required.cancelled'; Required = 'true'; Changes = 'success'; A = 'cancelled'; B = 'success'; Pass = $false }
  @{ Id = 'not-required.skipped'; Required = 'false'; Changes = 'success'; A = 'skipped'; B = 'skipped'; Pass = $true }
  @{ Id = 'not-required.failure'; Required = 'false'; Changes = 'success'; A = 'failure'; B = 'skipped'; Pass = $false }
  @{ Id = 'not-required.classifier-failure'; Required = 'false'; Changes = 'failure'; A = 'skipped'; B = 'skipped'; Pass = $false }
  @{ Id = 'invalid-requirement'; Required = 'unknown'; Changes = 'success'; A = 'success'; B = 'success'; Pass = $false }
)
foreach ($case in $cases) {
  Test-RootCase $case.Id {
    $needs = [ordered]@{
      changes = @{ result = $case.Changes; outputs = @{} }
      a = @{ result = $case.A; outputs = @{} }
      b = @{ result = $case.B; outputs = @{} }
    } | ConvertTo-Json -Depth 4 -Compress
    $accepted = $true
    try { & $gate -NeedsJson $needs -Required $case.Required | Out-Null } catch { $accepted = $false }
    Assert-Root ($accepted -eq $case.Pass) "Aggregate decision changed for $($case.Id)"
  }
}
Test-RootCase 'empty-parts' {
  $accepted = $true
  try { & $gate -NeedsJson '{"changes":{"result":"success"}}' -Required true | Out-Null } catch { $accepted = $false }
  Assert-Root (-not $accepted) 'Empty aggregate passed'
}
Write-RootSummary 'host.ci-aggregate'
