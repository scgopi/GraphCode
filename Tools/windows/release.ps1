<#
.SYNOPSIS
  Builds, labels, and optionally publishes the Windows release artifact.

.DESCRIPTION
  This is the single decision point between Tools/windows/package.ps1 and a
  GitHub release asset. It resolves a release tag to a package version, imports
  signing material when it is supplied in full, and refuses to let a build whose
  actual signing state contradicts the requested one reach a release.

  Signing is optional. With no signing material the run still succeeds and
  produces an artifact named and labeled as an unsigned development build, which
  cannot be published without an explicit opt-in.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $Tag,
  [string] $OutputDirectory,
  [string] $WinghosttyRoot = $env:GRAPHCODE_WINGHOSTTY_ROOT,
  [string] $ZmxRoot = $env:GRAPHCODE_ZMX_ROOT,
  [string] $Zig0152 = $env:GRAPHCODE_ZIG0152,
  [string] $Zig0160 = $env:GRAPHCODE_ZIG0160,
  [string] $SigningCertificateBase64 = $env:GRAPHCODE_SIGNING_CERTIFICATE,
  [string] $SigningCertificatePassword = $env:GRAPHCODE_SIGNING_CERTIFICATE_PASSWORD,
  [string] $SigningThumbprint = $env:GRAPHCODE_SIGNING_THUMBPRINT,
  [string] $SignTimestampUrl = $env:GRAPHCODE_SIGNING_TIMESTAMP_URL,
  [string] $PackageScript,
  [string] $GitHubCli = "gh",
  [switch] $Publish,
  [switch] $AllowUnsignedPublish
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if (-not $PackageScript) { $PackageScript = Join-Path $repoRoot "Tools\windows\package.ps1" }
if (-not (Test-Path -LiteralPath $PackageScript -PathType Leaf)) {
  throw "packaging script was not found: $PackageScript"
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot ".build\windows\release-publish" }

$UnsignedLabelPrefix = "UNSIGNED"
$importedCertificatePath = $null
$certificateFile = $null

function Resolve-ReleaseVersion([string] $tag) {
  $candidate = $tag.Trim()
  if ($candidate -notmatch "^v?([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.]*)?)$") {
    throw "release tag does not name a publishable version: '$tag'"
  }
  $version = $Matches[1]
  if ($version -in @("0.0.0-dev") -or $version -match "(?i)(^|[-.])dev([-.]|$)") {
    throw "release tag does not name a publishable version: '$tag'"
  }
  return $version
}

function Resolve-SigningRequest {
  $supplied = @(
    @{ name = "certificate"; value = $SigningCertificateBase64 },
    @{ name = "certificate password"; value = $SigningCertificatePassword },
    @{ name = "certificate thumbprint"; value = $SigningThumbprint }
  )
  $present = @($supplied | Where-Object { $_.value })
  if ($present.Count -eq 0) {
    if ($SignTimestampUrl) {
      Write-Warning "A timestamp service was configured without signing material; building unsigned."
    }
    return $false
  }
  if ($present.Count -ne $supplied.Count) {
    $missing = @($supplied | Where-Object { -not $_.value } | ForEach-Object { $_.name })
    throw "incomplete signing material: $($missing -join ', ') was not supplied. " +
      "Supply all of the signing secrets or none of them; a partial configuration is never " +
      "downgraded to an unsigned build."
  }
  if ($SigningThumbprint -notmatch "^[0-9a-fA-F]{40}$") {
    throw "signing certificate thumbprint must be 40 hexadecimal characters"
  }
  if ($SignTimestampUrl -and $SignTimestampUrl -notmatch "^https://") {
    throw "signing timestamp service must be an https URL"
  }
  return $true
}

