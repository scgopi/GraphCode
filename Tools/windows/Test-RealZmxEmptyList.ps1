[CmdletBinding()]
param(
  [string] $ZmxRoot = $env:GRAPHCODE_ZMX_ROOT,
  [string] $Zig0160 = $env:GRAPHCODE_ZIG0160,
  [string] $SwiftTest = "swift-test"
)

# Builds the pinned zmx provider and runs the real-zmx empty-list test with zmx.exe
# required: the test fails instead of skipping when it is missing, and this script fails
# unless that one test is reported executed and passed.
$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$testName = "testRealZmxEmptyListThroughRunCollectingOutput"

if (-not $ZmxRoot -or -not (Test-Path -LiteralPath $ZmxRoot -PathType Container)) {
  throw "zmx provider root not found: '$ZmxRoot' (run Tools\windows\bootstrap.ps1)"
}
if (-not $Zig0160 -or -not (Test-Path -LiteralPath $Zig0160 -PathType Leaf)) {
  throw "Zig 0.16.0 not found: '$Zig0160' (run Tools\windows\bootstrap.ps1)"
}

Push-Location $ZmxRoot
try {
  & $Zig0160 build -Dtarget=x86_64-windows-gnu
  if ($LASTEXITCODE -ne 0) { throw "zmx provider build failed with exit code $LASTEXITCODE" }
} finally {
  Pop-Location
}
$zmxExe = Join-Path $ZmxRoot "zig-out\bin\zmx.exe"
if (-not (Test-Path -LiteralPath $zmxExe -PathType Leaf)) {
  throw "zmx build produced no executable at $zmxExe"
}

$env:GRAPHCODE_ZMX_EXE = (Resolve-Path -LiteralPath $zmxExe).Path
$env:GRAPHCODE_REQUIRE_ZMX = "1"
$output = & $SwiftTest --package-path $repoRoot --disable-automatic-resolution `
  --filter "ZmxEmptyListStderrTests/$testName" 2>&1 | ForEach-Object { "$_" }
$exit = $LASTEXITCODE
$output | ForEach-Object { Write-Host $_ }
if ($exit -ne 0) { throw "swift test failed with exit code $exit" }

$passed = @($output | Where-Object {
    $_ -match "Test Case '.*ZmxEmptyListStderrTests\.$testName' passed"
  })
$skipped = @($output | Where-Object { $_ -match "skipped" })
$executed = @($output | Where-Object { $_ -match "Executed 1 test, with 0 failures" })
if ($passed.Count -lt 1 -or $skipped.Count -gt 0 -or $executed.Count -lt 1) {
  throw "Real zmx test did not execute and pass (passed=$($passed.Count) skipped=$($skipped.Count) executed-line=$($executed.Count))"
}
Write-Host "REAL_ZMX_TEST_EXECUTED: $($passed[0].Trim())"
