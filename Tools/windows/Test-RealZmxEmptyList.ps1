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

# Workaround: on the elevated hosted runner a scratch ZMX_DIR owned by BUILTIN\Administrators
# failed with AccessDenied (coneilen/zmx#6, root cause unresolved), so reassign the owner.
$scratch = Join-Path ([IO.Path]::GetTempPath()) "zmx-empty-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $scratch | Out-Null
$me = [Security.Principal.WindowsIdentity]::GetCurrent().User
Write-Host "DIAG current user SID=$($me.Value) owner-before=$((Get-Acl -LiteralPath $scratch).Owner)"
& icacls.exe $scratch /setowner "*$($me.Value)" 2>&1 | ForEach-Object { Write-Host "DIAG icacls: $_" }
$acl = Get-Acl -LiteralPath $scratch
if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $me.Value) {
  try {
    $acl.SetOwner($me)
    Set-Acl -LiteralPath $scratch -AclObject $acl
  } catch { Write-Host "DIAG Set-Acl failed: $_" }
}
$ownerNow = (Get-Acl -LiteralPath $scratch).GetOwner([Security.Principal.SecurityIdentifier]).Value
Write-Host "DIAG owner-after=$ownerNow"
try {
  $env:ZMX_DIR = $scratch
  $diag = & $zmxExe ls 2>&1 | ForEach-Object { "$_" }
  Write-Host "DIAG zmx ls direct: exit=$LASTEXITCODE output=[$(($diag | Select-Object -First 2) -join ' | ')]"
} finally {
  Remove-Item Env:ZMX_DIR -ErrorAction SilentlyContinue
}
$env:GRAPHCODE_ZMX_EMPTY_DIR = $scratch
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
Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
