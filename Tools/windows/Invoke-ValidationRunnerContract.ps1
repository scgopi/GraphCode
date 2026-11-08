[CmdletBinding()]
param(
  [string] $FixtureCompilerInput = "",
  [string] $FixtureCompilerInputSha256 = ""
)

function Invoke-WithValidationRunnerRuntime([scriptblock] $Action) {
  $selected = [Environment]::GetEnvironmentVariable("GRAPHCODE_DOTNET10403", "Process")
  $prior = @{}
  if (-not [string]::IsNullOrWhiteSpace($selected)) {
    if (-not [IO.Path]::IsPathFullyQualified($selected) -or
        -not (Test-Path -LiteralPath $selected -PathType Leaf)) {
      throw "GRAPHCODE_DOTNET10403 must identify the selected private dotnet executable"
    }
    $runtimeRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($selected))
    $environment = [Environment]::GetEnvironmentVariables("Process")
    foreach ($name in @("DOTNET_ROOT", "DOTNET_ROOT_X64")) {
      $prior[$name] = @{ present = $environment.Contains($name); value = $environment[$name] }
    }
  }
  try {
    foreach ($name in $prior.Keys) {
      [Environment]::SetEnvironmentVariable($name, $runtimeRoot, "Process")
    }
    & $Action
  } finally {
    foreach ($name in $prior.Keys) {
      $value = if ($prior[$name].present) { $prior[$name].value } else { $null }
      [Environment]::SetEnvironmentVariable($name, $value, "Process")
    }
  }
}

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
$exitCode = $null
$compilerArguments = @()
if ($FixtureCompilerInput -or $FixtureCompilerInputSha256) {
  if (-not $FixtureCompilerInput -or $FixtureCompilerInputSha256 -cnotmatch '\A[A-F0-9]{64}\z' -or
      -not [IO.Path]::IsPathFullyQualified($FixtureCompilerInput)) {
    throw "Fixture compiler input requires an absolute JSON path and uppercase SHA256"
  }
  $compilerArguments = @("--fixture-compiler-input", $FixtureCompilerInput,
    "--fixture-compiler-input-sha256", $FixtureCompilerInputSha256)
}
Invoke-WithValidationRunnerRuntime {
  & $runner --repository-root $repoRoot --artifact-root $artifactRoot @compilerArguments 2>&1 | ForEach-Object {
    $line = "$_"
    $output.Add($line)
    Write-Host $line
  }
  $script:exitCode = $LASTEXITCODE
}
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
