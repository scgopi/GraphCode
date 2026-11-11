<#
.SYNOPSIS
Checks that the Windows parity ledger and open parity backlog stay synchronized.

.DESCRIPTION
The ledger's canonical rows end with `| Partial |`. Each Partial row must link
an open `parity` issue either in the row itself or in the marked mapping table.
Every open parity issue must have one P1/P2/P3 priority, at least one assignee,
and evidence metadata in its body.

Use IssuesPath with a JSON array containing number, title, labels, assignees,
and body fields to audit a captured snapshot. Without it, the script reads the
current issue state through the GitHub CLI.
#>
[CmdletBinding()]
param(
  [string] $Repository = "scgopi/GraphCode",
  [string] $LedgerPath = "investigation\ui-parity-matrix.md",
  [string] $IssuesPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)) {
  throw "Parity ledger does not exist: $LedgerPath"
}

if ($IssuesPath) {
  if (-not (Test-Path -LiteralPath $IssuesPath -PathType Leaf)) {
    throw "Issue snapshot does not exist: $IssuesPath"
  }
  $rawIssues = Get-Content -LiteralPath $IssuesPath -Raw
} else {
  $rawIssues = & gh issue list `
    --repo $Repository `
    --state open `
    --label parity `
    --limit 200 `
    --json number,title,labels,assignees,body
  if ($LASTEXITCODE -ne 0) {
    throw "GitHub CLI could not read open parity issues for $Repository."
  }
  $rawIssues = $rawIssues -join "`n"
}

$issues = @($rawIssues | ConvertFrom-Json)
$openParity = @{}
$errors = [System.Collections.Generic.List[string]]::new()
$priorityNames = @("P1 layout", "P2 feature", "P3 polish")
$evidencePattern = "Current Windows evidence/status|Still open / Partial|Windows today:|Evidence:|Evidence limits:"

foreach ($issue in $issues) {
  $number = [int] $issue.number
  $labelNames = @($issue.labels | ForEach-Object { [string] $_.name })
  if ("parity" -notin $labelNames) {
    continue
  }

  $openParity[$number] = $issue
  $priorities = @($labelNames | Where-Object { $_ -in $priorityNames })
  if ($priorities.Count -ne 1) {
    $errors.Add("#$number has $($priorities.Count) parity priority labels; expected exactly one.")
  }

  if (@($issue.assignees).Count -eq 0) {
    $errors.Add("#$number has no owner.")
  }

  $body = [string] $issue.body
  if ($body -notmatch $evidencePattern) {
    $errors.Add("#$number has no structured evidence metadata.")
  }
}

$ledgerLines = Get-Content -LiteralPath $LedgerPath
$mappedByRow = @{}
$insideMappingTable = $false
foreach ($line in $ledgerLines) {
  if ($line -eq "<!-- parity-backlog-map:start -->") {
    $insideMappingTable = $true
    continue
  }
  if ($line -eq "<!-- parity-backlog-map:end -->") {
    $insideMappingTable = $false
    continue
  }
  if (-not $insideMappingTable) {
    continue
  }

  $mapping = [regex]::Match(
    $line,
    '^\|\s*(?<row>.+?)\s*\|\s*\[#(?<number>\d+)\]\([^)]+\)\s*\|\s*$'
  )
  if ($mapping.Success) {
    $row = $mapping.Groups["row"].Value.Trim()
    $number = [int] $mapping.Groups["number"].Value
    if (-not $mappedByRow.ContainsKey($row)) {
      $mappedByRow[$row] = [System.Collections.Generic.List[int]]::new()
    }
    $mappedByRow[$row].Add($number)
  }
}

$partialRows = 0
$partialRowNames = @{}
foreach ($line in $ledgerLines) {
  $rowMatch = [regex]::Match(
    $line,
    '^\|\s*(?<row>.+?)\s*\|.*\|\s*Partial\s*\|\s*$'
  )
  if (-not $rowMatch.Success) {
    continue
  }

  $partialRows++
  $row = $rowMatch.Groups["row"].Value.Trim()
  $partialRowNames[$row] = $true
  $linked = [System.Collections.Generic.List[int]]::new()
  foreach ($match in [regex]::Matches($line, '#(?<number>\d+)')) {
    $linked.Add([int] $match.Groups["number"].Value)
  }
  if ($mappedByRow.ContainsKey($row)) {
    foreach ($number in $mappedByRow[$row]) {
      $linked.Add($number)
    }
  }

  $hasOpenMapping = $false
  foreach ($number in $linked) {
    if ($openParity.ContainsKey($number)) {
      $hasOpenMapping = $true
      break
    }
  }
  if (-not $hasOpenMapping) {
    $errors.Add("Partial row '$row' has no open parity issue mapping.")
  }
}

if ($partialRows -eq 0) {
  $errors.Add("The ledger contains no canonical Partial rows.")
}

foreach ($row in $mappedByRow.Keys) {
  if (-not $partialRowNames.ContainsKey($row)) {
    $errors.Add("Mapping table row '$row' is not a canonical Partial row.")
  }
  if ($mappedByRow[$row].Count -ne 1) {
    $errors.Add("Mapping table row '$row' has $($mappedByRow[$row].Count) issues; expected exactly one.")
  }
  foreach ($number in $mappedByRow[$row]) {
    if (-not $openParity.ContainsKey($number)) {
      $errors.Add("Mapping table row '$row' references #$number, which is not an open parity issue.")
    }
  }
}

if ($errors.Count -gt 0) {
  foreach ($failure in $errors) {
    [Console]::Error.WriteLine($failure)
  }
  exit 1
}

Write-Host "Parity backlog audit: PASS ($partialRows Partial rows, $($openParity.Count) open parity issues)"
exit 0
