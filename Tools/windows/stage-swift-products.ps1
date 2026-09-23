<#
.SYNOPSIS
  Builds graphcoded/graphcode and stages them with the Swift runtime DLLs where
  Tools/windows/package.ps1 looks for release inputs.

.DESCRIPTION
  package.ps1 collects release inputs from graphcode-windows\zig-out\bin and
  .build\windows\release. The Zig side is built by package.ps1 itself; this
  script produces the Swift side, using the same toolchain and runtime
  resolution as Tools/windows/validate.ps1.
#>
[CmdletBinding()]
param(
  [string] $SwiftExecutable = $env:GRAPHCODE_SWIFT633,
  [string] $Destination
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if (-not $Destination) { $Destination = Join-Path $repoRoot ".build\windows\release" }

function Resolve-Swift {
  if ($SwiftExecutable) { return (Resolve-Path -LiteralPath $SwiftExecutable).Path }
  $candidates = @()
  $command = Get-Command swift.exe -ErrorAction SilentlyContinue
  if ($command) { $candidates += $command.Source }
  $candidates += Get-ChildItem (Join-Path $env:LOCALAPPDATA "Programs\Swift\Toolchains") `
    -Recurse -Filter swift.exe -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName
  $candidates += Get-ChildItem "C:\Library\Developer\Toolchains" `
    -Recurse -Filter swift.exe -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName
  foreach ($candidate in $candidates | Select-Object -Unique) {
    if ($candidate -match "\\Toolchains\\([0-9]+)\.[^\\]*\\usr\\bin\\swift\.exe$" -and
      [int] $Matches[1] -ge 6) {
      return $candidate
    }
  }
  throw "Swift 6 toolchain was not found; run Tools\windows\bootstrap.ps1 first"
}

function Resolve-SwiftRuntimeDirectory([string] $swift) {
  $toolBin = Split-Path $swift
  if ($swift -match "^(.*)\\Toolchains\\([^\\]+)\\usr\\bin\\swift\.exe$") {
    $version = $Matches[2].Split("+")[0]
    $candidates = @((Join-Path $Matches[1] "Runtimes\$version\usr\bin"), $toolBin)
    foreach ($runtime in $candidates | Select-Object -Unique) {
      if ((Test-Path -LiteralPath $runtime) -and
        (Get-ChildItem -LiteralPath $runtime -Filter *.dll -ErrorAction SilentlyContinue)) {
        return $runtime
      }
    }
  }
  throw "Swift runtime DLL directory was not found for $swift"
}

$swift = Resolve-Swift
$swiftBin = Split-Path $swift
$build = Join-Path $swiftBin "swift-build.exe"
foreach ($product in @("graphcoded", "graphcode")) {
  & $build --package-path $repoRoot --configuration release --product $product
  if ($LASTEXITCODE -ne 0) { throw "Swift release build failed for $product" }
}
$binPath = & $build --package-path $repoRoot --configuration release --show-bin-path
if ($LASTEXITCODE -ne 0) { throw "Swift release bin path lookup failed" }
$binPath = $binPath | Select-Object -Last 1

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
foreach ($name in @("graphcoded.exe", "graphcode.exe")) {
  $produced = Join-Path $binPath $name
  if (-not (Test-Path -LiteralPath $produced -PathType Leaf)) {
    throw "Swift release build did not produce $produced"
  }
  Copy-Item -LiteralPath $produced -Destination (Join-Path $Destination $name) -Force
}
Get-ChildItem -LiteralPath (Resolve-SwiftRuntimeDirectory $swift) -Filter *.dll |
  Copy-Item -Destination $Destination -Force

Write-Host "Staged Swift release products in $Destination"
