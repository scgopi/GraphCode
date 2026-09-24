[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $ZigExecutable,
  [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
)

$ErrorActionPreference = "Stop"

# Real live evidence for the Windows in-app updater's download/checksum/feed
# paths (issue: Windows updater install/relaunch parity). This is
# deliberately NOT wired into WindowsShell.Tests.ps1's anti-drift-guarded
# fast suite: it makes real HTTPS calls to the real GitHub API and a real
# release asset, and that suite is meant to run with no network. Invoke this
# script directly (mirrors DaemonHandoff.Live.Tests.ps1 and
# Packaging.RealLifecycle.Tests.ps1, which are also plain standalone live
# scripts rather than part of the fast contract).
#
# What this proves, for real, right now:
#   1. The real update-feed check against the actual scgopi/GraphCode
#      releases API resolves no Windows asset for the current latest
#      release -- the honest "no Windows build published" state the offer UI
#      must show, not a fixture standing in for it. (The last recorded
#      release-asset check found only macOS DMGs; this re-confirms that live
#      at test time rather than assuming it still holds.)
#   2. A real HTTPS download of a real, large (multi-megabyte) GitHub
#      release asset through `WindowsUpdateInstall.install()` reports
#      genuine, monotonically increasing download progress and verifies a
#      real running SHA-256 against the asset's real published digest,
#      reaching the `extracting` phase (which then fails for the honest,
#      expected reason that the real asset is a DMG, not a ZIP -- proving
#      download+checksum succeeded on real bytes without needing a Windows
#      asset to exist).
#   3. The exact same real download, verified against a deliberately wrong
#      digest, fails with ChecksumMismatch strictly before reaching
#      `extracting` -- proving the checksum gate inspects real downloaded
#      bytes rather than passing vacuously.
#
# What this does NOT prove (left honestly out of scope for this script):
# extraction of a real Windows ZIP asset, invocation of a real
# GraphCode-Setup.ps1 -Command Upgrade from a downloaded package, or the
# in-window progress dialog / relaunch prompt UI. No Windows release asset
# exists to extract at test time (see point 1), and PACKAGING's own
# Move-InstallDirectory/self-rename-while-running behavior is exercised
# separately by Packaging.RealLifecycle.Tests.ps1 against a locked-file
# scenario, not a genuinely running graphcode-windows.exe.

$repoRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$shellRoot = Join-Path $repoRoot "graphcode-windows"
$runner = Join-Path $shellRoot "src\UpdateInstallLiveRunner.zig"
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
  throw "live runner is missing: $runner"
}

$depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
$winghosttyRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_WINGHOSTTY_ROOT")
if (-not $winghosttyRoot) {
  $winghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
}
$include = Join-Path $winghosttyRoot "include"

function Invoke-Runner([string[]] $RunnerArgs) {
  Push-Location $shellRoot
  try {
    $output = & $ZigExecutable run "src\UpdateInstallLiveRunner.zig" -target x86_64-windows-msvc -lc -lwinhttp "-I$include" -- @RunnerArgs 2>&1 | Out-String
    return @{ ExitCode = $LASTEXITCODE; Output = $output }
  } finally { Pop-Location }
}

function Get-Field([string] $Output, [string] $Name) {
  $match = [regex]::Match($Output, "(?m)(?:^|\s)$Name=(\S+)")
  if (-not $match.Success) { throw "runner output is missing field '$Name': $Output" }
  return $match.Groups[1].Value.Trim()
}

