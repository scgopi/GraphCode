[CmdletBinding(DefaultParameterSetName = 'Compare')]
param(
  [Parameter(Mandatory, ParameterSetName = 'Compare')] [string] $EvidencePath,
  [string] $ReportPath,
  [string] $SourceRoot = (Join-Path $PSScriptRoot "..\.."),
  [switch] $AllowTestFixture,
  [Parameter(Mandatory, ParameterSetName = 'Sources')] [switch] $SourceSnapshot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$repoRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$requiredSources = @(
  "graphcode\Sources\Features\App\Theme.swift",
  "graphcode-windows\src\App.zig",
  "graphcode-windows\src\AppFont.zig",
  "graphcode-windows\src\GdiplusAA.zig",
  "graphcode-windows\src\GdiGradient.zig",
  "graphcode-windows\src\DesignTokens.zig",
  "graphcode-windows\src\GraphCanvas.zig",
  "graphcode-windows\src\Sidebar.zig",
  "graphcode-windows\src\TerminalSurface.zig",
  "graphcode-windows\src\WindowsProductSettings.zig",
  "graphcode-windows\provider-pins.json",
  "Tools\windows\capture-visual-baseline.ps1",
  "Tools\windows\Test-RenderedVisualBaseline.ps1"
)
Add-Type -AssemblyName System.Drawing

function Require-Rendered([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw "Rendered visual baseline: $Message" }
}

function Require-Integer($Value, [long] $Minimum, [long] $Maximum, [string] $Label) {
  Require-Rendered ($null -ne $Value -and $Value -isnot [string] -and $Value -isnot [bool] -and
    [double]$Value -eq [Math]::Truncate([double]$Value) -and
    [double]$Value -ge $Minimum -and [double]$Value -le $Maximum) "$Label must be an integer in $Minimum..$Maximum"
}

function Require-Hash([string] $Hash, [string] $Label) {
  Require-Rendered ($Hash -cmatch '^[0-9a-f]{64}$') "$Label must be a SHA-256"
}

function Resolve-EvidenceFile([string] $RelativePath) {
  Require-Rendered (-not [string]::IsNullOrWhiteSpace($RelativePath) -and
    -not [IO.Path]::IsPathRooted($RelativePath)) "image path must be relative"
  $path = [IO.Path]::GetFullPath((Join-Path $evidenceRoot $RelativePath))
  Require-Rendered ($path.StartsWith($evidenceRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase)) "image path escapes evidence directory"
  Require-Rendered (Test-Path -LiteralPath $path -PathType Leaf) "image is missing: $RelativePath"
  return $path
}

function Get-RgbKey([System.Drawing.Color] $Color) {
  return "$($Color.R),$($Color.G),$($Color.B)"
}

function Read-Rgb($Values, [string] $Label) {
  Require-Rendered (@($Values).Count -eq 3) "$Label requires three RGB channels"
  foreach ($value in $Values) { Require-Integer $value 0 255 "$Label channel" }
  return ($Values -join ',')
}

function Require-ProcessRecord($Record, [string] $Label) {
  Require-Rendered ($null -ne $Record) "$Label process provenance is missing"
  Require-Rendered ($null -ne $Record.PSObject.Properties['pid'] -and
    $null -ne $Record.PSObject.Properties['createdAt']) "$Label PID/creation provenance is missing"
  Require-Integer $Record.pid 1 ([int]::MaxValue) "$Label PID"
  $stamp = if ($Record.createdAt -is [DateTime]) {
    Require-Rendered ($Record.createdAt.Kind -ne [DateTimeKind]::Unspecified) "$Label creation time is invalid: missing timezone"
    $Record.createdAt.ToUniversalTime().ToString('o')
  } else { [string]$Record.createdAt }
  $date = [DateTimeOffset]::MinValue
  Require-Rendered ($stamp -match '^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$' -and
    [DateTimeOffset]::TryParse($stamp, [ref]$date)) "$Label creation time is invalid"
}

$designPath = Join-Path $repoRoot "graphcode-windows\src\DesignTokens.zig"
$null = . (Join-Path $PSScriptRoot "Test-CurrentThemeContract.ps1") `
  -ManifestPath (Join-Path $repoRoot "investigation\visual-baseline\manifest.json") `
  -ThemeSwiftPath (Join-Path $repoRoot "graphcode\Sources\Features\App\Theme.swift") `
  -DesignTokensPath $designPath
$snapshot = @(foreach ($path in $requiredSources) {
  $absolute = Join-Path $repoRoot $path
  [ordered]@{
    path = $path
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $absolute).Hash.ToLowerInvariant()
    lfSha256 = Get-NormalizedTextSha256 (Get-Content -LiteralPath $absolute -Raw)
  }
})
if ($SourceSnapshot) { return $snapshot }
$evidenceRoot = Split-Path (Resolve-Path -LiteralPath $EvidencePath).Path
$evidence = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json

Require-Rendered ($evidence.schemaVersion -eq 1) "unsupported schemaVersion"
$testFixture = $evidence.kind -eq "comparator-test"
Require-Rendered (($testFixture -and $AllowTestFixture) -or
  $evidence.kind -eq "windows-production-renderer-fixture") "unsupported evidence kind (test fixtures require explicit opt-in)"
Require-Rendered ($evidence.sourceCommit -cmatch '^[0-9a-f]{40}$' -and
  $evidence.sourceTree -cmatch '^[0-9a-f]{40}$') "source commit/tree provenance is missing"
Require-Integer $evidence.dpi 1 768 "capture DPI"
Require-Rendered ($evidence.renderer.uiaGate -ceq $false -and
  $evidence.renderer.daemonSupervisorHook -ceq $false) "production renderer requires both automation hooks disabled"
Require-Rendered ($evidence.fixture.name -eq "App.installUiaFixture" -and
  $evidence.fixture.daemonState -eq "disconnected" -and
  $evidence.fixture.zoom -eq 1) "incompatible fixture state"
Require-Hash $evidence.executable.sha256 "executable provenance"
Require-Rendered (-not [string]::IsNullOrWhiteSpace($evidence.capturedAt) -and
  -not [string]::IsNullOrWhiteSpace($evidence.os)) "capture time/OS provenance is missing"
Require-Rendered ($null -ne $evidence.PSObject.Properties['process']) "owned process provenance is missing"
Require-ProcessRecord $evidence.process "owned shell"
Require-Rendered ($null -ne $evidence.PSObject.Properties['providers']) "provider provenance is missing"
$pins = Get-Content -LiteralPath (Join-Path $repoRoot 'graphcode-windows\provider-pins.json') -Raw | ConvertFrom-Json
foreach ($name in @('zmx','winghostty')) {
  Require-Rendered ($null -ne $evidence.providers.PSObject.Properties[$name]) "$name provider provenance is missing"
  $provider = $evidence.providers.$name
  Require-Rendered ($null -ne $provider.PSObject.Properties['sha256']) "$name provider hash is missing"
  Require-Rendered ($null -ne $provider.PSObject.Properties['pin'] -and
    $null -ne $provider.PSObject.Properties['artifact']) "$name provider pin/artifact provenance is missing"
  Require-Hash $provider.sha256 "$name provider"
  Require-Rendered ($provider.pin -ceq $pins.$name.sha) "$name provider pin mismatch"
  $expectedArtifact = ".graphcode-tools\providers\$name\" + $pins.$name.artifact.Replace('/','\')
  Require-Rendered ($provider.artifact -ceq $expectedArtifact) "$name provider artifact identity mismatch"
}
Require-Rendered ($evidence.executable.artifact -ceq 'graphcode-windows\zig-out\bin\graphcode-windows.exe') `
  "shell executable artifact identity mismatch"
Require-Rendered ($null -ne $evidence.PSObject.Properties['backend']) "workspace backend provenance is missing"
Require-Integer $evidence.backend.clients 1 ([int]::MaxValue) "attached backend client count"
Require-ProcessRecord ([pscustomobject]@{ pid = $evidence.backend.backendPid; createdAt = $evidence.backend.createdAt }) "workspace backend"
Require-Rendered ($evidence.backend.session -cmatch '^v3-[0-9a-f]{8}11111111-1111-4111-8111-111111111111$' -and
  [IO.Path]::IsPathFullyQualified($evidence.backend.cwd)) "workspace backend session/cwd identity mismatch"
Require-Rendered ($null -ne $evidence.PSObject.Properties['zmxPathLengths']) "zmx path-length preflight is missing"
Require-Integer $evidence.zmxPathLengths.endpoint 1 253 "zmx endpoint path length"
Require-Integer $evidence.zmxPathLengths.lease 1 259 "zmx lease path length"
Require-Integer $evidence.zmxPathLengths.ownerPipe 1 255 "zmx owner pipe length"
Require-Rendered ($evidence.zmxPathLengths.lease -eq $evidence.zmxPathLengths.endpoint + 6) "zmx lease/endpoint lengths disagree"
Require-Rendered ($null -ne $evidence.PSObject.Properties['visibilityInterventions']) "window intervention provenance is missing"

$sourceNames = @($evidence.sources | ForEach-Object { $_.path })
Require-Rendered (@($sourceNames | Sort-Object -Unique).Count -eq $requiredSources.Count -and
  $sourceNames.Count -eq $requiredSources.Count) "source provenance cardinality/identity is incomplete"
foreach ($path in $requiredSources) {
  $source = @($evidence.sources | Where-Object path -eq $path)
  Require-Rendered ($source.Count -eq 1) "source provenance is missing: $path"
  Require-Hash $source[0].sha256 "source $path"
  Require-Hash $source[0].lfSha256 "LF-normalized source $path"
  $actual = @($snapshot | Where-Object path -eq $path)[0]
  Require-Rendered ($actual.lfSha256 -ceq $source[0].lfSha256) "source hash mismatch: $path"
}

$designText = Get-Content -LiteralPath $designPath -Raw

$images = @($evidence.images)
Require-Rendered ($images.Count -eq 3 -and
  ((@($images.id | Sort-Object) -join ',') -eq 'canvas-sidebar,dialog,workspace')) "exactly canvas-sidebar, dialog and workspace images are required"
$requiredFlatRegions = @{
  'canvas-sidebar' = @{ 'canvas-tone' = 'canvas_tone'; 'canvas-grid' = 'canvas_grid_line' }
  dialog = @{ 'dialog-panel' = 'dialog_panel' }
  workspace = @{ 'selected-tab' = 'tab_selected_background'; 'pane-focus' = 'pane_focus_tint' }
}
$surfaceStates = @{
  'canvas-sidebar' = 'fixture-project-disconnected'
  dialog = 'product-settings-unmodified'
  workspace = 'fixture-loop-attached'
}
$measurements = [Collections.Generic.List[object]]::new()
foreach ($image in $images) {
  Require-Rendered ($null -ne $image.PSObject.Properties['window']) "image window provenance is missing: $($image.id)"
  Require-Rendered ($null -ne $image.PSObject.Properties['state'] -and
    $image.state -ceq $surfaceStates[$image.id]) "image surface state mismatch: $($image.id)"
  Require-ProcessRecord $image.window "image $($image.id)"
  Require-Integer $image.window.hwnd 1 ([long]::MaxValue) "image HWND"
  Require-Rendered ($image.window.pid -eq $evidence.process.pid -and
    $image.window.createdAt -ceq $evidence.process.createdAt) "image does not identify the recorded owned process"
  Require-Integer $image.width 1 16384 "image width"
  Require-Integer $image.height 1 16384 "image height"
  $screenClient = @($image.window.screenClient)
  Require-Rendered ($screenClient.Count -eq 4) "image client geometry is missing"
  Require-Integer $screenClient[0] ([int]::MinValue) ([int]::MaxValue) "client left"
  Require-Integer $screenClient[1] ([int]::MinValue) ([int]::MaxValue) "client top"
  Require-Rendered ($screenClient[2] -eq $image.width -and $screenClient[3] -eq $image.height) `
    "image client geometry does not match dimensions"
  Require-Rendered ($image.dpi -eq $evidence.dpi) "incompatible image DPI: $($image.id)"
  Require-Hash $image.sha256 "image $($image.id)"
  $path = Resolve-EvidenceFile $image.file
  Require-Rendered ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() -ceq
    $image.sha256) "image hash mismatch: $($image.id)"
  $bitmap = [Drawing.Bitmap]::new($path)
  try {
    Require-Rendered ($bitmap.RawFormat.Guid -eq [Drawing.Imaging.ImageFormat]::Png.Guid) "image must be a lossless PNG"
    Require-Rendered ($bitmap.Width -eq $image.width -and $bitmap.Height -eq $image.height) "image dimensions mismatch: $($image.id)"
    $regions = @($image.regions)
    Require-Rendered ($regions.Count -gt 0) "regions must not be empty: $($image.id)"
    foreach ($entry in $requiredFlatRegions[$image.id].GetEnumerator()) {
      $required = @($regions | Where-Object id -eq $entry.Key)
      Require-Rendered ($required.Count -eq 1 -and $required[0].kind -eq 'flat' -and
        $required[0].windowsToken -eq $entry.Value) "required flat region/mapping missing: $($entry.Key)"
    }
    Require-Rendered (@($regions | Where-Object kind -in @('coverage', 'gradient')).Count -gt 0) `
      "image lacks a coverage/gradient observation: $($image.id)"
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($region in $regions) {
      Require-Rendered (-not [string]::IsNullOrWhiteSpace($region.id) -and $ids.Add($region.id)) "missing or duplicate region identity"
      Require-Rendered (-not [string]::IsNullOrWhiteSpace($region.source)) "region source mapping is missing: $($region.id)"
      $rect = @($region.rect)
      Require-Rendered ($rect.Count -eq 4) "region requires x,y,width,height"
      Require-Integer $rect[0] 0 ($bitmap.Width - 1) "region x"
      Require-Integer $rect[1] 0 ($bitmap.Height - 1) "region y"
      Require-Integer $rect[2] 1 $bitmap.Width "region width"
      Require-Integer $rect[3] 1 $bitmap.Height "region height"
      Require-Rendered ($rect[0] + $rect[2] -le $bitmap.Width -and
        $rect[1] + $rect[3] -le $bitmap.Height) "region is out of bounds: $($region.id)"
      Require-Rendered ($region.kind -in @('flat', 'coverage', 'gradient')) "unsupported region kind"
      $expected = $null
      if ($region.kind -eq 'flat') {
        $expected = (ConvertFrom-Colorref (Get-DesignTokenColorref $designText $region.windowsToken)) -join ','
      }
      if ($region.kind -eq 'coverage') {
        $background = Read-Rgb $region.backgroundRgb "background"
        $foreground = Read-Rgb $region.foregroundRgb "foreground"
        Require-Rendered ($foreground -ne $background) "coverage endpoints must differ"
      }
      $histogram = @{}
      $rows = [Collections.Generic.List[object]]::new()
      for ($y = [int]$rect[1]; $y -lt $rect[1] + $rect[3]; $y++) {
        $sum = @(0L, 0L, 0L)
        for ($x = [int]$rect[0]; $x -lt $rect[0] + $rect[2]; $x++) {
          $pixel = $bitmap.GetPixel($x, $y)
          Require-Rendered ($pixel.A -eq 255) "nonopaque sample: $($region.id) ($x,$y)"
          $key = Get-RgbKey $pixel
          if (-not $histogram.ContainsKey($key)) { $histogram[$key] = 0 }
          $histogram[$key]++
          if ($null -ne $expected -and $key -cne $expected) {
            throw "Rendered visual baseline: RGB mismatch $($image.id)/$($region.id) ($x,$y): expected $expected, actual $key; allowed channel delta=0"
          }
          $sum[0] += $pixel.R; $sum[1] += $pixel.G; $sum[2] += $pixel.B
        }
        if ($region.kind -eq 'gradient') {
          $rows.Add([ordered]@{ y = $y; meanRgb = @($sum | ForEach-Object { $_ / $rect[2] }) })
        }
      }
      $measurement = [ordered]@{
        image = $image.id; region = $region.id; kind = $region.kind; rect = $rect
        source = $region.source; pixels = $rect[2] * $rect[3]; distinctColors = $histogram.Count
        histogram = $histogram
      }
      if ($region.kind -eq 'coverage') {
        $backgroundCount = if ($histogram.ContainsKey($background)) { $histogram[$background] } else { 0 }
        $foregroundCount = if ($histogram.ContainsKey($foreground)) { $histogram[$foreground] } else { 0 }
        $measurement.backgroundPixels = $backgroundCount
        $measurement.foregroundPixels = $foregroundCount
        # Other colors can include decorations or subpixel fringes, not just AA.
        $measurement.otherPixels = $measurement.pixels - $backgroundCount - $foregroundCount
        $measurement.interpretation = "Observation only; other colors are not a visual-quality pass threshold."
      }
      if ($region.kind -eq 'gradient') { $measurement.rows = @($rows) }
      $measurements.Add($measurement)
    }
  } finally { $bitmap.Dispose() }
}
$report = [ordered]@{
  schemaVersion = 1
  kind = $evidence.kind
  result = "opaque-pixel-contracts-pass"
  matchedCurrentMacOS = "blocked: no compatible current capture"
  visualParity = "Partial"
  normalUserFocus = "Not validated; capture may temporarily hide an identity-proven owned attach window."
  measurements = @($measurements)
}
if ($ReportPath) { $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReportPath -Encoding utf8 }
Write-Output "Rendered visual baseline: PASS (opaque pixel contracts; font/edge/gradient observations, not macOS parity)"
