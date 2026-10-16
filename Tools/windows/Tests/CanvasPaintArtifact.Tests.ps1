[CmdletBinding()]
param([Parameter(Mandatory)][string] $ScratchRoot)

$ErrorActionPreference = "Stop"
$scratchFull = [IO.Path]::GetFullPath($ScratchRoot)
if (Test-Path -LiteralPath $scratchFull) { throw "Refusing existing converter contract root: $scratchFull" }
New-Item -ItemType Directory -Path $scratchFull | Out-Null
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$converter = Join-Path $PSScriptRoot "..\Convert-CanvasPaintArtifact.ps1"
$fixturePath = Join-Path $repoRoot "graphcode-windows\fixtures\paint-project-v1.json"
$fixtureHash = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash.ToLowerInvariant()
$sourcePathsV1 = @(
  "graphcode-windows\src\GraphCanvas.zig",
  "graphcode-windows\src\GdiplusAA.zig",
  "graphcode-windows\fixtures\paint-project-v1.json",
  "Tools\windows\Convert-CanvasPaintArtifact.ps1",
  "Tools\windows\Tests\CanvasPaintArtifact.Tests.ps1",
  "Tools\windows\Tests\WindowsShell.Tests.ps1",
  "graphcode-windows\README.md"
)
$caseResults = [Collections.Generic.List[object]]::new()
$sceneCaseResults = [Collections.Generic.List[object]]::new()
$syntheticFixture = Join-Path $scratchFull "synthetic-codec-fixture.bmp"

function Assert-Contract([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw $Message }
}

function Get-TestHash([byte[]] $Bytes) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return [Convert]::ToHexString($sha.ComputeHash($Bytes)).ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function New-SyntheticBmp([string] $Path, [int] $Width = 1280, [int] $Height = 720) {
  $rowBytes = $Width * 4
  $imageSize = $rowBytes * $Height
  $fileSize = 54 + $imageSize
  $bytes = [byte[]]::new($fileSize)
  $bytes[0] = 0x42
  $bytes[1] = 0x4D
  [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]$fileSize), 0, $bytes, 2, 4)
  [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]54), 0, $bytes, 10, 4)
  [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]40), 0, $bytes, 14, 4)
  [Buffer]::BlockCopy([BitConverter]::GetBytes([int32]$Width), 0, $bytes, 18, 4)
  [Buffer]::BlockCopy([BitConverter]::GetBytes([int32]$Height), 0, $bytes, 22, 4)
  [Buffer]::BlockCopy([BitConverter]::GetBytes([uint16]1), 0, $bytes, 26, 2)
  [Buffer]::BlockCopy([BitConverter]::GetBytes([uint16]32), 0, $bytes, 28, 2)
  [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]0), 0, $bytes, 30, 4)
  [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]$imageSize), 0, $bytes, 34, 4)
  [Buffer]::BlockCopy([BitConverter]::GetBytes([int32]3780), 0, $bytes, 38, 4)
  [Buffer]::BlockCopy([BitConverter]::GetBytes([int32]3780), 0, $bytes, 42, 4)
  $pixelIndex = 0
  for ($offset = 54; $offset -lt $bytes.Length; $offset += 4) {
    if ($pixelIndex % 2 -eq 0) {
      $bytes[$offset] = 0x33
      $bytes[$offset + 1] = 0x22
      $bytes[$offset + 2] = 0x11
    } else {
      $bytes[$offset] = 0x66
      $bytes[$offset + 1] = 0x55
      $bytes[$offset + 2] = 0x44
    }
    $bytes[$offset + 3] = 0xFF
    $pixelIndex++
  }
  [IO.File]::WriteAllBytes($Path, $bytes)
}

function New-SyntheticRgbHash([int] $Width = 1280, [int] $Height = 720) {
  $rgb = [byte[]]::new($Width * $Height * 3)
  $pixel = 0
  for ($offset = 0; $offset -lt $rgb.Length; $offset += 3) {
    if ($pixel % 2 -eq 0) {
      $rgb[$offset] = 0x11
      $rgb[$offset + 1] = 0x22
      $rgb[$offset + 2] = 0x33
    } else {
      $rgb[$offset] = 0x44
      $rgb[$offset + 1] = 0x55
      $rgb[$offset + 2] = 0x66
    }
    $pixel++
  }
  return (Get-TestHash $rgb)
}