# --- 1. Real feed check: confirms the honest "no Windows asset" state -----
$feed = Invoke-Runner @("feed-check")
if ($feed.ExitCode -ne 0) { throw "real feed check failed: $($feed.Output)" }
$feedState = Get-Field $feed.Output "state"
$feedAssetUrl = Get-Field $feed.Output "asset_url"
if ($feedState -ne "available") {
  throw "expected the real scgopi/GraphCode feed to report an available release right now, got state=$feedState. If this repository has since started shipping stable releases with no update pending, this assertion needs revisiting rather than loosening -- do not just delete it."
}
if ($feedAssetUrl -ne "none") {
  Write-Output "NOTE: a Windows asset is now published ($feedAssetUrl) -- the 'no Windows asset' constraint this gate exercises no longer holds for the current release. This is good news for the product; this gate's coverage of the no-asset path is now moot and the download/extract/upgrade path against a REAL Windows asset should be exercised live instead."
} else {
  Write-Output "Real feed check: latest release has no Windows asset (asset_url=none) -- PASS"
}

# --- 2. Real download + real checksum verification (correct digest) -------
$releases = Invoke-RestMethod -Uri "https://api.github.com/repos/scgopi/GraphCode/releases" -TimeoutSec 20
$assetRelease = $releases | Where-Object { $_.assets.Count -gt 0 } | Select-Object -First 1
if (-not $assetRelease) { throw "no published release has any asset to test a real download against" }
$asset = $assetRelease.assets[0]
if (-not $asset.digest -or $asset.digest -notmatch '^sha256:[0-9a-f]{64}$') {
  throw "the real asset '$($asset.name)' has no usable sha256 digest to verify against: '$($asset.digest)'"
}
$realDigest = $asset.digest -replace '^sha256:', ''

$success = Invoke-Runner @("download-checksum", $asset.browser_download_url, $realDigest)
if ($success.ExitCode -ne 0) { throw "download-checksum runner crashed: $($success.Output)" }
$successReports = [int](Get-Field $success.Output "reports")
$successMaxFraction = [double](Get-Field $success.Output "max_downloading_fraction")
$successPhase = Get-Field $success.Output "last_phase"
$successResult = Get-Field $success.Output "result"
if ($successReports -lt 10) {
  throw "expected many real progress reports streaming a multi-megabyte download, got only ${successReports}: $($success.Output)"
}
if ($successMaxFraction -lt 0.99) {
  throw "real download progress never reached completion (max_downloading_fraction=$successMaxFraction): $($success.Output)"
}
if ($successPhase -ne "extracting") {
  throw "expected checksum verification to succeed and reach extracting for a correct real digest, got last_phase=$successPhase result=$successResult`: $($success.Output)"
}
if ($success.Output -notmatch "result=error name=ExtractionFailed") {
  throw "expected extraction of a non-ZIP real asset to fail specifically with ExtractionFailed (proving it was genuinely attempted, not skipped), got: $($success.Output)"
}
Write-Output "Real download of $($asset.name) ($($asset.size) bytes): checksum verified against the real published digest, $successReports progress reports, reached extracting -- PASS"

# --- 3. Same real download, wrong digest: must fail before extraction -----
$wrongDigest = ("0" * 64)
if ($wrongDigest -eq $realDigest) { $wrongDigest = ("f" * 64) }
$mismatch = Invoke-Runner @("download-checksum", $asset.browser_download_url, $wrongDigest)
if ($mismatch.ExitCode -ne 0) { throw "download-checksum runner crashed: $($mismatch.Output)" }
$mismatchPhase = Get-Field $mismatch.Output "last_phase"
if ($mismatch.Output -notmatch "result=error name=ChecksumMismatch") {
  throw "a deliberately wrong digest against real downloaded bytes must fail with ChecksumMismatch -- this is the assertion that proves checksum verification is not vacuous. Got: $($mismatch.Output)"
}
if ($mismatchPhase -eq "extracting" -or $mismatchPhase -eq "installing") {
  throw "checksum mismatch must be caught before extraction, but reached phase=${mismatchPhase}: $($mismatch.Output)"
}
Write-Output "Real download of $($asset.name) with a deliberately wrong digest: rejected with ChecksumMismatch before extracting -- PASS"

Write-Output "Windows update install live gate: PASS"
