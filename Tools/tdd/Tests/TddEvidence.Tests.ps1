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

  # The shipped pull request template must never satisfy the gate on its own. It is
  # meant to fail until an author replaces the evidence lines. This also catches a
  # guidance comment that puts an example label at the start of a line, because the
  # validator matches the first RED:/GREEN:/REGRESSION: anywhere in the body and would
  # then read the comment as the author's evidence.
  $template = Join-Path $PSScriptRoot "..\..\..\.github\PULL_REQUEST_TEMPLATE.md"
  if (-not (Test-Path $template)) {
    throw "Pull request template not found at $template"
  }
  & $pwsh -NoProfile -File $validator -BodyPath $template *> $null
  if ($LASTEXITCODE -eq 0) {
    throw "Unedited pull request template was accepted as TDD evidence"
  }

  $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
  $templateText = Get-Content -LiteralPath $template -Raw
  $agentsText = Get-Content -LiteralPath (Join-Path $repositoryRoot "AGENTS.md") -Raw
  $matrixText = Get-Content -LiteralPath (Join-Path $repositoryRoot "Tools\windows\validation-matrix.md") -Raw
  $kickoffText = Get-Content -LiteralPath (Join-Path $repositoryRoot "investigation\windows-parity-lane-kickoff.md") -Raw

  foreach ($tier in @(
    "Tier A: focused local evidence",
    "Tier B: required CI merge gate",
    "Tier C: live/native devbox evidence"
  )) {
    if ($agentsText -notmatch [regex]::Escape($tier) -or
      $matrixText -notmatch [regex]::Escape($tier) -or
      $kickoffText -notmatch [regex]::Escape($tier)) {
      throw "Evidence tier definition is missing: $tier"
    }
  }

  foreach ($field in @(
    "Branch:",
    "HEAD / tree:",
    "Candidate hashes:",
    "Next exact command:",
    "Positive count:",
    "Permissions / time / desktop:",
    "Blocker category:",
    "Evidence paths:",
    "Stopping condition:",
    "Publication authority:"
  )) {
    if ($templateText -notmatch [regex]::Escape($field) -or
      $agentsText -notmatch [regex]::Escape($field) -or
      $kickoffText -notmatch [regex]::Escape($field)) {
      throw "Structured handoff field is missing: $field"
    }
  }
} finally {
  Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
}

Write-Host "TddEvidence.Tests.ps1: PASS"
exit 0
