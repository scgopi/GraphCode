[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $ScenarioRoot,
  [Parameter(Mandatory)][string] $AuthorityPath,
  [Parameter(Mandatory)][string] $AuthoritySha256,
  [string[]] $ClaimId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$schemaRoot = Join-Path $PSScriptRoot "..\..\windows-tests\ui-scenarios"
$states = @("success", "empty", "error", "disabled", "persistence-after-relaunch", "keyboard")
$hasClaimSelection = $PSBoundParameters.ContainsKey("ClaimId")

function Stop-UiScenario([string] $code) {
  $error = [InvalidOperationException]::new($code)
  $error.Data["UiScenarioCode"] = $code
  throw $error
}

function Get-UiScenarioDriveType([string] $root) {
  return [IO.DriveInfo]::new($root).DriveType
}

function Assert-UiScenarioPath([string] $path) {
  try {
    $full = [IO.Path]::GetFullPath($path)
    if ($full.StartsWith("\\") -or $full.IndexOf(":", 2) -ge 0) {
      Stop-UiScenario "UnsafePath"
    }
    if ((Get-UiScenarioDriveType ([IO.Path]::GetPathRoot($full))) -eq [IO.DriveType]::Network) {
      Stop-UiScenario "UnsafePath"
    }
    $current = $full
    while ($current) {
      $item = Get-Item -LiteralPath $current -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-UiScenario "UnsafePath"
      }
      $current = [IO.Path]::GetDirectoryName($current)
    }
    return $full
  } catch {
    Stop-UiScenario "UnsafePath"
  }
}

function Get-UiScenarioHash([byte[]] $bytes) {
  return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Assert-UiScenarioKeys([Text.Json.JsonElement] $element) {
  switch ($element.ValueKind) {
    Object {
      $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
      foreach ($property in $element.EnumerateObject()) {
        if (-not $names.Add($property.Name)) { Stop-UiScenario "DuplicateProperty" }
        Assert-UiScenarioKeys $property.Value
      }
    }
    Array {
      foreach ($child in $element.EnumerateArray()) { Assert-UiScenarioKeys $child }
    }
  }
}

function Read-UiScenarioJson([string] $path) {
  $full = Assert-UiScenarioPath $path
  $document = $null
  try {
    $stream = [IO.File]::OpenRead($full)
    try {
      if ($stream.Length -eq 0 -or $stream.Length -gt 1MB) { Stop-UiScenario "DocumentSize" }
      $bytes = [byte[]]::new([int]$stream.Length)
      $stream.ReadExactly($bytes, 0, $bytes.Length)
      if ($stream.ReadByte() -ne -1) { Stop-UiScenario "DocumentSize" }
    } finally { $stream.Dispose() }
    $text = $utf8.GetString($bytes)
    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 32
    $document = [Text.Json.JsonDocument]::Parse($text, $options)
    if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
      Stop-UiScenario "DocumentRoot"
    }
    Assert-UiScenarioKeys $document.RootElement
    return @{
      text = $text
      hash = Get-UiScenarioHash $bytes
      data = ConvertFrom-Json -InputObject $text -AsHashtable -DateKind String -Depth 32
    }
  } catch {
    if ($_.Exception.Data.Contains("UiScenarioCode")) { throw }
    Stop-UiScenario "InvalidJson"
  } finally {
    if ($null -ne $document) { $document.Dispose() }
  }
}

function Assert-UiScenarioLocalRefs($node) {
  if ($node -is [Collections.IDictionary]) {
    foreach ($key in $node.Keys) {
      if ($key -ceq '$ref' -and $node[$key] -cnotmatch '^#/definitions/[A-Za-z]+\z') {
        Stop-UiScenario "UnsafeSchemaReference"
      }
      Assert-UiScenarioLocalRefs $node[$key]
    }
  } elseif ($node -is [array]) {
    foreach ($child in $node) { Assert-UiScenarioLocalRefs $child }
  }
}

