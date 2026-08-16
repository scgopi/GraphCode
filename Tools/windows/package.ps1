[CmdletBinding()]
param(
  [ValidateSet("Build", "Verify", "Install", "Upgrade", "Uninstall", "CleanMachine")]
  [string] $Command = "Build",
  [string] $InputDirectory,
  [string] $OutputDirectory,
  [string] $Package,
  [string] $InstallRoot = (Join-Path $env:LOCALAPPDATA "GraphCode\current"),
  [string] $Version = "0.0.0-dev",
  [string] $SignCertificate,
  [string] $SignTimestampUrl,
  [switch] $KeepUserData,
  [switch] $NoScheduledTask,
  [switch] $Force
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$shellRoot = Join-Path $repoRoot "graphcode-windows"
$required = @("graphcoded.exe", "graphcode.exe", "zmx.exe")

function Fail([string] $message) { throw "GraphCode packaging: $message" }
function Require([bool] $condition, [string] $message) { if (-not $condition) { Fail $message } }
function Resolve-Input([string] $path) {
  if (-not $path) { return $null }
  if (-not (Test-Path -LiteralPath $path -PathType Container)) { Fail "input directory does not exist: $path" }
  return (Resolve-Path -LiteralPath $path).Path
}
function Copy-Tree([string] $source, [string] $destination) {
  New-Item -ItemType Directory -Force -Path $destination | Out-Null
  Get-ChildItem -LiteralPath $source -File -Recurse | ForEach-Object {
    $relative = $_.FullName.Substring($source.Length).TrimStart("\", "/")
    $target = Join-Path $destination $relative
    New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
  }
}
function Get-Manifest([string] $root) {
  @(Get-ChildItem -LiteralPath $root -File -Recurse |
    Where-Object { $_.Name -notin @("manifest.json", "checksums.sha256") } |
    ForEach-Object {
      $relative = $_.FullName.Substring($root.Length).TrimStart("\", "/").Replace("\", "/")
      [ordered]@{
        path = $relative
        size = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
      }
    } | Sort-Object path)
}
function Write-Metadata([string] $root, [string] $version) {
  $pins = Get-Content -LiteralPath (Join-Path $shellRoot "provider-pins.json") -Raw | ConvertFrom-Json
  $metadata = [ordered]@{
    schemaVersion = 1
    product = "GraphCode Windows"
    version = $version
    platform = "windows-x86_64"
    executables = [ordered]@{ shell = "bin/graphcode-windows.exe"; daemon = "bin/graphcoded.exe"; cli = "bin/graphcode.exe"; zmx = "bin/zmx.exe" }
    hostAssets = @(Get-ChildItem -LiteralPath (Join-Path $root "bin") -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match "winghostty|host" } | ForEach-Object { "bin/$($_.Name)" })
    providerPins = $pins
    signing = if ($SignCertificate) { "signed" } else { "UNSIGNED (development artifact; not code signed)" }
    userData = "%LOCALAPPDATA%/GraphCode/data (preserved by uninstall)"
  }
  $metadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root "metadata.json") -Encoding utf8
  @"
GraphCode Windows distribution
Version: $version
Signing: $($metadata.signing)

This artifact is not code signed unless an explicit signing certificate was supplied.
"@ | Set-Content -LiteralPath (Join-Path $root "SIGNING.txt") -Encoding utf8
}
function Assert-Package([string] $root) {
  Require (Test-Path -LiteralPath (Join-Path $root "metadata.json")) "metadata.json is missing"
  $metadata = Get-Content (Join-Path $root "metadata.json") -Raw | ConvertFrom-Json
  foreach ($name in $required) { Require (Test-Path -LiteralPath (Join-Path $root "bin\$name")) "$name is missing" }
  Require (Test-Path -LiteralPath (Join-Path $root "bin\graphcode-windows.exe")) "graphcode-windows.exe is missing"
  Require (@(Get-ChildItem -LiteralPath (Join-Path $root "bin") -Filter *.dll -ErrorAction SilentlyContinue).Count -gt 0) "Swift runtime DLLs are missing"
  Require (Test-Path -LiteralPath (Join-Path $root "LICENSE")) "LICENSE is missing"
  Require (Test-Path -LiteralPath (Join-Path $root "THIRD-PARTY-NOTICES.txt")) "third-party notices are missing"
  Require ($metadata.platform -eq "windows-x86_64") "unsupported package platform"
  return $metadata
}
function Verify-Manifest([string] $root) {
  $manifestPath = Join-Path $root "manifest.json"
  Require (Test-Path -LiteralPath $manifestPath) "manifest.json is missing"
  $expected = Get-Content $manifestPath -Raw | ConvertFrom-Json
  foreach ($entry in $expected.files) {
    $file = Join-Path $root ($entry.path -replace "/", "\")
    Require (Test-Path -LiteralPath $file -PathType Leaf) "manifest file is missing: $($entry.path)"
    $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    Require ($actual -eq $entry.sha256) "checksum mismatch: $($entry.path)"
  }
  return $expected
}
function Build-Package {
  $out = if ($OutputDirectory) { $OutputDirectory } else { Join-Path $repoRoot ".build\windows\packages" }
  New-Item -ItemType Directory -Force -Path $out | Out-Null
  $staging = Join-Path $out ".staging-$([guid]::NewGuid())"
  $root = Join-Path $staging "GraphCode"
  New-Item -ItemType Directory -Force -Path (Join-Path $root "bin") | Out-Null
  $source = Resolve-Input $InputDirectory
  if ($source) {
    Copy-Tree $source (Join-Path $root "bin")
  } else {
    $locations = @(
      (Join-Path $shellRoot "zig-out\bin"),
      (Join-Path $repoRoot ".build\windows\release")
    )
    foreach ($location in $locations) { if (Test-Path $location) { Get-ChildItem $location -File | Copy-Item -Destination (Join-Path $root "bin") -Force } }
  }
  foreach ($name in $required + "graphcode-windows.exe") {
    Require (Test-Path (Join-Path $root "bin\$name")) "$name was not found; pass -InputDirectory with release outputs"
  }
  Require (@(Get-ChildItem (Join-Path $root "bin") -Filter *.dll).Count -gt 0) "Swift runtime DLLs were not found"
  Copy-Item (Join-Path $repoRoot "LICENSE") (Join-Path $root "LICENSE") -Force
  @"
GraphCode includes zmx and Winghostty provider artifacts pinned in metadata.json.
Provider source: https://github.com/coneilen/zmx and https://github.com/coneilen/winghostty
See provider-pins.json in the source repository for immutable revisions.
"@ | Set-Content (Join-Path $root "THIRD-PARTY-NOTICES.txt") -Encoding utf8
  Copy-Item (Join-Path $shellRoot "provider-pins.json") (Join-Path $root "provider-pins.json") -Force
  Write-Metadata $root $Version
  if ($SignCertificate) {
    $signtool = Get-Command signtool.exe -ErrorAction SilentlyContinue
    Require $signtool "signtool.exe was not found; signed packaging requires Windows SDK"
    Get-ChildItem (Join-Path $root "bin") -Filter *.exe | ForEach-Object {
      $args = @("sign", "/sha1", $SignCertificate)
      if ($SignTimestampUrl) { $args += @("/tr", $SignTimestampUrl, "/td", "sha256") }
      $args += $_.FullName
      & $signtool.Source @args
      Require ($LASTEXITCODE -eq 0) "signtool failed for $($_.Name)"
    }
    Set-Content (Join-Path $root "SIGNATURES.txt") -Value "Signed with certificate thumbprint $SignCertificate" -Encoding utf8
  }
  $manifest = [ordered]@{ schemaVersion = 1; files = @(Get-Manifest $root) }
  $manifest | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $root "manifest.json") -Encoding utf8
  $lines = $manifest.files | ForEach-Object { "$($_.sha256)  $($_.path)" }
  $lines | Set-Content (Join-Path $root "checksums.sha256") -Encoding utf8
  $archive = Join-Path $out "GraphCode-$Version-windows-x86_64.zip"
  if (Test-Path $archive) { Remove-Item $archive -Force }
  Compress-Archive -Path (Join-Path $root "*") -DestinationPath $archive -CompressionLevel Optimal
  $final = Join-Path $out "GraphCode-$Version-windows-x86_64"
  if (Test-Path $final) { Remove-Item $final -Recurse -Force }
  Move-Item $root $final
  Remove-Item $staging -Recurse -Force
  $artifactHash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
  Set-Content (Join-Path $out "GraphCode-$Version-windows-x86_64.zip.sha256") "$artifactHash  $(Split-Path $archive -Leaf)" -Encoding ascii
  Write-Output $archive
}
function Open-Package([string] $path) {
  Require (Test-Path -LiteralPath $path) "package does not exist: $path"
  if ((Get-Item $path).PSIsContainer) { return (Resolve-Path $path).Path }
  $extract = Join-Path ([IO.Path]::GetTempPath()) "graphcode-package-$([guid]::NewGuid())"
  Expand-Archive -LiteralPath $path -DestinationPath $extract
  $nested = Get-ChildItem $extract -Directory | Select-Object -First 1
  return $nested.FullName
}
function Set-UserPath([string] $bin, [bool] $add) {
  $current = [Environment]::GetEnvironmentVariable("Path", "User")
  $parts = @($current -split ";" | Where-Object { $_ -and $_ -ne $bin })
  if ($add) { $parts += $bin }
  [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")
}
function Install-Package([bool] $upgrade) {
  $root = Open-Package ($(if ($Package) { $Package } else { Fail "-Package is required" }))
  $metadata = Assert-Package $root
  Verify-Manifest $root | Out-Null
  if ($Version -ne "0.0.0-dev" -and $metadata.version -ne $Version) { Fail "version mismatch: expected $Version, package is $($metadata.version)" }
  $parent = Split-Path $InstallRoot -Parent
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $stage = Join-Path $parent ".GraphCode-install-$([guid]::NewGuid())"
  Copy-Tree $root $stage
  $backup = Join-Path $parent ".GraphCode-rollback-$([guid]::NewGuid())"
  try {
    if (Test-Path $InstallRoot) { Move-Item $InstallRoot $backup }
    Move-Item $stage $InstallRoot
    Set-UserPath (Join-Path $InstallRoot "bin") $true
    if (-not $NoScheduledTask) {
      $taskName = "GraphCode daemon"
      & schtasks.exe /Create /TN $taskName /SC ONLOGON /TR "`"$InstallRoot\bin\graphcoded.exe`"" /F *> $null
      Require ($LASTEXITCODE -eq 0) "scheduled-task registration failed"
    }
  } catch {
    if (Test-Path $InstallRoot) { Remove-Item $InstallRoot -Recurse -Force }
    if (Test-Path $backup) { Move-Item $backup $InstallRoot }
    throw
  } finally {
    Remove-Item $stage,$backup -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Output "Installed GraphCode $($metadata.version) at $InstallRoot"
}
function Uninstall-Package {
  $bin = Join-Path $InstallRoot "bin"
  Set-UserPath $bin $false
  & schtasks.exe /Delete /TN "GraphCode daemon" /F *> $null
  if (Test-Path $InstallRoot) { Remove-Item $InstallRoot -Recurse -Force }
  if (-not $KeepUserData) { Write-Output "User data preserved under $(Split-Path $InstallRoot -Parent)\data" }
}

switch ($Command) {
  "Build" { Build-Package }
  "Verify" { $root = Open-Package $Package; Assert-Package $root | Out-Null; Verify-Manifest $root | Out-Null; Write-Output "Package verification: PASS" }
  "Install" { Install-Package $false }
  "Upgrade" { Install-Package $true }
  "Uninstall" { Uninstall-Package }
  "CleanMachine" { Uninstall-Package; Remove-Item (Join-Path $env:ProgramData "GraphCode") -Recurse -Force -ErrorAction SilentlyContinue }
}
