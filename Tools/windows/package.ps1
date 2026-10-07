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
  [string] $ReleaseTag,
  [ValidatePattern("^[0-9a-fA-F]{40}$")]
  [string] $ReleaseTagCommit,
  [ValidatePattern("^[0-9a-fA-F]{40}$")]
  [string] $SourceCommit,
  [ValidateSet("true", "false")]
  [string] $ReleaseTagMatchesSource,
  [ValidateSet("true", "false")]
  [string] $TagMismatchAllowed,
  [switch] $Local,
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
$localSourceCommit = $null
$localSourceTreeDirty = $false
$worktreesDeferred = "false"
if ($Local) {
  if ($Command -ne "Build") {
    throw "GraphCode packaging: -Local is only valid with -Command Build"
  }
  if ($versionWasProvided) {
    throw "GraphCode packaging: -Local generates its version from HEAD; do not pass -Version"
  }
  $resolvedCommit = & git -C $repoRoot rev-parse --verify HEAD 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "GraphCode packaging: could not resolve the local source commit"
  }
  $localSourceCommit = ([string] (@($resolvedCommit) | Select-Object -Last 1)).Trim().ToLowerInvariant()
  if ($localSourceCommit -notmatch "^[0-9a-f]{40}$") {
    throw "GraphCode packaging: HEAD resolved to invalid commit '$localSourceCommit'"
  }
  $localSourceTreeDirty = @(& git -C $repoRoot status --porcelain).Count -gt 0
  if ($LASTEXITCODE -ne 0) {
    throw "GraphCode packaging: could not inspect the local source tree"
  }
  $Version = "0.0.0-local+$($localSourceCommit.Substring(0, 12))"
} elseif (-not $Version) {
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
function Invoke-ShellQuery([string] $root, [string] $argument) {
  $stdout = Join-Path ([IO.Path]::GetTempPath()) "graphcode-shell-$([guid]::NewGuid()).out"
  $stderr = Join-Path ([IO.Path]::GetTempPath()) "graphcode-shell-$([guid]::NewGuid()).err"
  try {
    $process = Start-Process -FilePath (Join-Path $root "bin\graphcode-windows.exe") `
      -ArgumentList $argument -Wait -PassThru `
      -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $errorText = if (Test-Path -LiteralPath $stderr) {
      $rawError = Get-Content -LiteralPath $stderr -Raw
      if ($null -eq $rawError) { "" } else { $rawError.Trim() }
    } else {
      ""
    }
    Require ($process.ExitCode -eq 0) `
      "graphcode-windows.exe $argument failed with exit code $($process.ExitCode): $errorText"
    $rawOutput = Get-Content -LiteralPath $stdout -Raw
    Require ($null -ne $rawOutput) "graphcode-windows.exe $argument produced no output"
    return $rawOutput.Trim()
  } finally {
    Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
  }
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
  $signing = if ($Local) {
    "UNSIGNED LOCAL DEVELOPMENT PACKAGE (not code signed)"
  } elseif ($SignCertificate) {
    "signed"
  } else {
    "UNSIGNED (not code signed)"
  }
  $sourceProvenance = if ($Local) {
    [ordered]@{
      kind = "local"
      sourceCommit = $localSourceCommit
      sourceTreeDirty = $localSourceTreeDirty
    }
  } else {
    [ordered]@{
      kind = "release-tag"
      tag = $ReleaseTag
      tagCommit = $ReleaseTagCommit.ToLowerInvariant()
      sourceCommit = $SourceCommit.ToLowerInvariant()
      tagMatchesSource = ($ReleaseTagMatchesSource -eq "true")
      tagMismatchAllowed = ($TagMismatchAllowed -eq "true")
    }
  }
  $metadata = [ordered]@{
    schemaVersion = 1
    product = "GraphCode Windows"
    version = $version
    packageKind = if ($Local) { "local-development" } else { "release-candidate" }
    previewFeatures = [ordered]@{
      worktreesDeferred = ($worktreesDeferred -eq "true")
    }
    platform = "windows-x86_64"
    executables = [ordered]@{ shell = "bin/graphcode-windows.exe"; daemon = "bin/graphcoded.exe"; cli = "bin/graphcode.exe"; zmx = "bin/zmx.exe" }
    hostAssets = @(Get-ChildItem -LiteralPath (Join-Path $root "bin") -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match "winghostty|host" } | ForEach-Object { "bin/$($_.Name)" })
    providerPins = $pins
    signing = $signing
    sourceProvenance = $sourceProvenance
    userData = "%USERPROFILE%/.graphcode (preserved by uninstall)"
    providerProvenance = "provider-provenance.json"
    setup = "GraphCode-Setup.ps1"
  }
  $metadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root "metadata.json") -Encoding utf8
  @"
GraphCode Windows distribution
Version: $version
Signing: $($metadata.signing)

$(if ($Local) {
  "This is a local development artifact from source commit $localSourceCommit. It cannot be published."
} else {
  "This artifact is not code signed unless an explicit signing certificate was supplied."
})
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
  if ($Local) {
    Require (-not ($ReleaseTag -or $ReleaseTagCommit -or $SourceCommit -or
        $ReleaseTagMatchesSource -or $TagMismatchAllowed)) `
      "local packaging does not accept release-tag provenance"
    Require (-not $SignCertificate) "local packaging is always unsigned and does not accept -SignCertificate"
    Require (-not $TrustedSignerThumbprint) `
      "local packaging is always unsigned and does not accept -TrustedSignerThumbprint"
  } else {
    Require ($Version -and $Version -notin @("dev", "0.0.0-dev")) "release packaging requires a non-dev package version"
    Require ([bool] $ReleaseTag) "release packaging requires -ReleaseTag provenance"
    Require ([bool] $ReleaseTagCommit) "release packaging requires -ReleaseTagCommit provenance"
    Require ([bool] $SourceCommit) "release packaging requires -SourceCommit provenance"
    Require ([bool] $ReleaseTagMatchesSource) "release packaging requires -ReleaseTagMatchesSource provenance"
    Require ([bool] $TagMismatchAllowed) "release packaging requires -TagMismatchAllowed provenance"
  }
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
      (Join-Path $repoRoot ".build\windows\release"),
      (Join-Path $repoRoot ".build\windows\release-artifact"),
      (Join-Path $repoRoot ".build\x86_64-unknown-windows-msvc\release")
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
      $providerArtifact = Join-Path $spec.root ($spec.source -replace "/", "\")
      Remove-Item -LiteralPath $providerArtifact -Force -ErrorAction SilentlyContinue
      Push-Location $spec.root
      try {
        $zmxCache = $null
        $buildArgs = if ($spec.name -eq "winghostty") {
          @("build", "-Demit-win32-host=true")
        } else {
          # uucode runs its generator from the dependency directory. Zig 0.16
          # otherwise resolves a long cache executable path from that cwd and
          # fails to launch the generated tool.
          $zmxCache = Join-Path $repoRoot ".build\zmx-package-cache-$([guid]::NewGuid())"
          @("build", "-Dtarget=x86_64-windows-gnu", "--cache-dir", $zmxCache)
        }
        try {
          & $zig @buildArgs
          Require ($LASTEXITCODE -eq 0) "$($spec.name) pinned rebuild failed"
        } finally {
          if ($spec.name -eq "zmx" -and $zmxCache) {
            Remove-Item -LiteralPath $zmxCache -Recurse -Force -ErrorAction SilentlyContinue
          }
        }
      } finally { Pop-Location }
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
    Require ($WinghosttyRoot -and $Zig0152) "package build requires pinned Winghostty root and Zig 0.15.2"
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
  $reportedVersion = Invoke-ShellQuery $root "--version"
  Require ($reportedVersion -eq $Version) "graphcode-windows.exe reports $reportedVersion, expected $Version"
  $reportedWorktreeState = Invoke-ShellQuery $root "--worktrees-preview-state"
  $expectedWorktreeState = if ($worktreesDeferred -eq "true") { "deferred" } else { "available" }
  Require ($reportedWorktreeState -eq $expectedWorktreeState) `
    "graphcode-windows.exe reports Worktrees $reportedWorktreeState, expected $expectedWorktreeState"
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
  "Verify" {
    try {
      $root = Open-Package $Package
      Verify-PackageContents $root | Out-Null
      $metadata = Get-Content -LiteralPath (Join-Path $root "metadata.json") -Raw | ConvertFrom-Json
      Require ([bool] $metadata.previewFeatures.worktreesDeferred -eq $false) `
        "package metadata contradicts its Worktrees preview policy"
      if ([string] $metadata.packageKind -eq "local-development") {
        $provenance = $metadata.sourceProvenance
        $commit = [string] $provenance.sourceCommit
        Require ([string] $metadata.signing -match "^UNSIGNED LOCAL DEVELOPMENT PACKAGE") `
          "local package metadata must declare the unsigned local signing state"
        Require ([string] $provenance.kind -eq "local" -and $commit -match "^[0-9a-f]{40}$") `
          "local package metadata must contain an exact source commit"
        Require ([string] $metadata.version -eq "0.0.0-local+$($commit.Substring(0, 12))") `
          "local package version does not match its source commit"
        Write-Output "Package verification: PASS (LOCAL UNSIGNED source $commit)"
      } else {
        Write-Output "Package verification: PASS"
      }
    } finally { Close-Package }
  }
  "Install" { Install-Package $false }
  "Upgrade" { Install-Package $true }
  "Uninstall" { Uninstall-Package }
  "CleanMachine" { $RemoveUserData = $true; Uninstall-Package; Remove-Item (Join-Path $env:ProgramData "GraphCode") -Recurse -Force -ErrorAction SilentlyContinue }
}
