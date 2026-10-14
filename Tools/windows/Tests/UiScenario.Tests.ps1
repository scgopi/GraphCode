$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$validator = Join-Path $repoRoot "Tools\windows\Test-UiScenario.ps1"
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$scratch = Join-Path ([IO.Path]::GetTempPath()) ("gc-ui-contract-" + [guid]::NewGuid().ToString("N"))
$utf8 = [Text.UTF8Encoding]::new($false)
$results = [Collections.Generic.List[object]]::new()

function Assert-Contract([bool] $condition, [string] $message) {
  if (-not $condition) { throw "RED: $message" }
}
function Write-Json([string] $path, $data) {
  [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $data -Depth 32 -Compress), $utf8)
}
function Hash-File([string] $path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Hash-Text([string] $text) {
  return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($text))).ToLowerInvariant()
}
function Invoke-Validator([hashtable] $arguments = @{}) {
  $parameters = @{ ScenarioRoot = $root; AuthorityPath = $authorityPath; AuthoritySha256 = $authorityHash }
  foreach ($key in $arguments.Keys) { $parameters[$key] = $arguments[$key] }
  $serialized = ConvertTo-Json -InputObject $parameters -Compress
  $escaped = $serialized.Replace("'", "''")
  $command = "`$p = ConvertFrom-Json -AsHashtable '$escaped'; & '$($validator.Replace("'", "''"))' @p"
  $start = [Diagnostics.ProcessStartInfo]::new($pwsh)
  $start.UseShellExecute = $false
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  foreach ($arg in @("-NoProfile", "-NonInteractive", "-EncodedCommand",
      [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))) { $start.ArgumentList.Add($arg) }
  $process = [Diagnostics.Process]::Start($start)
  try {
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(20000)) {
      $process.Kill($true)
      $process.WaitForExit()
      throw "Validator child exceeded 20 seconds"
    }
    return @{ exitCode = $process.ExitCode; output = $stdout.GetAwaiter().GetResult().Trim()
      error = $stderr.GetAwaiter().GetResult() }
  } finally { $process.Dispose() }
}
function Reset-Inputs {
  $script:root = Join-Path $scratch ("case-" + $results.Count)
  $script:fixtureRoot = Join-Path $root "fixtures\synthetic"
  $script:scenarioPath = Join-Path $root "818-C1.json"
  $script:dataPath = Join-Path $fixtureRoot "data.txt"
  $script:manifestPath = Join-Path $fixtureRoot "manifest.json"
  $script:authorityPath = Join-Path $scratch ("authority-" + $results.Count + ".json")
  $null = New-Item -ItemType Directory -Path $fixtureRoot
  [IO.File]::WriteAllText($dataPath, $baseData, $utf8)
  $script:authority = ConvertFrom-Json $baseAuthority -AsHashtable -DateKind String
  $script:manifest = ConvertFrom-Json $baseManifest -AsHashtable
  $script:scenario = ConvertFrom-Json $baseScenario -AsHashtable
  Save-Inputs
}
function Save-Inputs {
  Write-Json $manifestPath $manifest
  Write-Json $authorityPath $authority
  $script:authorityHash = Hash-File $authorityPath
  $scenario.authoritySha256 = $authorityHash
  $scenario.fixture.manifestSha256 = Hash-File $manifestPath
  Write-Json $scenarioPath $scenario
}
function Refuse([string] $code, [hashtable] $arguments = @{}) {
  $result = Invoke-Validator $arguments
  Assert-Contract ($result.exitCode -ne 0 -and $result.error.Contains("UiScenario: $code ")) `
    "expected $code refusal, exit=$($result.exitCode) error=$($result.error)"
  Assert-Contract (-not ($result.output + $result.error).Contains("SECRET_CANARY")) "private input leaked"
}
function Accept([hashtable] $arguments = @{}) {
  $result = Invoke-Validator $arguments
  Assert-Contract ($result.exitCode -eq 0 -and $result.error.Length -eq 0) "positive data refused: $($result.error)"
  $summary = ConvertFrom-Json $result.output
  Assert-Contract ($summary.status -ceq "valid-data" -and $summary.documentCount -gt 0 -and
    $summary.caseCount -gt 0 -and $summary.assertionCount -gt 0 -and
    $summary.authoritySha256 -ceq $authorityHash) "positive structured counts/binding absent"
  Assert-Contract ($result.output -notmatch 'verified|verdict|SECRET_CANARY') "data report implies UI verification"
  return $summary
}
function Test-Contract([string] $name, [scriptblock] $body) {
  Reset-Inputs
  & $body
  $results.Add(@{ name = $name; passed = $true })
  Write-Host "PASS: $name"
}
function Assert-PathRefusedBeforeRead([string] $path, [IO.DriveType] $driveType = [IO.DriveType]::Fixed) {
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($validator, [ref]$null, [ref]$errors)
  Assert-Contract ($errors.Count -eq 0) "validator does not parse"
  foreach ($definition in $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -cin @("Stop-UiScenario", "Assert-UiScenarioPath")
    }, $true)) { . ([scriptblock]::Create($definition.Extent.Text)) }
  $script:pathGuardReads = 0
  function Get-UiScenarioDriveType {
    param([string] $root)
    return $driveType
  }
  function Get-Item {
    param([string] $LiteralPath, [switch] $Force)
    $script:pathGuardReads++
    throw "Filesystem access forbidden in path guard probe"
  }
  $code = $null
  try { $null = Assert-UiScenarioPath $path } catch { $code = $_.Exception.Data["UiScenarioCode"] }
  Assert-Contract ($code -ceq "UnsafePath" -and $script:pathGuardReads -eq 0) `
    "unsafe caller path reached filesystem before refusal"
}

