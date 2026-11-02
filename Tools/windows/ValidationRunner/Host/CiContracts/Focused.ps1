param(
  [Parameter(Mandatory)] [string] $RepositoryRoot,
  [Parameter(Mandatory)] [string] $ArtifactRoot,
  [Parameter(Mandatory)] [string] $AssemblyPath,
  [string] $Suite
)
$ErrorActionPreference = 'Stop'
$null = [Reflection.Assembly]::LoadFrom($AssemblyPath)
$exitCode = 1
try {
  $context = [GraphCode.Validation.ValidationContext]::new($RepositoryRoot, $ArtifactRoot)
  $suites = @([GraphCode.Validation.Host.RootContracts.SuiteRegistration]::CreateSuites())
  if ($Suite) {
    $suites = @($suites | Where-Object Id -CEQ $Suite)
    if ($suites.Count -ne 1) { throw "Unknown root suite: $Suite" }
  }
  $results = [Collections.Generic.List[object]]::new()
  foreach ($executor in $suites) {
    $rows = $executor.RunAsync($context, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    foreach ($row in $rows) {
      $results.Add($row)
      $row | ConvertTo-Json -Depth 8 -Compress | Write-Output
    }
  }
  if ($results.Count -eq $suites.Count -and @($results | Where-Object { $_.Status -ne 'Passed' -or $_.ExecutedCount -le 0 }).Count -eq 0) {
    $exitCode = 0
    Write-Output "ROOT_FOCUSED_PASSED=$($results.Count)"
  }
} finally {
  $null = [GraphCode.Validation.Host.TerminalSafety]::PreserveRetainedAuthorityAsync(
    [GraphCode.Validation.Ownership.OwnedChildSupervisor]::RetainedLeaseCount).GetAwaiter().GetResult()
}
exit $exitCode
