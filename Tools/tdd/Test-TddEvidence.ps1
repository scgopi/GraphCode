[CmdletBinding(DefaultParameterSetName = "Body")]
param(
  [Parameter(Mandatory, ParameterSetName = "Body")]
  [string] $BodyPath,
  [Parameter(Mandatory, ParameterSetName = "Event")]
  [string] $EventPath
)

$ErrorActionPreference = "Stop"

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
  if ($evidence.Length -lt 8 -or
    $evidence -match "<[^>]+>" -or
    $evidence -match "(?i)\b(todo|tbd|n/?a)\b") {
    throw "$label evidence is still a placeholder."
  }
  if ($evidence -notmatch "->") {
    throw "$label evidence must use '<command> -> <result>'."
  }
}

Write-Host "TDD evidence: PASS"
exit 0
