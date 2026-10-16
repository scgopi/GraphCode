[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $InputBmp,
  [Parameter(Mandatory)][string] $ReceiptPath,
  [Parameter(Mandatory)][string] $RunReceiptPath,
  [Parameter(Mandatory)][string] $TestBinaryPath,
  [Parameter(Mandatory)][string] $OutputDirectory,
  [ValidateSet("project-paint-v1", "project-paint-764", "overview-paint-764")]
  [string] $Scene = "project-paint-v1",
  [Parameter(DontShow)][switch] $TestPngCodecWriteFailure
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$sourceFilesV1 = @(
  "graphcode-windows\src\GraphCanvas.zig",
  "graphcode-windows\src\GdiplusAA.zig",
  "graphcode-windows\fixtures\paint-project-v1.json",
  "Tools\windows\Convert-CanvasPaintArtifact.ps1",
  "Tools\windows\Tests\CanvasPaintArtifact.Tests.ps1",
  "Tools\windows\Tests\WindowsShell.Tests.ps1",
  "graphcode-windows\README.md"
)
$profiles = @{
  "project-paint-v1" = [ordered]@{
    fixturePaths = @("graphcode-windows\fixtures\paint-project-v1.json")
    sourceFiles = $sourceFilesV1
    nodes = 2
    edges = 1
    createdAtValues = 0
    surface = $null
    headerContext = "Alpha"
    transportNames = @("project-paint-v1.bmp", "project-paint-v1-repeat-2.bmp", "project-paint-v1-repeat-3.bmp")
    artifactName = "project-paint-v1.png"
    excludedSurfaces = @("whole window", "composition", "popups", "terminals", "per-monitor DPI", "sidebar/right-panel fidelity", "native form controls", "accessibility")
  }
  "project-paint-764" = [ordered]@{
    fixturePaths = @("graphcode-windows\fixtures\paint-764-project.json")
    sourceFiles = @(
      "graphcode-windows\src\GraphCanvas.zig",
      "graphcode-windows\src\GdiplusAA.zig",
      "graphcode-windows\fixtures\paint-764-project.json",
      "Tools\windows\Convert-CanvasPaintArtifact.ps1",
      "Tools\windows\Tests\CanvasPaintArtifact.Tests.ps1",
      "Tools\windows\Tests\WindowsShell.Tests.ps1",
      "graphcode-windows\README.md"
    )
    nodes = 6
    edges = 3
    paintedEdges = 3
    createdAtValues = 6
    surface = "project"
    headerContext = "Card States"
    transportNames = @("project-paint-764.bmp", "project-paint-764-repeat-2.bmp", "project-paint-764-repeat-3.bmp")
    artifactName = "project-paint-764.png"
    excludedSurfaces = @("whole window composition", "input and button behavior", "project opening and canvas fit", "backend lifecycle and persistence", "UI Automation and accessibility", "per-monitor DPI", "unreviewed sidebar and loop-bar palette")
  }
  "overview-paint-764" = [ordered]@{
    fixturePaths = @("graphcode-windows\fixtures\paint-764-project.json", "graphcode-windows\fixtures\paint-764-overview-peer.json")
    sourceFiles = @(
      "graphcode-windows\src\GraphCanvas.zig",
      "graphcode-windows\src\GdiplusAA.zig",
      "graphcode-windows\fixtures\paint-764-project.json",
      "graphcode-windows\fixtures\paint-764-overview-peer.json",
      "Tools\windows\Convert-CanvasPaintArtifact.ps1",
      "Tools\windows\Tests\CanvasPaintArtifact.Tests.ps1",
      "Tools\windows\Tests\WindowsShell.Tests.ps1",
      "graphcode-windows\README.md"
    )
    nodes = 8
    edges = 4
    paintedEdges = 0
    createdAtValues = 8
    surface = "overview"
    headerContext = "Overview"
    transportNames = @("overview-paint-764.bmp", "overview-paint-764-repeat-2.bmp", "overview-paint-764-repeat-3.bmp")
    artifactName = "overview-paint-764.png"
    excludedSurfaces = @("whole window composition", "input and button behavior", "project opening and canvas fit", "backend lifecycle and persistence", "UI Automation and accessibility", "per-monitor DPI", "unreviewed sidebar and loop-bar palette")
  }
}
$profile = $profiles[$Scene]

function Stop-Artifact(
  [string] $Code,
  [string] $Message,
  [System.Exception] $InnerException = $null,
  [System.Collections.IDictionary] $Evidence = $null
) {
  $fullMessage = "CanvasPaintArtifact[$Code]: $Message"
  $exception = if ($null -ne $InnerException) {
    [InvalidOperationException]::new($fullMessage, $InnerException)
  } else {
    [InvalidOperationException]::new($fullMessage)
  }
  if ($null -ne $Evidence) {
    foreach ($key in $Evidence.Keys) {
      $exception.Data[$key] = $Evidence[$key]
    }
  }
  throw $exception
}

function Get-CardAgeLabel([long] $CreatedAt, [long] $ObservedAt) {
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

function Get-ExpectedAgeEvidence([string[]] $FixturePaths, [long] $ObservedAt) {
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
        display = Get-CardAgeLabel $createdAtEpochSeconds $ObservedAt
      })
    }
  }
  return [ordered]@{
    observedAtEpochSeconds = $ObservedAt
    nodes = @($nodes)
  }
}

function Get-Sha256Bytes([byte[]] $Bytes) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return [Convert]::ToHexString($sha.ComputeHash($Bytes)).ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function Get-Sha256File([string] $Path) {
  $stream = [IO.File]::OpenRead($Path)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return [Convert]::ToHexString($sha.ComputeHash($stream)).ToLowerInvariant() }
  finally {
    $sha.Dispose()
    $stream.Dispose()
  }
}

function Read-JsonArtifact([string] $Path, [string] $ErrorCode) {
  try {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $value = ConvertFrom-Json -InputObject $text -AsHashtable -ErrorAction Stop
    return [pscustomobject]@{
      Value = $value
      Sha256 = Get-Sha256Bytes $bytes
    }
  } catch {
    Stop-Artifact $ErrorCode "Could not read a valid UTF-8 JSON artifact at $Path`: $($_.Exception.Message)"
  }
}

function Read-StrictUtf8Artifact([string] $Path, [string] $ErrorCode) {
  try {
    $bytes = [IO.File]::ReadAllBytes($Path)
    return [pscustomobject]@{
      Text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
      Sha256 = Get-Sha256Bytes $bytes
    }
  } catch {
    Stop-Artifact $ErrorCode "Could not read a valid UTF-8 artifact at $Path`: $($_.Exception.Message)"
  }
}

