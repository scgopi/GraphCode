[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$assembly = & (Join-Path $PSScriptRoot "Build-CompiledValidationRunner.ps1") -Configuration Release
$runner = Join-Path (Split-Path $assembly -Parent) "ValidationRunner.exe"
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
  throw "Compiled validation build produced no executable"
}
$artifactRoot = Join-Path $repoRoot (".build\validation-runner-contract-" + [guid]::NewGuid().ToString("N"))
$output = [Collections.Generic.List[string]]::new()
$passMarkers = 0
$executedMarkers = 0
& $runner --repository-root $repoRoot --artifact-root $artifactRoot 2>&1 | ForEach-Object {
  $line = "$_"
  $output.Add($line)
  Write-Host $line
}
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
  throw "Compiled validation failed with exit code $exitCode; evidence retained at $artifactRoot"
}
$report = Get-Content -LiteralPath (Join-Path $artifactRoot "coverage.json") -Raw | ConvertFrom-Json
if ($report.runner -cne "CompiledValidationRunner" -or
    $report.complete -isnot [bool] -or -not $report.complete -or
    -not ($report.requiredCount -is [int] -or $report.requiredCount -is [long]) -or
    -not ($report.passedCount -is [int] -or $report.passedCount -is [long]) -or
    $report.requiredCount -le 0 -or $report.passedCount -ne $report.requiredCount -or
    @($report.units).Count -ne $report.requiredCount -or @($report.errors).Count -ne 0) {
  throw "Compiled validation did not report complete positive full coverage; evidence retained at $artifactRoot"
}
$passMarkers = @($output | Where-Object { $_ -ceq "CompiledValidationRunner: PASS" }).Count
$executedMarkers = @($output | Where-Object { $_ -ceq "VALIDATION_RUNNER_EXECUTED=1" }).Count
if ($passMarkers -ne 1 -or $executedMarkers -ne 1) {
  throw "Compiled validation must report exactly one full PASS and one positive execution marker"
}
exit 0
