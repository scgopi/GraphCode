[CmdletBinding(DefaultParameterSetName = "Body")]
param(
  [Parameter(Mandatory, ParameterSetName = "Body")]
  [string] $BodyPath,
  [Parameter(Mandatory, ParameterSetName = "Event")]
  [string] $EventPath
)

$ErrorActionPreference = "Stop"

function Get-EvidenceField {
  param(
    [string] $Text,
    [string] $Label
  )

  $match = [regex]::Match(
    $Text,
    "(?im)^[ \t]*(?:-[ \t]*)?(?:\*\*)?$([regex]::Escape($Label)):(?:\*\*)?[ \t]*(?<value>.*?)[ \t]*$"
  )
  if ($match.Success) {
    return $match.Groups["value"].Value.Trim()
  }
  return $null
}

function Test-PlaceholderEvidence {
  param(
    [string] $Value,
    [int] $MinimumLength = 8
  )

  return (
    [string]::IsNullOrWhiteSpace($Value) -or
    $Value.Length -lt $MinimumLength -or
    $Value -match "<[^>]+>" -or
    $Value -match "(?i)\b(todo|tbd|n/?a)\b"
  )
}

if ($PSCmdlet.ParameterSetName -eq "Event") {
  $event = Get-Content -LiteralPath $EventPath -Raw | ConvertFrom-Json
  $body = [string] $event.pull_request.body
} else {
  $body = Get-Content -LiteralPath $BodyPath -Raw
}

if ([string]::IsNullOrWhiteSpace($body)) {
  throw "Pull request body is empty; RED/GREEN/REGRESSION evidence is required."
}

$required = @("RED", "GREEN", "REGRESSION")
foreach ($label in $required) {
  $match = [regex]::Match(
    $body,
    "(?im)^\s*${label}:\s*(?<evidence>.+?)\s*$"
  )
  if (-not $match.Success) {
    throw "$label evidence is missing."
  }

  $evidence = $match.Groups["evidence"].Value.Trim()
  if (Test-PlaceholderEvidence $evidence) {
    throw "$label evidence is still a placeholder."
  }
  if ($evidence -notmatch "->") {
    throw "$label evidence must use '<command> -> <result>'."
  }
}

$identityLabels = @("Tier(s)", "Branch", "HEAD / tree", "Candidate hashes")
$identity = @{}
$identityPresent = $false
foreach ($label in $identityLabels) {
  $value = Get-EvidenceField -Text $body -Label $label
  $identity[$label] = $value
  if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace($value)) {
    $identityPresent = $true
  }
}

if ($identityPresent) {
  foreach ($label in $identityLabels) {
    if (Test-PlaceholderEvidence ([string] $identity[$label]) -MinimumLength 1) {
      throw "Evidence identity field '$label' is missing or still a placeholder."
    }
  }

  $tiers = [regex]::Split(
    [string] $identity["Tier(s)"],
    "\s*(?:,|/|\+|\band\b)\s*",
    [Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
  if ($tiers.Count -eq 0 -or @($tiers | Where-Object {
      $_ -notmatch "^(?i:Tier\s+)?[ABC]$"
    }).Count -ne 0) {
    throw "Tier(s) must contain only Tier A, Tier B and/or Tier C."
  }

  if ([string] $identity["Branch"] -match "\s") {
    throw "Branch must be one exact Git branch name."
  }
  if ([string] $identity["HEAD / tree"] -notmatch
    "(?i)^[0-9a-f]{7,40}\s*/\s*[0-9a-f]{7,40}\s+\((clean|dirty)\)$") {
    throw "HEAD / tree must contain two exact hashes and clean or dirty state."
  }
  if ([string] $identity["Candidate hashes"] -notmatch
    "(?i)(?:\b[0-9a-f]{8,64}\b|^none\b.+)") {
    throw "Candidate hashes must identify the relevant artifacts or explicitly state none."
  }
}

$handoffLabels = @(
  "Next exact command",
  "Positive count",
  "Permissions / time / desktop",
  "Blocker category",
  "Evidence paths",
  "Stopping condition",
  "Publication authority"
)
$handoff = @{}
$handoffPresent = $false
foreach ($label in $handoffLabels) {
  $value = Get-EvidenceField -Text $body -Label $label
  $handoff[$label] = $value
  if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace($value)) {
    $handoffPresent = $true
  }
}

if ($handoffPresent) {
  foreach ($label in $handoffLabels) {
    if (Test-PlaceholderEvidence ([string] $handoff[$label]) -MinimumLength 1) {
      throw "Stopping handoff field '$label' is missing or still a placeholder."
    }
  }

  $positiveCounts = [regex]::Matches(
    [string] $handoff["Positive count"],
    "\d+"
  )
  $hasPositiveCount = $false
  foreach ($count in $positiveCounts) {
    if ([int] $count.Value -gt 0) {
      $hasPositiveCount = $true
      break
    }
  }
  if (-not $hasPositiveCount) {
    throw "Positive count must report at least one executed item."
  }

  $blockerCategories = @(
    "product",
    "test/harness",
    "environment",
    "permissions/time/desktop",
    "infrastructure/CI",
    "scope/policy",
    "unknown"
  )
  if ($blockerCategories -cnotcontains [string] $handoff["Blocker category"]) {
    throw "Blocker category must be one of the documented classifications."
  }
}

Write-Host "TDD evidence: PASS"
exit 0