try {
  $root = Join-Path $scratch "scenarios"
  $fixtureRoot = Join-Path $root "fixtures\synthetic"
  $null = New-Item -ItemType Directory -Path $fixtureRoot
  $authorityPath = Join-Path $scratch "external-authority.json"
  $scenarioPath = Join-Path $root "818-C1.json"
  $dataPath = Join-Path $fixtureRoot "data.txt"
  [IO.File]::WriteAllText($dataPath, "Synthetic offline fixture, not product evidence.", $utf8)
  $manifest = @{ schemaVersion = 1; fixtureId = "synthetic"; fixtureVersion = 1
    files = @(@{ path = "data.txt"; sha256 = Hash-File $dataPath }) }
  $manifestPath = Join-Path $fixtureRoot "manifest.json"
  Write-Json $manifestPath $manifest
  $states = @{}
  foreach ($state in @("success", "empty", "error", "disabled", "persistence-after-relaunch", "keyboard")) {
    $states[$state] = @{ required = ($state -ceq "success"); reason = "Synthetic contract applicability only." }
  }
  $criterion = "Synthetic semantic claim; no actual product acceptance statement."
  $authority = @{ schemaVersion = 1; repository = "scgopi/GraphCode"; issueNumber = 818
    sourceUrl = "https://github.com/scgopi/GraphCode/issues/818#issuecomment-1"; sourceCommentId = 1
    sourceUpdatedAt = "2026-10-14T00:00:00Z"; sourceBodySha256 = Hash-Text "Synthetic source body."
    claims = @(@{ id = "818-C1"; criterion = $criterion; criterionSha256 = Hash-Text $criterion
      proofClass = "semantic-uia"; states = $states }) }
  Write-Json $authorityPath $authority
  $authorityHash = Hash-File $authorityPath
  $target = @{ automationId = "synthetic-button"; controlType = "Button"; scope = "owned-root"; matchCount = 1 }
  $anchor = @{ automationId = "synthetic-root"; controlType = "Window"; scope = "owned-root"; matchCount = 1 }
  $assertion = @{ kind = "property"; target = $target; property = "IsEnabled"; value = $true }
  $scenario = @{ schemaVersion = 1; claimId = "818-C1"; authoritySha256 = $authorityHash; coverage = "complete-semantic"
    fixture = @{ id = "synthetic"; version = 1; manifestSha256 = Hash-File $manifestPath }
    cases = @(@{ id = "synthetic-success"; state = "success"; tier = "uia"
      preconditions = @{ profile = "owned-isolated"; process = "owned-production"; readyRoot = $anchor
        initial = @($assertion); timeoutMs = 1000 }
      steps = @(@{ operation = "invoke"; target = $target; timeoutMs = 1000 })
      expected = @($assertion); timeoutMs = 5000
      cleanup = @{ intent = "owned-processes-and-fixture"; timeoutMs = 1000 } }) }
  Write-Json $scenarioPath $scenario
  $baseData = [IO.File]::ReadAllText($dataPath)
  $baseAuthority = [IO.File]::ReadAllText($authorityPath)
  $baseManifest = [IO.File]::ReadAllText($manifestPath)
  $baseScenario = [IO.File]::ReadAllText($scenarioPath)
  Test-Contract "positive synthetic data has nonzero document/case/assertion counts" {
    $summary = Accept
    Assert-Contract ($summary.documentCount -eq 1 -and $summary.caseCount -eq 1 -and
      $summary.assertionCount -eq 2 -and $summary.fixtures[0].fileCount -eq 1 -and
      $summary.coverage[0].uncoveredRequiredStates.Count -eq 0) "exact positive counts wrong"
  }
  Test-Contract "wrong authority revision is refused with ClaimAuthorityMismatch" {
    $scenario.authoritySha256 = "a" * 64
    Write-Json $scenarioPath $scenario
    Refuse "ClaimAuthorityMismatch"
  }
  foreach ($parameter in @("ScenarioRoot", "AuthorityPath")) {
    foreach ($path in @('\\server\share\root', '//server/share/root', '\\?\C:\root', 'C:\owned\file.json:stream')) {
      Test-Contract "$parameter refuses UNC device or ADS before filesystem access: $path" {
        Assert-PathRefusedBeforeRead $path
        Refuse "UnsafePath" @{ $parameter = $path }
      }
    }
  }
  Test-Contract "mapped network drive refuses before filesystem access" {
    Assert-PathRefusedBeforeRead 'Z:\owned\scenario' ([IO.DriveType]::Network)
  }
  Test-Contract "authority reparse ancestor refused" {
    $directory = Join-Path $scratch "authority-copy"
    $null = New-Item -ItemType Directory -Path $directory -Force
    Copy-Item -LiteralPath $authorityPath -Destination (Join-Path $directory "external-authority.json")
    $link = Join-Path $scratch "authority-link"
    $null = New-Item -ItemType Junction -Path $link -Target $directory
    try {
      Refuse "UnsafePath" @{ AuthorityPath = (Join-Path $link "external-authority.json") }
    } finally { Remove-Item -LiteralPath $link -Force }
  }
  Test-Contract "wrong caller hash" { Refuse "ClaimAuthorityMismatch" @{ AuthoritySha256 = "a" * 64 } }
  Test-Contract "missing authority" { Refuse "UnsafePath" @{ AuthorityPath = (Join-Path $scratch "missing.json") } }
  foreach ($mutation in @("issue", "repo", "comment", "source", "criterion", "claim-prefix", "date", "duplicate")) {
    Test-Contract "authority refuses $mutation" {
      $code = "ClaimAuthorityMismatch"
      switch ($mutation) {
        "issue" { $authority.issueNumber = 819 }
        "repo" { $authority.repository = "other/SECRET_CANARY"; $code = "SchemaInvalid" }
        "comment" { $authority.sourceCommentId = 2 }
        "source" { $authority.sourceUrl = "https://github.com/scgopi/GraphCode/issues/819#issuecomment-1" }
        "criterion" { $authority.claims[0].criterion += " changed" }
        "claim-prefix" { $authority.claims[0].id = "819-C1" }
        "date" { $authority.sourceUpdatedAt = "2026-02-30T00:00:00Z" }
        "duplicate" { $authority.claims += $authority.claims[0]; $code = "DuplicateClaim" }
      }
      Save-Inputs
      Refuse $code
    }
  }
  foreach ($mutation in @("source-revision", "applicability")) {
    Test-Contract "external trusted hash rejects edited $mutation" {
      if ($mutation -ceq "source-revision") { $authority.sourceUpdatedAt = "2026-10-15T00:00:00Z" } else {
        $authority.claims[0].states.success.required = $false
      }
      Write-Json $authorityPath $authority
      Refuse "ClaimAuthorityMismatch"
    }
  }
  foreach ($mutation in @("malformed", "truncated", "null", "scalar", "array", "empty", "oversize", "depth", "utf8")) {
    Test-Contract "parser refuses $mutation" {
      $code = "InvalidJson"
      switch ($mutation) {
        "malformed" { $text = '{"SECRET_CANARY":}' }
        "truncated" { $text = $baseScenario.Substring(0, $baseScenario.Length - 1) }
        "null" { $text = "null"; $code = "DocumentRoot" }
        "scalar" { $text = '"SECRET_CANARY"'; $code = "DocumentRoot" }
        "array" { $text = "[]"; $code = "DocumentRoot" }
        "empty" { $text = ""; $code = "DocumentSize" }
        "oversize" { $text = " " * (1MB + 1); $code = "DocumentSize" }
        "depth" { $text = '{"nested":' + ("[" * 33) + "0" + ("]" * 33) + "}" }
        "utf8" {
          [IO.File]::WriteAllBytes($scenarioPath, [byte[]]@(123, 34, 255, 34, 58, 49, 125))
          Refuse $code
          return
        }
      }
      [IO.File]::WriteAllText($scenarioPath, $text, $utf8)
      Refuse $code
    }
  }
  foreach ($document in @("scenario", "authority", "manifest")) {
    foreach ($duplicate in @('{"schemaVersion":1,', '{"SchemaVersion":1,')) {
      Test-Contract "$document recursive duplicate root property $duplicate" {
        $path = switch ($document) { "scenario" { $scenarioPath }; "authority" { $authorityPath }; "manifest" { $manifestPath } }
        $text = [IO.File]::ReadAllText($path)
        [IO.File]::WriteAllText($path, ($duplicate + $text.Substring(1)), $utf8)
        Refuse "DuplicateProperty"
      }
    }
  }
  foreach ($level in @("fixture", "case", "preconditions", "target", "assertion", "step", "cleanup", "state", "file")) {
    Test-Contract "duplicate property in nested $level" {
      $path = $scenarioPath
      $needle = switch ($level) {
        "fixture" { '"manifestSha256":' }; "case" { '"tier":' }; "preconditions" { '"profile":' }
        "target" { '"automationId":' }; "assertion" { '"kind":' }; "step" { '"operation":' }
        "cleanup" { '"intent":' }; "state" { $path = $authorityPath; '"reason":' }
        "file" { $path = $manifestPath; '"path":' }
      }
      $text = [IO.File]::ReadAllText($path)
      $text = $text.Replace($needle, ($needle + '"SECRET_CANARY",' + $needle))
      [IO.File]::WriteAllText($path, $text, $utf8)
      Refuse "DuplicateProperty"
    }
  }
  foreach ($mutation in @("unknown", "version", "claim-null", "claim-empty", "case-empty", "steps-empty", "expected-empty",
      "cases-missing", "action", "property", "proof", "approval", "coordinates", "visual-tier", "command", "cleanup-missing", "cleanup-disabled")) {
    Test-Contract "scenario schema refuses $mutation" {
      switch ($mutation) {
        "unknown" { $scenario.SECRET_CANARY = "ignored?" }
        "version" { $scenario.schemaVersion = 2 }
        "claim-null" { $scenario.claimId = $null }
        "claim-empty" { $scenario.claimId = "" }
        "case-empty" { $scenario.cases = @() }
        "steps-empty" { $scenario.cases[0].steps = @() }
        "expected-empty" { $scenario.cases[0].expected = @() }
        "cases-missing" { $scenario.Remove("cases") }
        "action" { $scenario.cases[0].steps[0].operation = "SECRET_CANARY" }
        "property" { $scenario.cases[0].expected[0].property = "SECRET_CANARY" }
        "proof" { $scenario.proofClass = "physical-input" }
        "approval" { $scenario.reviewed = $true }
        "coordinates" { $scenario.cases[0].steps[0].x = 1 }
        "visual-tier" { $scenario.cases[0].tier = "visual" }
        "command" { $scenario.cases[0].steps[0].command = "Set-Content '$scratch\executed' SECRET_CANARY" }
        "cleanup-missing" { $scenario.cases[0].Remove("cleanup") }
        "cleanup-disabled" { $scenario.cases[0].cleanup.intent = "none" }
      }
      Save-Inputs
      Refuse "SchemaInvalid"
      Assert-Contract (-not (Test-Path -LiteralPath (Join-Path $scratch "executed"))) "command canary executed"
    }
  }
  Test-Contract "unknown authority claim" {
    $scenario.claimId = "818-C99"
    Save-Inputs
    Move-Item -LiteralPath $scenarioPath -Destination (Join-Path $root "818-C99.json")
    Refuse "ClaimAuthorityMismatch"
  }
  Test-Contract "duplicate case identity" {
    $scenario.cases += $scenario.cases[0]; Save-Inputs; Refuse "DuplicateCase"
  }
  Test-Contract "mislabeled file identity" {
    Move-Item -LiteralPath $scenarioPath -Destination (Join-Path $root "818-C2.json"); Refuse "ScenarioFileIdentity"
  }
  Test-Contract "duplicate claim files" {
    $directory = New-Item -ItemType Directory -Path (Join-Path $root "nested")
    Copy-Item $scenarioPath (Join-Path $directory.FullName "818-C1.json"); Refuse "DuplicateClaimFile"
  }
  Test-Contract "unexpected JSON is not ignored" {
    [IO.File]::WriteAllText((Join-Path $root "unexpected.json"), "{}", $utf8); Refuse "SchemaInvalid"
  }
  Test-Contract "schema-only production discovery fails" {
    Remove-Item -LiteralPath $scenarioPath
    Copy-Item (Join-Path $repoRoot "windows-tests\ui-scenarios\scenario.schema.json") $root
    Refuse "EmptySelection"
  }
  Test-Contract "empty scenario directory" {
    Remove-Item -LiteralPath $scenarioPath; Refuse "EmptySelection"
  }
  Test-Contract "exact requested claim" { $null = Accept @{ ClaimId = @("818-C1") } }
  Test-Contract "unknown requested claim" { Refuse "UnknownClaim" @{ ClaimId = @("818-C99") } }
  Test-Contract "duplicate requested claim" { Refuse "DuplicateRequest" @{ ClaimId = @("818-C1", "818-C1") } }
  Test-Contract "empty requested selection" { Refuse "EmptySelection" @{ ClaimId = @() } }
  Test-Contract "known claim missing scenario" {
    $claim = ConvertFrom-Json (ConvertTo-Json $authority.claims[0] -Depth 32) -AsHashtable
    $claim.id = "818-C2"; $authority.claims += $claim; Save-Inputs
    Refuse "MissingScenario" @{ ClaimId = @("818-C2") }
  }
  Test-Contract "multiple states and exact hashes reported" {
    $authority.claims[0].states.empty.required = $true
    $case = ConvertFrom-Json (ConvertTo-Json $scenario.cases[0] -Depth 32) -AsHashtable
    $case.id = "synthetic-empty"; $case.state = "empty"
    $case.expected[0].property = "Value"; $case.expected[0].value = ""
    $scenario.cases += $case; Save-Inputs
    $summary = Accept
    Assert-Contract ($summary.caseCount -eq 2 -and $summary.assertionCount -eq 4 -and
      $summary.scenarioHashes.'818-C1' -ceq (Hash-File $scenarioPath) -and
      $summary.fixtures[0].manifestSha256 -ceq (Hash-File $manifestPath)) "multiple-state hashes/counts wrong"
  }
  Test-Contract "mixed component reports uncovered states and proof" {
    $authority.claims[0].proofClass = "mixed"; $authority.claims[0].states.error.required = $true
    $scenario.coverage = "component"; Save-Inputs
    $summary = Accept
    Assert-Contract ($summary.coverage[0].uncoveredRequiredStates -contains "error" -and
      $summary.coverage[0].uncoveredProofComponents.Count -gt 0) "mixed claim silently closed"
  }
  Test-Contract "input component remains incomplete evidence" {
    $authority.claims[0].proofClass = "input"; $scenario.coverage = "component"; Save-Inputs
    $summary = Accept
    Assert-Contract ($summary.coverage[0].uncoveredProofComponents.Count -gt 0) "input proof silently closed"
  }
  foreach ($proof in @("visual", "mixed", "input")) {
    Test-Contract "$proof cannot declare complete semantic coverage" {
      $authority.claims[0].proofClass = $proof; Save-Inputs; Refuse "ProofClassMismatch"
    }
  }
  Test-Contract "pure visual claim rejects component scenarios too" {
    $authority.claims[0].proofClass = "visual"; $scenario.coverage = "component"
    Save-Inputs; Refuse "ProofClassMismatch"
  }
  Test-Contract "complete semantic requires every applicable state" {
    $authority.claims[0].states.error.required = $true; Save-Inputs; Refuse "IncompleteSemanticCoverage"
  }
  Test-Contract "not-applicable state cannot be manufactured" {
    $scenario.cases[0].state = "error"; Save-Inputs; Refuse "StateNotApplicable"
  }
  foreach ($transport in @("post-message", "send-input")) {
    Test-Contract "interactive $transport is valid data not physical proof" {
      $scenario.cases[0].tier = "interactive"
      $scenario.cases[0].steps = @(@{ operation = "send-keys"; target = $target
        keys = "ENTER"; transport = $transport; timeoutMs = 1000 })
      Save-Inputs; $null = Accept
    }
  }
  Test-Contract "send-keys requires interactive tier" {
    $scenario.cases[0].steps = @(@{ operation = "send-keys"; target = $target
      keys = "ENTER"; transport = "post-message"; timeoutMs = 1000 })
    Save-Inputs; Refuse "InputTierRequired"
  }
  Test-Contract "keyboard state requires explicit key transport" {
    $authority.claims[0].states.keyboard.required = $true; $scenario.cases[0].state = "keyboard"
    $scenario.coverage = "component"; Save-Inputs; Refuse "KeyboardStepRequired"
  }
  Test-Contract "persistence state requires relaunch" {
    $authority.claims[0].states.'persistence-after-relaunch'.required = $true
    $scenario.cases[0].state = "persistence-after-relaunch"; $scenario.coverage = "component"
    Save-Inputs; Refuse "RelaunchStepRequired"
  }
  foreach ($mutation in @("empty", "wildcard", "newline", "name", "index", "first-match", "scope", "count-zero", "count-two", "count-bool", "type")) {
    Test-Contract "selector refuses $mutation" {
      $selector = $scenario.cases[0].steps[0].target
      switch ($mutation) {
        "empty" { $selector.automationId = "" }
        "wildcard" { $selector.automationId = "synthetic-*" }
        "newline" { $selector.automationId = "synthetic`n" }
        "name" { $selector.Name = "SECRET_CANARY" }
        "index" { $selector.index = 0 }
        "first-match" { $selector.firstMatch = $true }
        "scope" { $selector.scope = "desktop" }
        "count-zero" { $selector.matchCount = 0 }
        "count-two" { $selector.matchCount = 2 }
        "count-bool" { $selector.matchCount = $true }
        "type" { $selector.controlType = "SECRET_CANARY" }
      }
      Save-Inputs; Refuse "SchemaInvalid"
    }
  }
  Test-Contract "absence requires positive healthy root" {
    $scenario.cases[0].expected = @(@{ kind = "absent"; target = $target })
    Save-Inputs; Refuse "SchemaInvalid"
  }
  Test-Contract "absence anchor must be owned top-level Window" {
    $scenario.cases[0].expected = @(@{ kind = "absent"; target = $target; healthyRoot = $target })
    Save-Inputs; Refuse "HealthyRootRequired"
  }
  Test-Contract "absence cannot use its own target as healthy Window anchor" {
    $scenario.cases[0].expected = @(@{ kind = "absent"; target = $anchor; healthyRoot = $anchor })
    Save-Inputs; Refuse "HealthyRootRequired"
  }
  Test-Contract "absence with explicit healthy root accepted" {
    $scenario.cases[0].expected = @(@{ kind = "absent"; target = $target; healthyRoot = $anchor })
    Save-Inputs; $null = Accept
  }
  Test-Contract "explicit empty text accepted but missing value refused" {
    $scenario.cases[0].expected[0].property = "Value"; $scenario.cases[0].expected[0].value = ""
    Save-Inputs; $null = Accept
    $scenario.cases[0].expected[0].Remove("value"); Save-Inputs; Refuse "SchemaInvalid"
  }
  foreach ($operation in @("toggle", "select", "focus", "set-value", "wait-for", "relaunch")) {
    Test-Contract "closed operation $operation accepts its typed fields" {
      $step = @{ operation = $operation; target = $target; timeoutMs = 1000 }
      switch ($operation) {
        "set-value" { $step.value = "" }
        "wait-for" { $step.Remove("target"); $step.expected = $assertion }
        "relaunch" { $step.Remove("target"); $step.readyRoot = $anchor }
      }
      $scenario.cases[0].steps = @($step); Save-Inputs; $null = Accept
    }
  }
  foreach ($mutation in @("manifest-missing", "data-missing", "manifest-hash", "file-hash", "id", "version", "schema",
      "duplicate", "empty")) {
    Test-Contract "fixture refuses $mutation" {
      $code = "FixtureMismatch"
      switch ($mutation) {
        "manifest-missing" { Remove-Item -LiteralPath $manifestPath; $code = "UnsafePath" }
        "data-missing" { Remove-Item -LiteralPath $dataPath; $code = "UnsafePath" }
        "manifest-hash" { $scenario.fixture.manifestSha256 = "a" * 64; Write-Json $scenarioPath $scenario }
        "file-hash" { [IO.File]::WriteAllText($dataPath, "changed", $utf8); $code = "FixtureFileMismatch" }
        "id" { $manifest.fixtureId = "different"; Save-Inputs }
        "version" { $manifest.fixtureVersion = 2; Save-Inputs }
        "schema" { $manifest.schemaVersion = 2; Save-Inputs; $code = "SchemaInvalid" }
        "duplicate" { $manifest.files += $manifest.files[0]; Save-Inputs; $code = "DuplicateFixtureFile" }
        "empty" { $manifest.files = @(); Save-Inputs; $code = "SchemaInvalid" }
      }
      Refuse $code
    }
  }
  foreach ($path in @("..\data.txt", "/data.txt", "C:\data.txt", "\\server\data.txt", "\\?\C:\data.txt",
      "data.txt:secret", "NUL", "con.txt", "COM1.txt", "CONIN$", "CONOUT$", "CLOCK$", "CON .txt",
      ("COM" + [char]0x00b9 + ".txt"), "folder\..\data.txt", "data.txt.", "data.txt ", "a\\data.txt")) {
    Test-Contract "fixture path refuses $path" {
      $manifest.files[0].path = $path; Save-Inputs; Refuse "UnsafeFixturePath"
    }
  }
  Test-Contract "fixture reparse escape refused without reading foreign data" {
    $outside = Join-Path $scratch "outside"
    $null = New-Item -ItemType Directory -Path $outside -Force
    [IO.File]::WriteAllText((Join-Path $outside "SECRET_CANARY.txt"), "SECRET_CANARY", $utf8)
    $link = Join-Path $fixtureRoot "escape"
    $null = New-Item -ItemType Junction -Path $link -Target $outside
    try {
      $manifest.files[0].path = "escape\SECRET_CANARY.txt"; Save-Inputs; Refuse "UnsafePath"
    } finally { Remove-Item -LiteralPath $link -Force }
  }
  Test-Contract "reparse scenario root refused" {
    $link = Join-Path $scratch "scenario-link"
    $null = New-Item -ItemType Junction -Path $link -Target $root
    try { Refuse "UnsafePath" @{ ScenarioRoot = $link } } finally { Remove-Item -LiteralPath $link -Force }
  }
  foreach ($value in @("100", $true, -1, 0, 0.5, 10001)) {
    Test-Contract "ordinary deadline refuses $value" {
      $scenario.cases[0].steps[0].timeoutMs = $value; Save-Inputs; Refuse "SchemaInvalid"
    }
  }
  foreach ($mutation in @("relaunch", "cleanup", "case", "aggregate-case", "aggregate-scenario")) {
    Test-Contract "budget refuses $mutation" {
      $code = "SchemaInvalid"
      switch ($mutation) {
        "relaunch" {
          $scenario.cases[0].steps = @(@{ operation = "relaunch"; readyRoot = $anchor; timeoutMs = 30001 })
        }
        "cleanup" { $scenario.cases[0].cleanup.timeoutMs = 15001 }
        "case" { $scenario.cases[0].timeoutMs = 60001 }
        "aggregate-case" { $scenario.cases[0].timeoutMs = 2999; $code = "CaseBudgetExceeded" }
        "aggregate-scenario" {
          $scenario.cases[0].timeoutMs = 60000
          for ($index = 2; $index -le 4; $index++) {
            $case = ConvertFrom-Json (ConvertTo-Json $scenario.cases[0] -Depth 32) -AsHashtable
            $case.id = "synthetic-$index"; $scenario.cases += $case
          }
          $code = "ScenarioBudgetExceeded"
        }
      }
      Save-Inputs; Refuse $code
    }
  }
  foreach ($document in @("scenario", "authority", "fixture")) {
    Test-Contract "$document unknown version is refused" {
      switch ($document) {
        "scenario" { $scenario.schemaVersion = 99 }
        "authority" { $authority.schemaVersion = 99 }
        "fixture" { $manifest.schemaVersion = 99 }
      }
      Save-Inputs; Refuse "SchemaInvalid"
    }
  }
  foreach ($collection in @("cases", "steps", "expected")) {
    Test-Contract "$collection upper count bound" {
      if ($collection -ceq "cases") {
        $scenario.cases = @($scenario.cases[0]) * 17
      } else { $scenario.cases[0][$collection] = @($scenario.cases[0][$collection][0]) * 129 }
      Save-Inputs; Refuse "SchemaInvalid"
    }
  }
  Test-Contract "exact relaunch cleanup case and scenario budget upper boundaries" {
    $scenario.cases[0].preconditions.timeoutMs = 10000
    $scenario.cases[0].steps = @(@{ operation = "relaunch"; readyRoot = $anchor; timeoutMs = 30000 })
    $scenario.cases[0].cleanup.timeoutMs = 15000
    $scenario.cases[0].timeoutMs = 60000
    for ($index = 2; $index -le 3; $index++) {
      $case = ConvertFrom-Json (ConvertTo-Json $scenario.cases[0] -Depth 32) -AsHashtable
      $case.id = "boundary-$index"; $scenario.cases += $case
    }
    Save-Inputs
    $summary = Accept
    Assert-Contract ($summary.coverage[0].budgetMs -eq 180000) "exact maximum budget not reported"
  }
  Test-Contract "minimum deadlines and exact aggregate case budget" {
    $scenario.cases[0].preconditions.timeoutMs = 1; $scenario.cases[0].steps[0].timeoutMs = 1
    $scenario.cases[0].cleanup.timeoutMs = 1; $scenario.cases[0].timeoutMs = 3
    Save-Inputs; $null = Accept
  }
  Test-Contract "fixture directory is not a data file" {
    $null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot "directory")
    $manifest.files[0].path = "directory"; Save-Inputs; Refuse "UnsafeFixturePath"
  }
  Test-Contract "case-insensitive normalized fixture paths are duplicates" {
    $file = @{ path = "DATA.TXT"; sha256 = $manifest.files[0].sha256 }
    $manifest.files += $file; Save-Inputs; Refuse "DuplicateFixtureFile"
  }
  Test-Contract "strict case-sensitive scenario properties" {
    $scenario.SchemaVERSION = $scenario.schemaVersion; $scenario.Remove("schemaVersion")
    Save-Inputs; Refuse "SchemaInvalid"
  }
  Test-Contract "typed Toggle pattern assertion" {
    $scenario.cases[0].expected = @(@{ kind = "pattern"; target = $target; pattern = "Toggle"; value = "On" })
    Save-Inputs; $null = Accept
  }
  Test-Contract "positive keyboard and persistence cases retain component limits" {
    $authority.claims[0].proofClass = "mixed"
    $authority.claims[0].states.keyboard.required = $true
    $authority.claims[0].states.'persistence-after-relaunch'.required = $true
    $scenario.coverage = "component"
    $keyboard = ConvertFrom-Json (ConvertTo-Json $scenario.cases[0] -Depth 32) -AsHashtable
    $keyboard.id = "keyboard"; $keyboard.state = "keyboard"; $keyboard.tier = "interactive"
    $keyboard.steps = @(@{ operation = "send-keys"; target = $target
      keys = "ENTER"; transport = "send-input"; timeoutMs = 1000 })
    $persist = ConvertFrom-Json (ConvertTo-Json $scenario.cases[0] -Depth 32) -AsHashtable
    $persist.id = "persistence"; $persist.state = "persistence-after-relaunch"
    $persist.steps = @(@{ operation = "relaunch"; readyRoot = $anchor; timeoutMs = 1000 })
    $scenario.cases += @($keyboard, $persist); Save-Inputs
    $summary = Accept
    Assert-Contract ($summary.caseCount -eq 3 -and $summary.coverage[0].uncoveredRequiredStates.Count -eq 0 -and
      $summary.coverage[0].uncoveredProofComponents.Count -gt 0) "component became a whole-claim result"
  }
  Assert-Contract ($results.Count -gt 0) "zero invoked contract cases"
  Write-Host "All $($results.Count) offline contract tests passed"
  [ordered]@{ suite = "UiScenario"; executed = $results.Count; passed = $results.Count; failed = 0 } |
    ConvertTo-Json -Compress
} finally {
  if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