function Assert-NativeArtifactBinding(
  [System.Collections.IDictionary] $Artifacts,
  [string] $Name,
  [string] $ExpectedPath,
  [string] $ActualHash,
  [string] $MismatchCode
) {
  $artifact = $Artifacts[$Name]
  if ($artifact -isnot [System.Collections.IDictionary] -or
      $artifact.present -isnot [bool] -or -not $artifact.present) {
    Stop-Artifact "NativeArtifactMissing" "Native run receipt does not record a present $Name artifact."
  }
  if ([string]::IsNullOrWhiteSpace([string]$artifact.path) -or
      -not [StringComparer]::OrdinalIgnoreCase.Equals(
        [IO.Path]::GetFullPath([string]$artifact.path),
        [IO.Path]::GetFullPath($ExpectedPath))) {
    Stop-Artifact "NativeArtifactReceiptInvalid" "Native run receipt path does not identify the canonical $Name artifact."
  }
  $recordedHash = [string]$artifact.sha256
  if ($recordedHash -cnotmatch '^[0-9a-f]{64}$') {
    Stop-Artifact "NativeArtifactReceiptInvalid" "Native run receipt must contain a lowercase SHA-256 for $Name."
  }
  if ($ActualHash -cne $recordedHash) {
    Stop-Artifact $MismatchCode "The $Name bytes differ from the hash captured immediately after the native command."
  }
}

function Test-PathWithin([string] $Root, [string] $Path) {
  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
  $pathFull = [IO.Path]::GetFullPath($Path)
  $relative = [IO.Path]::GetRelativePath($rootFull, $pathFull)
  return -not [IO.Path]::IsPathRooted($relative) -and
    $relative -ne ".." -and
    -not $relative.StartsWith(".." + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)
}

function Test-HasReparseComponent([string] $Path) {
  $full = [IO.Path]::GetFullPath($Path)
  $root = [IO.Path]::GetPathRoot($full)
  $current = $root
  $relative = $full.Substring($root.Length)
  foreach ($part in $relative.Split([IO.Path]::DirectorySeparatorChar, [StringSplitOptions]::RemoveEmptyEntries)) {
    $current = Join-Path $current $part
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
    }
  }
  return $false
}

function Read-BmpHeader([string] $Path) {
  $length = ([IO.FileInfo]::new($Path)).Length
  if ($length -lt 54) { Stop-Artifact "TruncatedBmp" "BMP file is shorter than the 54-byte header." }
  $stream = [IO.File]::OpenRead($Path)
  $reader = [IO.BinaryReader]::new($stream)
  try {
    if ($reader.ReadByte() -ne 0x42 -or $reader.ReadByte() -ne 0x4D) {
      Stop-Artifact "InvalidBmp" "Transport is not a Windows BMP."
    }
    $declaredLength = $reader.ReadUInt32()
    [void] $reader.ReadUInt32()
    $pixelOffset = $reader.ReadUInt32()
    $headerSize = $reader.ReadUInt32()
    $width = $reader.ReadInt32()
    $height = $reader.ReadInt32()
    $planes = $reader.ReadUInt16()
    $bitsPerPixel = $reader.ReadUInt16()
    $compression = $reader.ReadUInt32()
    $imageSize = $reader.ReadUInt32()
  } finally {
    $reader.Dispose()
    $stream.Dispose()
  }
  if ($declaredLength -ne $length -or $headerSize -ne 40 -or $pixelOffset -ne 54 -or
      $planes -ne 1 -or $bitsPerPixel -ne 32 -or $compression -ne 0 -or $height -le 0) {
    Stop-Artifact "InvalidBmp" "BMP header does not match the required 32-bit BI_RGB transport."
  }
  if ($width -ne 1280 -or $height -ne 720) {
    Stop-Artifact "WrongGeometry" "BMP must be exactly 1280x720; found ${width}x${height}."
  }
  $expectedImageSize = [long]$width * $height * 4
  if ($imageSize -ne $expectedImageSize -or $pixelOffset + $expectedImageSize -ne $length) {
    Stop-Artifact "TruncatedBmp" "BMP pixel buffer is incomplete or has trailing bytes."
  }
  return [pscustomobject]@{
    Width = $width
    Height = $height
    PixelOffset = $pixelOffset
    ImageSize = $imageSize
  }
}

function Get-DecodedRgbSha256([Drawing.Bitmap] $Bitmap) {
  $rgb = [byte[]]::new($Bitmap.Width * $Bitmap.Height * 3)
  $offset = 0
  $firstColor = -1
  $nonBackgroundPixels = 0
  for ($y = 0; $y -lt $Bitmap.Height; $y++) {
    for ($x = 0; $x -lt $Bitmap.Width; $x++) {
      $pixel = $Bitmap.GetPixel($x, $y)
      if ($pixel.A -ne 255) { Stop-Artifact "NonOpaquePixel" "Decoded SDR RGB transport contains a non-opaque pixel." }
      $color = ($pixel.R -shl 16) -bor ($pixel.G -shl 8) -bor $pixel.B
      if ($firstColor -lt 0) {
        $firstColor = $color
      } elseif ($color -ne $firstColor) {
        $nonBackgroundPixels++
      }
      $rgb[$offset++] = $pixel.R
      $rgb[$offset++] = $pixel.G
      $rgb[$offset++] = $pixel.B
    }
  }
  if ($nonBackgroundPixels -le 10000) {
    Stop-Artifact "BlankOrPartialImage" "Decoded image does not contain the minimum painted pixel coverage."
  }
  return (Get-Sha256Bytes $rgb)
}

function Get-FontFileFact([string] $Name) {
  $path = Join-Path $env:WINDIR ("Fonts\" + $Name)
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return [ordered]@{ name = $Name; resolved = $false; path = $null; version = $null; sha256 = $null }
  }
  $item = Get-Item -LiteralPath $path
  return [ordered]@{
    name = $Name
    resolved = $true
    path = $item.FullName
    version = [Diagnostics.FileVersionInfo]::GetVersionInfo($item.FullName).FileVersion
    sha256 = Get-Sha256File $item.FullName
  }
}

