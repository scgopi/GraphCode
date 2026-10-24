[CmdletBinding()]
param(
  [ValidateSet("IncompleteFlight", "CoreBoundary", "All")]
  [string] $Case = "All"
)

$ErrorActionPreference = "Stop"
$qualification = Join-Path $PSScriptRoot "PreviewCore.Qualification.ps1"
if (-not (Test-Path -LiteralPath $qualification -PathType Leaf)) {
  throw "PreviewCore qualification entrypoint is missing (structural contract RED; no product runtime ran)"
}
. $qualification -HelpersOnly

$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$root = Join-Path $repo (".build\preview-core-contract-" + [guid]::NewGuid().ToString("N"))
$executed = 0
$oldTemp = $env:TEMP
$oldTmp = $env:TMP

function New-ContractArtifact {
  $hashes = [ordered]@{}
  foreach ($name in @("metadata", "manifest", "providerProvenance", "shell", "daemon", "cli", "zmx")) {
    $hashes[$name] = "a" * 64
  }
  [pscustomobject]@{
    sourceCommit = "b" * 40; sha256 = "c" * 64; version = "1.2.3-alpha"
    tag = "v1.2.3-alpha"; tagCommit = "b" * 40
    tagMatchesSource = $true; tagMismatchAllowed = $false
    signing = "UNSIGNED (not code signed)"
    winghosttyCommit = "e0a5579f3b470bede72294d661282a391c502ace"
    zmxCommit = "785b3fd15dcafd1882b495c831a10f98c201b908"
    hashes = [pscustomobject]$hashes
  }
}

function New-ContractReference([string] $relative) {
  [pscustomobject]@{ path = $relative; sha256 = Get-PreviewCoreHash (Join-Path $root $relative) }
}

