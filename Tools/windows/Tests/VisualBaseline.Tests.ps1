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

Remove-Item -LiteralPath $fixture.Dir -Recurse -Force

Write-Host "VisualBaseline.Tests.ps1: PASS"
exit 0
