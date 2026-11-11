<#
.SYNOPSIS
Checks that the Windows parity ledger and open parity backlog stay synchronized.

.DESCRIPTION
The ledger has exactly 89 named canonical rows ending with `| Partial |`. Each
Partial row must link an open `parity` issue either in the row itself or in the
marked mapping table. Every open parity issue must map back to a row unless it
has an explicit metadata/infrastructure exemption, and must have one P1/P2/P3
priority, at least one assignee, and evidence metadata in its body.

Use IssuesPath with a JSON array containing number, state, labels, assignees,
and body fields to audit a captured snapshot. Snapshot entries must be OPEN;
missing or closed states fail closed. Without IssuesPath, the script reads the
current open issue state through the GitHub CLI.
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
    --json number,state,title,labels,assignees,body
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
$expectedPartialRows = @(
  "Main split view",
  "Window toolbar",
  "Jump palette",
  "File/Loop/Terminal menus",
  "Workspace lifecycle",
  "Update command",
  "Tray lifecycle",
  "Connection failure presentation",
  "Five-page onboarding",
  "No-project Welcome detail",
  "Empty global graph",
  "Empty project canvas",
  "Empty Quick Chats canvas",
  "Graph row",
  "Quick Chats group",
  "Local/remote sections",
  "Project rows",
  "Nested loop tree",
  "Loop row presentation",
  "Project context menu",
  "Loop context menu",
  "Recent projects",
  "Add Folder menu",
  "Sidebar update banner",
  "Sidebar error footer",
  "Activity strip",
  "Cross-project global graph",
  "Folder lanes/bands",
  "Notebook grid",
  "Pan and anchored zoom",
  "Zoom controls",
  "New Loop canvas button",
  "Composite breadcrumb",
  "Canvas attention rail",
  "Node positioning",
  "Connector handles",
  "Loop card identity",
  "Loop card live detail",
  "Loop card attention",
  "Unwired card recovery",
  "Worktree reclaim offer",
  "Composite card actions",
  "Edge presentation",
  "Edge creation sheet",
  "Custody child creation",
  "Node creation sheet",
  "Node update/rename",
  "Delete confirmations",
  "Canvas context menu",
  "Sketch promotion",
  "Quick Chats canvas",
  "Quick Chat cards",
  "Create chat",
  "Rename chat",
  "Delete chat",
  "Chat workspace",
  "Terminal VT state and rendering",
  "Folder toolbar identity",
  "Loop bar",
  "Tab pills",
  "Split controls",
  "Pane headers",
  "Right loop panel",
  "Open Folder",
  "Clone Repository sheet",
  "Add Remote Repository sheet",
  "Remote Connection info",
  "Add Codespace sheet",
  "Product Settings window",
  "Project Settings sheet",
  "Worktree sweep sheet",
  "Worktree notice chip",
  "Available update alert",
  "Install progress",
  "Relaunch prompt",
  "Install failure",
  "Loop rename",
  "Loop delete",
  "Chat rename/delete",
  "Project delete loops",
  "Project remove/trash",
  "UI Automation tree",
  "Keyboard discovery",
  "Clipboard/selection",
  "Per-monitor DPI",
  "Dark visual language",
  "Font rendering quality",
  "Line/shape anti-aliasing",
  "Color palette fidelity"
)

foreach ($issue in $issues) {
  $number = [int] $issue.number
  $stateProperty = $issue.PSObject.Properties["state"]
  if ($null -eq $stateProperty) {
    $errors.Add("#$number snapshot entry has no state; expected OPEN.")
    continue
  }
  $state = [string] $stateProperty.Value
  if ($state -cne "OPEN") {
    $errors.Add("#$number snapshot entry has state '$state'; expected OPEN.")
    continue
  }

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
$exemptIssues = @{}
$mappedIssues = @{}
$insideMappingTable = $false
$insideExemptionTable = $false
foreach ($line in $ledgerLines) {
  if ($line -eq "<!-- parity-backlog-map:start -->") {
    $insideMappingTable = $true
    continue
  }
  if ($line -eq "<!-- parity-backlog-map:end -->") {
    $insideMappingTable = $false
    continue
  }
  if ($line -eq "<!-- parity-backlog-exempt:start -->") {
    $insideExemptionTable = $true
    continue
  }
  if ($line -eq "<!-- parity-backlog-exempt:end -->") {
    $insideExemptionTable = $false
    continue
  }
  if (-not $insideMappingTable -and -not $insideExemptionTable) {
    continue
  }

  if ($insideExemptionTable) {
    $exemption = [regex]::Match(
      $line,
      '^\|\s*\[#(?<number>\d+)\]\([^)]+\)\s*\|\s*(?<reason>.+?)\s*\|\s*$'
    )
    if ($exemption.Success) {
      $number = [int] $exemption.Groups["number"].Value
      if ($exemptIssues.ContainsKey($number)) {
        $errors.Add("Open parity issue #$number has duplicate exemptions.")
      }
      $exemptIssues[$number] = $exemption.Groups["reason"].Value.Trim()
    }
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
  if ($partialRowNames.ContainsKey($row)) {
    $errors.Add("Canonical Partial row '$row' appears more than once.")
  }
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
      $mappedIssues[$number] = $true
    }
  }
  if (-not $hasOpenMapping) {
    $errors.Add("Partial row '$row' has no open parity issue mapping.")
  }
}

if ($partialRows -ne 89) {
  $errors.Add("The ledger has $partialRows canonical Partial rows; expected 89.")
}
if ($partialRowNames.Count -ne 89) {
  $errors.Add("The ledger has $($partialRowNames.Count) unique canonical Partial row identities; expected 89.")
}
foreach ($expectedRow in $expectedPartialRows) {
  if (-not $partialRowNames.ContainsKey($expectedRow)) {
    $errors.Add("Canonical Partial row '$expectedRow' is missing.")
  }
}
foreach ($actualRow in $partialRowNames.Keys) {
  if ($actualRow -notin $expectedPartialRows) {
    $errors.Add("Canonical Partial row '$actualRow' is not in the expected identity set.")
  }
}

foreach ($row in $mappedByRow.Keys) {
  if (-not $partialRowNames.ContainsKey($row)) {
    $errors.Add("Mapping table row '$row' is not a canonical Partial row.")
  }
  foreach ($number in $mappedByRow[$row]) {
    if (-not $openParity.ContainsKey($number)) {
      $errors.Add("Mapping table row '$row' references #$number, which is not an open parity issue.")
    } else {
      $mappedIssues[$number] = $true
    }
  }
}

foreach ($number in $exemptIssues.Keys) {
  if (-not $openParity.ContainsKey($number)) {
    $errors.Add("Exemption #$number is not an open parity issue.")
  }
}
foreach ($number in $openParity.Keys) {
  if (-not $mappedIssues.ContainsKey($number) -and -not $exemptIssues.ContainsKey($number)) {
    $errors.Add("Open parity issue #$number is neither mapped to a Partial row nor explicitly exempt.")
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