function New-ProductionCoreContract {
  $packet = New-PreviewCorePacket (New-ContractArtifact) $root ("d" * 64) |
    ConvertTo-Json -Depth 20 | ConvertFrom-Json
  $packet.testOnly = $true
  $packet.profile.os = "Windows Server (pure contract, not an executed profile)"
  $packet.profile.build = "contract-build"
  $packet.profile.role = "Server"
  $packet.profile.architecture = "x64"
  $packet.profile.shellVersion = "contract-shell"
  $packet.profile.nativeLease = "test-only; no native lease"
  $packet.profile.ownedAccountIsolationWitnessed = $true
  $packet.backend.kind = "copilotCLI"
  $packet.backend.version = "contract-version; no agent invoked"
  $packet.backend.executableSha256 = "e" * 64
  $packet.backend.permissions = "ask"
  $packet.backend.model = "backend default"
  $packet.backend.approval = "test-only; no credentials or credits granted"
  $packet.backend.authenticationProvisionedInOwnedAccount = $true
  $packet.runtime.daemon = "Production"
  $packet.runtime.installation = "ScheduledTask"
  $packet.runtime.seededModel = $false
  $packet.runtime.testHooks = $false
  $packet.runtime.supportDirectory = Join-Path $root "support"
  $packet.runtime.installDirectory = Join-Path $root "install"
  $packet.runtime.endpoint = "\\.\pipe\pure-contract-not-a-running-daemon"
  $packet.runtime.loopId = "D1111111-1111-4111-8111-111111111111"
  $packet.runtime.terminalSessionName = $packet.runtime.loopId
  $packet.runtime.backendSessionId = "opaque-conversation-id-not-a-guid"
  foreach ($name in @("shell", "daemon", "cli", "zmx")) {
    $packet.runtime.installedHashes.$name = $packet.artifact.hashes.$name
  }
  $prefix = "contract-" + [guid]::NewGuid().ToString("N")
  $png = "$prefix.png"
  [IO.File]::WriteAllBytes((Join-Path $root $png), [Convert]::FromBase64String(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lX8AAAAASUVORK5CYII="))
  $build = "$prefix-build.txt"
  [IO.File]::WriteAllText((Join-Path $root $build), "Pure contract reference; NOT actual production/build evidence")
  $packet.custody.build = New-ContractReference $build
  $packet.custody.reviewer = "pure-contract observer, not a real approval"
  $packet.custody.accepted = $true
  $packet.custody.reviewedEvidenceIsOwnedAndSanitized = $true
  # Matches LoopGraph/ProjectRef/LoopNode Codable; this is NOT a captured daemon graph.
  $graph = @{
    id = "E2222222-2222-4222-8222-222222222222"
    project = @{ path = (Join-Path $root "project").Replace('\', '/'); name = "project"; lastOpenedAt = 42.5 }
    edges = @()
    nodes = @(@{
      id = $packet.runtime.loopId; title = "AlphaRenamed"; loopType = "turnBased"
      backend = $packet.backend.kind; checkDescription = "A-start-Z-end"; createdAt = 42.5
      state = @{ idle = @{} }; pilotState = @{ notPiloted = @{} }
      pausesBeforeWritesOnly = $false; attachments = @(); metricHistory = @(); sessionRestarts = 0
    })
  }
  $coreGraph = "$prefix-core.json"
  [IO.File]::WriteAllText((Join-Path $root $coreGraph), ($graph | ConvertTo-Json -Depth 10))
  $graph.nodes[0].state = @{ stopped = @{} }
  $stoppedGraph = "$prefix-stopped.json"
  [IO.File]::WriteAllText((Join-Path $root $stoppedGraph), ($graph | ConvertTo-Json -Depth 10))
  $session = "$prefix-session.json"
  $binding = @{
    loopId = $packet.runtime.loopId; terminalSessionName = $packet.runtime.terminalSessionName
    backendKind = $packet.backend.kind; backendSessionId = $packet.runtime.backendSessionId
    backendExecutableSha256 = $packet.backend.executableSha256
  }
  [IO.File]::WriteAllText((Join-Path $root $session), ($binding | ConvertTo-Json))
  foreach ($row in $packet.observations) {
    $row.status = "Passed"; $row.count = 1
    $row.method = if ($row.id -in @("production-core", "actual-backend-terminal", "safe-stop-reopen")) { "NativeManual" } else { "OwnedRuntime" }
    $row.evidence = @((New-ContractReference $png))
    foreach ($check in (Get-PreviewCoreChecks $row.id)) { $row.facts.$check = $true }
    switch ($row.id) {
      "production-core" {
        $row.facts.createdCount = 1; $row.facts.selectedLoopId = $packet.runtime.loopId
        $row.facts.persistedLoopId = $packet.runtime.loopId
        $row.facts.graphTitle = "AlphaRenamed"; $row.facts.sidebarTitle = "AlphaRenamed"
        $row.facts.checkDescription = "A-start-Z-end"; $row.facts.cancelDraft = "CancelMustNotPersist"
        $row.facts.readback = New-ContractReference $coreGraph
        $row.facts.cancelBeforeSha256 = $row.facts.readback.sha256
        $row.facts.cancelAfterSha256 = $row.facts.cancelBeforeSha256
      }
      "actual-backend-terminal" {
        $row.facts.loopId = $packet.runtime.loopId; $row.facts.backendKind = $packet.backend.kind
        $row.facts.backendVersion = $packet.backend.version; $row.facts.agentTurns = 2
        $row.facts.input = "Reply with FlightOutput2."; $row.facts.output1 = "A-start-Z-end FlightOutput1"
        $row.facts.output2 = "FlightOutput2"; $row.facts.terminalMode = "default"
        $row.facts.sessionReadback = New-ContractReference $session
      }
      "safe-stop-reopen" {
        $row.facts.stoppedLoopId = $packet.runtime.loopId; $row.facts.reopenedLoopId = $packet.runtime.loopId
        $row.facts.stoppedSessionName = $packet.runtime.terminalSessionName
        $row.facts.reopenedTitle = "AlphaRenamed"; $row.facts.reopenedCheckDescription = "A-start-Z-end"
        $row.facts.readback = New-ContractReference $stoppedGraph
      }
    }
  }
  $packet | Add-Member -NotePropertyName externalReleaseEvidence -NotePropertyValue @{
    predecessor = "NotExecuted"; upgrade = "NotExecuted"; rollback = "NotExecuted"
    uninstall = "NotExecuted"; dpiIme = "NotExecuted"; destructiveWorkspace = "NotExecuted"
  }
  return $packet
}

function Test-Contract([string] $name, [scriptblock] $body) {
  & $body
  $script:executed++
  Write-Output "CONTRACT CASE: $name"
}

function Assert-Rejected([scriptblock] $body, [string] $message) {
  $failure = $null
  try { & $body | Out-Null } catch { $failure = $_ }
  if (-not $failure -or $failure.Exception.Message -notlike "*$message*") {
    throw "Expected rejection '$message'; actual: $failure"
  }
}

function Assert-Equal($actual, $expected) {
  if ($actual -cne $expected) { throw "Expected '$expected', got '$actual'" }
}

try {
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  $env:TEMP = $root
  $env:TMP = $root
  if ($Case -in @("CoreBoundary", "All")) {
    Test-Contract "five core observations do not require an upgrade predecessor or release programme" {
      $core = @("artifact-custody", "installed-production", "production-core", "actual-backend-terminal", "safe-stop-reopen")
      $rows = @($core | ForEach-Object { [pscustomobject]@{ id = $_ } })
      Assert-PreviewCoreCoverage $rows
      Assert-Equal ((Get-PreviewCoreSteps | Sort-Object) -join ',') (($core | Sort-Object) -join ',')
    }
    Test-Contract "production Codable CORE contract accepts unexecuted predecessor without release approval" {
      $packet = New-ProductionCoreContract
      Assert-PreviewCoreCoreContract $packet ("b" * 40) ("c" * 64) $root
      Assert-Equal $packet.externalReleaseEvidence.predecessor "NotExecuted"
      $outcome = Get-PreviewCoreOutcome $packet
      Assert-Equal $outcome.state "CORE_CONTRACT_COMPLETE"
      Assert-Equal $outcome.previewReleaseQualified $false
      Assert-Equal $outcome.publicationApproved $false
      Assert-Equal $outcome.profileRole "Server"
      Assert-Rejected { Assert-PreviewCoreFlight $packet ("b" * 40) ("c" * 64) $root } "test-only evidence"
    }
    Test-Contract "saved graph must contain production Codable state, not string or missing fixture flags" {
      $packet = New-ProductionCoreContract
      $ref = @($packet.observations | Where-Object id -eq "production-core")[0].facts.readback
      $path = Join-Path $root $ref.path
      $graph = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
      $graph.nodes[0].state = "idle"
      [IO.File]::WriteAllText($path, ($graph | ConvertTo-Json -Depth 10))
      $ref.sha256 = Get-PreviewCoreHash $path
      Assert-Rejected { Assert-PreviewCoreSavedGraph $ref $packet $root } "production Codable LoopState"
      $graph.nodes[0].state = [pscustomobject]@{ idle = [pscustomobject]@{} }
      $graph.nodes[0].PSObject.Properties.Remove("createdAt")
      [IO.File]::WriteAllText($path, ($graph | ConvertTo-Json -Depth 10))
      $ref.sha256 = Get-PreviewCoreHash $path
      Assert-Rejected { Assert-PreviewCoreSavedGraph $ref $packet $root } "node timestamp"
    }
    Test-Contract "ordinary terminal namespace and opaque backend ID are separate and bound" {
      $packet = New-ProductionCoreContract
      Assert-PreviewCoreCoreContract $packet ("b" * 40) ("c" * 64) $root
      $packet.runtime.terminalSessionName = "graphcode-" + $packet.runtime.loopId
      Assert-Rejected { Assert-PreviewCoreCoreContract $packet ("b" * 40) ("c" * 64) $root } "ordinary Windows terminal session name"
      $packet.runtime.terminalSessionName = $packet.runtime.loopId
      $ref = @($packet.observations | Where-Object id -eq "actual-backend-terminal")[0].facts.sessionReadback
      $path = Join-Path $root $ref.path
      $session = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
      $session.backendSessionId = "unrelated-opaque-id"
      [IO.File]::WriteAllText($path, ($session | ConvertTo-Json))
      $ref.sha256 = Get-PreviewCoreHash $path
      Assert-Rejected { Assert-PreviewCoreCoreContract $packet ("b" * 40) ("c" * 64) $root } "session identity mismatch"
    }
    Test-Contract "complete core shape still rejects missing or substituted actual backend proof" {
      $packet = New-ProductionCoreContract
      $terminal = @($packet.observations | Where-Object id -eq "actual-backend-terminal")[0]
      $terminal.status = "NotExecuted"
      Assert-Rejected { Assert-PreviewCoreCoreContract $packet ("b" * 40) ("c" * 64) $root } "actual-backend-terminal is NotExecuted"
      $terminal.status = "Passed"; $terminal.count = 0
      Assert-Rejected { Assert-PreviewCoreCoreContract $packet ("b" * 40) ("c" * 64) $root } "positive integer observation count"
      $terminal.count = 1; $terminal.facts.actualAgent = $false
      Assert-Rejected { Assert-PreviewCoreCoreContract $packet ("b" * 40) ("c" * 64) $root } "actual-backend-terminal.actualAgent"
    }
    Test-Contract "stopped state must survive the core reopen snapshot" {
      $packet = New-ProductionCoreContract
      $ref = @($packet.observations | Where-Object id -eq "safe-stop-reopen")[0].facts.readback
      $path = Join-Path $root $ref.path
      $graph = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
      $graph.nodes[0].state = [pscustomobject]@{ running = [pscustomobject]@{} }
      [IO.File]::WriteAllText($path, ($graph | ConvertTo-Json -Depth 10))
      $ref.sha256 = Get-PreviewCoreHash $path
      Assert-Rejected { Assert-PreviewCoreCoreContract $packet ("b" * 40) ("c" * 64) $root } "persisted loop is not stopped"
    }
  }
  if ($Case -ne "CoreBoundary") {
  Test-Contract "NotExecuted cannot qualify" {
    $observation = [pscustomobject]@{
      id = "production-core"; status = "NotExecuted"; count = 0
      method = ""; evidence = @(); facts = [pscustomobject]@{}
    }
    Assert-Rejected { Assert-PreviewCoreObservation $observation $root } "production-core is NotExecuted"
  }
  }
  if ($Case -eq "All") {
    Test-Contract "Failed cannot qualify" {
      $observation = [pscustomobject]@{ id = "production-core"; status = "Failed"; count = 1 }
      Assert-Rejected { Assert-PreviewCoreObservation $observation $root } "production-core is Failed"
    }
    Test-Contract "unknown status cannot qualify" {
      $observation = [pscustomobject]@{ id = "production-core"; status = "Unknown"; count = 1 }
      Assert-Rejected { Assert-PreviewCoreObservation $observation $root } "invalid observation status"
    }
    Test-Contract "zero and string counts cannot qualify" {
      foreach ($count in @(0, "1", 1.5)) {
        $observation = [pscustomobject]@{ id = "production-core"; status = "Passed"; count = $count }
        Assert-Rejected { Assert-PreviewCoreObservation $observation $root } "positive integer observation count"
      }
      Assert-Equal (Test-PreviewCoreInteger ([long]1)) $true
      Assert-Equal (Test-PreviewCoreInteger "1") $false
      Assert-Equal (Test-PreviewCoreInteger 1.5) $false
    }
    Test-Contract "hashes and paths are exact" {
      Assert-Rejected { Assert-PreviewCoreHash "not-a-hash" 64 "ZIP" } "invalid ZIP"
      foreach ($relative in @("..\foreign.txt", "C:\foreign.txt", "\\server\share\file", "a:stream", "a/../b", "", "NUL.txt", "a\COM1", "wild*.txt")) {
        Assert-Rejected { Resolve-PreviewCoreChild $root $relative } "invalid owned relative path"
      }
      Assert-Equal (Resolve-PreviewCoreChild $root "owned.txt") (Join-Path $root "owned.txt")
    }
    Test-Contract "prepared packet leaves all live observations unexecuted" {
      $packet = New-PreviewCorePacket (New-ContractArtifact) $root ("d" * 64)
      Assert-Equal @($packet.observations).Count 5
      Assert-Equal @($packet.observations | Where-Object { $_.status -ne "NotExecuted" -or $_.count -ne 0 }).Count 0
      Assert-Equal $packet.backend.version ""
      Assert-Equal $packet.runtime.daemon "Unknown"
      Assert-Equal $packet.custody.accepted $false
      Assert-Equal $packet.scope "CoreOnly"
      Assert-Equal ($packet.profile.PSObject.Properties.Name -contains "minimumViewportDip") $false
      Assert-Equal ($packet.custody.PSObject.Properties.Name -contains "sourceCI") $false
      foreach ($row in $packet.observations) {
        foreach ($check in (Get-PreviewCoreChecks $row.id)) {
          Assert-Equal $row.facts[$check] $null
        }
      }
    }
    Test-Contract "fixture contains public sentinels but no graph or sessions" {
      $fixture = Join-Path $root "fixture"
      New-Item -ItemType Directory -Path $fixture | Out-Null
      Write-PreviewCoreFixture $fixture
      Assert-Equal ([IO.File]::ReadAllText((Join-Path $fixture "project\alpha.txt"))) "A-start-Z-end`n"
      Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $fixture "support") -Force).Count 0
      Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $fixture "install") -Force).Count 0
      Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $fixture "evidence") -Force).Count 0
      if ([IO.File]::ReadAllText((Join-Path $fixture "FLIGHT.txt")) -notmatch "PREPARED ONLY") {
        throw "Flight instructions did not distinguish preparation from qualification"
      }
      Assert-Rejected { Write-PreviewCoreFixture $fixture } "already exists"
    }
    Test-Contract "contract-valid artifact is not a production flight" {
      $artifact = New-ContractArtifact
      Assert-PreviewCoreArtifact $artifact ("b" * 40) ("c" * 64)
      $packet = New-PreviewCorePacket $artifact $root ("d" * 64)
      $packet.testOnly = $true
      Assert-Rejected { Assert-PreviewCoreFlight $packet ("b" * 40) ("c" * 64) $root } "test-only evidence"
    }
    foreach ($mutation in @(
        @{ Name = "source identity"; Field = "sourceCommit"; Value = ("e" * 40); Error = "candidate identity mismatch" },
        @{ Name = "package identity"; Field = "sha256"; Value = ("e" * 64); Error = "candidate identity mismatch" },
        @{ Name = "tag source"; Field = "tagCommit"; Value = ("e" * 40); Error = "tag/source mismatch" },
        @{ Name = "tag version"; Field = "tag"; Value = "v9.9.9"; Error = "tag/version mismatch" },
        @{ Name = "development version"; Field = "version"; Value = "1.2.3-dev"; Error = "non-dev" },
        @{ Name = "unknown version"; Field = "version"; Value = "unknown"; Error = "non-dev" },
        @{ Name = "mismatch override"; Field = "tagMismatchAllowed"; Value = $true; Error = "tag mismatch override" },
        @{ Name = "string boolean"; Field = "tagMatchesSource"; Value = "true"; Error = "tag/source equality" },
        @{ Name = "missing unsigned declaration"; Field = "signing"; Value = ""; Error = "unsigned preview warning" },
        @{ Name = "provider repin"; Field = "zmxCommit"; Value = ("e" * 40); Error = "provider pins changed" }
      )) {
      Test-Contract ("reject " + $mutation.Name) {
        $artifact = New-ContractArtifact
        $artifact.($mutation.Field) = $mutation.Value
        Assert-Rejected { Assert-PreviewCoreArtifact $artifact ("b" * 40) ("c" * 64) } $mutation.Error
      }
    }
    Test-Contract "a parseable boolean string is not an approval" {
      Assert-Rejected { Assert-PreviewCoreTrue "true" "approval" } "approval must be witnessed true"
      Assert-Rejected { Assert-PreviewCoreFalse "false" "seeded model" } "seeded model must be explicit false"
    }
    Test-Contract "reparse paths are rejected without following their targets" {
      $target = Join-Path $root "owned-target"
      $junction = Join-Path $root "owned-junction"
      New-Item -ItemType Directory -Path $target | Out-Null
      New-Item -ItemType Junction -Path $junction -Target $target | Out-Null
      try {
        Assert-Rejected { Resolve-PreviewCoreChild $root "owned-junction\readback.json" } "reparse point"
      } finally { [IO.Directory]::Delete($junction) }
    }
    Test-Contract "evidence is digest bound, not merely present" {
      [IO.File]::WriteAllText((Join-Path $root "witness.txt"), "public pure-contract witness")
      $reference = New-ContractReference "witness.txt"
      Assert-PreviewCoreEvidence $reference $root
      $reference.sha256 = "0" * 64
      Assert-Rejected { Assert-PreviewCoreEvidence $reference $root } "evidence digest mismatch"
    }
    Test-Contract "native input counts alone cannot qualify" {
      $observation = [pscustomobject]@{
        id = "production-core"; status = "Passed"; count = 10
        method = "QueuedInput"; evidence = @((New-ContractReference "witness.txt"))
      }
      Assert-Rejected { Assert-PreviewCoreObservation $observation $root } "requires NativeManual"
      $observation.method = "NativeManual"
      Assert-Rejected { Assert-PreviewCoreObservation $observation $root } "PNG pixel witness"
    }
    Test-Contract "unknown PNG bytes cannot become pixel evidence" {
      [IO.File]::WriteAllText((Join-Path $root "invalid.png"), "not a screenshot")
      Assert-Rejected { Assert-PreviewCoreEvidence (New-ContractReference "invalid.png") $root -RequirePng } "invalid owned PNG"
      Assert-Rejected { Assert-PreviewCoreEvidence (New-ContractReference "witness.txt") $root -RequirePng } "PNG pixel witness"
    }
    Test-Contract "missing and duplicate flight rows cannot qualify" {
      $packet = New-PreviewCorePacket (New-ContractArtifact) $root ("d" * 64)
      Assert-Equal @(Get-PreviewCoreSteps | Sort-Object -Unique).Count 5
      Assert-PreviewCoreCoverage $packet.observations
      $packet.observations = @()
      Assert-Rejected { Assert-PreviewCoreCoverage $packet.observations } "missing or duplicated"
      $packet = New-PreviewCorePacket (New-ContractArtifact) $root ("d" * 64)
      $packet.observations[0].id = $packet.observations[1].id
      Assert-Rejected { Assert-PreviewCoreCoverage $packet.observations } "missing or duplicated"
    }
    Test-Contract "stub and seeded production claims cannot qualify" {
      $packet = New-PreviewCorePacket (New-ContractArtifact) $root ("d" * 64)
      $packet.runtime.daemon = "Stub"
      Assert-Rejected { Assert-PreviewCoreFlight $packet ("b" * 40) ("c" * 64) $root } "ordinary installed production daemon"
      $packet.runtime.daemon = "Production"
      $packet.runtime.installation = "ScheduledTask"
      $packet.runtime.seededModel = $true
      Assert-Rejected { Assert-PreviewCoreFlight $packet ("b" * 40) ("c" * 64) $root } "seeded model"
      $packet.runtime.seededModel = $false
      $packet.runtime.testHooks = $true
      Assert-Rejected { Assert-PreviewCoreFlight $packet ("b" * 40) ("c" * 64) $root } "test hooks"
    }
    Test-Contract "pure artifact mismatch does not create a flight root" {
      $archive = Join-Path $root "not-a-package.zip"
      [IO.File]::WriteAllText($archive, "test-only; not a production package")
      $run = Join-Path $repo (".build\preview-core\flight-" + [guid]::NewGuid().ToString("N"))
      Assert-Rejected { Invoke-PreviewCorePrepare $archive ("b" * 40) ("0" * 64) $run } "ZIP hash mismatch"
      Assert-Equal (Test-Path -LiteralPath $run) $false
    }
    Test-Contract "run roots cannot adopt external or shared state" {
      Assert-Rejected { Assert-PreviewCoreRunRoot $root } "child of this checkout"
      Assert-Rejected { Assert-PreviewCoreRunRoot $repo } "child of this checkout"
    }
    Test-Contract "package snapshot reader binds actual file bytes without claiming verification" {
      $snapshot = Join-Path $root "snapshot"
      New-Item -ItemType Directory -Path (Join-Path $snapshot "bin") -Force | Out-Null
      $artifact = New-ContractArtifact
      $metadata = [ordered]@{
        version = $artifact.version; signing = $artifact.signing
        providerPins = [ordered]@{
          winghostty = @{ sha = $artifact.winghosttyCommit }
          zmx = @{ sha = $artifact.zmxCommit }
        }
        sourceProvenance = @{
          sourceCommit = $artifact.sourceCommit; tag = $artifact.tag; tagCommit = $artifact.tagCommit
          tagMatchesSource = $true; tagMismatchAllowed = $false
        }
      }
      [IO.File]::WriteAllText((Join-Path $snapshot "metadata.json"), ($metadata | ConvertTo-Json -Depth 5))
      foreach ($file in @("manifest.json", "provider-provenance.json", "bin\graphcode-windows.exe",
          "bin\graphcoded.exe", "bin\graphcode.exe", "bin\zmx.exe")) {
        [IO.File]::WriteAllText((Join-Path $snapshot $file), "test-only snapshot bytes; NOT a verified package")
      }
      $read = Get-PreviewCoreArtifact $snapshot ("b" * 40) ("c" * 64)
      Assert-Equal $read.hashes.daemon (Get-PreviewCoreHash (Join-Path $snapshot "bin\graphcoded.exe"))
      [IO.File]::WriteAllText((Join-Path $snapshot "bin\graphcoded.exe"), "different test-only snapshot bytes")
      $changed = Get-PreviewCoreArtifact $snapshot ("b" * 40) ("c" * 64)
      if ($changed.hashes.daemon -ceq $read.hashes.daemon) { throw "Changed payload bytes were not detected" }
    }
    Test-Contract "public checker rejects test-only packet before package or runtime access" {
      $run = Join-Path $repo (".build\preview-core\flight-" + [guid]::NewGuid().ToString("N"))
      Assert-PreviewCoreRunRoot $run
      Assert-Equal (Test-Path -LiteralPath $run) $false
      New-Item -ItemType Directory -Path $run -Force | Out-Null
      try {
        Write-PreviewCoreFixture $run
        $scriptHash = Get-PreviewCoreHash $qualification
        $packet = New-PreviewCorePacket (New-ContractArtifact) $run $scriptHash
        $packet.testOnly = $true
        foreach ($file in @("prepared.json", "qualification.json")) {
          [IO.File]::WriteAllText((Join-Path $run $file), ($packet | ConvertTo-Json -Depth 20))
        }
        $owner = @{
          flightId = $packet.flightId; sourceCommit = "b" * 40; zipSha256 = "c" * 64
          scriptSha256 = $scriptHash
          preparedSha256 = Get-PreviewCoreHash (Join-Path $run "prepared.json")
          projectSha256 = Get-PreviewCoreHash (Join-Path $run "project\alpha.txt")
        }
        [IO.File]::WriteAllText((Join-Path $run "owner.json"), ($owner | ConvertTo-Json))
        Assert-Rejected {
          & $qualification -Command VerifyEvidence -EvidencePath (Join-Path $run "qualification.json") `
            -ExpectedSource ("b" * 40) -ExpectedSha256 ("c" * 64)
        } "test-only evidence"
        Assert-Equal (Test-Path -LiteralPath (Join-Path $run "candidate.zip")) $false
        $owner.preparedSha256 = "0" * 64
        [IO.File]::WriteAllText((Join-Path $run "owner.json"), ($owner | ConvertTo-Json))
        Assert-Rejected {
          & $qualification -Command VerifyEvidence -EvidencePath (Join-Path $run "qualification.json") `
            -ExpectedSource ("b" * 40) -ExpectedSha256 ("c" * 64)
        } "prepared packet was modified"
      } finally {
        Remove-Item -LiteralPath $run -Recurse -Force
      }
    }
    Test-Contract "entrypoint has no live or publication mode" {
      $tokens = $null
      $errors = $null
      $ast = [Management.Automation.Language.Parser]::ParseFile($qualification, [ref]$tokens, [ref]$errors)
      Assert-Equal $errors.Count 0
      $commands = @($ast.FindAll({
          param($node)
          $node -is [Management.Automation.Language.CommandAst]
        }, $true) | ForEach-Object { $_.GetCommandName() })
      foreach ($forbidden in @("Start-Process", "Stop-Process", "Add-Type", "Get-CimInstance", "Get-Process",
          "Get-WinEvent", "Set-Clipboard", "Get-Clipboard", "Register-ScheduledTask", "schtasks.exe", "gh")) {
        Assert-Equal ($commands -contains $forbidden) $false
      }
      $liveModes = @($ast.FindAll({
          param($node)
          $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
          $node.Value -cin @("Install", "Upgrade", "Uninstall", "Publish", "Execute", "Run")
        }, $true))
      Assert-Equal $liveModes.Count 0
    }
    Test-Contract "one existing packaging-contracts hook consumes this pure unit" {
      $validation = Join-Path $repo "Tools\windows\validate.ps1"
      $tokens = $null
      $errors = $null
      $ast = [Management.Automation.Language.Parser]::ParseFile($validation, [ref]$tokens, [ref]$errors)
      Assert-Equal $errors.Count 0
      $hooks = @($ast.FindAll({
          param($node)
          $node -is [Management.Automation.Language.CommandAst] -and
          $node.Extent.Text -match '^& \(Join-Path \$repoRoot "Tools\\windows\\Tests\\PreviewCore\.Tests\.ps1"\)$'
        }, $true))
      Assert-Equal $hooks.Count 1
      $ancestor = $hooks[0].Parent
      while ($ancestor -and $ancestor -isnot [Management.Automation.Language.IfStatementAst]) {
        $ancestor = $ancestor.Parent
      }
      if (-not $ancestor -or $ancestor.Clauses[0].Item1.Extent.Text -cne '$PackagingPart -ne "real"') {
        throw "Pure PreviewCore hook must remain inside packaging-contracts selection"
      }
    }
  }
  if ($executed -lt 1) { throw "No PreviewCore contract cases executed" }
  Write-Output "PREVIEW_CORE_CONTRACTS: executed=$executed; failed=0; testOnly=true; no production flight ran"
} finally {
  $env:TEMP = $oldTemp
  $env:TMP = $oldTmp
  if (Test-Path -LiteralPath $root -PathType Container) {
    Remove-Item -LiteralPath $root -Recurse -Force
  }
}
