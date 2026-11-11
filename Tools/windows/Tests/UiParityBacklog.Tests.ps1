$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$auditor = Join-Path $repositoryRoot "Tools\windows\Test-UiParityBacklog.ps1"
$ledgerPath = Join-Path $repositoryRoot "investigation\ui-parity-matrix.md"
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("graphcode-parity-audit-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null

function Invoke-AuditFailure {
  param(
    [string] $Path,
    [string] $Expected
  )

  $output = & pwsh -NoProfile -File $auditor -LedgerPath $Path -IssuesPath $script:snapshotPath 2>&1
  $code = $LASTEXITCODE
  if ($code -eq 0) {
    throw "Negative fixture unexpectedly passed: $Path"
  }
  $text = $output -join "`n"
  if ($text -notmatch [regex]::Escape($Expected)) {
    throw "Negative fixture '$Path' omitted expected error '$Expected'. Output: $text"
  }
}

try {
  Push-Location $repositoryRoot
  $script:snapshotPath = Join-Path $fixtureRoot "open-issues.json"
  $snapshot = & gh issue list `
    --repo scgopi/GraphCode `
    --state open `
    --label parity `
    --limit 200 `
    --json number,state,title,labels,assignees,body
  if ($LASTEXITCODE -ne 0) {
    throw "Could not capture open parity issues."
  }
  $snapshot -join "`n" | Set-Content -LiteralPath $script:snapshotPath -Encoding utf8NoBOM

  $ledger = Get-Content -LiteralPath $ledgerPath
  $partialIndexes = @(
    0..($ledger.Count - 1) |
      Where-Object { $ledger[$_] -match '^\|\s*.+?\s*\|.*\|\s*Partial\s*\|\s*$' }
  )
  $duplicateLedgerPath = Join-Path $fixtureRoot "duplicate-row-identity.md"
  $firstRow = $ledger[$partialIndexes[0]]
  $lastIndex = $partialIndexes[-1]
  $duplicateLedger = @($ledger)
  $duplicateLedger[$lastIndex] = $firstRow
  $duplicateLedger | Set-Content -LiteralPath $duplicateLedgerPath -Encoding utf8NoBOM
  Invoke-AuditFailure $duplicateLedgerPath "has 88 unique canonical Partial row identities; expected 89"

  $removedLedgerPath = Join-Path $fixtureRoot "removed-row-identity.md"
  $removedLedger = @(
    0..($ledger.Count - 1) |
      Where-Object { $_ -ne $lastIndex } |
      ForEach-Object { $ledger[$_] }
  )
  $removedLedger | Set-Content -LiteralPath $removedLedgerPath -Encoding utf8NoBOM
  $removedRowName = [regex]::Match(
    $ledger[$lastIndex],
    '^\|\s*(?<row>.+?)\s*\|'
  ).Groups["row"].Value.Trim()
  Invoke-AuditFailure $removedLedgerPath "Canonical Partial row '$removedRowName' is missing"

  $missingStatePath = Join-Path $fixtureRoot "missing-state.json"
  $missingState = @($snapshot | ConvertFrom-Json)
  $missingState[0].PSObject.Properties.Remove("state")
  $missingState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $missingStatePath -Encoding utf8NoBOM
  $script:previousSnapshotPath = $script:snapshotPath
  $script:snapshotPath = $missingStatePath
  Invoke-AuditFailure $ledgerPath "snapshot entry has no state; expected OPEN"

  $closedStatePath = Join-Path $fixtureRoot "closed-state.json"
  $closedState = @(Get-Content -LiteralPath $script:previousSnapshotPath -Raw | ConvertFrom-Json)
  $closedState[0].state = "CLOSED"
  $closedState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $closedStatePath -Encoding utf8NoBOM
  $script:snapshotPath = $closedStatePath
  Invoke-AuditFailure $ledgerPath "snapshot entry has state 'CLOSED'; expected OPEN"

  $unmappedPath = Join-Path $fixtureRoot "unmapped-open-issue.json"
  $unmapped = @(Get-Content -LiteralPath $script:previousSnapshotPath -Raw | ConvertFrom-Json)
  $unmapped += [pscustomobject]@{
    number = 999999
    state = "OPEN"
    title = "Negative reverse-coverage fixture"
    labels = @(
      [pscustomobject]@{ name = "parity" },
      [pscustomobject]@{ name = "P2 feature" }
    )
    assignees = @([pscustomobject]@{ login = "coneilen" })
    body = "Evidence: intentional negative fixture"
  }
  $unmapped | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $unmappedPath -Encoding utf8NoBOM
  $script:snapshotPath = $unmappedPath
  Invoke-AuditFailure $ledgerPath "Open parity issue #999999 is neither mapped to a Partial row nor explicitly exempt"

  Write-Host "UiParityBacklog.Tests.ps1: PASS"
} finally {
  Pop-Location
  Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
