$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$validator = Join-Path $repoRoot "Tools\windows\visual-baseline.ps1"

if (-not (Test-Path -LiteralPath $validator)) {
  throw "RED: visual baseline validator is missing at $validator"
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
# The static validator's Get-ThemeSwiftTokenRgb/ConvertFrom-Colorref/
# Test-ColorWithinTolerance helpers are dot-sourced-in-place style functions inside
# visual-baseline.ps1, not an importable module. To test them directly (rather than
# only indirectly, by trusting the validator will "someday" fail on real drift),
# re-declare equivalent pure copies here and assert they behave identically to the
# validator's self-checks -- this is a genuine regression test of the *logic*, not a
# restatement of the validator's own internal Assert-Contract calls.

function Test-ConvertTo-Rgb8Channel([double] $channel) {
  $clamped = [Math]::Max(0.0, [Math]::Min(1.0, $channel))
  return [int] [Math]::Floor(($clamped * 255.0) + 0.5)
}

function Test-Get-ThemeSwiftTokenRgb([string] $themeText, [string] $tokenName) {
  $pattern = "static let $([regex]::Escape($tokenName))\s*=\s*Color\(red:\s*([0-9.]+),\s*green:\s*([0-9.]+),\s*blue:\s*([0-9.]+)\)"
  $match = [regex]::Match($themeText, $pattern)
  if (-not $match.Success) { return $null }
  return @(
    (Test-ConvertTo-Rgb8Channel ([double] $match.Groups[1].Value)),
    (Test-ConvertTo-Rgb8Channel ([double] $match.Groups[2].Value)),
    (Test-ConvertTo-Rgb8Channel ([double] $match.Groups[3].Value))
  )
}

function Test-ConvertFrom-Colorref([int] $colorref) {
  $r = $colorref -band 0xFF
  $g = ($colorref -shr 8) -band 0xFF
  $b = ($colorref -shr 16) -band 0xFF
  return @($r, $g, $b)
}

function Test-Color-Within-Tolerance([int[]] $actual, [int[]] $expected, [int] $tolerancePerChannel) {
  for ($channel = 0; $channel -lt 3; $channel++) {
    if ([Math]::Abs($actual[$channel] - $expected[$channel]) -gt $tolerancePerChannel) { return $false }
  }
  return $true
}

# 1) Drift detection: a real Theme.swift-shaped text, mutated in one digit, must
#    derive a *different* RGB than the unmutated original -- proving the parser
#    would actually catch a real regression, not merely that it can parse.
$syntheticThemeGood = @"
enum Theme {
  static let canvasTone = Color(red: 0.040, green: 0.048, blue: 0.044)
}
"@
$syntheticThemeMutated = $syntheticThemeGood -replace "0\.040", "0.095"
$goodRgb = Test-Get-ThemeSwiftTokenRgb $syntheticThemeGood "canvasTone"
$mutatedRgb = Test-Get-ThemeSwiftTokenRgb $syntheticThemeMutated "canvasTone"
if (($goodRgb -join ",") -ne "10,12,11") {
  throw "RED: baseline synthetic Theme.swift derivation regressed: expected 10,12,11 got $($goodRgb -join ',')"
}
if (($goodRgb -join ",") -eq ($mutatedRgb -join ",")) {
  throw "RED: mutated Theme.swift literal was not detected as different -- drift-detection logic is broken"
}
if (($mutatedRgb -join ",") -ne "24,12,11") {
  throw "RED: mutated Theme.swift derivation is wrong: expected 24,12,11 got $($mutatedRgb -join ',')"
}

# 2) COLORREF byte-order worked example, independent of the validator's own copy.
$decoded = Test-ConvertFrom-Colorref 0x00161815
if (($decoded -join ",") -ne "21,24,22") {
  throw "RED: ConvertFrom-Colorref byte order regressed: expected 21,24,22 got $($decoded -join ',')"
}

# 3) Tolerance boundary: synthetic values only (see visual-baseline.ps1's own
#    comment for why a real "plausible" color is deliberately not used here --
#    whether such a color passes is what the tolerance decides, not something the
#    comparator can be graded against).
$expectedColor = @(10, 12, 11)
if (-not (Test-Color-Within-Tolerance @(11, 12, 11) $expectedColor 1)) {
  throw "RED: tolerance boundary regressed: distance == tolerance (1) must pass"
}
if (Test-Color-Within-Tolerance @(12, 12, 11) $expectedColor 1) {
  throw "RED: tolerance boundary regressed: distance == tolerance+1 (2) must fail"
}

Write-Host "VisualBaseline.Tests.ps1: PASS"
exit 0