function Import-SigningCertificate([string] $staging) {
  $script:certificateFile = Join-Path $staging "signing-$([guid]::NewGuid()).pfx"
  try {
    $bytes = [Convert]::FromBase64String($SigningCertificateBase64)
  } catch {
    throw "signing certificate is not valid base64-encoded PFX content"
  }
  [IO.File]::WriteAllBytes($script:certificateFile, $bytes)
  $password = ConvertTo-SecureString $SigningCertificatePassword -AsPlainText -Force
  $imported = Import-PfxCertificate -FilePath $script:certificateFile `
    -CertStoreLocation "Cert:\CurrentUser\My" -Password $password
  $script:importedCertificatePath = "Cert:\CurrentUser\My\$($imported.Thumbprint)"
  if ($imported.Thumbprint -ne $SigningThumbprint.ToUpperInvariant()) {
    throw "the imported signing certificate thumbprint does not match the declared thumbprint"
  }
  if (-not $imported.HasPrivateKey) {
    throw "the imported signing certificate has no private key"
  }
  return $imported.Thumbprint
}

function Invoke-Packaging([string[]] $arguments, [string] $activity) {
  & pwsh -NoProfile -File $PackageScript @arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Windows packaging ($activity) failed with exit code $LASTEXITCODE"
  }
}

$version = Resolve-ReleaseVersion $Tag
$signingRequested = Resolve-SigningRequest
if ($Publish -and -not $signingRequested -and -not $AllowUnsignedPublish) {
  throw "refusing to publish an unsigned artifact; pass -AllowUnsignedPublish to attach a " +
    "clearly labeled development build to release $Tag"
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$packages = Join-Path $OutputDirectory "packages"
$publishDirectory = Join-Path $OutputDirectory "publish"
$staging = Join-Path $OutputDirectory "staging"
foreach ($directory in @($publishDirectory, $staging)) {
  if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
New-Item -ItemType Directory -Force -Path $packages, $publishDirectory, $staging | Out-Null

try {
  $thumbprint = $null
  if ($signingRequested) { $thumbprint = Import-SigningCertificate $staging }

  $buildArguments = @("-Command", "Build", "-OutputDirectory", $packages, "-Version", $version)
  foreach ($pair in @(
      @{ name = "WinghosttyRoot"; value = $WinghosttyRoot },
      @{ name = "ZmxRoot"; value = $ZmxRoot },
      @{ name = "Zig0152"; value = $Zig0152 },
      @{ name = "Zig0160"; value = $Zig0160 })) {
    if ($pair.value) { $buildArguments += @("-$($pair.name)", $pair.value) }
  }
  if ($signingRequested) {
    $buildArguments += @("-SignCertificate", $thumbprint)
    if ($SignTimestampUrl) { $buildArguments += @("-SignTimestampUrl", $SignTimestampUrl) }
  }
  Invoke-Packaging $buildArguments "build"

  $packageName = "GraphCode-$version-windows-x86_64"
  $archive = Join-Path $packages "$packageName.zip"
  $packageRoot = Join-Path $packages $packageName
  foreach ($produced in @($archive, $packageRoot)) {
    if (-not (Test-Path -LiteralPath $produced)) {
      throw "Windows packaging did not produce $produced"
    }
  }

  # The package states its own signing state. Publishing is allowed only when
  # that statement agrees with what this run actually did.
  $metadata = Get-Content -LiteralPath (Join-Path $packageRoot "metadata.json") -Raw | ConvertFrom-Json
  $reported = [string] $metadata.signing
  $expectedSigned = $reported -eq "signed"
  $expectedUnsigned = $reported.StartsWith($UnsignedLabelPrefix)
  if ($signingRequested -ne $expectedSigned -or ($signingRequested -eq $expectedUnsigned)) {
    throw "package signing state '$reported' contradicts this run " +
      "(signing requested: $signingRequested); refusing to publish"
  }
  if ([string] $metadata.version -ne $version) {
    throw "package reports version '$($metadata.version)', expected '$version'"
  }

  $verifyArguments = @("-Command", "Verify", "-Package", $archive)
  if ($signingRequested) { $verifyArguments += @("-TrustedSignerThumbprint", $thumbprint) }
  Invoke-Packaging $verifyArguments "verification"

  # The published name mirrors the versionless macOS DMG so that
  # releases/latest/download keeps working, and an unsigned development build
  # can never occupy that name.
  $assetName = if ($signingRequested) {
    "graphcode-windows-x86_64.zip"
  } else {
    "graphcode-windows-x86_64-unsigned.zip"
  }
  $asset = Join-Path $publishDirectory $assetName
  Copy-Item -LiteralPath $archive -Destination $asset -Force
  $assetHash = (Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash.ToLowerInvariant()
  $checksum = "$asset.sha256"
  Set-Content -LiteralPath $checksum -Value "$assetHash  $assetName" -Encoding ascii
  Copy-Item -LiteralPath (Join-Path $packageRoot "metadata.json") `
    -Destination (Join-Path $publishDirectory "metadata.json") -Force

  $published = $false
  if ($Publish) {
    & $GitHubCli release upload $Tag $asset $checksum --clobber
    if ($LASTEXITCODE -ne 0) {
      throw "release asset upload failed with exit code $LASTEXITCODE"
    }
    $published = $true
  }

  $summary = [ordered]@{
    schemaVersion = 1
    tag = $Tag
    version = $version
    signed = $signingRequested
    signing = $reported
    asset = $assetName
    sha256 = $assetHash
    published = $published
  }
  $summary | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $publishDirectory "release-summary.json") -Encoding utf8

  $state = if ($signingRequested) {
    "signed with certificate $thumbprint"
  } else {
    "$reported - not publishable as a release artifact without -AllowUnsignedPublish"
  }
  Write-Host "GraphCode $version for Windows: $state"
  Write-Host "Asset: $asset"
  Write-Host "SHA-256: $assetHash"
  Write-Host "Published to $Tag`: $published"
  if ($env:GITHUB_STEP_SUMMARY) {
    @(
      "### GraphCode Windows $version",
      "",
      "| Field | Value |",
      "| --- | --- |",
      "| Tag | ``$Tag`` |",
      "| Signing | ``$reported`` |",
      "| Asset | ``$assetName`` |",
      "| SHA-256 | ``$assetHash`` |",
      "| Published | ``$published`` |"
    ) | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
  }
  Write-Output $asset
} finally {
  if ($importedCertificatePath -and (Test-Path -LiteralPath $importedCertificatePath)) {
    Remove-Item -LiteralPath $importedCertificatePath -Force -ErrorAction SilentlyContinue
  }
  if ($certificateFile -and (Test-Path -LiteralPath $certificateFile)) {
    Remove-Item -LiteralPath $certificateFile -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $staging) {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
  }
}
