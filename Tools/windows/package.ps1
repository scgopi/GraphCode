[CmdletBinding()]
param(
  [ValidateSet("Build", "Verify", "Install", "Upgrade", "Uninstall", "CleanMachine")]
  [string] $Command = "Build",
  [string] $InputDirectory,
  [string] $OutputDirectory,
  [string] $Package,
  [string] $InstallRoot = (Join-Path $env:LOCALAPPDATA "GraphCode\current"),
  [string] $Version,
  [ValidatePattern("^[0-9a-fA-F]{40}$")]
  [string] $SignCertificate,
  [string] $SignTimestampUrl,
  [string] $SignToolPath,
  [ValidatePattern("^[0-9a-fA-F]{40}$")]
  [string] $TrustedSignerThumbprint,
  [string] $WinghosttyRoot,
  [string] $ZmxRoot,
  [string] $Zig0152 = $env:GRAPHCODE_ZIG0152,
  [string] $Zig0160 = $env:GRAPHCODE_ZIG0160,
  [switch] $KeepUserData,
  [switch] $RemoveUserData,
  [switch] $NoScheduledTask,
  [switch] $Force
)

$ErrorActionPreference = "Stop"
$versionWasProvided = [bool]$Version
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$shellRoot = Join-Path $repoRoot "graphcode-windows"
$ProviderPinsPath = Join-Path $shellRoot "provider-pins.json"
$required = @("graphcoded.exe", "graphcode.exe", "zmx.exe")
$packageManifest = Get-Content (Join-Path $shellRoot "build.zig.zon") -Raw
if (-not $Version) {
  if ($packageManifest -notmatch '(?m)\.version\s*=\s*"([^"]+)"') {
    throw "GraphCode packaging: package version is missing"
  }
  $Version = $Matches[1]
}

. (Join-Path $PSScriptRoot "PackageRuntime.ps1")

function Resolve-Input([string] $path) {
  if (-not $path) { return $null }
  if (-not (Test-Path -LiteralPath $path -PathType Container)) { Fail "input directory does not exist: $path" }
  return (Resolve-Path -LiteralPath $path).Path
}
function Get-Manifest([string] $root) {
  @(Get-ChildItem -LiteralPath $root -File -Recurse -Force |
    Where-Object {
      $_.FullName -ne (Join-Path $root "manifest.json") -and
      $_.FullName -ne (Join-Path $root "checksums.sha256") -and
      $_.FullName -ne (Join-Path $root "package.cat")
    } |
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
    signing = if ($SignCertificate) { "signed" } else { "UNSIGNED (not code signed)" }
    userData = "%USERPROFILE%/.graphcode (preserved by uninstall)"
    providerProvenance = "provider-provenance.json"
    setup = "GraphCode-Setup.ps1"
  }
  $metadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root "metadata.json") -Encoding utf8
  @"
GraphCode Windows distribution
Version: $version
Signing: $($metadata.signing)