function Assert-UiScenarioSchema($json, [string] $schemaName) {
  $schema = Read-UiScenarioJson (Join-Path $schemaRoot $schemaName)
  Assert-UiScenarioLocalRefs $schema.data
  try {
    $valid = Test-Json -Json $json.text -Schema $schema.text -ErrorAction SilentlyContinue
  } catch { Stop-UiScenario "SchemaInvalid" }
  if (-not $valid) { Stop-UiScenario "SchemaInvalid" }
  return $schema.hash
}

function Assert-UiScenarioAuthority($authority) {
  if ($AuthoritySha256 -cnotmatch '^[a-f0-9]{64}\z' -or $authority.hash -cne $AuthoritySha256) {
    Stop-UiScenario "ClaimAuthorityMismatch"
  }
  $data = $authority.data
  $expectedUrl = "https://github.com/scgopi/GraphCode/issues/$($data.issueNumber)#issuecomment-$($data.sourceCommentId)"
  if ($data.sourceUrl -cne $expectedUrl) { Stop-UiScenario "ClaimAuthorityMismatch" }
  $timestamp = [DateTimeOffset]::MinValue
  if (-not [DateTimeOffset]::TryParseExact($data.sourceUpdatedAt,
      [string[]]@("yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'"),
      [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$timestamp)) {
    Stop-UiScenario "ClaimAuthorityMismatch"
  }
  $claims = @{}
  foreach ($claim in $data.claims) {
    if (-not $claim.id.StartsWith("$($data.issueNumber)-C", [StringComparison]::Ordinal) -or
        (Get-UiScenarioHash $utf8.GetBytes($claim.criterion)) -cne $claim.criterionSha256) {
      Stop-UiScenario "ClaimAuthorityMismatch"
    }
    if ($claims.ContainsKey($claim.id)) { Stop-UiScenario "DuplicateClaim" }
    $claims[$claim.id] = $claim
  }
  return $claims
}

function Resolve-UiScenarioFixture($scenario, [string] $root) {
  $fixture = $scenario.fixture
  $directory = Join-Path $root ("fixtures\" + $fixture.id)
  $manifest = Read-UiScenarioJson (Join-Path $directory "manifest.json")
  $schemaHash = Assert-UiScenarioSchema $manifest "fixture.schema.json"
  if ($manifest.hash -cne $fixture.manifestSha256 -or
      $manifest.data.fixtureId -cne $fixture.id -or $manifest.data.fixtureVersion -ne $fixture.version) {
    Stop-UiScenario "FixtureMismatch"
  }
  $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($file in $manifest.data.files) {
    $segments = $file.path -split '[\\/]'
    foreach ($segment in $segments) {
      if ($segment -in @("", ".", "..") -or $segment -match '[<>:"|?*\x00-\x1f]' -or
          $segment.EndsWith(".") -or $segment.EndsWith(" ") -or
          $segment -match '^(?i:CON|PRN|AUX|NUL|COM[0-9\u00b9\u00b2\u00b3]|LPT[0-9\u00b9\u00b2\u00b3])(?:[ .]|$)' -or
          $segment -match '^(?i:CONIN\$|CONOUT\$|CLOCK\$)(?:\.|$)') {
        Stop-UiScenario "UnsafeFixturePath"
      }
    }
    $relative = $segments -join "\"
    if (-not $paths.Add($relative)) { Stop-UiScenario "DuplicateFixtureFile" }
    $full = Assert-UiScenarioPath (Join-Path $directory $relative)
    if ((Get-Item -LiteralPath $full).PSIsContainer) { Stop-UiScenario "UnsafeFixturePath" }
    if ((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256) {
      Stop-UiScenario "FixtureFileMismatch"
    }
  }
  return [ordered]@{ id = $fixture.id; version = $fixture.version; manifestSha256 = $manifest.hash
    fileCount = $paths.Count; schemaSha256 = $schemaHash }
}

function Assert-UiScenarioRootAnchor($target) {
  if ($target.scope -cne "owned-root" -or $target.controlType -cne "Window") {
    Stop-UiScenario "HealthyRootRequired"
  }
}

function Assert-UiScenarioAssertion($assertion) {
  if ($assertion.kind -ceq "absent") {
    Assert-UiScenarioRootAnchor $assertion.healthyRoot
    if ($assertion.target.automationId -ceq $assertion.healthyRoot.automationId -and
        $assertion.target.scope -ceq $assertion.healthyRoot.scope) {
      Stop-UiScenario "HealthyRootRequired"
    }
  }
}

function Get-UiScenarioCoverage($scenario, $claim) {
  if ($claim.proofClass -ceq "visual" -or
      ($scenario.coverage -ceq "complete-semantic" -and $claim.proofClass -cne "semantic-uia")) {
    Stop-UiScenario "ProofClassMismatch"
  }
  $caseIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $covered = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $caseCount = 0
  $assertionCount = 0
  $budget = 0L
  foreach ($case in $scenario.cases) {
    if (-not $caseIds.Add($case.id)) { Stop-UiScenario "DuplicateCase" }
    if (-not $claim.states[$case.state].required) { Stop-UiScenario "StateNotApplicable" }
    $null = $covered.Add($case.state)
    Assert-UiScenarioRootAnchor $case.preconditions.readyRoot
    $allocated = [long]$case.preconditions.timeoutMs + $case.cleanup.timeoutMs
    foreach ($assertion in @($case.preconditions.initial) + @($case.expected)) {
      Assert-UiScenarioAssertion $assertion
      $assertionCount++
    }
    foreach ($step in $case.steps) {
      $allocated += $step.timeoutMs
      if ($step.operation -ceq "send-keys" -and $case.tier -cne "interactive") {
        Stop-UiScenario "InputTierRequired"
      }
      if ($step.operation -ceq "wait-for") {
        Assert-UiScenarioAssertion $step.expected
        $assertionCount++
      }
      if ($step.operation -ceq "relaunch") { Assert-UiScenarioRootAnchor $step.readyRoot }
    }
    if ($case.state -ceq "keyboard" -and
        @($case.steps | Where-Object operation -CEQ "send-keys").Count -eq 0) {
      Stop-UiScenario "KeyboardStepRequired"
    }
    if ($case.state -ceq "persistence-after-relaunch" -and
        @($case.steps | Where-Object operation -CEQ "relaunch").Count -eq 0) {
      Stop-UiScenario "RelaunchStepRequired"
    }
    if ($allocated -gt $case.timeoutMs) { Stop-UiScenario "CaseBudgetExceeded" }
    $budget += $case.timeoutMs
    $caseCount++
  }
  if ($budget -gt 180000) { Stop-UiScenario "ScenarioBudgetExceeded" }
  $uncovered = @($states | Where-Object { $claim.states[$_].required -and -not $covered.Contains($_) })
  if ($scenario.coverage -ceq "complete-semantic" -and $uncovered.Count -gt 0) {
    Stop-UiScenario "IncompleteSemanticCoverage"
  }
  $components = @(switch ($claim.proofClass) {
    "mixed" { @("non-uia-evidence-required-by-criterion") }
    "input" { @("input-transport-and-end-state", "physical-input-if-required-by-criterion") }
    default { @() }
  })
  return [ordered]@{ claimId = $scenario.claimId; coverage = $scenario.coverage; proofClass = $claim.proofClass
    coveredStates = @($states | Where-Object { $covered.Contains($_) })
    uncoveredRequiredStates = $uncovered; uncoveredProofComponents = @($components)
    caseCount = $caseCount; assertionCount = $assertionCount; budgetMs = $budget }
}

function Test-UiScenarioSet {
  $root = Assert-UiScenarioPath $ScenarioRoot
  if (-not (Get-Item -LiteralPath $root).PSIsContainer) { Stop-UiScenario "ScenarioRoot" }
  $authority = Read-UiScenarioJson $AuthorityPath
  $authoritySchemaHash = Assert-UiScenarioSchema $authority "claim-authority.schema.json"
  $claims = Assert-UiScenarioAuthority $authority
  $requested = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  if ($hasClaimSelection) {
    if ($ClaimId.Count -eq 0) { Stop-UiScenario "EmptySelection" }
    foreach ($id in $ClaimId) {
      if ($id -cnotmatch '^[1-9][0-9]*-C[1-9][0-9]*\z') { Stop-UiScenario "UnknownClaim" }
      if (-not $requested.Add($id)) { Stop-UiScenario "DuplicateRequest" }
      if (-not $claims.ContainsKey($id)) { Stop-UiScenario "UnknownClaim" }
    }
  }
  $scenarios = @{}
  $queue = [Collections.Generic.Queue[string]]::new()
  $queue.Enqueue($root)
  $scenarioSchemaHash = $null
  while ($queue.Count -gt 0) {
    $directory = $queue.Dequeue()
    foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
      if ($directory -ceq $root -and $item.PSIsContainer -and $item.Name -ceq "fixtures") { continue }
      $null = Assert-UiScenarioPath $item.FullName
      if ($item.PSIsContainer) { $queue.Enqueue($item.FullName); continue }
      if ($item.Extension -ine ".json") { continue }
      if ($directory -ceq $root -and
          $item.Name -cin @("scenario.schema.json", "claim-authority.schema.json", "fixture.schema.json")) { continue }
      $json = Read-UiScenarioJson $item.FullName
      $scenarioSchemaHash = Assert-UiScenarioSchema $json "scenario.schema.json"
      $id = $json.data.claimId
      if ($scenarios.ContainsKey($id)) { Stop-UiScenario "DuplicateClaimFile" }
      if ($directory -cne $root -or $item.Name -cne "$id.json") { Stop-UiScenario "ScenarioFileIdentity" }
      $scenarios[$id] = $json
    }
  }
  if ($scenarios.Count -eq 0) { Stop-UiScenario "EmptySelection" }
  foreach ($id in $requested) {
    if (-not $scenarios.ContainsKey($id)) { Stop-UiScenario "MissingScenario" }
  }
  $selectedIds = @(if ($requested.Count -gt 0) { @($requested | Sort-Object -CaseSensitive) } else {
    @($scenarios.Keys | Sort-Object -CaseSensitive)
  })
  $coverage = @()
  $fixtures = @()
  $scenarioHashes = [ordered]@{}
  $caseCount = 0
  $assertionCount = 0
  foreach ($id in $selectedIds) {
    $json = $scenarios[$id]
    if (-not $claims.ContainsKey($id) -or $json.data.authoritySha256 -cne $authority.hash) {
      Stop-UiScenario "ClaimAuthorityMismatch"
    }
    $fixtures += Resolve-UiScenarioFixture $json.data $root
    $report = Get-UiScenarioCoverage $json.data $claims[$id]
    $coverage += $report
    $scenarioHashes[$id] = $json.hash
    $caseCount += $report.caseCount
    $assertionCount += $report.assertionCount
  }
  if ($selectedIds.Count -eq 0 -or $caseCount -eq 0 -or $assertionCount -eq 0) {
    Stop-UiScenario "EmptySelection"
  }
  return [ordered]@{
    status = "valid-data"
    schemaVersion = 1
    authoritySha256 = $authority.hash
    schemaHashes = @{ authority = $authoritySchemaHash; scenario = $scenarioSchemaHash }
    scenarioHashes = $scenarioHashes
    documentCount = $selectedIds.Count
    caseCount = $caseCount
    assertionCount = $assertionCount
    selectedClaimIds = $selectedIds
    fixtures = $fixtures
    coverage = $coverage
  }
}

try {
  Test-UiScenarioSet | ConvertTo-Json -Depth 32 -Compress
  exit 0
} catch {
  $code = if ($_.Exception.Data.Contains("UiScenarioCode")) { $_.Exception.Data["UiScenarioCode"] } else { "ValidationError" }
  [Console]::Error.WriteLine("UiScenario: $code (offline data validation refused)")
  exit 1
}
