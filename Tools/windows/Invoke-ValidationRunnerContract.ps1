[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$runner = Join-Path $PSScriptRoot "Tests\ValidationRunner.Tests.ps1"
$pwsh = (Get-Process -Id $PID).Path
$passMarkers = 0
& $pwsh -NoProfile -File $runner 2>&1 | ForEach-Object {
  $line = "$_"
  if ($line -ceq "ValidationRunner.Tests.ps1: PASS") { $script:passMarkers++ }
  Write-Host $line
}
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
  throw "Validation runner contract failed with exit code $exitCode"
}
if ($passMarkers -ne 1) {
  throw "Validation runner contract did not report exactly one PASS marker"
}
Write-Host "VALIDATION_RUNNER_EXECUTED=1"
exit 0
