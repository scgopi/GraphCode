$ErrorActionPreference = "Stop"

$validator = Join-Path $PSScriptRoot "..\Test-TddEvidence.ps1"
if (-not (Test-Path $validator)) {
  throw "RED: TDD evidence validator does not exist at $validator"
}

$temporaryDirectory = Join-Path $env:TEMP "graphcode-tdd-$([guid]::NewGuid())"
New-Item -ItemType Directory -Force $temporaryDirectory | Out-Null
try {
  $valid = Join-Path $temporaryDirectory "valid.md"
  @"
## Summary
Adds a behavior.

## Test plan

RED: pwsh Tests/Feature.Tests.ps1 -> missing behavior assertion failed
GREEN: pwsh Tests/Feature.Tests.ps1 -> pass
REGRESSION: pwsh Tests/All.Tests.ps1 -> pass
"@ | Set-Content -LiteralPath $valid
  & $validator -BodyPath $valid
  if ($LASTEXITCODE -ne 0) {
    throw "Valid TDD evidence was rejected"
  }

  $missingRed = Join-Path $temporaryDirectory "missing-red.md"
  @"
GREEN: pwsh Tests/Feature.Tests.ps1 -> pass
REGRESSION: pwsh Tests/All.Tests.ps1 -> pass
"@ | Set-Content -LiteralPath $missingRed
  $pwsh = (Get-Process -Id $PID).Path
  & $pwsh -NoProfile -File $validator -BodyPath $missingRed *> $null
  if ($LASTEXITCODE -eq 0) {
    throw "Missing RED evidence was accepted"
  }

  $placeholder = Join-Path $temporaryDirectory "placeholder.md"
  @"
RED: <command> -> <expected failure>
GREEN: <command> -> pass
REGRESSION: <command(s)> -> pass
"@ | Set-Content -LiteralPath $placeholder
  & $pwsh -NoProfile -File $validator -BodyPath $placeholder *> $null
  if ($LASTEXITCODE -eq 0) {
    throw "Placeholder TDD evidence was accepted"
  }
} finally {
  Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
}

Write-Host "TddEvidence.Tests.ps1: PASS"
exit 0
