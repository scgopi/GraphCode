param(
  [Parameter(Mandatory)] [string] $RepositoryRoot,
  [Parameter(Mandatory)] [string] $ArtifactRoot,
  [Parameter(Mandatory)] [string] $AssemblyPath
)
$ErrorActionPreference = 'Stop'
$null = [Reflection.Assembly]::LoadFrom($AssemblyPath)
$null = [Reflection.Assembly]::LoadFrom((Join-Path (Split-Path $AssemblyPath -Parent) 'WindowsValidationBindings.dll'))
$exitCode = 1
try {
  $context = [GraphCode.Validation.ValidationContext]::new($RepositoryRoot, $ArtifactRoot)
  $suites = [GraphCode.Validation.Host.RootContracts.ResidualScopeRegistration]::CreateSuites()
  if ($suites.Count -ne 1) { throw 'Residual registration must expose exactly one suite' }
  $rows = $suites[0].RunAsync($context, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
  $rows | ConvertTo-Json -Depth 8 -Compress | Write-Output
  if ($rows.Count -eq 1 -and $rows[0].Status -eq 'Passed' -and $rows[0].ExecutedCount -eq 16) {
    $exitCode = 0
    Write-Output 'RESIDUAL_FOCUSED_PASSED=16'
  }
} finally {
  $null = [GraphCode.Validation.Host.TerminalSafety]::PreserveRetainedAuthorityAsync(
    [GraphCode.Validation.Ownership.OwnedChildSupervisor]::RetainedLeaseCount).GetAwaiter().GetResult()
}
exit $exitCode
