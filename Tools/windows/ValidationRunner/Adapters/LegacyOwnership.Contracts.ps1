param(
  [Parameter(Mandatory)][string] $RepositoryRoot,
  [Parameter(Mandatory)][string] $ArtifactRoot,
  [Parameter(Mandatory)][string] $AssemblyPath,
  [Parameter(Mandatory)][ValidateSet("shell-scope", "live-adapter", "live-cleanup", "sdk-prerequisites", "compiled-environment")][string] $Contract
)
$ErrorActionPreference = "Stop"
function Get-ShellScopeDiagnosticGroups($Run, $Required) {
  $expected = @($Required.requiredGroups)
  if ($expected.Count -ne 7 -or @($expected | Sort-Object -Unique).Count -ne $expected.Count -or
      $Required.minimumCount -ne 70 + $expected.Count -or $Required.exactCount -ne $Required.minimumCount -or
      $Run.TotalCount -ne $Required.exactCount) {
    throw "Shell ownership registry must retain 70 existing cases and exactly seven distinct diagnostic cases"
  }
  $diagnostics = @($Run.Tests | Where-Object { $_.Tag -ccontains "FirstFailureDiagnostic" })
  if ($diagnostics.Count -ne $expected.Count) { throw "Shell ownership diagnostic case count differs" }
  foreach ($name in $expected) {
    $matching = @($diagnostics | Where-Object { $_.Name -ceq $name })
    if ($matching.Count -ne 1 -or $matching[0].Executed -ne $true -or $matching[0].Result -cne "Passed") {
      throw "Shell ownership diagnostic case did not execute and pass exactly once: $name"
    }
  }
  return $expected
}
$tests = Join-Path $RepositoryRoot "Tools\windows\Tests"
$caseRoot = Join-Path $ArtifactRoot ("legacy-mock-" + [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($caseRoot)
$previous = [Console]::Out
$capturedConsole = [IO.StringWriter]::new()
$output = @()
$run = $null
$groups = @()
try {
  # Legacy suites inject mocked ownership diagnostics. Keep those signals in
  # their evidence rather than treating them as a native owner's lifetime signal.
  [Console]::SetOut($capturedConsole)
  if ($Contract -ceq "live-cleanup") {
    $output = @(& (Join-Path $tests "OwnedLiveProcessCleanup.Tests.ps1") 6>&1 3>&1 4>&1 5>&1)
  } else {
    . (Join-Path $RepositoryRoot "Tools\windows\Import-PinnedPester.ps1")
    $files = if ($Contract -ceq "shell-scope") { @("ShellProcessOwnership.Tests.ps1") } `
      elseif ($Contract -ceq "sdk-prerequisites") { @("DotNetSdk.Tests.ps1", "Bootstrap.Tests.ps1") } `
      elseif ($Contract -ceq "compiled-environment") { @("CompiledValidationEnvironment.Tests.ps1") } `
      else { @("OwnedLiveAdapter.Tests.ps1") }
    $paths = @($files | ForEach-Object { Join-Path $tests $_ })
    $output = @(Invoke-Pester -Path $paths -PassThru -Output None 6>&1 3>&1 4>&1 5>&1)
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
  if ($Contract -ceq "shell-scope") {
    $registry = Get-Content (Join-Path $RepositoryRoot "Tools\windows\ValidationRunner\Manifests\host.json") -Raw | ConvertFrom-Json
    $required = @($registry.units | Where-Object id -CEQ "host.legacy-ownership.shell-scope")
    if ($required.Count -ne 1) { throw "Shell ownership registry identity is absent or duplicated" }
    $groups = @(Get-ShellScopeDiagnosticGroups $run $required[0])
  }
}
$id = if ($Contract -ceq "sdk-prerequisites") { "host.sdk-prerequisites" } `
  elseif ($Contract -ceq "compiled-environment") { "host.compiled-assembly-environment" } `
  else { "host.legacy-ownership.$Contract" }
$description = if ($Contract -ceq "sdk-prerequisites") {
  "SDK prerequisites: actual installed-SDK probe plus controlled bootstrap/dependency cases"
} elseif ($Contract -ceq "compiled-environment") {
  "Actual scoped caller publication, supplied/empty/missing state, failure identity and native child environment controls"
} elseif ($Contract -ceq "shell-scope") {
  "Actual original shell-scope suite: mock/filesystem contracts and controlled native suspended-launch fixtures"
} else { "Actual original $Contract suite" }
$row = [ordered]@{
  id = $id; status = "Passed"; executedCount = $count
  evidence = "$description; positive count and zero failed/skipped/not-run; retained detailed evidence: $caseRoot"
}
if ($Contract -ceq "shell-scope") { $row.groups = $groups }
Write-Output ("HOST_CASE_RESULT=" + ($row | ConvertTo-Json -Compress))
