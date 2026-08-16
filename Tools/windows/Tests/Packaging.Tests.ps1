[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$script = Join-Path $repoRoot "Tools\windows\package.ps1"
$fixture = Join-Path $repoRoot ".build\packaging-test-fixture-$PID"
$out = Join-Path $repoRoot ".build\packaging-test-output-$PID"
$install = Join-Path $repoRoot ".build\packaging install $PID\深い\GraphCode"

function Invoke-Package([string] $command, [hashtable] $extra = @{}) {
  $args = @("-NoProfile", "-File", $script, "-Command", $command)
  foreach ($key in $extra.Keys) { $args += @("-$key", [string] $extra[$key]) }
  & pwsh @args
  if ($LASTEXITCODE -ne 0) { throw "packaging $command failed" }
}
function Assert-VerifyReject([string] $label, [scriptblock] $mutate, [string] $message) {
  $copy = Join-Path $out "negative-$([guid]::NewGuid())"
  Copy-Item $artifact $copy -Recurse
  & $mutate $copy
  $output = & pwsh -NoProfile -File $script -Command Verify -Package $copy 2>&1 | Out-String
  $code = $LASTEXITCODE
  Remove-Item $copy -Recurse -Force -ErrorAction SilentlyContinue
  if ($code -eq 0 -or $output -notmatch [regex]::Escape($message)) {
    throw "$label did not fail specifically: $output"
  }
}
try {
  $depot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $wingRoot = if ($env:GRAPHCODE_WINGHOSTTY_ROOT) { $env:GRAPHCODE_WINGHOSTTY_ROOT } else { Join-Path $depot "Winghostty-worktrees\host-integration" }
  $zmxRoot = if ($env:GRAPHCODE_ZMX_ROOT) { $env:GRAPHCODE_ZMX_ROOT } else { Join-Path $depot "zmx-worktrees\attach" }
  if (-not (Test-Path $wingRoot) -or -not (Test-Path $zmxRoot)) { throw "trusted provider roots are required" }
  $fixtureBin = Join-Path $fixture "nested space\unicode-日本\bin"
  New-Item -ItemType Directory -Force -Path $fixtureBin | Out-Null
  $release = Join-Path $repoRoot ".build\windows\release-artifact"
  if (-not (Test-Path (Join-Path $release "graphcoded.exe"))) {
    $release = Join-Path $repoRoot ".build\x86_64-unknown-windows-msvc\release"
  }
  foreach ($name in @("graphcode-windows.exe", "graphcoded.exe", "graphcode.exe")) {
    $candidate = if ($name -eq "graphcode-windows.exe") {
      Join-Path $repoRoot "graphcode-windows\zig-out\bin\$name"
    } else { Join-Path $release $name }
    if (-not (Test-Path $candidate)) { throw "real release executable missing: $candidate" }
    Copy-Item $candidate (Join-Path $fixtureBin $name)
  }
  Copy-Item (Join-Path $zmxRoot "zig-out\bin\zmx.exe") (Join-Path $fixtureBin "zmx.exe")
  Get-ChildItem $release -Filter *.dll | Copy-Item -Destination $fixtureBin
  $untrusted = & pwsh -NoProfile -File $script -Command Build -InputDirectory $fixtureBin `
    -OutputDirectory $out -Version "untrusted" 2>&1 | Out-String
  if ($LASTEXITCODE -eq 0 -or $untrusted -notmatch "trusted pinned") {
    throw "untrusted provider input was accepted: $untrusted"
  }
  Invoke-Package "Build" @{ InputDirectory = $fixtureBin; OutputDirectory = $out; Version = "1.2.3"; WinghosttyRoot = $wingRoot; ZmxRoot = $zmxRoot }
  $artifact = Join-Path $out "GraphCode-1.2.3-windows-x86_64"
  $zip = "$artifact.zip"
  Invoke-Package "Verify" @{ Package = $zip }
  Invoke-Package "Install" @{ Package = $zip; InstallRoot = $install; NoScheduledTask = $true }
  if (-not (Test-Path (Join-Path $install "bin\graphcode.exe"))) { throw "install did not place CLI" }
  $userData = Join-Path $env:USERPROFILE ".graphcode\packaging-test-$PID\user.json"
  New-Item -ItemType Directory -Force -Path (Split-Path $userData -Parent) | Out-Null
  Set-Content $userData "preserve" -Force
  Invoke-Package "Upgrade" @{ Package = $zip; InstallRoot = $install; NoScheduledTask = $true }
  Invoke-Package "Uninstall" @{ InstallRoot = $install; KeepUserData = $true; NoScheduledTask = $true }
  if (Test-Path $install) { throw "uninstall left installed binaries" }
  if (-not (Test-Path $userData)) { throw "uninstall removed user data" }
  & pwsh -NoProfile -File (Join-Path $PSScriptRoot "Packaging.RealLifecycle.Tests.ps1") `
    -Package $zip -RepositoryRoot $repoRoot
  if ($LASTEXITCODE -ne 0) { throw "real scheduled lifecycle test failed" }
  Assert-VerifyReject "checksum" { param($p) Add-Content (Join-Path $p "bin\zmx.exe") corrupt } "size mismatch"
  Assert-VerifyReject "extra file" { param($p) Set-Content (Join-Path $p "extra.txt") unexpected } "manifest file set differs"
  Assert-VerifyReject "traversal" {
    param($p); $m=Get-Content (Join-Path $p "manifest.json") -Raw | ConvertFrom-Json
    $m.files[0].path="../escape.txt"; $m | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $p "manifest.json")
  } "unsafe path"
  Assert-VerifyReject "absolute" {
    param($p); $m=Get-Content (Join-Path $p "manifest.json") -Raw | ConvertFrom-Json
    $m.files[0].path="/absolute.txt"; $m | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $p "manifest.json")
  } "absolute path"
  Assert-VerifyReject "duplicate" {
    param($p); $m=Get-Content (Join-Path $p "manifest.json") -Raw | ConvertFrom-Json
    $m.files += $m.files[0]; $m | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $p "manifest.json")
  } "duplicate paths"
  Assert-VerifyReject "provenance" {
    param($p); $v=Get-Content (Join-Path $p "provider-provenance.json") -Raw | ConvertFrom-Json
    $path=Join-Path $p "provider-provenance.json"
    $v.zmx.sha256=("0"*64); $v | ConvertTo-Json -Depth 10 | Set-Content $path
    $m=Get-Content (Join-Path $p "manifest.json") -Raw | ConvertFrom-Json
    $entry=@($m.files | Where-Object path -eq "provider-provenance.json")[0]
    $entry.size=(Get-Item $path).Length
    $entry.sha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $m | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $p "manifest.json")
  } "provenance digest mismatch"
  Assert-VerifyReject "reserved nested name" {
    param($p); New-Item -ItemType Directory (Join-Path $p "nested") | Out-Null
    Set-Content (Join-Path $p "nested\manifest.json") reserved
  } "reserved filename"
  Write-Output "Packaging executable install/upgrade/uninstall tests: PASS"
  exit 0
} finally {
  Remove-Item $fixture,$out,(Split-Path $install -Parent), `
    (Join-Path $env:USERPROFILE ".graphcode\packaging-test-$PID") `
    -Recurse -Force -ErrorAction SilentlyContinue
}
