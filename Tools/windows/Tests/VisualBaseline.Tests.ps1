$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$validator = Join-Path $repoRoot "Tools\windows\visual-baseline.ps1"

if (-not (Test-Path -LiteralPath $validator)) {
  throw "RED: visual baseline validator is missing at $validator"
}

$output = & $validator
if ($LASTEXITCODE -ne 0) {
  throw "Visual baseline validation failed with exit code $LASTEXITCODE"
}
if (($output -join "`n") -notmatch "Visual baseline: PASS") {
  throw "Visual baseline validator did not report PASS"
}

Write-Host "VisualBaseline.Tests.ps1: PASS"
exit 0