This artifact is not code signed unless an explicit signing certificate was supplied.
"@ | Set-Content -LiteralPath (Join-Path $root "SIGNING.txt") -Encoding utf8
}
function Sign-PackageFile([string] $tool, [string] $path) {
  $arguments = @("sign", "/sha1", $SignCertificate, "/fd", "sha256")
  if ($SignTimestampUrl) { $arguments += @("/tr", $SignTimestampUrl, "/td", "sha256") }
  $arguments += $path
  & $tool @arguments
  Require ($LASTEXITCODE -eq 0) "signtool failed for $(Split-Path $path -Leaf)"
}
function Write-PackageSetup([string] $root) {
  $template = Get-Content -LiteralPath (Join-Path $repoRoot "Tools\windows\setup.template.ps1") -Raw
  $runtime = Get-Content -LiteralPath (Join-Path $repoRoot "Tools\windows\PackageRuntime.ps1") -Raw
  $marker = "# GRAPHCODE_PACKAGE_RUNTIME"
  Require ([regex]::Matches($template, [regex]::Escape($marker)).Count -eq 1) "setup template must contain one runtime marker"
  $source = $template.Replace($marker, $runtime.Trim())
  [IO.File]::WriteAllText((Join-Path $root "GraphCode-Setup.ps1"), $source, [Text.UTF8Encoding]::new($true))
}
function Build-Package {
  Require ($Version -and $Version -notin @("dev", "0.0.0-dev")) "release packaging requires a non-dev package version"
  if ($SignCertificate) {
    Require ($SignCertificate -match "^[0-9a-fA-F]{40}$") "signing certificate thumbprint is invalid"
    Require (-not $TrustedSignerThumbprint -or $TrustedSignerThumbprint -eq $SignCertificate) `
      "trusted publisher thumbprint does not match signing certificate"
  } else {
    Require (-not $TrustedSignerThumbprint) "trusted publisher verification requires -SignCertificate when building"
  }
  $out = if ($OutputDirectory) { $OutputDirectory } else { Join-Path $repoRoot ".build\windows\packages" }
  New-Item -ItemType Directory -Force -Path $out | Out-Null
  $staging = Join-Path $out ".staging-$([guid]::NewGuid())"
  $root = Join-Path $staging "GraphCode"
  New-Item -ItemType Directory -Force -Path (Join-Path $root "bin") | Out-Null
  $root = (Resolve-Path -LiteralPath $root).Path
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
  $provenancePath = Join-Path $root "provider-provenance.json"
  if ($WinghosttyRoot -or $ZmxRoot) {
    Require ($WinghosttyRoot -and $ZmxRoot) "both provider roots are required"
    Require ($Zig0152 -and $Zig0160) "pinned Zig 0.15.2 and 0.16.0 executables are required"
    $pins = Get-Content (Join-Path $shellRoot "provider-pins.json") -Raw | ConvertFrom-Json
    foreach ($spec in @(
      @{ name = "winghostty"; root = $WinghosttyRoot; pin = $pins.winghostty; source = $pins.winghostty.artifact; destination = "assets/winghostty-win32-host.lib" },
      @{ name = "zmx"; root = $ZmxRoot; pin = $pins.zmx; source = $pins.zmx.artifact; destination = "bin/zmx.exe" }
    )) {
      Require ((git -C $spec.root rev-parse HEAD) -eq $spec.pin.sha) "$($spec.name) provider is not pinned"
      Require (@(git -C $spec.root status --porcelain).Count -eq 0) "$($spec.name) provider worktree is dirty"
      $zig = if ($spec.name -eq "winghostty") { $Zig0152 } else { $Zig0160 }
      Require (Test-Path $zig -PathType Leaf) "pinned Zig executable is missing for $($spec.name)"
      Push-Location $spec.root
      try {
        $buildArgs = if ($spec.name -eq "winghostty") {
          @("build", "-Demit-win32-host=true")
        } else {
          @("build", "-Dtarget=x86_64-windows-gnu")
        }
        & $zig @buildArgs
        Require ($LASTEXITCODE -eq 0) "$($spec.name) pinned rebuild failed"
      } finally { Pop-Location }
      $providerArtifact = Join-Path $spec.root ($spec.source -replace "/", "\")
      Require (Test-Path $providerArtifact -PathType Leaf) "$($spec.name) provider artifact is missing"
      $destination = Join-Path $root ($spec.destination -replace "/", "\")
      New-Item -ItemType Directory -Force (Split-Path $destination -Parent) | Out-Null
      Copy-Item $providerArtifact $destination -Force
      $digest = (Get-FileHash $destination -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($spec.name -eq "winghostty") { $wingDigest = $digest } else { $zmxDigest = $digest }
    }
    @{
      schemaVersion = 1
      winghostty = @{ repository = $pins.winghostty.repository; sha = $pins.winghostty.sha; packagePath = "assets/winghostty-win32-host.lib"; sha256 = $wingDigest; trustedSha256 = $wingDigest }
      zmx = @{ repository = $pins.zmx.repository; sha = $pins.zmx.sha; packagePath = "bin/zmx.exe"; sha256 = $zmxDigest; trustedSha256 = $zmxDigest }
    } | ConvertTo-Json -Depth 5 | Set-Content $provenancePath -Encoding utf8
  } else {
    Fail "trusted pinned Winghostty and zmx roots are required; fixture provenance is not accepted"
  }
  if (-not $source) {
    Require ($WinghosttyRoot -and $Zig0152) "release build requires pinned Winghostty root and Zig 0.15.2"
    Push-Location $shellRoot
    try {
      & $Zig0152 build `
        "-Dwinghostty-dir=$WinghosttyRoot" `
        "-Dwinghostty-lib=$(Join-Path $WinghosttyRoot 'zig-out\lib\winghostty-win32-host.lib')" `
        "-Dversion=$Version" `
        -Doptimize=ReleaseSafe
      Require ($LASTEXITCODE -eq 0) "GraphCode Windows release build failed"
    } finally { Pop-Location }
    foreach ($file in @(Get-ChildItem (Join-Path $shellRoot "zig-out\bin") -File)) {
      Copy-Item $file (Join-Path $root "bin\$($file.Name)") -Force
    }
  }
  foreach ($name in $required + "graphcode-windows.exe") {
    Require (Test-Path (Join-Path $root "bin\$name")) "$name was not found; pass -InputDirectory with release outputs"
  }
  $reportedVersion = (& (Join-Path $root "bin\graphcode-windows.exe") --version 2>$null | Select-Object -First 1).Trim()
  Require ($reportedVersion -eq $Version) "graphcode-windows.exe reports $reportedVersion, expected $Version"
  Require (@(Get-ChildItem (Join-Path $root "bin") -Filter *.dll).Count -gt 0) "Swift runtime DLLs were not found"
  Copy-Item (Join-Path $repoRoot "LICENSE") (Join-Path $root "LICENSE") -Force
  Require ($WinghosttyRoot -and $ZmxRoot) "trusted provider roots are required for license attribution"
  $wingLicensePath = Join-Path $WinghosttyRoot "LICENSE"
  $zmxLicensePath = Join-Path $ZmxRoot "LICENSE"
  Require (Test-Path $wingLicensePath -PathType Leaf) "Winghostty LICENSE is missing"
  Require (Test-Path $zmxLicensePath -PathType Leaf) "zmx LICENSE is missing"
  $wingLicense = Get-Content $wingLicensePath -Raw
  $zmxLicense = Get-Content $zmxLicensePath -Raw
  New-Item -ItemType Directory -Force (Join-Path $root "licenses") | Out-Null
  Set-Content (Join-Path $root "licenses\WINGHOSTTY-LICENSE.txt") $wingLicense -Encoding utf8
  Set-Content (Join-Path $root "licenses\ZMX-LICENSE.txt") $zmxLicense -Encoding utf8
  $provenance = Get-Content $provenancePath -Raw | ConvertFrom-Json
  $provenance.winghostty | Add-Member -NotePropertyName licensePath -NotePropertyValue "licenses/WINGHOSTTY-LICENSE.txt"
  $provenance.winghostty | Add-Member -NotePropertyName licenseSha256 -NotePropertyValue `
    ((Get-FileHash (Join-Path $root "licenses\WINGHOSTTY-LICENSE.txt") -Algorithm SHA256).Hash.ToLowerInvariant())
  $provenance.zmx | Add-Member -NotePropertyName licensePath -NotePropertyValue "licenses/ZMX-LICENSE.txt"
  $provenance.zmx | Add-Member -NotePropertyName licenseSha256 -NotePropertyValue `
    ((Get-FileHash (Join-Path $root "licenses\ZMX-LICENSE.txt") -Algorithm SHA256).Hash.ToLowerInvariant())
  $provenance | ConvertTo-Json -Depth 8 | Set-Content $provenancePath -Encoding utf8
  @"
GraphCode provider attributions

Winghostty: https://github.com/coneilen/winghostty
$wingLicense

zmx: https://github.com/coneilen/zmx
$zmxLicense
"@ | Set-Content (Join-Path $root "THIRD-PARTY-NOTICES.txt") -Encoding utf8
  Copy-Item (Join-Path $shellRoot "provider-pins.json") (Join-Path $root "provider-pins.json") -Force
  Write-PackageSetup $root
  Write-Metadata $root $Version
  if ($SignCertificate) {
    $signtool = if ($SignToolPath) { (Resolve-Path $SignToolPath).Path } else { (Get-Command signtool.exe -ErrorAction SilentlyContinue).Source }
    Require ([bool]$signtool) "signtool.exe was not found; signed packaging requires Windows SDK"
    Get-PackageCodeFiles $root | ForEach-Object {
      Sign-PackageFile $signtool $_.FullName
    }
    Set-Content (Join-Path $root "SIGNATURES.txt") -Value "Signed with certificate thumbprint $SignCertificate" -Encoding utf8
    $signedProvenance = Get-Content $provenancePath -Raw | ConvertFrom-Json
    $signedProvenance.zmx.sha256 = (Get-FileHash (Join-Path $root "bin\zmx.exe") -Algorithm SHA256).Hash.ToLowerInvariant()
    $signedProvenance | ConvertTo-Json -Depth 8 | Set-Content $provenancePath -Encoding utf8
  }
  $manifest = [ordered]@{ schemaVersion = 1; files = @(Get-Manifest $root) }
  $manifest | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $root "manifest.json") -Encoding utf8
  $lines = $manifest.files | ForEach-Object { "$($_.sha256)  $($_.path)" }
  $lines | Set-Content (Join-Path $root "checksums.sha256") -Encoding utf8
  if ($SignCertificate) {
    $catalogPath = Join-Path $root "package.cat"
    New-FileCatalog -Path $root -CatalogFilePath $catalogPath -CatalogVersion 2.0 | Out-Null
    Sign-PackageFile $signtool $catalogPath
  }
  Verify-PackageContents $root $SignCertificate | Out-Null
  $archive = Join-Path $out "GraphCode-$Version-windows-x86_64.zip"
  if (Test-Path $archive) { Remove-Item $archive -Force }
  [IO.Compression.ZipFile]::CreateFromDirectory($root, $archive, [IO.Compression.CompressionLevel]::Optimal, $true)
  $final = Join-Path $out "GraphCode-$Version-windows-x86_64"
  if (Test-Path $final) { Remove-Item $final -Recurse -Force }
  Move-Item $root $final
  Remove-Item $staging -Recurse -Force
  $artifactHash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
  Set-Content (Join-Path $out "GraphCode-$Version-windows-x86_64.zip.sha256") "$artifactHash  $(Split-Path $archive -Leaf)" -Encoding ascii
  Write-Output $archive
}

switch ($Command) {
  "Build" { Build-Package }
  "Verify" { try { $root = Open-Package $Package; Verify-PackageContents $root | Out-Null; Write-Output "Package verification: PASS" } finally { Close-Package } }
  "Install" { Install-Package $false }
  "Upgrade" { Install-Package $true }
  "Uninstall" { Uninstall-Package }
  "CleanMachine" { $RemoveUserData = $true; Uninstall-Package; Remove-Item (Join-Path $env:ProgramData "GraphCode") -Recurse -Force -ErrorAction SilentlyContinue }
}
