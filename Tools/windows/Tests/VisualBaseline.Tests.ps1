$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$validator = Join-Path $repoRoot "Tools\windows\visual-baseline.ps1"
$themeContractValidator = Join-Path $repoRoot "Tools\windows\Test-CurrentThemeContract.ps1"

if (-not (Test-Path -LiteralPath $validator)) {
  throw "RED: visual baseline validator is missing at $validator"
}
if (-not (Test-Path -LiteralPath $themeContractValidator)) {
  throw "RED: currentThemeContract validator is missing at $themeContractValidator"
}

$output = & $validator
if ($LASTEXITCODE -ne 0) {
  throw "Visual baseline validation failed with exit code $LASTEXITCODE"
}
if (($output -join "`n") -notmatch "Visual baseline: PASS") {
  throw "Visual baseline validator did not report PASS"
}

# --- currentThemeContract regression coverage --------------------------------
#
# These tests invoke Tools\windows\Test-CurrentThemeContract.ps1 itself, as a real
# subprocess, against temporary fixture files -- never a re-declared copy of its
# logic. Because it is the exact production comparator, deleting or breaking the
# real drift assertion in that file would make these tests fail too, not silently
# keep passing.

function New-ThemeContractFixture {
  param(
    [Parameter(Mandatory)] [string] $ThemeSwiftText,
    [Parameter(Mandatory)] [string] $DesignTokensText,
    [Parameter(Mandatory)] [hashtable] $ManifestObject
  )
  $dir = Join-Path ([IO.Path]::GetTempPath()) "graphcode-theme-contract-$([guid]::NewGuid())"
  New-Item -ItemType Directory -Path $dir | Out-Null
  $themePath = Join-Path $dir "Theme.swift"
  $designPath = Join-Path $dir "DesignTokens.zig"
  $manifestPath = Join-Path $dir "manifest.json"
  Set-Content -LiteralPath $themePath -Value $ThemeSwiftText -NoNewline
  Set-Content -LiteralPath $designPath -Value $DesignTokensText -NoNewline
  ($ManifestObject | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $manifestPath -NoNewline
  return [pscustomobject]@{
    Dir = $dir; ThemePath = $themePath; DesignPath = $designPath; ManifestPath = $manifestPath
  }
}

function Invoke-ThemeContractValidator {
  param(
    [Parameter(Mandatory)] [string] $ManifestPath,
    [Parameter(Mandatory)] [string] $ThemeSwiftPath,
    [Parameter(Mandatory)] [string] $DesignTokensPath
  )
  $captured = & pwsh -NoProfile -File $themeContractValidator `
    -ManifestPath $ManifestPath -ThemeSwiftPath $ThemeSwiftPath -DesignTokensPath $DesignTokensPath 2>&1
  return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = ($captured | Out-String) }
}

function Assert-Fails([object] $Result, [string] $ExpectedSubstring, [string] $ScenarioName) {
  if ($Result.ExitCode -eq 0) {
    throw "RED ($ScenarioName): expected a nonzero exit code but got 0. Output: $($Result.Text)"
  }
  if ($Result.Text -notlike "*$ExpectedSubstring*") {
    throw "RED ($ScenarioName): expected diagnostic containing '$ExpectedSubstring', got: $($Result.Text)"
  }
}

function Assert-Passes([object] $Result, [string] $ScenarioName) {
  if ($Result.ExitCode -ne 0) {
    throw "RED ($ScenarioName): expected exit code 0 (restored/PASS) but got $($Result.ExitCode). Output: $($Result.Text)"
  }
  if ($Result.Text -notlike "*currentThemeContract: PASS*") {
    throw "RED ($ScenarioName): expected 'currentThemeContract: PASS', got: $($Result.Text)"
  }
}

$goodThemeSwift = @"
enum Theme {
  static let canvasTone = Color(red: 0.040, green: 0.048, blue: 0.044)
  static let canvasGridLine = Color(red: 0.082, green: 0.094, blue: 0.086)
}
"@

$goodDesignTokens = @"
pub const Color = u32;
pub const canvas_tone: Color = 0x000B0C0A;
pub const canvas_grid_line: Color = 0x00161815;
"@

function New-GoodManifestObject([string] $ThemeSwiftBlobSha256) {
  return @{
    currentThemeContract = @{
      schemaVersion         = 1
      supersedes            = "tokenContracts"
      themeSwiftBlobSha256  = $ThemeSwiftBlobSha256
      tokens                = @(
        @{ name = "Theme.canvasTone"; sourceLine = 2; rgb = @(10, 12, 11); hex = "#0A0C0B"; windowsToken = "canvas_tone" }
        @{ name = "Theme.canvasGridLine"; sourceLine = 3; rgb = @(21, 24, 22); hex = "#151816"; windowsToken = "canvas_grid_line" }
      )
    }
  }
}

# The good fixture's own approved blob hash: this is fixture setup data (what
# hash the checked-in-below Theme.swift text ought to have), not a copy of the
# validator's comparison -- the validator (Test-CurrentThemeContract.ps1) is what
# actually re-derives and checks this hash against $fixture.ThemePath below.
function Get-Sha256HexOfLfNormalizedText([string] $Text) {
  $normalized = $Text -replace "`r`n", "`n"
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha256.ComputeHash($bytes)
    return (($hash | ForEach-Object { $_.ToString("x2") }) -join "")
  } finally {
    $sha256.Dispose()
  }
}
$goodHash = Get-Sha256HexOfLfNormalizedText $goodThemeSwift

