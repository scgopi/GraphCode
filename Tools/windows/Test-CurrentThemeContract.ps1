# Static source-drift check for investigation/visual-baseline/manifest.json's
# currentThemeContract section. Re-derives color tokens from the actual
# Theme.swift/DesignTokens.zig text on disk and asserts an exact (zero-tolerance)
# match. This file is dot-sourced by visual-baseline.ps1 for the real static run,
# and invoked directly (as its own pwsh process) by
# Tools\windows\Tests\VisualBaseline.Tests.ps1 against fixture files, so tests
# exercise this exact production code -- never a re-declared copy.
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $ManifestPath,
  [Parameter(Mandatory)] [string] $ThemeSwiftPath,
  [Parameter(Mandatory)] [string] $DesignTokensPath
)

$ErrorActionPreference = "Stop"

# The two tokens this contract currently tracks. Exact identity/cardinality is
# enforced below so an empty or partial token list cannot pass vacuously.
$script:RequiredThemeContractTokenNames = @("Theme.canvasTone", "Theme.canvasGridLine")

# Each required token must map to exactly this Windows constant name; the
# cross-check below is mandatory, not opt-in via a field that could be left
# blank or removed to silently disable it.
$script:RequiredWindowsTokenByThemeToken = @{
  "Theme.canvasTone"     = "canvas_tone"
  "Theme.canvasGridLine" = "canvas_grid_line"
}

function ConvertTo-Rgb8Channel([double] $Channel) {
  # Round-half-up: floor(x*255 + 0.5), clamped to [0,255].
  $clamped = [Math]::Max(0.0, [Math]::Min(1.0, $Channel))
  return [int] [Math]::Floor(($clamped * 255.0) + 0.5)
}

function Remove-LineComments([string] $Text, [string] $CommentToken) {
  # Strips "// ..." (or the given token) from each line so a commented-out,
  # obsolete declaration is never matched as if it were active.
  return (($Text -split "`r?`n" | ForEach-Object {
    $idx = $_.IndexOf($CommentToken)
    if ($idx -ge 0) { $_.Substring(0, $idx) } else { $_ }
  }) -join "`n")
}

function Remove-SwiftComments([string] $Text) {
  # Strips "// ..." per line first, then "/* ... */" blocks (which may span
  # multiple lines) so a declaration commented out either way is treated as
  # absent, never matched as active. This is a minimal, explicit grammar, not
  # a general Swift parser: if a "/*" or "*/" marker survives both passes
  # (e.g. an unterminated block comment), fail explicitly rather than risk
  # silently validating or silently ignoring a declaration.
  $lineStripped = Remove-LineComments $Text "//"
  $blockStripped = [regex]::Replace($lineStripped, "(?s)/\*.*?\*/", "")
  if ($blockStripped -match "/\*" -or $blockStripped -match "\*/") {
    throw "Theme.swift contains an unterminated or unsupported block-comment delimiter ('/*' or '*/') that this checker's minimal comment grammar cannot safely parse"
  }
  return $blockStripped
}

function Get-ThemeSwiftTokenRgb([string] $ThemeText, [string] $TokenName) {
  $active = Remove-SwiftComments $ThemeText
  $pattern = "static let $([regex]::Escape($TokenName))\s*=\s*Color\(red:\s*([0-9.]+),\s*green:\s*([0-9.]+),\s*blue:\s*([0-9.]+)\)([^\n]*)"
  $found = [regex]::Matches($active, $pattern)
  if ($found.Count -eq 0) {
    throw "Theme.swift no longer defines an active Color(red:green:blue:) literal for token: $TokenName"
  }
  if ($found.Count -gt 1) {
    throw "Theme.swift defines $($found.Count) active Color(red:green:blue:) literals for token: $TokenName (ambiguous)"
  }
  $match = $found[0]
  $trailing = $match.Groups[4].Value.Trim()
  if ($trailing.Length -gt 0) {
    # e.g. a trailing ".opacity(0.5)" would silently change the effective color;
    # this contract only supports a bare opaque literal, so reject instead of
    # ignoring the suffix.
    throw "Theme.swift token $TokenName has an unsupported trailing expression after its Color(...) literal: '$trailing' -- only a bare opaque Color(red:green:blue:) literal is supported"
  }
  return @(
    (ConvertTo-Rgb8Channel ([double] $match.Groups[1].Value)),
    (ConvertTo-Rgb8Channel ([double] $match.Groups[2].Value)),
    (ConvertTo-Rgb8Channel ([double] $match.Groups[3].Value))
  )
}