function Get-TestFileHash([string] $Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-SceneFixturePaths([string] $Scene) {
  switch ($Scene) {
    "project-paint-v1" { return @("graphcode-windows\fixtures\paint-project-v1.json") }
    "project-paint-764" { return @("graphcode-windows\fixtures\paint-764-project.json") }
    "overview-paint-764" {
      return @(
        "graphcode-windows\fixtures\paint-764-project.json",
        "graphcode-windows\fixtures\paint-764-overview-peer.json"
      )
    }
    default { throw "Unknown synthetic scene profile: $Scene" }
  }
}

function Get-SceneSourcePaths([string] $Scene) {
  switch ($Scene) {
    "project-paint-v1" { return $sourcePathsV1 }
    "project-paint-764" {
      return @(
        "graphcode-windows\src\GraphCanvas.zig",
        "graphcode-windows\src\GdiplusAA.zig",
        "graphcode-windows\fixtures\paint-764-project.json",
        "Tools\windows\Convert-CanvasPaintArtifact.ps1",
        "Tools\windows\Tests\CanvasPaintArtifact.Tests.ps1",
        "Tools\windows\Tests\WindowsShell.Tests.ps1",
        "graphcode-windows\README.md"
      )
    }
    "overview-paint-764" {
      return @(
        "graphcode-windows\src\GraphCanvas.zig",
        "graphcode-windows\src\GdiplusAA.zig",
        "graphcode-windows\fixtures\paint-764-project.json",
        "graphcode-windows\fixtures\paint-764-overview-peer.json",
        "Tools\windows\Convert-CanvasPaintArtifact.ps1",
        "Tools\windows\Tests\CanvasPaintArtifact.Tests.ps1",
        "Tools\windows\Tests\WindowsShell.Tests.ps1",
        "graphcode-windows\README.md"
      )
    }
    default { throw "Unknown synthetic scene profile: $Scene" }
  }
}

function Get-SyntheticAgeLabel([long] $CreatedAt, [long] $ObservedAt) {
  $seconds = [Math]::Max(0, $ObservedAt - $CreatedAt)
  $days = [long][Math]::Floor($seconds / 86400)
  $hours = [long][Math]::Floor($seconds / 3600) % 24
  $minutes = [long][Math]::Floor($seconds / 60) % 60
  if ($days -gt 0) {
    if ($hours -gt 0) { return [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0}d {1}h", $days, $hours) }
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0}d", $days)
  }
  if ($hours -gt 0) {
    if ($minutes -gt 0) { return [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0}h {1}m", $hours, $minutes) }
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0}h", $hours)
  }
  if ($minutes -gt 0) { return [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0}m", $minutes) }
  return [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0}s", $seconds)
}

function Get-SyntheticAgeEvidence([string[]] $FixturePaths, [long] $ObservedAt) {
  $nodes = [Collections.Generic.List[object]]::new()
  $referenceDateUnixOffset = [long]978307200
  foreach ($relativePath in $FixturePaths) {
    $fixturePath = Join-Path $repoRoot $relativePath
    $fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -AsHashtable
    foreach ($node in $fixture.event.graphChanged.nodes) {
      if ($null -eq $node.createdAt) { continue }
      $createdAtEpochSeconds = [long][Math]::Floor([double]$node.createdAt) + $referenceDateUnixOffset
      $nodes.Add([ordered]@{
        id = [string]$node.id
        createdAtEpochSeconds = $createdAtEpochSeconds
        display = Get-SyntheticAgeLabel $createdAtEpochSeconds $ObservedAt
      })
    }
  }
  return [ordered]@{ observedAtEpochSeconds = $ObservedAt; nodes = @($nodes) }
}

function Get-ContractSourceHashes([string] $Scene = "project-paint-v1") {
  $hashes = [ordered]@{}
  foreach ($relativePath in (Get-SceneSourcePaths $Scene)) {
    $hashes[$relativePath] = Get-TestFileHash (Join-Path $repoRoot $relativePath)
  }
  return $hashes
}

function Get-SyntheticArtifactFact([string] $Path) {
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    return [ordered]@{
      path = $Path
      present = $true
      sha256 = (Get-TestFileHash $Path)
    }
  }
  return [ordered]@{
    path = $Path
    present = $false
    sha256 = $null
  }
}

function Update-SyntheticArtifactHash([object] $Run, [string] $Name) {
  $runReceipt = Get-Content -LiteralPath $Run.RunReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $path = switch ($Name) {
    "testBinary" { $Run.TestBinaryPath }
    "nativeLog" { $Run.NativeLogPath }
    "paintReceipt" { $Run.ReceiptPath }
    default { throw "Unknown synthetic native artifact: $Name" }
  }
  $runReceipt.nativeArtifacts[$Name] = Get-SyntheticArtifactFact $path
  [IO.File]::WriteAllText(
    $Run.RunReceiptPath,
    ($runReceipt | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false))
}

function New-Receipt(
  [string] $TransportPath,
  [string] $RgbHash,
  [string] $BmpHash,
  [string] $FixtureDigest,
  [string] $Scene = "project-paint-v1"
) {
  $fixturePaths = Get-SceneFixturePaths $Scene
  $fixtureFacts = @(
    foreach ($relativePath in $fixturePaths) {
      [ordered]@{
        path = $relativePath.Replace("\", "/")
        sha256 = Get-TestFileHash (Join-Path $repoRoot $relativePath)
      }
    }
  )
  $is764 = $Scene -ne "project-paint-v1"
  $nodes = switch ($Scene) {
    "project-paint-764" { 6 }
    "overview-paint-764" { 8 }
    default { 2 }
  }
  $edges = switch ($Scene) {
    "project-paint-764" { 3 }
    "overview-paint-764" { 4 }
    default { 1 }
  }
  $paintedEdges = if ($Scene -eq "project-paint-764") { 3 } elseif ($Scene -eq "overview-paint-764") { 0 } else { $null }
  $createdAtValues = if ($is764) { $nodes } else { 0 }
  $ageObservedAt = 1800000000
  $surface = if ($Scene -eq "project-paint-764") { "project" } elseif ($Scene -eq "overview-paint-764") { "overview" } else { $null }
  $headerContext = if ($Scene -eq "project-paint-764") { "Card States" } elseif ($Scene -eq "overview-paint-764") { "Overview" } else { "Alpha" }
  $transportNames = switch ($Scene) {
    "project-paint-764" { @("project-paint-764.bmp", "project-paint-764-repeat-2.bmp", "project-paint-764-repeat-3.bmp") }
    "overview-paint-764" { @("overview-paint-764.bmp", "overview-paint-764-repeat-2.bmp", "overview-paint-764-repeat-3.bmp") }
    default { @("project-paint-v1.bmp", "project-paint-v1-repeat-2.bmp", "project-paint-v1-repeat-3.bmp") }
  }
  $excludedSurfaces = if ($is764) {
    @("whole window composition", "input and button behavior", "project opening and canvas fit", "backend lifecycle and persistence", "UI Automation and accessibility", "per-monitor DPI", "unreviewed sidebar and loop-bar palette")
  } else {
    @("whole window", "composition", "popups", "terminals", "per-monitor DPI", "sidebar/right-panel fidelity", "native form controls", "accessibility")
  }
  $receipt = [ordered]@{
    schemaVersion = 1
    evidenceClass = "paint-only"
    scene = $Scene
    fixturePath = $fixtureFacts[0].path
    fixtureSha256 = $fixtureFacts[0].sha256
    sourceCommit = "0000000000000000000000000000000000000000"
    renderer = "GraphCanvas.paint + GraphCanvas.paintHeader -> memory DIB"
    dimensions = [ordered]@{ width = 1280; height = 720; logicalWidth = 1280; logicalHeight = 720 }
    dpiMapping = [ordered]@{ windowExtX = 96; windowExtY = 96; viewportExtX = 96; viewportExtY = 96; deviceDpiX = 96; deviceDpiY = 96 }
    canvas = [ordered]@{ zoom = 1; panX = 0; panY = 0; selectedIndex = 0; railVisible = $true; panelVisible = $false; activityEnabled = $false }
    model = [ordered]@{ nodes = $nodes; edges = $edges; activityHistory = 0; createdAtValues = $createdAtValues }
    header = [ordered]@{ title = "GraphCode"; context = $headerContext; reachabilityClaim = "declared fixture/test value only; not App reachability" }
    gdiPlusReady = $true
    colorAssumption = "SDR RGB; unused DIB alpha is normalized to opaque in BMP transport"
    fontEvidenceScope = "Sampled card title, state, metadata, and header title font selections only; not a census of every text draw"
    fonts = @(
      [ordered]@{ role = "card-title"; logicalFace = "Segoe UI"; actualFace = "Segoe UI"; height = -15; weight = 600; quality = "CLEARTYPE_QUALITY" },
      [ordered]@{ role = "card-state"; logicalFace = "Segoe UI"; actualFace = "Segoe UI"; height = -10; weight = 700; quality = "CLEARTYPE_QUALITY" },
      [ordered]@{ role = "card-mono"; logicalFace = "Consolas"; actualFace = "Consolas"; height = -11; weight = 400; quality = "CLEARTYPE_QUALITY" },
      [ordered]@{ role = "header"; logicalFace = "Segoe UI"; actualFace = "Segoe UI"; height = -11; weight = 400; quality = "CLEARTYPE_QUALITY" }
    )
    transport = @(
      [ordered]@{ name = $transportNames[0]; bmpSha256 = $BmpHash; rgbSha256 = $RgbHash },
      [ordered]@{ name = $transportNames[1]; rgbSha256 = $RgbHash },
      [ordered]@{ name = $transportNames[2]; rgbSha256 = $RgbHash }
    )
    renderRgbSha256 = @($RgbHash, $RgbHash, $RgbHash)
    candidateArtifactCount = 1
    excludedSurfaces = $excludedSurfaces
  }
  if ($is764) {
    $receipt["fixtures"] = $fixtureFacts
    $receipt.model["paintedEdges"] = $paintedEdges
    $receipt["ageEvidence"] = Get-SyntheticAgeEvidence $fixturePaths $ageObservedAt
    $receipt.canvas["surface"] = $surface
  }
  $receiptPath = Join-Path $TransportPath "paint-receipt.json"
  [IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  return $receiptPath
}

function New-SyntheticRun(
  [string] $Name,
  [int] $Width = 1280,
  [int] $Height = 720,
  [string] $Scene = "project-paint-v1"
) {
  $runRoot = Join-Path $scratchFull $Name
  $transportRoot = Join-Path $runRoot "export\transport"
  New-Item -ItemType Directory -Path $transportRoot -Force | Out-Null
  $testBinary = Join-Path $runRoot "canvas-paint-tests.exe"
  [IO.File]::WriteAllBytes($testBinary, [Text.Encoding]::ASCII.GetBytes("synthetic test binary identity"))
  $nativeLog = Join-Path $runRoot "native.log"
  $nativeTestName = "GraphCanvas.test.paint export: $Scene"
  [IO.File]::WriteAllText(
    $nativeLog,
    "Synthetic codec fixture only; no product scene.`n" +
      "1/1 $nativeTestName...synthetic contract evidence`nOK`nAll 1 tests passed.`n")
  $transportNames = switch ($Scene) {
    "project-paint-764" { @("project-paint-764.bmp", "project-paint-764-repeat-2.bmp", "project-paint-764-repeat-3.bmp") }
    "overview-paint-764" { @("overview-paint-764.bmp", "overview-paint-764-repeat-2.bmp", "overview-paint-764-repeat-3.bmp") }
    default { @("project-paint-v1.bmp", "project-paint-v1-repeat-2.bmp", "project-paint-v1-repeat-3.bmp") }
  }
  $canonical = Join-Path $transportRoot $transportNames[0]
  if ($Width -eq 1280 -and $Height -eq 720) {
    Copy-Item -LiteralPath $syntheticFixture -Destination $canonical
  } else {
    New-SyntheticBmp $canonical $Width $Height
  }
  Copy-Item -LiteralPath $canonical -Destination (Join-Path $transportRoot $transportNames[1])
  Copy-Item -LiteralPath $canonical -Destination (Join-Path $transportRoot $transportNames[2])
  $rgbHash = $script:syntheticRgbHash
  $bmpHash = Get-TestFileHash $canonical
  $receipt = New-Receipt $transportRoot $rgbHash $bmpHash $fixtureHash $Scene
  $runReceiptPath = Join-Path $runRoot "run-receipt.json"
  $sourceHashes = Get-ContractSourceHashes $Scene
  $command = '& $env:GRAPHCODE_ZIG0152 test src\GraphCanvas.zig -target x86_64-windows-msvc -lc -luser32 -lgdi32 -lgdiplus "-I$env:GRAPHCODE_WINGHOSTTY_ROOT\include" --test-filter "paint export: ' + $Scene + '" -femit-bin=' + $testBinary
  $runReceipt = [ordered]@{
    runId = $Name
    command = $command
    sourceHeadBefore = "0000000000000000000000000000000000000000"
    sourceHeadAfter = "0000000000000000000000000000000000000000"
    sourceHashesBefore = $sourceHashes
    sourceHashesAfter = $sourceHashes
    nativeExitCode = 0
    exportDirectory = (Join-Path $runRoot "export")
    emittedTestBinary = $testBinary
    log = $nativeLog
    nativeArtifacts = [ordered]@{
      capturedImmediatelyAfterNativeCommand = $true
      testBinary = (Get-SyntheticArtifactFact $testBinary)
      nativeLog = (Get-SyntheticArtifactFact $nativeLog)
      paintReceipt = (Get-SyntheticArtifactFact $receipt)
    }
    environmentFile = "synthetic contract input"
    completedAt = [DateTimeOffset]::Now.ToString("o")
  }
  [IO.File]::WriteAllText($runReceiptPath, ($runReceipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  return [pscustomobject]@{
    Scene = $Scene
    RunRoot = $runRoot
    TransportRoot = $transportRoot
    InputBmp = $canonical
    ReceiptPath = $receipt
    RunReceiptPath = $runReceiptPath
    TestBinaryPath = $testBinary
    NativeLogPath = $nativeLog
    OutputDirectory = Join-Path $runRoot "published"
  }
}

New-SyntheticBmp $syntheticFixture
$script:syntheticRgbHash = New-SyntheticRgbHash

function Invoke-Converter([object] $Run) {
  $arguments = @{
    InputBmp = $Run.InputBmp
    ReceiptPath = $Run.ReceiptPath
    RunReceiptPath = $Run.RunReceiptPath
    TestBinaryPath = $Run.TestBinaryPath
    OutputDirectory = $Run.OutputDirectory
    Scene = $Run.Scene
  }
  if ($Run.TestPngCodecWriteFailure) {
    $arguments.TestPngCodecWriteFailure = $true
  }
  return @(& $converter @arguments)
}

function Assert-ConverterFailure([object] $Run, [string] $Code) {
  $outputExisted = Test-Path -LiteralPath $Run.OutputDirectory
  $failure = $null
  try {
    $null = Invoke-Converter $Run
  } catch {
    $failure = $_.Exception
  }
  Assert-Contract ($null -ne $failure) "Converter unexpectedly succeeded; expected $Code."
  $message = $failure.Message
  Assert-Contract $message.Contains("CanvasPaintArtifact[$Code]") `
    "Converter failed for the wrong reason; expected $Code, got: $message"
  Assert-Contract (-not (Test-Path -LiteralPath (Join-Path $Run.OutputDirectory "paint-only-manifest.json"))) `
    "A failed conversion must not publish a success manifest."
  if (-not $outputExisted) {
    Assert-Contract (-not (Test-Path -LiteralPath $Run.OutputDirectory)) `
      "A failed conversion must not expose a partial output directory."
  }
  if ($Code -eq "OutputPublishFailed") {
    $staging = @(Get-ChildItem -LiteralPath $Run.RunRoot -Directory -Filter ".canvas-paint-staging-*")
    Assert-Contract ($staging.Count -eq 1) "A failed publication must preserve its staging directory."
    Assert-Contract ((Test-Path -LiteralPath (Join-Path $staging[0].FullName "project-paint-v1.png")) -and
      (Test-Path -LiteralPath (Join-Path $staging[0].FullName "paint-only-manifest.json"))) `
      "The verified staging artifacts must be preserved after publication failure."
  }
  if ($Code -eq "CodecWriteFailed") {
    $evidence = $failure.Data
    Assert-Contract ($evidence["saveReturnedNormally"] -is [bool]) `
      "Codec-write failure must record whether Bitmap.Save returned normally."
    Assert-Contract ($evidence["writeCallbackCount"] -is [long] -and
      $evidence["writeCallbackCount"] -gt 0) `
      "Codec-write failure must record at least one real stream write callback."
    Assert-Contract ($evidence["partialBytesWritten"] -is [long] -and
      $evidence["partialBytesWritten"] -gt 0) `
      "Codec-write failure must record bytes successfully written before the injected failure."
    Assert-Contract ($evidence["injectedIOExceptionObserved"] -is [bool] -and
      $evidence["injectedIOExceptionObserved"]) `
      "Codec-write failure must record the injected IOException at the stream boundary."
    $injectedIOException = $evidence["injectedIOException"]
    Assert-Contract ($injectedIOException -is [IO.IOException] -and
      -not [string]::IsNullOrWhiteSpace($injectedIOException.StackTrace)) `
      "Codec-write failure must retain the injected IOException, stack, and HRESULT."
    Assert-Contract ($failure.InnerException -is [System.Exception]) `
      "Codec-write failure must preserve its original exception chain."
    Assert-Contract ($message.Contains(("HRESULT=0x{0:X8}" -f $injectedIOException.HResult))) `
      "Codec-write failure details must preserve the injected IOException HRESULT."
    $saveException = $evidence["saveException"]
    if ($evidence["saveReturnedNormally"]) {
      Assert-Contract ($null -eq $saveException) `
        "A normally returning Bitmap.Save must not record a propagated Save exception."
    } else {
      Assert-Contract ($saveException -is [System.Exception] -and
        -not [string]::IsNullOrWhiteSpace($saveException.ToString())) `
        "A propagated Bitmap.Save exception must retain its original exception details."
      Assert-Contract ($message.Contains(("Propagated Bitmap.Save exception HRESULT=0x{0:X8}" -f
          $saveException.HResult))) `
        "Codec-write failure details must preserve the propagated Bitmap.Save HRESULT."
    }
    $flushException = $evidence["flushException"]
    if ($null -ne $flushException) {
      Assert-Contract ($flushException -is [System.Exception] -and
        -not [string]::IsNullOrWhiteSpace($flushException.ToString())) `
        "A propagated stream flush exception must retain its original exception details."
      Assert-Contract ($message.Contains(("Propagated stream flush exception HRESULT=0x{0:X8}" -f
          $flushException.HResult))) `
        "Codec-write failure details must preserve the propagated stream flush HRESULT."
    }
    $propagatedException = $evidence["propagatedException"]
    if ($null -ne $propagatedException) {
      Assert-Contract ($propagatedException -is [System.Exception] -and
        -not [string]::IsNullOrWhiteSpace($propagatedException.ToString())) `
        "A propagated Save/flush exception must retain its original exception details."
    }
    Write-Host "CODEC_WRITE_EVIDENCE saveReturnedNormally=$($evidence['saveReturnedNormally']) callbacks=$($evidence['writeCallbackCount']) partialBytes=$($evidence['partialBytesWritten'])"
    Write-Host "Injected IOException evidence:`n$($injectedIOException.ToString())"
    if ($null -ne $propagatedException) {
      Write-Host "Propagated Save/flush exception evidence:`n$($propagatedException.ToString())"
    }
    Write-Host "Wrapped converter exception chain:`n$($failure.ToString())"
    $staging = @(Get-ChildItem -LiteralPath $Run.RunRoot -Directory -Filter ".canvas-paint-staging-*")
    Assert-Contract ($staging.Count -eq 1) "A PNG codec write failure must preserve its staging directory."
    $partialPng = Join-Path $staging[0].FullName "project-paint-v1.png"
    Assert-Contract ((Test-Path -LiteralPath $partialPng -PathType Leaf) -and
      (Get-Item -LiteralPath $partialPng).Length -gt 0) `
      "The actual PNG codec must partially write its staging file before the injected stream failure."
    Assert-Contract (-not (Test-Path -LiteralPath (Join-Path $staging[0].FullName "paint-only-manifest.json"))) `
      "A PNG codec write failure must not create a success manifest."
  }
}

function Invoke-ContractCase([string] $Name, [scriptblock] $Body) {
  try {
    & $Body
    $caseResults.Add([pscustomobject]@{ Name = $Name; Passed = $true; Error = $null })
    Write-Host "PASS $Name"
  } catch {
    $caseResults.Add([pscustomobject]@{ Name = $Name; Passed = $false; Error = $_.Exception.Message })
    Write-Host "FAIL $Name :: $($_.Exception.Message)"
  }
}

function Invoke-SceneContractCase([string] $Name, [scriptblock] $Body) {
  try {
    & $Body
    $sceneCaseResults.Add([pscustomobject]@{ Name = $Name; Passed = $true; Error = $null })
    Write-Host "PASS scene profile $Name"
  } catch {
    $sceneCaseResults.Add([pscustomobject]@{ Name = $Name; Passed = $false; Error = $_.Exception.Message })
    Write-Host "FAIL scene profile $Name :: $($_.Exception.Message)"
  }
}

Invoke-ContractCase "valid round-trip" {
  $run = New-SyntheticRun "valid"
  $result = @(Invoke-Converter $run)
  Assert-Contract ($result.Count -eq 1) "Valid conversion must return exactly one result."
  Assert-Contract ($result[0].ArtifactCount -eq 1) "Valid conversion must publish exactly one PNG."
  Assert-Contract (Test-Path -LiteralPath $result[0].Artifact -PathType Leaf) "PNG output is missing."
  $manifest = Get-Content -LiteralPath $result[0].Manifest -Raw | ConvertFrom-Json
  Assert-Contract ($manifest.evidenceClass -ceq "real paint path, offscreen component render") `
    "Manifest evidence class is incorrect."
  Assert-Contract ($manifest.nativeRun.nativeExitCode -eq 0 -and
    $manifest.nativeRun.testSummary -ceq "All 1 tests passed.") `
    "Manifest must record a positive native-run result."
  Assert-Contract ($manifest.nativeRun.runReceiptSha256 -ceq (Get-TestFileHash $run.RunReceiptPath)) `
    "Manifest must bind the exact parsed native run receipt bytes."
  Assert-Contract ($manifest.nativeRun.runReceiptPath -ceq $run.RunReceiptPath) `
    "Manifest must identify the bound native run receipt."
  Assert-Contract ($manifest.nativeRun.artifactHashes.capturedImmediatelyAfterNativeCommand -eq $true) `
    "Manifest must identify hashes captured immediately after the native command."
  Assert-Contract ($manifest.nativeRun.artifactHashes.testBinarySha256 -ceq
    (Get-TestFileHash $run.TestBinaryPath)) "Manifest must preserve the native-run test-binary hash."
  Assert-Contract ($manifest.nativeRun.artifactHashes.nativeLogSha256 -ceq
    (Get-TestFileHash $run.NativeLogPath)) "Manifest must preserve the native-run log hash."
  Assert-Contract ($manifest.nativeRun.artifactHashes.paintReceiptSha256 -ceq
    (Get-TestFileHash $run.ReceiptPath)) "Manifest must preserve the native-run paint-receipt hash."
  Assert-Contract ($manifest.nativeRun.artifactHashes.identityScope -match "not cryptographic execution attestation") `
    "Manifest must not overstate native artifact association as execution attestation."
  Assert-Contract ($manifest.environment.pinEvidenceScope -match "not measured by the converter") `
    "Manifest must label Zig and Winghostty values as repository pins, not measured process identity."
  Assert-Contract ($manifest.paintReceipt.sha256 -ceq (Get-TestFileHash $run.ReceiptPath)) `
    "Manifest must bind the exact parsed paint receipt bytes."
  Assert-Contract ($manifest.nativeLog.sha256 -ceq (Get-TestFileHash $run.NativeLogPath)) `
    "Manifest must bind the exact native test log bytes."
  Assert-Contract ($manifest.fixture.sourceBaseCommit -ceq "0000000000000000000000000000000000000000") `
    "Fixture provenance must label sourceCommit as the native run's base HEAD."
  Assert-Contract ($manifest.gdiPlusEvidenceScope -match "does not prove every drawing operation") `
    "Manifest must limit the GDI+ readiness claim."
  Assert-Contract ($manifest.fontFileEvidenceScope -match "lookup candidates") `
    "Manifest must distinguish selected font-face evidence from font-file lookup candidates."
  Assert-Contract (@($manifest.sourceFiles).Count -eq 7) `
    "Manifest must carry all seven source hashes from the native run receipt."
  $currentSourceHashes = Get-ContractSourceHashes
  foreach ($sourceFact in $manifest.sourceFiles) {
    $relativePath = $sourceFact.path.Replace("/", "\")
    Assert-Contract ($sourceFact.sha256 -ceq $currentSourceHashes[$relativePath]) `
      "Manifest source identity differs from the actual native-run source snapshot: $relativePath"
  }
  Assert-Contract ($manifest.artifact.width -eq 1280 -and $manifest.artifact.height -eq 720) `
    "PNG output geometry is incorrect."
  $published = @(Get-ChildItem -LiteralPath $run.OutputDirectory -Force)
  Assert-Contract ($published.Count -eq 2) "Output must contain exactly one PNG and one manifest."
  $staging = @(Get-ChildItem -LiteralPath $run.RunRoot -Directory -Filter ".canvas-paint-staging-*")
  Assert-Contract ($staging.Count -eq 0) "Successful publication must not leave a staging directory."
}

Invoke-ContractCase "absent BMP" {
  $run = New-SyntheticRun "absent"
  Remove-Item -LiteralPath $run.InputBmp
  Assert-ConverterFailure $run "InputBmpMissing"

  $failedLogRun = New-SyntheticRun "failed-native-log"
  [IO.File]::WriteAllText(
    $failedLogRun.NativeLogPath,
    "1/1 GraphCanvas.test.paint export: project-paint-v1...FAIL`nAll 1 tests failed.`n")
  Update-SyntheticArtifactHash $failedLogRun "nativeLog"
  Assert-ConverterFailure $failedLogRun "NativeRunSummaryInvalid"
  Write-Host "PASS subcontrol rejects a failed native test summary"

  $zeroRun = New-SyntheticRun "zero-native-tests"
  [IO.File]::WriteAllText($zeroRun.NativeLogPath, "All 0 tests passed.`n")
  Update-SyntheticArtifactHash $zeroRun "nativeLog"
  Assert-ConverterFailure $zeroRun "NativeRunSummaryInvalid"
  Write-Host "PASS subcontrol rejects a zero-test native summary"

  $skippedRun = New-SyntheticRun "skipped-native-test"
  [IO.File]::WriteAllText(
    $skippedRun.NativeLogPath,
    "1/1 GraphCanvas.test.paint export: project-paint-v1...SKIP`nAll 1 tests skipped.`n")
  Update-SyntheticArtifactHash $skippedRun "nativeLog"
  Assert-ConverterFailure $skippedRun "NativeRunSummaryInvalid"
  Write-Host "PASS subcontrol rejects a skipped native test"

  $failedExitRun = New-SyntheticRun "failed-native-exit"
  $failedExitReceipt = Get-Content -LiteralPath $failedExitRun.RunReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $failedExitReceipt.nativeExitCode = 1
  [IO.File]::WriteAllText($failedExitRun.RunReceiptPath, ($failedExitReceipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  Assert-ConverterFailure $failedExitRun "NativeRunFailed"
  Write-Host "PASS subcontrol rejects a nonzero native exit"

  $logMismatchRun = New-SyntheticRun "native-log-path-mismatch"
  $logMismatchReceipt = Get-Content -LiteralPath $logMismatchRun.RunReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $logMismatchReceipt.log = Join-Path $logMismatchRun.RunRoot "other.log"
  [IO.File]::WriteAllText(
    $logMismatchRun.RunReceiptPath,
    ($logMismatchReceipt | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false))
  Assert-ConverterFailure $logMismatchRun "NativeRunReceiptInvalid"
  Write-Host "PASS subcontrol rejects a native log path mismatch"

  $binarySubstitutionRun = New-SyntheticRun "substituted-test-binary"
  [IO.File]::WriteAllBytes(
    $binarySubstitutionRun.TestBinaryPath,
    [Text.Encoding]::ASCII.GetBytes("substituted test binary bytes"))
  Assert-ConverterFailure $binarySubstitutionRun "NativeTestBinaryHashMismatch"
  Write-Host "PASS subcontrol rejects post-run test-binary substitution"

  $logSubstitutionRun = New-SyntheticRun "substituted-native-log"
  [IO.File]::AppendAllText($logSubstitutionRun.NativeLogPath, "`n")
  Assert-ConverterFailure $logSubstitutionRun "NativeLogHashMismatch"
  Write-Host "PASS subcontrol rejects post-run native-log substitution"

  $paintReceiptSubstitutionRun = New-SyntheticRun "substituted-paint-receipt"
  [IO.File]::AppendAllText($paintReceiptSubstitutionRun.ReceiptPath, "`n")
  Assert-ConverterFailure $paintReceiptSubstitutionRun "NativePaintReceiptHashMismatch"
  Write-Host "PASS subcontrol rejects post-run paint-receipt substitution"
}

Invoke-ContractCase "truncated BMP" {
  $run = New-SyntheticRun "truncated"
  [IO.File]::WriteAllBytes($run.InputBmp, [byte[]]@(0x42, 0x4D, 0x00))
  Assert-ConverterFailure $run "TruncatedBmp"
}

Invoke-ContractCase "wrong geometry" {
  $run = New-SyntheticRun "wrong-geometry" 1280 719
  Assert-ConverterFailure $run "WrongGeometry"
}

Invoke-ContractCase "fixture hash mismatch" {
  $run = New-SyntheticRun "fixture-mismatch"
  $receipt = Get-Content -LiteralPath $run.ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $receipt.fixtureSha256 = "0000000000000000000000000000000000000000000000000000000000000000"
  [IO.File]::WriteAllText($run.ReceiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  Update-SyntheticArtifactHash $run "paintReceipt"
  Assert-ConverterFailure $run "FixtureHashMismatch"

  $staleSourceRun = New-SyntheticRun "stale-native-source"
  $staleSourceReceipt = Get-Content -LiteralPath $staleSourceRun.RunReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $staleHash = "0000000000000000000000000000000000000000000000000000000000000000"
  $staleSourceReceipt.sourceHashesBefore["graphcode-windows\src\GraphCanvas.zig"] = $staleHash
  $staleSourceReceipt.sourceHashesAfter["graphcode-windows\src\GraphCanvas.zig"] = $staleHash
  [IO.File]::WriteAllText(
    $staleSourceRun.RunReceiptPath,
    ($staleSourceReceipt | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false))
  Assert-ConverterFailure $staleSourceRun "NativeSourceHashMismatch"
  Write-Host "PASS subcontrol rejects a stale native source hash"

  $changedDuringRun = New-SyntheticRun "source-changed-during-run"
  $changedReceipt = Get-Content -LiteralPath $changedDuringRun.RunReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $changedReceipt.sourceHashesBefore["graphcode-windows\src\GraphCanvas.zig"] = $staleHash
  [IO.File]::WriteAllText(
    $changedDuringRun.RunReceiptPath,
    ($changedReceipt | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false))
  Assert-ConverterFailure $changedDuringRun "NativeSourceChangedDuringRun"
  Write-Host "PASS subcontrol rejects source changes during native execution"
}

Invoke-ContractCase "existing foreign output" {
  $overlappingRun = New-SyntheticRun "transport-output"
  $overlappingRun.OutputDirectory = Join-Path $overlappingRun.TransportRoot "published"
  Assert-ConverterFailure $overlappingRun "OutputPathOverlapsTransport"

  $run = New-SyntheticRun "foreign-output"
  New-Item -ItemType Directory -Path $run.OutputDirectory | Out-Null
  [IO.File]::WriteAllText((Join-Path $run.OutputDirectory "foreign.txt"), "preserve")
  Assert-ConverterFailure $run "OutputNotFresh"
  Assert-Contract (Test-Path -LiteralPath (Join-Path $run.OutputDirectory "foreign.txt")) `
    "Converter must preserve foreign output."
}

Invoke-ContractCase "reparse output" {
  $run = New-SyntheticRun "reparse-output"
  New-Item -ItemType Junction -Path $run.OutputDirectory -Target $run.RunRoot | Out-Null
  Assert-ConverterFailure $run "ReparsePoint"
}

Invoke-ContractCase "codec/write failure" {
  $run = New-SyntheticRun "codec-write-failure"
  $run | Add-Member -NotePropertyName TestPngCodecWriteFailure -NotePropertyValue $true
  Assert-ConverterFailure $run "CodecWriteFailed"
  Write-Host "PASS subcontrol fails inside Bitmap.Save after a partial staging-file write"

  $publishRun = New-SyntheticRun "publish-failure"
  $blocker = Join-Path $publishRun.RunRoot "not-a-directory"
  [IO.File]::WriteAllText($blocker, "output parent blocker")
  $publishRun.OutputDirectory = Join-Path $blocker "published"
  Assert-ConverterFailure $publishRun "OutputPublishFailed"
  Write-Host "PASS subcontrol preserves verified staging after final publication failure"
}

$expectedNames = @(
  "valid round-trip",
  "absent BMP",
  "truncated BMP",
  "wrong geometry",
  "fixture hash mismatch",
  "existing foreign output",
  "reparse output",
  "codec/write failure"
)
$names = @($caseResults | ForEach-Object { $_.Name })
$uniqueNames = @($names | Sort-Object -Unique)
$passed = @($caseResults | Where-Object Passed).Count
$failed = $caseResults.Count - $passed
$skipped = 0
$namesMatch = ($names.Count -eq $expectedNames.Count) -and
  (($names -join "`n") -ceq ($expectedNames -join "`n")) -and
  ($uniqueNames.Count -eq $expectedNames.Count)
$summary = [pscustomobject]@{
  Executed = [int]$caseResults.Count
  Passed = [int]$passed
  Failed = [int]$failed
  Skipped = [int]$skipped
  CaseNames = [string[]]$names
}
Write-Host "CANVAS_PAINT_CASES executed=$($summary.Executed) passed=$($summary.Passed) skipped=$($summary.Skipped) failed=$($summary.Failed) names=$($names -join '|')"
Write-Output $summary
if (-not $namesMatch -or $summary.Executed -ne 8 -or $summary.Passed -ne 8 -or
    $summary.Skipped -ne 0 -or $summary.Failed -ne 0) {
  foreach ($failure in $caseResults | Where-Object { -not $_.Passed }) {
    Write-Error "Contract $($failure.Name) failed: $($failure.Error)" -ErrorAction Continue
  }
  throw "Canvas paint artifact contracts did not execute the exact 8/8/0/0 suite."
}

foreach ($scene in @("project-paint-764", "overview-paint-764")) {
  $artifactName = "$scene.png"
  $expectedSurface = if ($scene -eq "project-paint-764") { "project" } else { "overview" }
  Invoke-SceneContractCase "$scene valid round-trip" {
    $run = New-SyntheticRun "scene-$scene-valid" -Scene $scene
    $result = @(Invoke-Converter $run)
    Assert-Contract ($result.Count -eq 1 -and $result[0].ArtifactCount -eq 1) `
      "The closed scene profile must publish exactly one artifact."
    Assert-Contract ([IO.Path]::GetFileName($result[0].Artifact) -ceq $artifactName) `
      "The published image name must be fixed by the selected scene profile."
    $manifest = Get-Content -LiteralPath $result[0].Manifest -Raw | ConvertFrom-Json -AsHashtable
    $receipt = Get-Content -LiteralPath $run.ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-Contract ($manifest.scene -ceq $scene -and $manifest.canvasSurface -ceq $expectedSurface) `
      "Manifest must retain the selected scene and surface."
    Assert-Contract ($receipt.ageEvidence.nodes[0].createdAtEpochSeconds -eq 1704067200) `
      "Fixture daemon-reference timestamps must normalize to Unix seconds before age evidence is recorded."
    $receiptAgeJson = ConvertTo-Json -InputObject $receipt.ageEvidence -Depth 8 -Compress
    $manifestAgeJson = ConvertTo-Json -InputObject $manifest.ageEvidence -Depth 8 -Compress
    Assert-Contract ($manifestAgeJson -ceq $receiptAgeJson) `
      "Manifest must preserve the validated age observation and labels."
    Assert-Contract ($manifest.nativeRun.testName -ceq "GraphCanvas.test.paint export: $scene") `
      "Manifest must bind the exact scene-specific native test."
    $expectedFixturePaths = @(Get-SceneFixturePaths $scene | ForEach-Object { $_.Replace("\", "/") })
    $actualFixturePaths = @($manifest.fixtureFiles | ForEach-Object { $_.path })
    Assert-Contract (($actualFixturePaths -join "`n") -ceq ($expectedFixturePaths -join "`n")) `
      "Manifest must bind the exact fixture set in order."
    $expectedSourcePaths = @(Get-SceneSourcePaths $scene | ForEach-Object { $_.Replace("\", "/") } | Sort-Object -CaseSensitive)
    $actualSourcePaths = @($manifest.sourceFiles | ForEach-Object { $_.path } | Sort-Object -CaseSensitive)
    Assert-Contract ($expectedSourcePaths.Count -eq (6 + $expectedFixturePaths.Count) -and
      ($actualSourcePaths -join "`n") -ceq ($expectedSourcePaths -join "`n")) `
      "Manifest must bind the exact scene-specific leased source paths."
    Assert-Contract ((Get-ChildItem -LiteralPath $run.OutputDirectory -Force).Count -eq 2) `
      "Scene publication must contain exactly the PNG and manifest."
  }
}

Invoke-SceneContractCase "project-paint-764 fixture digest refusal" {
  $run = New-SyntheticRun "scene-project-paint-764-fixture-mismatch" -Scene "project-paint-764"
  $receipt = Get-Content -LiteralPath $run.ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $receipt.fixtureSha256 = "0000000000000000000000000000000000000000000000000000000000000000"
  [IO.File]::WriteAllText($run.ReceiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  Update-SyntheticArtifactHash $run "paintReceipt"
  Assert-ConverterFailure $run "FixtureHashMismatch"
}

Invoke-SceneContractCase "overview-paint-764 source inventory refusal" {
  $run = New-SyntheticRun "scene-overview-paint-764-source-inventory" -Scene "overview-paint-764"
  $receipt = Get-Content -LiteralPath $run.RunReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $receipt.sourceHashesBefore["unleased-source.json"] = "0000000000000000000000000000000000000000000000000000000000000000"
  $receipt.sourceHashesAfter["unleased-source.json"] = "0000000000000000000000000000000000000000000000000000000000000000"
  [IO.File]::WriteAllText($run.RunReceiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  Assert-ConverterFailure $run "NativeSourceSnapshotInvalid"
}

Invoke-SceneContractCase "project-paint-764 wrong surface refusal" {
  $run = New-SyntheticRun "scene-project-paint-764-wrong-surface" -Scene "project-paint-764"
  $receipt = Get-Content -LiteralPath $run.ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $receipt.canvas.surface = "overview"
  [IO.File]::WriteAllText($run.ReceiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  Update-SyntheticArtifactHash $run "paintReceipt"
  Assert-ConverterFailure $run "RenderConfigurationInvalid"
}

Invoke-SceneContractCase "project-paint-764 wrong scene refusal" {
  $run = New-SyntheticRun "scene-project-paint-764-wrong-scene" -Scene "project-paint-764"
  $receipt = Get-Content -LiteralPath $run.ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $receipt.scene = "overview-paint-764"
  [IO.File]::WriteAllText($run.ReceiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  Update-SyntheticArtifactHash $run "paintReceipt"
  Assert-ConverterFailure $run "ReceiptSchemaInvalid"
}

Invoke-SceneContractCase "overview-paint-764 missing fixture refusal" {
  $run = New-SyntheticRun "scene-overview-paint-764-missing-fixture" -Scene "overview-paint-764"
  $receipt = Get-Content -LiteralPath $run.ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $receipt.fixtures = @($receipt.fixtures | Select-Object -First 1)
  [IO.File]::WriteAllText($run.ReceiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  Update-SyntheticArtifactHash $run "paintReceipt"
  Assert-ConverterFailure $run "FixtureHashMismatch"
}

Invoke-SceneContractCase "overview-paint-764 fixture order refusal" {
  $run = New-SyntheticRun "scene-overview-paint-764-fixture-order" -Scene "overview-paint-764"
  $receipt = Get-Content -LiteralPath $run.ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $receipt.fixtures = @($receipt.fixtures[1], $receipt.fixtures[0])
  [IO.File]::WriteAllText($run.ReceiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  Update-SyntheticArtifactHash $run "paintReceipt"
  Assert-ConverterFailure $run "FixtureHashMismatch"
}

Invoke-SceneContractCase "overview-paint-764 native profile mismatch refusal" {
  $run = New-SyntheticRun "scene-overview-paint-764-native-profile-mismatch" -Scene "overview-paint-764"
  $runReceipt = Get-Content -LiteralPath $run.RunReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $runReceipt.command = $runReceipt.command.Replace(
    '--test-filter "paint export: overview-paint-764"',
    '--test-filter "paint export: project-paint-764"')
  [IO.File]::WriteAllText($run.RunReceiptPath, ($runReceipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  Assert-ConverterFailure $run "NativeRunReceiptInvalid"
}

Invoke-SceneContractCase "project-paint-v1 stray profile fields refusal" {
  $run = New-SyntheticRun "scene-project-paint-v1-stray-profile-fields" -Scene "project-paint-v1"
  $receipt = Get-Content -LiteralPath $run.ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $receipt["fixtures"] = @([ordered]@{ path = "graphcode-windows/fixtures/paint-project-v1.json"; sha256 = $fixtureHash })
  $receipt.canvas["surface"] = "project"
  [IO.File]::WriteAllText($run.ReceiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  Update-SyntheticArtifactHash $run "paintReceipt"
  Assert-ConverterFailure $run "SceneProfileFieldsInvalid"
}

Invoke-SceneContractCase "overview-paint-764 painted edge mismatch refusal" {
  $run = New-SyntheticRun "scene-overview-paint-764-painted-edge-mismatch" -Scene "overview-paint-764"
  $receipt = Get-Content -LiteralPath $run.ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $receipt.model.paintedEdges = 4
  [IO.File]::WriteAllText($run.ReceiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  Update-SyntheticArtifactHash $run "paintReceipt"
  Assert-ConverterFailure $run "PaintEvidenceInvalid"
}

Invoke-SceneContractCase "project-paint-764 painted edge mismatch refusal" {
  $run = New-SyntheticRun "scene-project-paint-764-painted-edge-mismatch" -Scene "project-paint-764"
  $receipt = Get-Content -LiteralPath $run.ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $receipt.model.paintedEdges = 0
  [IO.File]::WriteAllText($run.ReceiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  Update-SyntheticArtifactHash $run "paintReceipt"
  Assert-ConverterFailure $run "PaintEvidenceInvalid"
}

Invoke-SceneContractCase "project-paint-764 age label mismatch refusal" {
  $run = New-SyntheticRun "scene-project-paint-764-age-label-mismatch" -Scene "project-paint-764"
  $receipt = Get-Content -LiteralPath $run.ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $receipt.ageEvidence.nodes[0].display = "incorrect-age"
  [IO.File]::WriteAllText($run.ReceiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  Update-SyntheticArtifactHash $run "paintReceipt"
  Assert-ConverterFailure $run "AgeEvidenceInvalid"
}

Invoke-SceneContractCase "overview-paint-764 age count refusal" {
  $run = New-SyntheticRun "scene-overview-paint-764-age-count" -Scene "overview-paint-764"
  $receipt = Get-Content -LiteralPath $run.ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $receipt.ageEvidence.nodes = @($receipt.ageEvidence.nodes | Select-Object -First 7)
  [IO.File]::WriteAllText($run.ReceiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  Update-SyntheticArtifactHash $run "paintReceipt"
  Assert-ConverterFailure $run "AgeEvidenceInvalid"
}

Invoke-SceneContractCase "project-paint-764 age epoch type refusal" {
  $run = New-SyntheticRun "scene-project-paint-764-age-epoch-type" -Scene "project-paint-764"
  $receipt = Get-Content -LiteralPath $run.ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $receipt.ageEvidence.observedAtEpochSeconds = "1800000000"
  [IO.File]::WriteAllText($run.ReceiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  Update-SyntheticArtifactHash $run "paintReceipt"
  Assert-ConverterFailure $run "AgeEvidenceInvalid"
}

Invoke-SceneContractCase "project-paint-764 timestamp census refusal" {
  $run = New-SyntheticRun "scene-project-paint-764-timestamp-census" -Scene "project-paint-764"
  $receipt = Get-Content -LiteralPath $run.ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
  $receipt.model.createdAtValues = 5
  [IO.File]::WriteAllText($run.ReceiptPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  Update-SyntheticArtifactHash $run "paintReceipt"
  Assert-ConverterFailure $run "PaintEvidenceInvalid"
}

$expectedSceneNames = @(
  "project-paint-764 valid round-trip",
  "overview-paint-764 valid round-trip",
  "project-paint-764 fixture digest refusal",
  "overview-paint-764 source inventory refusal",
  "project-paint-764 wrong surface refusal",
  "project-paint-764 wrong scene refusal",
  "overview-paint-764 missing fixture refusal",
  "overview-paint-764 fixture order refusal",
  "overview-paint-764 native profile mismatch refusal",
  "project-paint-v1 stray profile fields refusal",
  "overview-paint-764 painted edge mismatch refusal",
  "project-paint-764 painted edge mismatch refusal",
  "project-paint-764 age label mismatch refusal",
  "overview-paint-764 age count refusal",
  "project-paint-764 age epoch type refusal",
  "project-paint-764 timestamp census refusal"
)
$sceneNames = @($sceneCaseResults | ForEach-Object { $_.Name })
$scenePassed = @($sceneCaseResults | Where-Object Passed).Count
$sceneFailed = $sceneCaseResults.Count - $scenePassed
$sceneNamesMatch = ($sceneNames.Count -eq $expectedSceneNames.Count) -and
  (($sceneNames -join "`n") -ceq ($expectedSceneNames -join "`n"))
Write-Host "CANVAS_PAINT_SCENE_CASES executed=$($sceneCaseResults.Count) passed=$scenePassed failed=$sceneFailed names=$($sceneNames -join '|')"
if (-not $sceneNamesMatch -or $sceneCaseResults.Count -ne 16 -or $scenePassed -ne 16 -or $sceneFailed -ne 0) {
  foreach ($failure in $sceneCaseResults | Where-Object { -not $_.Passed }) {
    Write-Error "Scene profile contract $($failure.Name) failed: $($failure.Error)" -ErrorAction Continue
  }
  throw "Canvas paint scene profile contracts did not execute the exact 16/16/0 suite."
}