$inputFull = [IO.Path]::GetFullPath($InputBmp)
$receiptFull = [IO.Path]::GetFullPath($ReceiptPath)
$runReceiptFull = [IO.Path]::GetFullPath($RunReceiptPath)
$testBinaryFull = [IO.Path]::GetFullPath($TestBinaryPath)
$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$runRoot = [IO.Path]::GetDirectoryName($testBinaryFull)
$transportRoot = Join-Path $runRoot "export\transport"
$expectedInput = Join-Path $transportRoot $profile.transportNames[0]
$expectedReceipt = Join-Path $transportRoot "paint-receipt.json"
$expectedRunReceipt = Join-Path $runRoot "run-receipt.json"
$nativeLogPath = Join-Path $runRoot "native.log"
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$sourceFiles = @($profile.sourceFiles)
if (-not [StringComparer]::OrdinalIgnoreCase.Equals($inputFull, $expectedInput) -or
    -not [StringComparer]::OrdinalIgnoreCase.Equals($receiptFull, $expectedReceipt) -or
    -not [StringComparer]::OrdinalIgnoreCase.Equals($runReceiptFull, $expectedRunReceipt)) {
  Stop-Artifact "TransportPathInvalid" "BMP, paint receipt, and run receipt must be the canonical files for this native test run."
}
if (-not (Test-PathWithin $runRoot $outputFull)) {
  Stop-Artifact "OutputPathEscape" "Output directory must remain inside the owned native-test run root."
}
if (Test-PathWithin $transportRoot $outputFull) {
  Stop-Artifact "OutputPathOverlapsTransport" "Published output must remain separate from BMP transport and receipt files."
}
if (-not (Test-Path -LiteralPath $testBinaryFull -PathType Leaf)) {
  Stop-Artifact "TestBinaryMissing" "The emitted native test binary is missing."
}
if (-not (Test-Path -LiteralPath $nativeLogPath -PathType Leaf) -or
    (Get-Item -LiteralPath $nativeLogPath).Length -eq 0) {
  Stop-Artifact "NativeLogMissing" "The native test run log is missing or empty."
}
if (-not (Test-Path -LiteralPath $inputFull -PathType Leaf)) {
  Stop-Artifact "InputBmpMissing" "The canonical BMP transport is missing."
}
if (-not (Test-Path -LiteralPath $receiptFull -PathType Leaf)) {
  Stop-Artifact "ReceiptMissing" "The paint receipt is missing."
}
if (-not (Test-Path -LiteralPath $runReceiptFull -PathType Leaf)) {
  Stop-Artifact "RunReceiptMissing" "The frozen native test run receipt is missing."
}
foreach ($path in @($runRoot, $testBinaryFull, $transportRoot, $inputFull, $receiptFull, $runReceiptFull, $nativeLogPath, $outputFull)) {
  if (Test-HasReparseComponent $path) {
    Stop-Artifact "ReparsePoint" "Artifact paths may not traverse reparse points: $path"
  }
}
if (Test-Path -LiteralPath $outputFull) {
  Stop-Artifact "OutputNotFresh" "Output directory must not already exist."
}