function Get-DesignTokenColorref([string] $DesignTokensText, [string] $TokenName) {
  $active = Remove-LineComments $DesignTokensText "//"
  $pattern = "pub const $([regex]::Escape($TokenName)):\s*Color\s*=\s*(0x[0-9A-Fa-f]+)\s*;"
  $found = [regex]::Matches($active, $pattern)
  if ($found.Count -eq 0) {
    throw "DesignTokens.zig no longer defines an active Color constant: $TokenName"
  }
  if ($found.Count -gt 1) {
    throw "DesignTokens.zig defines $($found.Count) active Color constants for: $TokenName (ambiguous)"
  }
  return [Convert]::ToInt32($found[0].Groups[1].Value, 16)
}

function ConvertTo-IntegralRgbChannel([object] $Value, [string] $TokenName, [int] $ChannelIndex) {
  # Reject before any [int] coercion would silently round a fraction or parse
  # a string: a recorded channel must already be a whole number.
  if ($null -eq $Value) {
    throw "currentThemeContract token $TokenName has a null RGB channel value at index $ChannelIndex"
  }
  if ($Value -is [string] -or $Value -is [bool]) {
    throw "currentThemeContract token $TokenName has a non-numeric RGB channel value at index $ChannelIndex`: '$Value'"
  }
  $asDouble = [double] $Value
  if ($asDouble -ne [Math]::Truncate($asDouble)) {
    throw "currentThemeContract token $TokenName has a fractional (non-integral) RGB channel value at index $ChannelIndex`: $Value"
  }
  return [int] $asDouble
}

function ConvertFrom-Colorref([int] $Colorref) {
  # Win32 COLORREF packs 0x00BBGGRR, the reverse of what a hex literal like this
  # superficially resembles.
  $r = $Colorref -band 0xFF
  $g = ($Colorref -shr 8) -band 0xFF
  $b = ($Colorref -shr 16) -band 0xFF
  return @($r, $g, $b)
}

