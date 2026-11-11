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

  $enhancedValid = Join-Path $temporaryDirectory "enhanced-valid.md"
  @"
## Summary
Adds evidence metadata.

## Test plan

RED: pwsh Tools/tdd/Tests/TddEvidence.Tests.ps1 -> invalid Tier B metadata was accepted
GREEN: pwsh Tools/tdd/Tests/TddEvidence.Tests.ps1 -> pass
REGRESSION: pwsh Tools/tdd/Tests/TddEvidence.Tests.ps1 -> pass

## Candidate and evidence identity

- **Tier(s):** Tier A, Tier B
- **Branch:** main
- **HEAD / tree:** a3f3d8df8bedb4b325dc57cf1120636d110ad01f / aebc8c8c35056d0bb0f1706e74a282c87a544902 (clean)
- **Candidate hashes:** PR body sha256:1234abcd; provider pin sha256:5678efab

## Stopping handoff

- **Next exact command:** pwsh -NoProfile -File Tools\tdd\Tests\TddEvidence.Tests.ps1
- **Positive count:** 1 test entry passed
- **Permissions / time / desktop:** no live desktop required
- **Blocker category:** product
- **Evidence paths:** Tools\tdd\Tests\TddEvidence.Tests.ps1.log
- **Stopping condition:** stop before any publication action
- **Publication authority:** coordinator only
"@ | Set-Content -LiteralPath $enhancedValid
  & $validator -BodyPath $enhancedValid
  if ($LASTEXITCODE -ne 0) {
    throw "Complete evidence metadata was rejected"
  }
  $enhancedBody = Get-Content -LiteralPath $enhancedValid -Raw

  $optionalHandoffValid = Join-Path $temporaryDirectory "optional-handoff-valid.md"
  $optionalHandoffBody = $enhancedBody -replace
    "(?m)^(- \*\*Candidate hashes:\*\*).*$",
    '$1 none (repository candidate only)'
  foreach ($label in @(
    "Next exact command",
    "Positive count",
    "Permissions / time / desktop",
    "Blocker category",
    "Evidence paths",
    "Stopping condition",
    "Publication authority"
  )) {
    $optionalHandoffBody = $optionalHandoffBody -replace
      "(?m)^(- \*\*$([regex]::Escape($label)):\*\*).*$",
      '$1'
  }
  Set-Content -LiteralPath $optionalHandoffValid -Value $optionalHandoffBody
  & $validator -BodyPath $optionalHandoffValid
  if ($LASTEXITCODE -ne 0) {
    throw "Optional stopping handoff was rejected"
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

  $invalidMetadataCases = @(
    @{
      Name = "invalid-tier.md"
      Replacement = "Tier A, Tier Z"
      Target = "Tier A, Tier B"
      Message = "Invalid evidence tier was accepted"
    },
    @{
      Name = "missing-branch.md"
      Replacement = ""
      Target = "main"
      Message = "Incomplete candidate identity was accepted"
    },
    @{
      Name = "missing-head-tree.md"
      Replacement = "a3f3d8d / missing-tree (clean)"
      Target = "a3f3d8df8bedb4b325dc57cf1120636d110ad01f / aebc8c8c35056d0bb0f1706e74a282c87a544902 (clean)"
      Message = "Incomplete HEAD/tree identity was accepted"
    },
    @{
      Name = "missing-candidate-hashes.md"
      Replacement = ""
      Target = "PR body sha256:1234abcd; provider pin sha256:5678efab"
      Message = "Missing candidate hashes were accepted"
    },
    @{
      Name = "placeholder-candidate-hashes.md"
      Replacement = "hashes not recorded"
      Target = "PR body sha256:1234abcd; provider pin sha256:5678efab"
      Message = "Placeholder candidate hashes were accepted"
    },
    @{
      Name = "missing-next-command.md"
      Replacement = ""
      Target = "pwsh -NoProfile -File Tools\tdd\Tests\TddEvidence.Tests.ps1"
      Message = "Incomplete stopping command was accepted"
    },
    @{
      Name = "zero-positive-count.md"
      Replacement = "0 tests executed"
      Target = "1 test entry passed"
      Message = "Zero positive count was accepted"
    },
    @{
      Name = "invalid-blocker.md"
      Replacement = "tooling-ish"
      Target = "product"
      Message = "Unclassified blocker was accepted"
    },
    @{
      Name = "missing-stopping-condition.md"
      Replacement = ""
      Target = "stop before any publication action"
      Message = "Incomplete stopping handoff was accepted"
    },
    @{
      Name = "missing-publication-authority.md"
      Replacement = ""
      Target = "coordinator only"
      Message = "Missing publication authority was accepted"
    }
  )

  foreach ($case in $invalidMetadataCases) {
    $invalidBody = $enhancedBody
    $target = if ($case.Target) { $case.Target } else { "feature/evidence-workflow" }
    $invalidBody = $invalidBody.Replace($target, [string] $case.Replacement)
    $invalidPath = Join-Path $temporaryDirectory $case.Name
    Set-Content -LiteralPath $invalidPath -Value $invalidBody
    & $pwsh -NoProfile -File $validator -BodyPath $invalidPath *> $null
    if ($LASTEXITCODE -eq 0) {
      throw $case.Message
    }
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

  $mergeGateText = "Every exact-head PR workflow failure blocks merge"
  foreach ($policyText in @(
    $agentsText,
    $matrixText,
    $kickoffText
  )) {
    if ($policyText -notmatch [regex]::Escape($mergeGateText)) {
      throw "Exact-head PR workflow failure boundary is undocumented"
    }
  }
} finally {
  Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
}

Write-Host "TddEvidence.Tests.ps1: PASS"
exit 0