$receiptDocument = Read-JsonArtifact $receiptFull "ReceiptSchemaInvalid"
$receipt = $receiptDocument.Value
$runReceiptDocument = Read-JsonArtifact $runReceiptFull "NativeRunReceiptInvalid"
$runReceipt = $runReceiptDocument.Value
if ($runReceipt -isnot [System.Collections.IDictionary] -or
    [string]::IsNullOrWhiteSpace([string]$runReceipt.runId) -or
    [string]::IsNullOrWhiteSpace([string]$runReceipt.exportDirectory) -or
    [string]::IsNullOrWhiteSpace([string]$runReceipt.emittedTestBinary) -or
    [string]::IsNullOrWhiteSpace([string]$runReceipt.log)) {
  Stop-Artifact "NativeRunReceiptInvalid" "Run receipt is missing its run, export, binary, or log identity."
}
if ($receipt.schemaVersion -ne 1 -or $receipt.evidenceClass -cne "paint-only" -or
    $receipt.scene -cne $Scene -or $receipt.renderer -cne "GraphCanvas.paint + GraphCanvas.paintHeader -> memory DIB") {
  Stop-Artifact "ReceiptSchemaInvalid" "Receipt does not describe the approved paint-only render."
}
if ($Scene -eq "project-paint-v1" -and
    ($receipt.Contains("fixtures") -or $receipt.canvas.Contains("surface") -or $receipt.model.Contains("paintedEdges"))) {
  Stop-Artifact "SceneProfileFieldsInvalid" "The legacy scene profile may not include the newer closed-profile fields."
}
if ($receipt.sourceCommit -cnotmatch '^[0-9a-f]{40}$') {
  Stop-Artifact "SourceCommitInvalid" "Receipt source commit must be a full lowercase Git object ID."
}
try {
  $runExportFull = [IO.Path]::GetFullPath([string]$runReceipt.exportDirectory)
  $runBinaryFull = [IO.Path]::GetFullPath([string]$runReceipt.emittedTestBinary)
  $runLogFull = [IO.Path]::GetFullPath([string]$runReceipt.log)
} catch {
  Stop-Artifact "NativeRunReceiptInvalid" "Run receipt contains an invalid artifact path: $($_.Exception.Message)"
}
if ($runReceipt.runId -cnotmatch '^[a-z0-9-]+$' -or
    $runReceipt.runId -cne [IO.Path]::GetFileName($runRoot) -or
    $runReceipt.sourceHeadBefore -cnotmatch '^[0-9a-f]{40}$' -or
    $runReceipt.sourceHeadAfter -cne $runReceipt.sourceHeadBefore -or
    $receipt.sourceCommit -cne $runReceipt.sourceHeadBefore -or
    -not [StringComparer]::OrdinalIgnoreCase.Equals(
      $runExportFull,
      [IO.Path]::GetFullPath((Join-Path $runRoot "export")))) {
  Stop-Artifact "NativeRunReceiptInvalid" "Run identity, base HEAD, or exported artifact directory does not match the canonical native run."
}
if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
      $runBinaryFull, $testBinaryFull) -or
    -not [StringComparer]::OrdinalIgnoreCase.Equals($runLogFull, $nativeLogPath)) {
  Stop-Artifact "NativeRunReceiptInvalid" "Run receipt test-binary or log identity does not match the converter inputs."
}
$nativeCommand = [string]$runReceipt.command
if ([string]::IsNullOrWhiteSpace($nativeCommand) -or
    -not $nativeCommand.Contains("test src\GraphCanvas.zig") -or
    -not $nativeCommand.Contains("--test-filter `"paint export: $Scene`"") -or
    $nativeCommand.IndexOf($testBinaryFull, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
  Stop-Artifact "NativeRunReceiptInvalid" "Run receipt command does not identify the approved filtered GraphCanvas paint test and emitted binary."
}
if (($runReceipt.nativeExitCode -isnot [int]) -and ($runReceipt.nativeExitCode -isnot [long])) {
  Stop-Artifact "NativeRunReceiptInvalid" "Run receipt nativeExitCode must be a JSON integer."
}
if ([long]$runReceipt.nativeExitCode -ne 0) {
  Stop-Artifact "NativeRunFailed" "The native paint test did not exit successfully."
}

$nativeLogDocument = Read-StrictUtf8Artifact $nativeLogPath "NativeRunSummaryInvalid"
if ($runReceipt.nativeArtifacts -isnot [System.Collections.IDictionary]) {
  Stop-Artifact "NativeArtifactReceiptInvalid" "Run receipt is missing native artifact hash facts."
}
if ($runReceipt.nativeArtifacts.capturedImmediatelyAfterNativeCommand -isnot [bool] -or
    -not $runReceipt.nativeArtifacts.capturedImmediatelyAfterNativeCommand) {
  Stop-Artifact "NativeArtifactReceiptInvalid" "Native artifact hashes must be recorded immediately after the native command."
}
Assert-NativeArtifactBinding $runReceipt.nativeArtifacts "testBinary" $testBinaryFull `
  (Get-Sha256File $testBinaryFull) "NativeTestBinaryHashMismatch"
Assert-NativeArtifactBinding $runReceipt.nativeArtifacts "nativeLog" $nativeLogPath `
  $nativeLogDocument.Sha256 "NativeLogHashMismatch"
Assert-NativeArtifactBinding $runReceipt.nativeArtifacts "paintReceipt" $receiptFull `
  $receiptDocument.Sha256 "NativePaintReceiptHashMismatch"
$nativeLogLines = @($nativeLogDocument.Text -split "\r?\n" | Where-Object { $_.Length -gt 0 })
$nativeResultLines = @($nativeLogLines | Where-Object { $_ -match '^\d+/\d+ ' })
$expectedNativeTest = "GraphCanvas.test.paint export: $Scene"
$nativeTestPattern = '^1/1 ' + [regex]::Escape($expectedNativeTest) + '\.\.\.'
$nativeTestLines = @($nativeLogLines | Where-Object { $_ -match $nativeTestPattern })
$nativeSummaries = @($nativeLogLines | Where-Object { $_ -match '^All \d+ tests (?:passed|failed|skipped)\.$' })
$nativeFailureMarkers = @($nativeLogLines | Where-Object { $_ -match '(?i)\b(?:FAIL|FAILED|SKIP|SKIPPED|ERROR|PANIC)\b' })
if ($nativeResultLines.Count -ne 1 -or $nativeTestLines.Count -ne 1 -or $nativeSummaries.Count -ne 1 -or
    $nativeSummaries[0] -cne "All 1 tests passed." -or
    $nativeFailureMarkers.Count -ne 0) {
  Stop-Artifact "NativeRunSummaryInvalid" "Native log must contain exactly one named 1/1 paint test, one positive pass summary, and no failure or skip marker."
}
$nativeTestLineIndex = [Array]::IndexOf($nativeLogLines, $nativeTestLines[0])
if ($nativeTestLineIndex -lt 0 -or $nativeTestLineIndex + 1 -ge $nativeLogLines.Count -or
    $nativeLogLines[$nativeTestLineIndex + 1] -cne "OK") {
  Stop-Artifact "NativeRunSummaryInvalid" "The named paint test does not have an unambiguous OK result."
}

$expectedSourceKeys = @($sourceFiles | Sort-Object -CaseSensitive)
if ($runReceipt.sourceHashesBefore -isnot [System.Collections.IDictionary] -or
    $runReceipt.sourceHashesAfter -isnot [System.Collections.IDictionary]) {
  Stop-Artifact "NativeSourceSnapshotInvalid" "Run receipt must contain before and after source hash maps."
}
$beforeKeys = @($runReceipt.sourceHashesBefore.Keys | Sort-Object -CaseSensitive)
$afterKeys = @($runReceipt.sourceHashesAfter.Keys | Sort-Object -CaseSensitive)
if (($beforeKeys -join "`n") -cne ($expectedSourceKeys -join "`n") -or
    ($afterKeys -join "`n") -cne ($expectedSourceKeys -join "`n")) {
  Stop-Artifact "NativeSourceSnapshotInvalid" "Run receipt source paths do not match the exact scene profile before and after the native test."
}
$sourceHashes = [Collections.Generic.List[object]]::new()
foreach ($relativePath in $sourceFiles) {
  $fullPath = Join-Path $repoRoot $relativePath
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf) -or (Test-HasReparseComponent $fullPath)) {
    Stop-Artifact "SourceFileMissing" "Required source/provenance file is missing or a reparse point: $relativePath"
  }
  $beforeHash = [string]$runReceipt.sourceHashesBefore[$relativePath]
  $afterHash = [string]$runReceipt.sourceHashesAfter[$relativePath]
  if ($beforeHash -cnotmatch '^[0-9a-f]{64}$' -or $afterHash -cnotmatch '^[0-9a-f]{64}$') {
    Stop-Artifact "NativeSourceSnapshotInvalid" "Run receipt source hashes must be full lowercase SHA-256 values: $relativePath"
  }
  if ($beforeHash -cne $afterHash) {
    Stop-Artifact "NativeSourceChangedDuringRun" "Source changed while the native test ran: $relativePath"
  }
  $currentHash = Get-Sha256File $fullPath
  if ($currentHash -cne $beforeHash) {
    Stop-Artifact "NativeSourceHashMismatch" "Current source bytes do not match the native run for $relativePath."
  }
  $sourceHashes.Add([ordered]@{ path = $relativePath.Replace("\", "/"); sha256 = $beforeHash })
}
if ($receipt.dimensions.width -ne 1280 -or $receipt.dimensions.height -ne 720 -or
    $receipt.dimensions.logicalWidth -ne 1280 -or $receipt.dimensions.logicalHeight -ne 720 -or
    $receipt.dpiMapping.windowExtX -ne 96 -or $receipt.dpiMapping.windowExtY -ne 96 -or
    $receipt.dpiMapping.viewportExtX -ne 96 -or $receipt.dpiMapping.viewportExtY -ne 96 -or
    $receipt.canvas.zoom -ne 1 -or $receipt.canvas.panX -ne 0 -or $receipt.canvas.panY -ne 0 -or
    $receipt.canvas.selectedIndex -ne 0 -or -not $receipt.canvas.railVisible -or
    $receipt.canvas.panelVisible -or $receipt.canvas.activityEnabled) {
  Stop-Artifact "RenderConfigurationInvalid" "Receipt does not match the fixed 1280x720 canvas configuration."
}
if ($null -ne $profile.surface -and $receipt.canvas.surface -cne $profile.surface) {
  Stop-Artifact "RenderConfigurationInvalid" "Receipt surface does not match the approved scene profile."
}
if ($receipt.dpiMapping.deviceDpiX -le 0 -or $receipt.dpiMapping.deviceDpiY -le 0) {
  Stop-Artifact "DeviceMetricsInvalid" "Receipt must contain positive device-context DPI metrics."
}
if ($receipt.model.nodes -ne $profile.nodes -or $receipt.model.edges -ne $profile.edges -or
    $receipt.model.activityHistory -ne 0 -or $receipt.model.createdAtValues -ne $profile.createdAtValues -or
    $receipt.header.title -cne "GraphCode" -or $receipt.header.context -cne $profile.headerContext -or
    $receipt.gdiPlusReady -ne $true -or $receipt.candidateArtifactCount -ne 1) {
  Stop-Artifact "PaintEvidenceInvalid" "Receipt model census, header, readiness, or artifact count is invalid."
}
if ($Scene -ne "project-paint-v1" -and $receipt.model.paintedEdges -ne $profile.paintedEdges) {
  Stop-Artifact "PaintEvidenceInvalid" "Painted edge count does not match the selected scene surface."
}
if ($receipt.header.reachabilityClaim -cne "declared fixture/test value only; not App reachability") {
  Stop-Artifact "HeaderClaimInvalid" "Header provenance must not imply App reachability."
}
if ($receipt.colorAssumption -cne "SDR RGB; unused DIB alpha is normalized to opaque in BMP transport") {
  Stop-Artifact "ColorAssumptionInvalid" "Receipt must state the SDR RGB and opaque-alpha transport assumptions."
}
if ($receipt.fontEvidenceScope -cne "Sampled card title, state, metadata, and header title font selections only; not a census of every text draw") {
  Stop-Artifact "FontEvidenceScopeInvalid" "Receipt must state the limits of its sampled font evidence."
}
$expectedExcludedSurfaces = @($profile.excludedSurfaces)
if (($receipt.excludedSurfaces -join "`n") -cne ($expectedExcludedSurfaces -join "`n")) {
  Stop-Artifact "ExcludedSurfacesInvalid" "Receipt does not preserve the approved evidence limits."
}

$fixtureFacts = [Collections.Generic.List[object]]::new()
foreach ($relativePath in $profile.fixturePaths) {
  $fixturePath = Join-Path $repoRoot $relativePath
  if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf) -or (Test-HasReparseComponent $fixturePath)) {
    Stop-Artifact "FixtureHashMismatch" "Scene fixture is missing or a reparse point: $relativePath"
  }
  $fixtureFacts.Add([ordered]@{
    path = $relativePath.Replace("\", "/")
    sha256 = Get-Sha256File $fixturePath
  })
}
$actualFixtureHash = [string]$fixtureFacts[0].sha256
if ($receipt.fixturePath -cne $fixtureFacts[0].path -or $receipt.fixtureSha256 -cne $actualFixtureHash) {
  Stop-Artifact "FixtureHashMismatch" "Receipt primary fixture identity does not match the bytes in the repository."
}
if ($Scene -eq "project-paint-v1") {
  if ($profile.fixturePaths.Count -ne 1) {
    Stop-Artifact "FixtureHashMismatch" "The legacy scene profile must bind exactly its original fixture."
  }
} else {
  if ($receipt.fixtures -isnot [System.Collections.IList] -or
      @($receipt.fixtures).Count -ne $fixtureFacts.Count) {
    Stop-Artifact "FixtureHashMismatch" "Receipt must bind every fixture in the closed scene profile."
  }
  for ($index = 0; $index -lt $fixtureFacts.Count; $index++) {
    if ($receipt.fixtures[$index].path -cne $fixtureFacts[$index].path -or
        $receipt.fixtures[$index].sha256 -cne $fixtureFacts[$index].sha256) {
      Stop-Artifact "FixtureHashMismatch" "Receipt fixture identity differs from the scene profile at index $index."
    }
  }
  $ageEvidence = $receipt.ageEvidence
  if ($ageEvidence -isnot [System.Collections.IDictionary] -or
      ($ageEvidence.observedAtEpochSeconds -isnot [int] -and $ageEvidence.observedAtEpochSeconds -isnot [long]) -or
      $ageEvidence.nodes -isnot [System.Collections.IList]) {
    Stop-Artifact "AgeEvidenceInvalid" "Scene receipts must bind an age observation time and node display list."
  }
  $expectedAgeEvidence = Get-ExpectedAgeEvidence $profile.fixturePaths ([long]$ageEvidence.observedAtEpochSeconds)
  if (@($ageEvidence.nodes).Count -ne @($expectedAgeEvidence.nodes).Count) {
    Stop-Artifact "AgeEvidenceInvalid" "Age evidence must cover every timestamped node in fixture order."
  }
  for ($index = 0; $index -lt @($expectedAgeEvidence.nodes).Count; $index++) {
    $actualAge = $ageEvidence.nodes[$index]
    $expectedAge = $expectedAgeEvidence.nodes[$index]
    if ($actualAge.id -cne $expectedAge.id -or
        $actualAge.createdAtEpochSeconds -ne $expectedAge.createdAtEpochSeconds -or
        $actualAge.display -cne $expectedAge.display) {
      Stop-Artifact "AgeEvidenceInvalid" "Age evidence differs from the fixture metadata at node index $index."
    }
  }
}

$expectedFontRoles = @(
  @{ role = "card-title"; face = "Segoe UI"; height = -15; weight = 600 },
  @{ role = "card-state"; face = "Segoe UI"; height = -10; weight = 700 },
  @{ role = "card-mono"; face = "Consolas"; height = -11; weight = 400 },
  @{ role = "header"; face = "Segoe UI"; height = -11; weight = 400 }
)
if (@($receipt.fonts).Count -ne $expectedFontRoles.Count) {
  Stop-Artifact "FontFactsInvalid" "Receipt must include all four sampled font facts."
}
for ($index = 0; $index -lt $expectedFontRoles.Count; $index++) {
  $font = $receipt.fonts[$index]
  if ($font.role -cne $expectedFontRoles[$index].role -or
      $font.logicalFace -cne $expectedFontRoles[$index].face -or
      $font.actualFace -cne $expectedFontRoles[$index].face -or
      $font.quality -cne "CLEARTYPE_QUALITY" -or
      $font.height -ne $expectedFontRoles[$index].height -or
      $font.weight -ne $expectedFontRoles[$index].weight) {
    Stop-Artifact "FontFactsInvalid" "Requested and selected font facts differ for $($expectedFontRoles[$index].role)."
  }
}

$expectedTransportNames = @($profile.transportNames)
if (@($receipt.transport).Count -ne $expectedTransportNames.Count -or
    @($receipt.renderRgbSha256).Count -ne 3 -or
    $receipt.renderRgbSha256[0] -cne $receipt.renderRgbSha256[1] -or
    $receipt.renderRgbSha256[0] -cne $receipt.renderRgbSha256[2]) {
  Stop-Artifact "RenderRepeatMismatch" "Three independent DIB renders must have identical RGB hashes."
}
$transportNames = @(Get-ChildItem -LiteralPath $transportRoot -Force | ForEach-Object { $_.Name } | Sort-Object)
$expectedNames = @($expectedTransportNames + "paint-receipt.json")
[Array]::Sort($expectedNames, [StringComparer]::Ordinal)
if (($transportNames -join "`n") -cne ($expectedNames -join "`n")) {
  Stop-Artifact "TransportContentsInvalid" "Transport must contain only the three expected BMPs and the receipt."
}

$transportFacts = [Collections.Generic.List[object]]::new()
$canonicalBitmap = $null
for ($index = 0; $index -lt $expectedTransportNames.Count; $index++) {
  $bmpPath = Join-Path $transportRoot $expectedTransportNames[$index]
  if (-not (Test-Path -LiteralPath $bmpPath -PathType Leaf)) {
    Stop-Artifact "RepeatBmpMissing" "Expected independent render transport is missing: $($expectedTransportNames[$index])"
  }
  if (Test-HasReparseComponent $bmpPath) { Stop-Artifact "ReparsePoint" "BMP transport may not be a reparse point." }
  $bmpHeader = Read-BmpHeader $bmpPath
  $bitmap = [Drawing.Bitmap]::new($bmpPath)
  try {
    if ($bitmap.Width -ne $bmpHeader.Width -or $bitmap.Height -ne $bmpHeader.Height) {
      Stop-Artifact "BmpDecodeGeometryMismatch" "Decoded BMP dimensions differ from its header."
    }
    $decodedRgbHash = Get-DecodedRgbSha256 $bitmap
    if ($decodedRgbHash -cne $receipt.transport[$index].rgbSha256 -or
        $decodedRgbHash -cne $receipt.renderRgbSha256[$index]) {
      Stop-Artifact "BmpRgbHashMismatch" "Decoded RGB pixels differ from the native paint receipt."
    }
    if ($receipt.transport[$index].name -cne $expectedTransportNames[$index]) {
      Stop-Artifact "TransportContentsInvalid" "Receipt transport names do not match the canonical files."
    }
    $bmpHash = Get-Sha256File $bmpPath
    if ($receipt.transport[$index].bmpSha256 -and $receipt.transport[$index].bmpSha256 -cne $bmpHash) {
      Stop-Artifact "BmpHashMismatch" "BMP file hash does not match the native receipt."
    }
    if ($index -eq 0) {
      if ($bmpHash -cne $receipt.transport[0].bmpSha256) {
        Stop-Artifact "BmpHashMismatch" "Canonical BMP file hash does not match the native receipt."
      }
      $canonicalBitmap = $bitmap
    } else {
      $bitmap.Dispose()
    }
    $transportFacts.Add([ordered]@{
        name = $expectedTransportNames[$index]
        bmpSha256 = $bmpHash
        decodedRgbSha256 = $decodedRgbHash
      })
  } catch {
    $bitmap.Dispose()
    if ($null -ne $canonicalBitmap) {
      $canonicalBitmap.Dispose()
      $canonicalBitmap = $null
    }
    throw
  }
}

$stagingFull = Join-Path $runRoot (".canvas-paint-staging-" + [guid]::NewGuid().ToString("N"))
$stagingDirectoryCreated = $false
$published = $false
try {
  try {
    New-Item -ItemType Directory -Path $stagingFull -ErrorAction Stop | Out-Null
    $stagingDirectoryCreated = $true
  } catch {
    Stop-Artifact "OutputWriteFailed" "Could not create a fresh staging directory: $($_.Exception.Message)"
  }
  $pngPath = Join-Path $stagingFull $profile.artifactName
  $manifestPath = Join-Path $stagingFull "paint-only-manifest.json"
  $pngFileStream = $null
  $pngStream = $null
  try {
    if ($TestPngCodecWriteFailure -and
        -not ("GraphCode.PaintArtifactTests.ThrowAfterPartialWriteStream" -as [type])) {
      Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;

namespace GraphCode.PaintArtifactTests
{
    public sealed class ThrowAfterPartialWriteStream : Stream
    {
        private readonly Stream inner;
        private long writeCallbackCount;
        private long partialBytesWritten;
        private int injectedIOExceptionObserved;
        private IOException injectedIOException;

        public ThrowAfterPartialWriteStream(Stream inner) => this.inner = inner;

        public long WriteCallbackCount => Interlocked.Read(ref writeCallbackCount);
        public long PartialBytesWritten => Interlocked.Read(ref partialBytesWritten);
        public bool InjectedIOExceptionObserved => Volatile.Read(ref injectedIOExceptionObserved) != 0;
        public IOException InjectedIOException => injectedIOException;
        public override bool CanRead => inner.CanRead;
        public override bool CanSeek => inner.CanSeek;
        public override bool CanWrite => inner.CanWrite;
        public override long Length => inner.Length;
        public override long Position { get => inner.Position; set => inner.Position = value; }

        public override void Flush() => inner.Flush();
        public override int Read(byte[] buffer, int offset, int count) => inner.Read(buffer, offset, count);
        public override long Seek(long offset, SeekOrigin origin) => inner.Seek(offset, origin);
        public override void SetLength(long value) => inner.SetLength(value);

        public override void Write(byte[] buffer, int offset, int count)
        {
            Interlocked.Increment(ref writeCallbackCount);
            if (count > 0)
            {
                int partialCount = Math.Max(1, count / 2);
                inner.Write(buffer, offset, partialCount);
                Interlocked.Add(ref partialBytesWritten, partialCount);
            }
            ThrowInjectedIOException();
        }

        public override void Write(ReadOnlySpan<byte> buffer)
        {
            Interlocked.Increment(ref writeCallbackCount);
            if (buffer.Length > 0)
            {
                int partialCount = Math.Max(1, buffer.Length / 2);
                inner.Write(buffer.Slice(0, partialCount));
                Interlocked.Add(ref partialBytesWritten, partialCount);
            }
            ThrowInjectedIOException();
        }

        public override void WriteByte(byte value)
        {
            Interlocked.Increment(ref writeCallbackCount);
            inner.WriteByte(value);
            Interlocked.Increment(ref partialBytesWritten);
            ThrowInjectedIOException();
        }

        private void ThrowInjectedIOException()
        {
            var exception = new IOException("Injected PNG staging stream write failure.");
            injectedIOException = exception;
            Volatile.Write(ref injectedIOExceptionObserved, 1);
            throw exception;
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) inner.Dispose();
            base.Dispose(disposing);
        }
    }
}
'@ -ErrorAction Stop
    }
    $pngFileStream = [IO.File]::Open($pngPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $pngStream = if ($TestPngCodecWriteFailure) {
      [GraphCode.PaintArtifactTests.ThrowAfterPartialWriteStream]::new($pngFileStream)
    } else {
      $pngFileStream
    }
    $saveException = $null
    $flushException = $null
    $saveReturnedNormally = $false
    try {
      $canonicalBitmap.Save($pngStream, [Drawing.Imaging.ImageFormat]::Png)
      $saveReturnedNormally = $true
    } catch {
      $saveException = $_.Exception
    }
    if ($saveReturnedNormally) {
      try {
        if ($TestPngCodecWriteFailure) { $pngStream.Flush() } else { $pngFileStream.Flush($true) }
      } catch {
        $flushException = $_.Exception
      }
    }
  } finally {
    if ($null -ne $pngStream) {
      $pngStream.Dispose()
    } elseif ($null -ne $pngFileStream) {
      $pngFileStream.Dispose()
    }
  }
  if ($TestPngCodecWriteFailure) {
    $writeCallbackCount = [long]$pngStream.WriteCallbackCount
    $partialBytesWritten = [long]$pngStream.PartialBytesWritten
    $injectedIOExceptionObserved = [bool]$pngStream.InjectedIOExceptionObserved
    $injectedIOException = $pngStream.InjectedIOException
    $propagatedException = if ($null -ne $saveException) { $saveException } else { $flushException }
    $evidence = [ordered]@{
      saveReturnedNormally = [bool]$saveReturnedNormally
      saveException = $saveException
      flushException = $flushException
      writeCallbackCount = $writeCallbackCount
      partialBytesWritten = $partialBytesWritten
      injectedIOExceptionObserved = $injectedIOExceptionObserved
      injectedIOException = $injectedIOException
      propagatedException = $propagatedException
    }
    $details = "Bitmap.Save returned normally=$saveReturnedNormally; write callbacks=$writeCallbackCount; " +
      "partial bytes successfully written=$partialBytesWritten; injected IOException observed=$injectedIOExceptionObserved."
    if ($null -ne $saveException) {
      $details += (" Propagated Bitmap.Save exception HRESULT=0x{0:X8}: {1}" -f
        $saveException.HResult, $saveException.ToString())
    }
    if ($null -ne $flushException) {
      $details += (" Propagated stream flush exception HRESULT=0x{0:X8}: {1}" -f
        $flushException.HResult, $flushException.ToString())
    }
    if ($null -ne $injectedIOException) {
      $details += (" Injected IOException HRESULT=0x{0:X8}: {1}" -f
        $injectedIOException.HResult, $injectedIOException.ToString())
    }
    if (-not $injectedIOExceptionObserved -or $writeCallbackCount -le 0 -or
        $partialBytesWritten -le 0 -or $null -eq $injectedIOException) {
      Stop-Artifact "CodecFaultNotObserved" `
        "The requested codec-write fault was not proven at the stream boundary. $details" `
        $propagatedException $evidence
    }
    $failureCause = $injectedIOException
    if ($null -ne $propagatedException -and
        -not [object]::ReferenceEquals($propagatedException, $injectedIOException)) {
      $failureCause = [AggregateException]::new(
        "The injected stream IOException and propagated Save/flush exception are both retained.",
        [System.Exception[]]@($injectedIOException, $propagatedException))
    } elseif ($null -ne $propagatedException) {
      $failureCause = $propagatedException
    }
    Stop-Artifact "CodecWriteFailed" $details $failureCause $evidence
  }
  if ($null -ne $saveException -or $null -ne $flushException) {
    $propagatedException = if ($null -ne $saveException) { $saveException } else { $flushException }
    $details = "Bitmap.Save returned normally=$saveReturnedNormally. PNG codec or output stream failed: " +
      $propagatedException.ToString()
    Stop-Artifact "CodecWriteFailed" $details $propagatedException ([ordered]@{
        saveReturnedNormally = [bool]$saveReturnedNormally
        saveException = $saveException
        flushException = $flushException
        propagatedException = $propagatedException
      })
  }

  $pngBitmap = [Drawing.Bitmap]::new($pngPath)
  try {
    if ($pngBitmap.Width -ne 1280 -or $pngBitmap.Height -ne 720) {
      Stop-Artifact "PngGeometryMismatch" "PNG decode changed the 1280x720 canvas dimensions."
    }
    $pngRgbHash = Get-DecodedRgbSha256 $pngBitmap
  } finally {
    $pngBitmap.Dispose()
  }
  if ($pngRgbHash -cne $receipt.renderRgbSha256[0]) {
    Stop-Artifact "PngRgbHashMismatch" "PNG decoded RGB pixels differ from the native paint render."
  }

  foreach ($sourceFact in $sourceHashes) {
    $fullPath = Join-Path $repoRoot $sourceFact.path.Replace("/", "\")
    if ((Get-Sha256File $fullPath) -cne $sourceFact.sha256) {
      Stop-Artifact "NativeSourceChangedDuringConversion" "Source bytes changed while the PNG and manifest were being prepared: $($sourceFact.path)"
    }
  }
  foreach ($nativeArtifact in @(
    @{ Path = $testBinaryFull; Hash = [string]$runReceipt.nativeArtifacts.testBinary.sha256; Code = "NativeTestBinaryChangedDuringConversion"; Name = "test binary" },
    @{ Path = $nativeLogPath; Hash = [string]$runReceipt.nativeArtifacts.nativeLog.sha256; Code = "NativeLogChangedDuringConversion"; Name = "native log" },
    @{ Path = $receiptFull; Hash = [string]$runReceipt.nativeArtifacts.paintReceipt.sha256; Code = "NativePaintReceiptChangedDuringConversion"; Name = "paint receipt" }
  )) {
    if ((Get-Sha256File $nativeArtifact.Path) -cne $nativeArtifact.Hash) {
      Stop-Artifact $nativeArtifact.Code "The $($nativeArtifact.Name) changed while the PNG and manifest were being prepared."
    }
  }

  $fontFiles = @(
    (Get-FontFileFact "seguisb.ttf"),
    (Get-FontFileFact "segoeuib.ttf"),
    (Get-FontFileFact "consola.ttf"),
    (Get-FontFileFact "segoeui.ttf")
  )
  $fontFacts = @()
  for ($index = 0; $index -lt $expectedFontRoles.Count; $index++) {
    $fontFacts += [ordered]@{
      role = $receipt.fonts[$index].role
      logicalFace = $receipt.fonts[$index].logicalFace
      actualFace = $receipt.fonts[$index].actualFace
      height = $receipt.fonts[$index].height
      weight = $receipt.fonts[$index].weight
      quality = $receipt.fonts[$index].quality
      file = $fontFiles[$index]
    }
  }
  $manifest = [ordered]@{
    schemaVersion = 1
    evidenceClass = "real paint path, offscreen component render"
    artifactCount = 1
    artifact = [ordered]@{
      name = $profile.artifactName
      width = 1280
      height = 720
      pngSha256 = Get-Sha256File $pngPath
      decodedRgbSha256 = $pngRgbHash
    }
    scene = $receipt.scene
    renderer = $receipt.renderer
    fixture = [ordered]@{
      path = $receipt.fixturePath
      sha256 = $actualFixtureHash
      sourceBaseCommit = $receipt.sourceCommit
      sourceBaseCommitRole = "Base HEAD only; sourceFiles SHA-256 values bind the selected scene profile's leased files, not a clean-tree snapshot of other imported modules or their dirty/untracked state."
    }
    sourceFiles = $sourceHashes.ToArray()
    nativeRun = [ordered]@{
      runId = $runReceipt.runId
      runReceiptPath = $runReceiptFull
      runReceiptSha256 = $runReceiptDocument.Sha256
      nativeExitCode = $runReceipt.nativeExitCode
      testName = $expectedNativeTest
      testSummary = $nativeSummaries[0]
      sourceHeadBefore = $runReceipt.sourceHeadBefore
      sourceHeadAfter = $runReceipt.sourceHeadAfter
      artifactHashes = [ordered]@{
        capturedImmediatelyAfterNativeCommand = $runReceipt.nativeArtifacts.capturedImmediatelyAfterNativeCommand
        testBinarySha256 = $runReceipt.nativeArtifacts.testBinary.sha256
        nativeLogSha256 = $runReceipt.nativeArtifacts.nativeLog.sha256
        paintReceiptSha256 = $runReceipt.nativeArtifacts.paintReceipt.sha256
        identityScope = "Hashes bind the exact artifact bytes observed after the native command to conversion inputs; they are not cryptographic execution attestation."
      }
    }
    paintReceipt = [ordered]@{
      path = $receiptFull
      sha256 = $runReceipt.nativeArtifacts.paintReceipt.sha256
    }
    testBinary = [ordered]@{
      path = $testBinaryFull
      sha256 = $runReceipt.nativeArtifacts.testBinary.sha256
      identityNote = "SHA-256 was captured immediately after the native command and verified unchanged at conversion; identity is provenance, not cryptographic execution attestation."
    }
    nativeLog = [ordered]@{
      path = $nativeLogPath
      sha256 = $runReceipt.nativeArtifacts.nativeLog.sha256
    }
    environment = [ordered]@{
      osVersion = [Environment]::OSVersion.Version.ToString()
      platform = [Environment]::OSVersion.Platform.ToString()
      zigVersion = "0.15.2"
      winghosttyPin = "6286560d0aa3103e068b2b7afa81eac373d870c9"
      pinEvidenceScope = "Expected repository pins; actual Zig executable and Winghostty checkout identity are not measured by the converter."
    }
    dimensions = $receipt.dimensions
    dpiMapping = $receipt.dpiMapping
    canvas = $receipt.canvas
    model = $receipt.model
    header = $receipt.header
    gdiPlusReady = $receipt.gdiPlusReady
    colorAssumption = $receipt.colorAssumption
    fontEvidenceScope = $receipt.fontEvidenceScope
    fonts = $fontFacts
    transport = $transportFacts.ToArray()
    renderRgbSha256 = $receipt.renderRgbSha256
    determinismScope = "Three fresh memory-DIB renders on this host/build/fixture only; not a golden or cross-machine guarantee."
    gdiPlusEvidenceScope = "GDI+ readiness is observed; this does not prove every drawing operation used GDI+ instead of the existing GDI fallback."
    fontFileEvidenceScope = "actualFace is the selected face reported by GetTextFace/LOGFONT; file entries are lookup candidates and do not identify the selected physical font file."
    excludedSurfaces = $receipt.excludedSurfaces
  }
  if ($Scene -ne "project-paint-v1") {
    $manifest["fixtureFiles"] = $fixtureFacts.ToArray()
    $manifest["canvasSurface"] = $profile.surface
    $manifest["ageEvidence"] = $receipt.ageEvidence
  }
  $json = $manifest | ConvertTo-Json -Depth 12
  $manifestBytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
  $manifestPartial = $manifestPath + ".partial"
  $manifestStream = [IO.File]::Open($manifestPartial, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try {
    $manifestStream.Write($manifestBytes, 0, $manifestBytes.Length)
    $manifestStream.Flush($true)
  } finally {
    $manifestStream.Dispose()
  }
  [IO.File]::Move($manifestPartial, $manifestPath)
  $publishedNames = @(Get-ChildItem -LiteralPath $stagingFull -Force | ForEach-Object { $_.Name } | Sort-Object)
  $expectedPublishedNames = @("paint-only-manifest.json", $profile.artifactName)
  [Array]::Sort($expectedPublishedNames, [StringComparer]::Ordinal)
  if (($publishedNames -join "`n") -cne ($expectedPublishedNames -join "`n")) {
    Stop-Artifact "PublishedContentsInvalid" "Published output must contain exactly one PNG and one manifest."
  }
  if (Test-Path -LiteralPath $outputFull) {
    Stop-Artifact "OutputNotFresh" "Output directory appeared while the verified artifact was being prepared."
  }
  try {
    [IO.Directory]::Move($stagingFull, $outputFull)
    $published = $true
  } catch {
    Stop-Artifact "OutputPublishFailed" "Could not atomically publish the verified output from $stagingFull`: $($_.Exception.Message)"
  }
  [pscustomobject]@{
    Artifact = (Join-Path $outputFull $profile.artifactName)
    Manifest = (Join-Path $outputFull "paint-only-manifest.json")
    ArtifactCount = 1
    PngSha256 = $manifest.artifact.pngSha256
    RgbSha256 = $pngRgbHash
    FixtureSha256 = $actualFixtureHash
    TestBinarySha256 = $manifest.testBinary.sha256
  }
} finally {
  if ($stagingDirectoryCreated -and -not $published) {
    Write-Warning "Failed artifact staging preserved at $stagingFull"
  }
  if ($null -ne $canonicalBitmap) { $canonicalBitmap.Dispose() }
}