$fixture = $null
try {

# Baseline fixture with the real hash: must pass outright.
$fixture = New-ThemeContractFixture -ThemeSwiftText $goodThemeSwift -DesignTokensText $goodDesignTokens `
  -ManifestObject (New-GoodManifestObject $goodHash)
Assert-Passes (Invoke-ThemeContractValidator -ManifestPath $fixture.ManifestPath `
  -ThemeSwiftPath $fixture.ThemePath -DesignTokensPath $fixture.DesignPath) "baseline fixture"

function Test-ThemeSwiftMutation {
  param([string] $MutatedThemeSwift, [string] $ExpectedSubstring, [string] $ScenarioName)
  Set-Content -LiteralPath $fixture.ThemePath -Value $MutatedThemeSwift -NoNewline
  Assert-Fails (Invoke-ThemeContractValidator -ManifestPath $fixture.ManifestPath `
    -ThemeSwiftPath $fixture.ThemePath -DesignTokensPath $fixture.DesignPath) $ExpectedSubstring $ScenarioName
  Set-Content -LiteralPath $fixture.ThemePath -Value $goodThemeSwift -NoNewline
  Assert-Passes (Invoke-ThemeContractValidator -ManifestPath $fixture.ManifestPath `
    -ThemeSwiftPath $fixture.ThemePath -DesignTokensPath $fixture.DesignPath) "$ScenarioName (restored)"
}

function Test-DesignTokensMutation {
  param([string] $MutatedDesignTokens, [string] $ExpectedSubstring, [string] $ScenarioName)
  Set-Content -LiteralPath $fixture.DesignPath -Value $MutatedDesignTokens -NoNewline
  Assert-Fails (Invoke-ThemeContractValidator -ManifestPath $fixture.ManifestPath `
    -ThemeSwiftPath $fixture.ThemePath -DesignTokensPath $fixture.DesignPath) $ExpectedSubstring $ScenarioName
  Set-Content -LiteralPath $fixture.DesignPath -Value $goodDesignTokens -NoNewline
  Assert-Passes (Invoke-ThemeContractValidator -ManifestPath $fixture.ManifestPath `
    -ThemeSwiftPath $fixture.ThemePath -DesignTokensPath $fixture.DesignPath) "$ScenarioName (restored)"
}