function Get-NormalizedTextSha256([string] $Text) {
  # CRLF-normalized to LF before hashing, so this does not depend on the
  # checkout's line-ending config (core.autocrlf) or on any historical git object.
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

function Test-CurrentThemeContract {
  param(
    [Parameter(Mandatory)] [object] $Manifest,
    [Parameter(Mandatory)] [string] $ThemeSwiftText,
    [Parameter(Mandatory)] [string] $DesignTokensText,
    [string] $ThemeSwiftPathForDiagnostics = "Theme.swift",
    [string] $DesignTokensPathForDiagnostics = "DesignTokens.zig"
  )

  $contract = $Manifest.currentThemeContract
  if ($null -eq $contract) { throw "currentThemeContract section is missing from the manifest" }
  if ($contract.schemaVersion -ne 1) {
    throw "currentThemeContract.schemaVersion must be 1, got $($contract.schemaVersion)"
  }
  if ($contract.supersedes -ne "tokenContracts") {
    throw "currentThemeContract must declare it supersedes tokenContracts, not replace it"
  }

  $tokens = @($contract.tokens)
  if ($tokens.Count -eq 0) {
    throw "currentThemeContract.tokens must not be empty"
  }

  $seenNames = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($token in $tokens) {
    if (-not $seenNames.Add([string] $token.name)) {
      throw "currentThemeContract.tokens contains a duplicate token name: $($token.name)"
    }
  }
  $actualNames = [string[]] (($tokens | ForEach-Object { [string] $_.name }) | Sort-Object)
  $expectedNames = [string[]] ($script:RequiredThemeContractTokenNames | Sort-Object)
  if (($actualNames -join "|") -ne ($expectedNames -join "|")) {
    throw ("currentThemeContract.tokens must contain exactly {" + ($script:RequiredThemeContractTokenNames -join ", ") +
      "}, got {" + ($actualNames -join ", ") + "}")
  }

  foreach ($token in $tokens) {
    $rawRgb = @($token.rgb)
    if ($rawRgb.Count -ne 3) {
      throw "currentThemeContract token $($token.name) must record exactly 3 RGB channel values, got $($rawRgb.Count)"
    }
    $recordedRgb = @()
    for ($i = 0; $i -lt $rawRgb.Count; $i++) {
      $recordedRgb += (ConvertTo-IntegralRgbChannel $rawRgb[$i] $token.name $i)
    }
    foreach ($channel in $recordedRgb) {
      if ($channel -lt 0 -or $channel -gt 255) {
        throw "currentThemeContract token $($token.name) has an out-of-range RGB channel value: $channel"
      }
    }
    if ($token.hex -notmatch "^#[0-9A-Fa-f]{6}$") {
      throw "currentThemeContract token $($token.name) has a malformed hex field: $($token.hex)"
    }
    $expectedHex = "#{0:X2}{1:X2}{2:X2}" -f $recordedRgb[0], $recordedRgb[1], $recordedRgb[2]
    if ($token.hex.ToUpperInvariant() -ne $expectedHex) {
      throw "currentThemeContract token $($token.name) hex field ($($token.hex)) does not match its recorded rgb ($($recordedRgb -join ','))"
    }

    $shortName = $token.name -replace "^Theme\.", ""
    $derivedRgb = Get-ThemeSwiftTokenRgb $ThemeSwiftText $shortName
    if (($derivedRgb -join ",") -ne ($recordedRgb -join ",")) {
      throw ("currentThemeContract drift detected for $($token.name): Theme.swift ($ThemeSwiftPathForDiagnostics, " +
        "line ~$($token.sourceLine)) now derives RGB($($derivedRgb -join ',')) but the manifest still " +
        "records RGB($($recordedRgb -join ',')). If this is an intentional design change, update " +
        "currentThemeContract's rgb/hex/swiftLiteral/themeSwiftBlobSha256; otherwise this is a real regression.")
    }

    # Mandatory: every required token must map to its exact required Windows
    # constant name. A blank/missing/wrong-mapped windowsToken field fails
    # outright rather than silently skipping the cross-source check.
    $expectedWindowsToken = $script:RequiredWindowsTokenByThemeToken[$token.name]
    $actualWindowsToken = [string] $token.windowsToken
    if ([string]::IsNullOrWhiteSpace($actualWindowsToken)) {
      throw "currentThemeContract token $($token.name) is missing its required windowsToken mapping (expected '$expectedWindowsToken')"
    }
    if ($actualWindowsToken -ne $expectedWindowsToken) {
      throw "currentThemeContract token $($token.name) has windowsToken '$actualWindowsToken' but the required mapping is '$expectedWindowsToken'"
    }

    # Genuine cross-source check: an actual Windows constant, independently
    # decoded, compared against the Swift-derived expectation above -- not a
    # manifest constant compared against another manifest constant.
    $designColorref = Get-DesignTokenColorref $DesignTokensText $actualWindowsToken
    $decoded = ConvertFrom-Colorref $designColorref
    if (($decoded -join ",") -ne ($recordedRgb -join ",")) {
      throw ("DesignTokens.zig ($DesignTokensPathForDiagnostics) $actualWindowsToken decodes to RGB(" +
        "$($decoded -join ',')) but Theme.swift ($ThemeSwiftPathForDiagnostics) $shortName derives RGB(" +
        "$($recordedRgb -join ',')) -- the Windows and macOS sources have drifted apart.")
    }
  }

  # Whole-file provenance check, last: any per-token literal mismatch above is a
  # more specific and actionable diagnostic than this, so it must win first. This
  # catches an approved-blob change that a per-token regex would not notice (e.g.
  # an edit elsewhere in the file, or to an untracked token).
  if ([string]::IsNullOrWhiteSpace([string] $contract.themeSwiftBlobSha256)) {
    throw "currentThemeContract.themeSwiftBlobSha256 is missing"
  }
  $actualBlobHash = Get-NormalizedTextSha256 $ThemeSwiftText
  if ($actualBlobHash -ne $contract.themeSwiftBlobSha256) {
    throw ("Theme.swift ($ThemeSwiftPathForDiagnostics) no longer matches the approved blob hash: " +
      "recorded $($contract.themeSwiftBlobSha256), actual $actualBlobHash (SHA-256 over LF-normalized text)")
  }
}

# Self-checks for the helpers above: worked examples, run on every invocation.
if ((ConvertTo-Rgb8Channel 0.040) -ne 10) { throw "rounding reimplementation drifted at 0.040" }
if ((ConvertTo-Rgb8Channel 0.048) -ne 12) { throw "rounding reimplementation drifted at 0.048" }
if ((ConvertTo-Rgb8Channel 0.044) -ne 11) { throw "rounding reimplementation drifted at 0.044" }
$colorrefWorkedExample = ConvertFrom-Colorref 0x00161815
if (($colorrefWorkedExample -join ",") -ne "21,24,22") {
  throw "ConvertFrom-Colorref byte order is wrong: expected 0x00161815 -> RGB(21,24,22), got $($colorrefWorkedExample -join ',')"
}

if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "manifest is missing: $ManifestPath" }
if (-not (Test-Path -LiteralPath $ThemeSwiftPath)) { throw "Theme.swift is missing: $ThemeSwiftPath" }
if (-not (Test-Path -LiteralPath $DesignTokensPath)) { throw "DesignTokens.zig is missing: $DesignTokensPath" }

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$themeSwiftText = Get-Content -LiteralPath $ThemeSwiftPath -Raw
$designTokensText = Get-Content -LiteralPath $DesignTokensPath -Raw

Test-CurrentThemeContract -Manifest $manifest -ThemeSwiftText $themeSwiftText -DesignTokensText $designTokensText `
  -ThemeSwiftPathForDiagnostics $ThemeSwiftPath -DesignTokensPathForDiagnostics $DesignTokensPath

Write-Output "currentThemeContract: PASS"
