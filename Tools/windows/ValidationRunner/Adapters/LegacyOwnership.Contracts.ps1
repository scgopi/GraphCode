param(
  [Parameter(Mandatory)][string] $RepositoryRoot,
  [Parameter(Mandatory)][string] $ArtifactRoot,
  [Parameter(Mandatory)][string] $AssemblyPath,
  [Parameter(Mandatory)][ValidateSet("shell-scope", "live-adapter", "live-cleanup")][string] $Contract
)
$ErrorActionPreference = "Stop"
$tests = Join-Path $RepositoryRoot "Tools\windows\Tests"
$caseRoot = Join-Path $ArtifactRoot ("legacy-mock-" + [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($caseRoot)
$previous = [Console]::Out
$capturedConsole = [IO.StringWriter]::new()
$output = @()
$run = $null
try {
  # These named suites use mocked authorities only; their deliberate retention
  # diagnostics must not be forwarded as a real native owner's lifetime signal.
  [Console]::SetOut($capturedConsole)
  if ($Contract -ceq "live-cleanup") {
    $output = @(& (Join-Path $tests "OwnedLiveProcessCleanup.Tests.ps1") 6>&1 3>&1 4>&1 5>&1)
  } else {
    . (Join-Path $RepositoryRoot "Tools\windows\Import-PinnedPester.ps1")
    $file = if ($Contract -ceq "shell-scope") { "ShellProcessOwnership.Tests.ps1" } else { "OwnedLiveAdapter.Tests.ps1" }
    $output = @(Invoke-Pester -Path (Join-Path $tests $file) -PassThru -Output None 6>&1 3>&1 4>&1 5>&1)
    $runs = @($output | Where-Object {
        $null -ne $_.PSObject.Properties["TotalCount"] -and
          $null -ne $_.PSObject.Properties["PassedCount"] -and
          $null -ne $_.PSObject.Properties["FailedCount"]
      })
    if ($runs.Count -ne 1) { throw "Original ownership Pester suite did not return exactly one run result" }
    $run = $runs[0]
  }
} finally {
  [Console]::SetOut($previous)
  [IO.File]::WriteAllText((Join-Path $caseRoot "mock-console.txt"), $capturedConsole.ToString(), [Text.UTF8Encoding]::new($false))
  $capturedConsole.Dispose()
  [IO.File]::WriteAllText((Join-Path $caseRoot "mock-powershell-streams.txt"),
    (($output | ForEach-Object { "$_" }) -join "`n"), [Text.UTF8Encoding]::new($false))
}
if ($Contract -ceq "live-cleanup") {
  $summary = @($output | Where-Object { "$_" -ceq "OWNED_LIVE_PROCESS_CLEANUP_CASES=84 FAILURES=0" })
  if ($summary.Count -ne 1) { throw "Original owned live cleanup suite did not pass all 84 actual controls" }
  $count = 84
} else {
  foreach ($property in @("TotalCount", "PassedCount", "FailedCount", "SkippedCount", "NotRunCount")) {
    if ($null -eq $run.PSObject.Properties[$property]) { throw "Pester result omits $property" }
  }
  [IO.File]::WriteAllText((Join-Path $caseRoot "pester-summary.json"), ([ordered]@{
    executed = $run.TotalCount; passed = $run.PassedCount; failed = $run.FailedCount
    skipped = $run.SkippedCount; notRun = $run.NotRunCount
  } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
  if ($run.TotalCount -le 0 -or $run.PassedCount -ne $run.TotalCount -or
      $run.FailedCount -ne 0 -or $run.SkippedCount -ne 0 -or $run.NotRunCount -ne 0) {
    throw "Original ownership Pester suite failed or omitted controls; retained evidence: $caseRoot"
  }
  $count = $run.TotalCount
}
$row = [ordered]@{
  id = "host.legacy-ownership.$Contract"; status = "Passed"; executedCount = $count
  evidence = "Actual original $Contract mock-only suite; positive count and zero failed/skipped/not-run; retained detailed evidence: $caseRoot"
}
Write-Output ("HOST_CASE_RESULT=" + ($row | ConvertTo-Json -Compress))