function Test-ManifestMutation {
  param([hashtable] $MutatedManifestObject, [string] $ExpectedSubstring, [string] $ScenarioName)
  ($MutatedManifestObject | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $fixture.ManifestPath -NoNewline
  Assert-Fails (Invoke-ThemeContractValidator -ManifestPath $fixture.ManifestPath `
    -ThemeSwiftPath $fixture.ThemePath -DesignTokensPath $fixture.DesignPath) $ExpectedSubstring $ScenarioName
  ((New-GoodManifestObject $goodHash) | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $fixture.ManifestPath -NoNewline
  Assert-Passes (Invoke-ThemeContractValidator -ManifestPath $fixture.ManifestPath `
    -ThemeSwiftPath $fixture.ThemePath -DesignTokensPath $fixture.DesignPath) "$ScenarioName (restored)"
}

# 1) Theme.swift mutation: a changed literal must produce the specific per-token
#    drift diagnostic, not merely "something is wrong".
Test-ThemeSwiftMutation `
  ($goodThemeSwift -replace "0\.040", "0.095") `
  "currentThemeContract drift detected for Theme.canvasTone" `
  "Theme.swift literal mutated"

# 2) Manifest mutation (Theme.swift untouched): the other direction of the same
#    drift check, with its own internally-consistent (but wrong) rgb/hex so the
#    hex-consistency check does not mask it.
$manifestWithWrongGridLine = New-GoodManifestObject $goodHash
$manifestWithWrongGridLine.currentThemeContract.tokens[1].rgb = @(21, 25, 22)
$manifestWithWrongGridLine.currentThemeContract.tokens[1].hex = "#151916"
Test-ManifestMutation $manifestWithWrongGridLine `
  "currentThemeContract drift detected for Theme.canvasGridLine" `
  "manifest rgb/hex mutated away from Theme.swift"

# 2b) Recorded blob hash itself is wrong (Theme.swift and tokens both untouched
#     and correct): the whole-file provenance check must independently reject it.
$manifestWithWrongHash = New-GoodManifestObject ("0" * 64)
Test-ManifestMutation $manifestWithWrongHash "no longer matches the approved blob hash" "recorded blob hash wrong"

# 3) Empty token list must not pass vacuously.
$manifestWithNoTokens = New-GoodManifestObject $goodHash
$manifestWithNoTokens.currentThemeContract.tokens = @()
Test-ManifestMutation $manifestWithNoTokens "tokens must not be empty" "empty token list"

# 4) Missing a required token (wrong cardinality/identity).
$manifestWithOneToken = New-GoodManifestObject $goodHash
$manifestWithOneToken.currentThemeContract.tokens = @($manifestWithOneToken.currentThemeContract.tokens[0])
Test-ManifestMutation $manifestWithOneToken "must contain exactly" "required token missing"

# 5) Duplicate token identity.
$manifestWithDuplicateToken = New-GoodManifestObject $goodHash
$manifestWithDuplicateToken.currentThemeContract.tokens = @(
  $manifestWithDuplicateToken.currentThemeContract.tokens[0],
  $manifestWithDuplicateToken.currentThemeContract.tokens[0]
)
Test-ManifestMutation $manifestWithDuplicateToken "duplicate token name" "duplicate token"

# 6) RGB shape violation (wrong channel count).
$manifestWithBadShape = New-GoodManifestObject $goodHash
$manifestWithBadShape.currentThemeContract.tokens[0].rgb = @(10, 12)
Test-ManifestMutation $manifestWithBadShape "must record exactly 3 RGB channel values" "RGB wrong channel count"

# 7) RGB range violation (out of 0..255).
$manifestWithBadRange = New-GoodManifestObject $goodHash
$manifestWithBadRange.currentThemeContract.tokens[0].rgb = @(10, 12, 300)
Test-ManifestMutation $manifestWithBadRange "out-of-range RGB channel value" "RGB out of range"

# 8) A commented-out, obsolete declaration must not be silently validated: comment
#    out the only active definition and confirm it is treated as absent, not as a
#    match.
$themeSwiftWithCommentedToken = @"
enum Theme {
  // static let canvasTone = Color(red: 0.040, green: 0.048, blue: 0.044)
  static let canvasGridLine = Color(red: 0.082, green: 0.094, blue: 0.086)
}
"@
Test-ThemeSwiftMutation $themeSwiftWithCommentedToken `
  "no longer defines an active Color(red:green:blue:) literal for token: canvasTone" `
  "commented-out declaration ignored"

# 9) An opacity suffix on the literal must be rejected outright, not silently
#    validated against only the base RGB it wraps.
$themeSwiftWithOpacitySuffix = $goodThemeSwift -replace `
  "Color\(red: 0\.040, green: 0\.048, blue: 0\.044\)", `
  "Color(red: 0.040, green: 0.048, blue: 0.044).opacity(0.5)"
Test-ThemeSwiftMutation $themeSwiftWithOpacitySuffix `
  "unsupported trailing expression" `
  "opacity suffix rejected"

# 10) Windows/macOS cross-source mismatch: DesignTokens.zig's real constant must
#     independently agree with Theme.swift, not merely echo a manifest constant.
Test-DesignTokensMutation `
  ($goodDesignTokens -replace "0x00161815", "0x00161915") `
  "the Windows and macOS sources have drifted apart" `
  "DesignTokens.zig cross-check mismatch"

# 11) Whole-file blob hash catches a change a per-token regex would miss (an
#     addition that touches neither tracked literal).
$themeSwiftWithUnrelatedEdit = "// unrelated added comment`n" + $goodThemeSwift
Test-ThemeSwiftMutation $themeSwiftWithUnrelatedEdit `
  "no longer matches the approved blob hash" `
  "unrelated edit caught by blob hash"

# 12) windowsToken is mandatory: blank/missing must fail outright, not silently
#     skip the Windows/macOS cross-check.
$manifestWithBlankWindowsToken = New-GoodManifestObject $goodHash
$manifestWithBlankWindowsToken.currentThemeContract.tokens[0].windowsToken = ""
Test-ManifestMutation $manifestWithBlankWindowsToken `
  "is missing its required windowsToken mapping" `
  "windowsToken blank"

$manifestWithRemovedWindowsToken = New-GoodManifestObject $goodHash
$manifestWithRemovedWindowsToken.currentThemeContract.tokens[0].Remove("windowsToken")
Test-ManifestMutation $manifestWithRemovedWindowsToken `
  "is missing its required windowsToken mapping" `
  "windowsToken field removed"

# 13) windowsToken present but mapped to the wrong constant name must also fail
#     outright, not silently cross-check against an unrelated constant.
$manifestWithWrongWindowsTokenMap = New-GoodManifestObject $goodHash
$manifestWithWrongWindowsTokenMap.currentThemeContract.tokens[0].windowsToken = "canvas_grid_line"
Test-ManifestMutation $manifestWithWrongWindowsTokenMap `
  "has windowsToken 'canvas_grid_line' but the required mapping is" `
  "windowsToken wrong mapping"

# 14) schemaVersion must be exactly 1.
$manifestWithWrongSchemaVersion = New-GoodManifestObject $goodHash
$manifestWithWrongSchemaVersion.currentThemeContract.schemaVersion = 2
Test-ManifestMutation $manifestWithWrongSchemaVersion `
  "schemaVersion must be 1" `
  "wrong schemaVersion"

# 15) A fractional recorded RGB channel must be rejected before any [int]
#     coercion would silently round it.
$manifestWithFractionalChannel = New-GoodManifestObject $goodHash
$manifestWithFractionalChannel.currentThemeContract.tokens[0].rgb = @(10, 12, 11.5)
Test-ManifestMutation $manifestWithFractionalChannel `
  "has a fractional (non-integral) RGB channel value" `
  "fractional RGB channel"

# 16) A null recorded RGB channel must be rejected before any [int] coercion
#     would silently convert it to 0.
$manifestWithNullChannel = New-GoodManifestObject $goodHash
$manifestWithNullChannel.currentThemeContract.tokens[0].rgb = @(10, 12, $null)
Test-ManifestMutation $manifestWithNullChannel `
  "has a null RGB channel value" `
  "null RGB channel"

# 17) A declaration commented out via a Swift block comment ("/* ... */",
#     possibly spanning multiple lines) must be treated as absent, same as a
#     line-commented one -- not matched as if it were active.
$themeSwiftWithBlockCommentedToken = @"
enum Theme {
  /* static let canvasTone =
       Color(red: 0.040, green: 0.048, blue: 0.044) */
  static let canvasGridLine = Color(red: 0.082, green: 0.094, blue: 0.086)
}
"@
Test-ThemeSwiftMutation $themeSwiftWithBlockCommentedToken `
  "no longer defines an active Color(red:green:blue:) literal for token: canvasTone" `
  "block-commented-out declaration ignored"

# 18) An unterminated block comment is unsupported syntax for this minimal
#     grammar; it must fail explicitly rather than silently misparse the rest
#     of the file as active or as commented out.
$themeSwiftWithUnterminatedBlockComment = @"
enum Theme {
  /* static let canvasTone = Color(red: 0.040, green: 0.048, blue: 0.044)
  static let canvasGridLine = Color(red: 0.082, green: 0.094, blue: 0.086)
}
"@
Test-ThemeSwiftMutation $themeSwiftWithUnterminatedBlockComment `
  "unterminated or unsupported block-comment delimiter" `
  "unterminated block comment rejected"

} finally {
  if ($fixture) {
    Remove-Item -LiteralPath $fixture.Dir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# Tiny generated images below test the production PNG comparator. They are not
# app captures and require explicit comparator-test opt-in.
Add-Type -AssemblyName System.Drawing
$renderedValidator = Join-Path $repoRoot "Tools\windows\Test-RenderedVisualBaseline.ps1"
$renderedDir = Join-Path ([IO.Path]::GetTempPath()) "graphcode-rendered-test-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $renderedDir
$renderedPath = Join-Path $renderedDir "evidence.json"
$reportPath = Join-Path $renderedDir "report.json"
try {
  $sourceRecords = @(& $renderedValidator -SourceSnapshot)
  $specs = @(
    @{ id = 'canvas-sidebar'; tokens = @('canvas_tone','canvas_grid_line')
      regionIds = @('canvas-tone','canvas-grid'); rgb = @(@(10,12,11),@(21,24,22)); state = 'fixture-project-disconnected' },
    @{ id = 'dialog'; tokens = @('dialog_panel')
      regionIds = @('dialog-panel'); rgb = ,@(35,35,38); state = 'product-settings-unmodified' },
    @{ id = 'workspace'; tokens = @('tab_selected_background','pane_focus_tint')
      regionIds = @('selected-tab','pane-focus'); rgb = @(@(60,62,68),@(255,132,10)); state = 'fixture-loop-attached' }
  )
  $testImages = @()
  foreach ($spec in $specs) {
    $bitmap = [Drawing.Bitmap]::new(4, 3)
    try {
      $graphics = [Drawing.Graphics]::FromImage($bitmap)
      try { $graphics.Clear([Drawing.Color]::Black) } finally { $graphics.Dispose() }
      $regions = @()
      for ($i = 0; $i -lt $spec.tokens.Count; $i++) {
        $rgb = $spec.rgb[$i]
        $bitmap.SetPixel($i, 0, [Drawing.Color]::FromArgb($rgb[0], $rgb[1], $rgb[2]))
        $regions += @{ id = $spec.regionIds[$i]; kind = 'flat'; rect = @($i,0,1,1)
          windowsToken = $spec.tokens[$i]; source = 'explicit comparator test input' }
      }
      $bitmap.SetPixel(1, 1, [Drawing.Color]::White)
      $bitmap.SetPixel(2, 1, [Drawing.Color]::FromArgb(128,128,128))
      $regions += @{ id = 'coverage'; kind = 'coverage'; rect = @(0,1,4,1)
        backgroundRgb = @(0,0,0); foregroundRgb = @(255,255,255); source = 'explicit comparator test input' }
      $file = "$($spec.id).png"
      $imagePath = Join-Path $renderedDir $file
      $bitmap.Save($imagePath, [Drawing.Imaging.ImageFormat]::Png)
      $testImages += @{ id = $spec.id; file = $file; sha256 = (Get-FileHash $imagePath).Hash.ToLowerInvariant()
        width = 4; height = 3; dpi = 96; regions = $regions; state = $spec.state
        window = @{ pid = 123; createdAt = '2026-01-15T14:59:00Z'; hwnd = 100; screenClient = @(0,0,4,3) } }
    } finally { $bitmap.Dispose() }
  }
  $goodRendered = @{
    schemaVersion = 1; kind = 'comparator-test'; sourceCommit = ('1' * 40); sourceTree = ('2' * 40)
    capturedAt = '2026-01-15T15:00:00Z'; os = 'synthetic comparator input, not runtime'
    dpi = 96; executable = @{ sha256 = ('3' * 64); artifact = 'graphcode-windows\zig-out\bin\graphcode-windows.exe' }
    sources = $sourceRecords; process = @{ pid = 123; createdAt = '2026-01-15T14:59:00Z' }
    backend = @{ session = 'v3-deadbeef11111111-1111-4111-8111-111111111111'; clients = 1
      backendPid = 125; createdAt = '2026-01-15T14:59:01Z'; cwd = 'C:\fixture' }
    zmxPathLengths = @{ endpoint = 214; lease = 220; ownerPipe = 165 }; visibilityInterventions = @()
    providers = @{
      zmx = @{ sha256 = ('4' * 64); pin = '029e11d2b19162fb3bdf90c8270237d303b8bfb4'
        artifact = '.graphcode-tools\providers\zmx\zig-out\bin\zmx.exe' }
      winghostty = @{ sha256 = ('5' * 64); pin = 'f5abc059e4ca58b376eb209313aca7784659c679'
        artifact = '.graphcode-tools\providers\winghostty\zig-out\lib\winghostty-win32-host.lib' }
    }
    renderer = @{ uiaGate = $false; daemonSupervisorHook = $false }
    fixture = @{ name = 'App.installUiaFixture'; daemonState = 'disconnected'; zoom = 1 }
    images = $testImages
  } | ConvertTo-Json -Depth 15

  function Invoke-RenderedTest([string] $ExpectedFailure = '', [switch] $WithoutOptIn, [string] $SourceRoot = '') {
    $arguments = @('-NoProfile','-File',$renderedValidator,'-EvidencePath',$renderedPath,'-ReportPath',$reportPath)
    if (-not $WithoutOptIn) { $arguments += '-AllowTestFixture' }
    if ($SourceRoot) { $arguments += @('-SourceRoot',$SourceRoot) }
    $text = (& pwsh @arguments 2>&1 | Out-String)
    $result = [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $text }
    if ($ExpectedFailure) {
      Assert-Fails $result $ExpectedFailure "rendered $ExpectedFailure"
    } elseif ($result.ExitCode -ne 0 -or $text -notlike '*Rendered visual baseline: PASS*') {
      throw "Rendered comparator did not pass: $text"
    }
  }
  $goodRendered | Set-Content -LiteralPath $renderedPath
  Invoke-RenderedTest
  $measure = @((Get-Content $reportPath -Raw | ConvertFrom-Json).measurements | Where-Object region -eq 'coverage')[0]
  if ($measure.backgroundPixels -ne 2 -or $measure.foregroundPixels -ne 1 -or
      $measure.otherPixels -ne 1 -or $measure.distinctColors -ne 3) {
    throw "Production comparator coverage counts are incorrect"
  }
  Invoke-RenderedTest 'test fixtures require explicit opt-in' -WithoutOptIn

  & {
    $OutputDirectory = Join-Path $renderedDir 'cleanup'
    $null = New-Item -ItemType Directory -Path $OutputDirectory
    $tokens = $null; $parseErrors = $null
    $captureAst = [Management.Automation.Language.Parser]::ParseFile(
      (Join-Path $repoRoot 'Tools\windows\capture-visual-baseline.ps1'), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
    foreach ($name in @('Get-CaptureUtcTicks','Test-CaptureProcessIdentity','Stop-CaptureProcesses',
        'Get-ClientRelativeBounds','Get-ZmxCapturePaths','Get-OwnedZmxWindowRecord','ConvertFrom-CaptureZmxInfo')) {
      $definition = $captureAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
      }, $true)
      . ([scriptblock]::Create($definition.Extent.Text))
    }
    $bounds = [pscustomobject]@{ X = -1550.5; Y = 210.25; Width = 250.0; Height = 106.0 }
    $relative = @(Get-ClientRelativeBounds $bounds ([Drawing.Rectangle]::new(-1600,180,1200,800)))
    if (($relative -join ',') -ne '49.5,30.25,250,106') {
      throw "Actual capture bounds helper returned incorrect shape/coordinates: $($relative -join ',')"
    }
    $fixtureSession = '11111111-1111-4111-8111-111111111111'
    $pathProbe = Get-ZmxCapturePaths 'C:\x' 'v3-deadbeef' 'S-1-5-21-123' $fixtureSession
    $maxRoot = 'C:\x' + ('x' * (259 - $pathProbe.leaseLength))
    $boundary = Get-ZmxCapturePaths $maxRoot 'v3-deadbeef' 'S-1-5-21-123' $fixtureSession
    if ($boundary.leaseLength -ne 259) { throw 'Pinned zmx length boundary fixture is incorrect' }
    $rejected = $false
    try { $null = Get-ZmxCapturePaths ($maxRoot + 'x') 'v3-deadbeef' 'S-1-5-21-123' $fixtureSession }
    catch { $rejected = $_.Exception.Message -like '*Pinned zmx path limit*' }
    if (-not $rejected) { throw 'Capture accepted a 260-character lease path' }
    $infoText = "v3-deadbeef$fixtureSession`tclients=1`tpid=123`tcmd=`tcwd=C:\fixture`n"
    $parsedInfo = ConvertFrom-CaptureZmxInfo $infoText "v3-deadbeef$fixtureSession" 'C:\fixture'
    if ($parsedInfo.backendPid -ne 123 -or $parsedInfo.clients -ne 1) { throw 'Pinned zmx info parser lost backend/client identity' }
    $pendingInfo = ConvertFrom-CaptureZmxInfo ($infoText.Replace('clients=1','clients=0')) "v3-deadbeef$fixtureSession" 'C:\fixture'
    if ($pendingInfo.clients -ne 0) { throw 'No-client zmx readiness was silently promoted' }
    foreach ($badInfo in @($infoText.Replace('deadbeef','cafebabe'), $infoText.Replace('pid=123','pid=0'),
        $infoText.Replace('C:\fixture','C:\foreign'))) {
      $rejected = $false
      try { $null = ConvertFrom-CaptureZmxInfo $badInfo "v3-deadbeef$fixtureSession" 'C:\fixture' }
      catch { $rejected = $_.Exception.Message -like '*exact attached fixture session/backend/cwd*' }
      if (-not $rejected) { throw 'Capture accepted mismatched backend/session/cwd info' }
    }
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    foreach ($arg in @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 60')) {
      $start.ArgumentList.Add($arg)
    }
    $sleeper = [Diagnostics.Process]::Start($start)
    try {
      $record = @{ pid = $sleeper.Id; executable = $sleeper.Path; commandLine = "$($sleeper.Path) attach fixture"
        createdAt = $sleeper.StartTime.ToUniversalTime().ToString('o') }
      if (-not (Test-CaptureProcessIdentity $sleeper $record)) { throw 'String process timestamp identity failed' }
      $parsedRecord = $record | ConvertTo-Json | ConvertFrom-Json
      if (-not (Test-CaptureProcessIdentity $sleeper $parsedRecord)) { throw 'JSON process timestamp identity failed' }
      $registry = [Collections.Generic.Dictionary[int,object]]::new()
      $registry[$sleeper.Id] = $record
      if ($null -eq (Get-OwnedZmxWindowRecord $sleeper.Id $registry $sleeper.Path)) { throw 'Exact owned attach identity was not recognized' }
      if ($null -ne (Get-OwnedZmxWindowRecord 1 $registry $sleeper.Path) -or
          $null -ne (Get-OwnedZmxWindowRecord $sleeper.Id $registry 'C:\foreign.exe')) {
        throw 'Visibility policy accepted unrecorded or foreign executable identity'
      }
      $record.commandLine = "$($sleeper.Path) --daemon fixture"
      if ($null -ne (Get-OwnedZmxWindowRecord $sleeper.Id $registry $sleeper.Path)) { throw 'Visibility policy accepted a non-attach process' }
      $record.commandLine = "$($sleeper.Path) attach fixture"
      foreach ($invalidTime in @('not-a-time', '2026-01-15T14:59:00',
          [DateTime]::SpecifyKind($sleeper.StartTime, [DateTimeKind]::Unspecified))) {
        $rejected = $false
        try { $null = Get-CaptureUtcTicks $invalidTime } catch { $rejected = $true }
        if (-not $rejected) { throw 'Cleanup accepted an invalid/ambiguous process timestamp' }
      }
      $record.createdAt = $sleeper.StartTime.ToUniversalTime().AddTicks(1).ToString('o')
      if (Test-CaptureProcessIdentity $sleeper $record) { throw 'Process identity lost subsecond timestamp precision' }
      if ($null -ne (Get-OwnedZmxWindowRecord $sleeper.Id $registry $sleeper.Path)) { throw 'Visibility policy accepted reused PID identity' }
      $record.createdAt = $sleeper.StartTime.ToUniversalTime().AddSeconds(-1).ToString('o')
      $record | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'processes.json')
      Stop-CaptureProcesses
      if ($sleeper.HasExited) { throw 'Cleanup killed a process with mismatched creation time' }
      $parsedRecord | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'processes.json')
      Stop-CaptureProcesses
      if (-not $sleeper.HasExited) { throw 'Cleanup left its matching owned process alive' }
    } finally {
      if (-not $sleeper.HasExited) {
        Stop-Process -Id $sleeper.Id -Force
        $null = $sleeper.WaitForExit(5000)
      }
      $sleeper.Dispose()
    }
  }

  $copiedSourceRoot = Join-Path $renderedDir 'source'
  foreach ($relative in @($sourceRecords.path) + @('investigation\visual-baseline\manifest.json')) {
    $destination = Join-Path $copiedSourceRoot $relative
    $null = New-Item -ItemType Directory -Path (Split-Path $destination) -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot $relative) -Destination $destination
  }
  foreach ($newline in @("`n","`r`n")) {
    foreach ($record in $sourceRecords) {
      $path = Join-Path $copiedSourceRoot $record.path
      $text = [IO.File]::ReadAllText($path).Replace("`r`n","`n").Replace("`n",$newline)
      [IO.File]::WriteAllText($path,$text)
    }
    Invoke-RenderedTest -SourceRoot $copiedSourceRoot
  }
  $driftPath = Join-Path $copiedSourceRoot 'graphcode-windows\src\AppFont.zig'
  [IO.File]::AppendAllText($driftPath,"`n// actual content drift in copied source fixture`n")
  Invoke-RenderedTest 'source hash mismatch: graphcode-windows\src\AppFont.zig' -SourceRoot $copiedSourceRoot

  foreach ($case in @(
    @{ name = 'one-channel delta=1'; rgb = @(11,12,11) },
    @{ name = 'neutral gray'; rgb = @(12,12,12) },
    @{ name = 'BGR swap'; rgb = @(11,12,10) }
  )) {
    $imagePath = Join-Path $renderedDir 'canvas-sidebar.png'
    $original = [IO.File]::ReadAllBytes($imagePath)
    $bitmap = [Drawing.Bitmap]::new($imagePath)
    try {
      $bitmap.SetPixel(0,0,[Drawing.Color]::FromArgb($case.rgb[0],$case.rgb[1],$case.rgb[2]))
      $mutationPath = Join-Path $renderedDir 'mutation.png'
      $bitmap.Save($mutationPath,[Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }
    Move-Item -LiteralPath $mutationPath -Destination $imagePath -Force
    $mutated = $goodRendered | ConvertFrom-Json -AsHashtable
    $mutated.images[0].sha256 = (Get-FileHash $imagePath).Hash.ToLowerInvariant()
    $mutated | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $renderedPath
    Invoke-RenderedTest 'RGB mismatch canvas-sidebar/canvas-tone (0,0)'
    [IO.File]::WriteAllBytes($imagePath,$original)
    $goodRendered | Set-Content -LiteralPath $renderedPath
    Invoke-RenderedTest
    Write-Host "Rendered boundary: $($case.name) rejected; unchanged delta=0 accepted"
  }

  foreach ($case in @(
    @{ diagnostic = 'regions must not be empty'; edit = { param($m) $m.images[0].regions = @() } },
    @{ diagnostic = 'required flat region/mapping missing'; edit = { param($m) $m.images[0].regions[0].id = 'wrong' } },
    @{ diagnostic = 'missing or duplicate region identity'; edit = { param($m) $m.images[0].regions += $m.images[0].regions[2] } },
    @{ diagnostic = 'region is out of bounds'; edit = { param($m) $m.images[0].regions[0].rect = @(3,0,2,1) } },
    @{ diagnostic = 'region width must be an integer'; edit = { param($m) $m.images[0].regions[0].rect[2] = 0 } },
    @{ diagnostic = 'image dimensions mismatch'; edit = { param($m) $m.images[0].width = 5; $m.images[0].window.screenClient[2] = 5 } },
    @{ diagnostic = 'image hash mismatch'; edit = { param($m) $m.images[0].sha256 = ('0' * 64) } },
    @{ diagnostic = 'source provenance cardinality/identity'; edit = { param($m) $m.sources = @() } },
    @{ diagnostic = 'source hash mismatch'; edit = { param($m) $m.sources[0].lfSha256 = ('0' * 64) } },
    @{ diagnostic = 'incompatible image DPI'; edit = { param($m) $m.images[0].dpi = 120 } },
    @{ diagnostic = 'incompatible fixture state'; edit = { param($m) $m.fixture.zoom = 2 } },
    @{ diagnostic = 'production renderer requires both automation hooks disabled'; edit = { param($m) $m.renderer.uiaGate = $true } },
    @{ diagnostic = 'image window provenance is missing'; edit = { param($m) $m.images[0].Remove('window') } },
    @{ diagnostic = 'image surface state mismatch'; edit = { param($m) $m.images[0].Remove('state') } },
    @{ diagnostic = 'image surface state mismatch'; edit = { param($m) $m.images[0].state = 'wrong-surface' } },
    @{ diagnostic = 'image does not identify the recorded owned process'; edit = { param($m) $m.images[0].window.pid = 456 } },
    @{ diagnostic = 'image HWND must be an integer'; edit = { param($m) $m.images[0].window.hwnd = 0 } },
    @{ diagnostic = 'creation time is invalid'; edit = { param($m) $m.images[0].window.createdAt = 'invalid' } },
    @{ diagnostic = 'creation time is invalid'; edit = { param($m) $m.images[0].window.createdAt = '2026-01-15T14:59:00' } },
    @{ diagnostic = 'provider provenance is missing'; edit = { param($m) $m.Remove('providers') } },
    @{ diagnostic = 'zmx provider provenance is missing'; edit = { param($m) $m.providers.Remove('zmx') } },
    @{ diagnostic = 'zmx provider hash is missing'; edit = { param($m) $m.providers.zmx.Remove('sha256') } },
    @{ diagnostic = 'winghostty provider must be a SHA-256'; edit = { param($m) $m.providers.winghostty.sha256 = 'invalid' } },
    @{ diagnostic = 'zmx provider pin mismatch'; edit = { param($m) $m.providers.zmx.pin = ('0' * 40) } },
    @{ diagnostic = 'workspace backend provenance is missing'; edit = { param($m) $m.Remove('backend') } },
    @{ diagnostic = 'attached backend client count must be an integer'; edit = { param($m) $m.backend.clients = 0 } },
    @{ diagnostic = 'workspace backend session/cwd identity mismatch'; edit = { param($m) $m.backend.session = 'foreign' } },
    @{ diagnostic = 'zmx lease path length must be an integer'; edit = { param($m) $m.zmxPathLengths.lease = 260 } },
    @{ diagnostic = 'window intervention provenance is missing'; edit = { param($m) $m.Remove('visibilityInterventions') } }
  )) {
    $mutated = $goodRendered | ConvertFrom-Json -AsHashtable
    & $case.edit $mutated
    $mutated | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $renderedPath
    Invoke-RenderedTest $case.diagnostic
  }
} finally {
  Remove-Item -LiteralPath $renderedDir -Recurse -Force
}

Write-Host "VisualBaseline.Tests.ps1: PASS"
exit 0
