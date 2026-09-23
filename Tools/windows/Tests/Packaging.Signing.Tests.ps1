[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$packageScript = Join-Path $repoRoot "Tools\windows\package.ps1"
$fixture = Join-Path $repoRoot ".build\packaging-signing-$([guid]::NewGuid())"
$tokens = $null
$errors = $null
$asts = @(foreach ($path in @($packageScript, (Join-Path $repoRoot "Tools\windows\PackageRuntime.ps1"))) {
  [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  if ($errors.Count) { throw "Packaging script has parse errors: $errors" }
})
foreach ($name in @("Fail", "Require", "Get-Manifest", "Normalize-ManifestPath",
    "Get-ActualPackageFiles", "Verify-Manifest", "Get-PackageCodeFiles", "Verify-SignedPackage",
    "Verify-PackageContents", "Sign-PackageFile", "Move-InstallDirectory", "Install-Package", "Copy-Tree")) {
  $definition = $asts | ForEach-Object { $_.Find({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true) } | Where-Object { $_ } | Select-Object -First 1
  if (-not $definition) { throw "Packaging helper is missing: $name" }
  . ([scriptblock]::Create($definition.Extent.Text))
}

function Assert-Rejected([string] $label, [scriptblock] $action, [string] $message) {
  try { & $action | Out-Null } catch {
    if ($_.Exception.Message -notmatch [regex]::Escape($message)) {
      throw "$label failed for the wrong reason: $_"
    }
    return
  }
  throw "RED: $label was accepted"
}
function Write-TestManifest([string] $root) {
  @{ schemaVersion = 1; files = @(Get-Manifest $root) } |
    ConvertTo-Json -Depth 10 | Set-Content (Join-Path $root "manifest.json") -Encoding utf8
}
function New-TestPackage {
  $root = Join-Path $fixture ([guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Path (Join-Path $root "bin") -Force | Out-Null
  Set-Content (Join-Path $root "bin\graphcode.exe") "executable fixture"
  Set-Content (Join-Path $root "bin\swiftCore.dll") "runtime fixture"
  Set-Content (Join-Path $root "GraphCode-Setup.ps1") "# setup fixture"
  Set-Content (Join-Path $root "metadata.json") '{"signing":"signed","version":"1.2.3"}'
  Set-Content (Join-Path $root "SIGNATURES.txt") "publisher fixture"
  Set-Content (Join-Path $root "checksums.sha256") "checksum fixture"
  Write-TestManifest $root
  New-FileCatalog -Path $root -CatalogFilePath (Join-Path $root "package.cat") `
    -CatalogVersion 2.0 | Out-Null
  return $root
}

# Only the OS trust decision is simulated. Catalog creation and hash validation
# use the native Windows cmdlets; no certificate store is changed.
$TrustedSignerThumbprint = "A" * 40
$SignToolPath = Join-Path $fixture "no-sdk-signtool.exe"
$signatureMode = "valid"
function Get-AuthenticodeSignature([string] $FilePath) {
  $catalog = [IO.Path]::GetExtension($FilePath) -eq ".cat"
  $setup = [IO.Path]::GetExtension($FilePath) -eq ".ps1"
  $invalid = ($catalog -and $signatureMode -eq "invalid-catalog") -or
    ($setup -and $signatureMode -eq "invalid-setup") -or
    (-not $catalog -and -not $setup -and $signatureMode -eq "invalid-executable")
  $wrongSigner = ($catalog -and $signatureMode -eq "wrong-catalog-signer") -or
    ($setup -and $signatureMode -eq "wrong-setup-signer") -or
    (-not $catalog -and -not $setup -and $signatureMode -eq "wrong-executable-signer")
  [pscustomobject]@{
    Status = if ($invalid) { "NotTrusted" } else { "Valid" }
    SignerCertificate = [pscustomobject]@{
      Thumbprint = if ($wrongSigner) { "B" * 40 } else { "A" * 40 }
    }
  }
}

try {
  $signed = [pscustomobject]@{ signing = "signed" }
  $unsigned = [pscustomobject]@{ signing = "UNSIGNED (not code signed)" }
  $root = New-TestPackage
  Assert-Rejected "rewritten DLL and manifest" {
    Add-Content (Join-Path $root "bin\swiftCore.dll") "tampered"
    Write-TestManifest $root
    Verify-Manifest $root | Out-Null
    Verify-SignedPackage $root $signed
  } "catalog contents do not match"

  $root = New-TestPackage
  Verify-Manifest $root | Out-Null
  Verify-SignedPackage $root $signed
  $nativeSignature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature `
    -FilePath (Join-Path $root "package.cat")
  if ($nativeSignature.Status -ne "NotSigned") {
    throw "The deterministic catalog fixture unexpectedly has a real signature"
  }
  & {
    function Get-AuthenticodeSignature([string] $FilePath) {
      Microsoft.PowerShell.Security\Get-AuthenticodeSignature -FilePath $FilePath
    }
    Assert-Rejected "native unsigned catalog" {
      Verify-SignedPackage $root $signed
    } "catalog Authenticode verification failed"
  }
  foreach ($case in @(
      @{ mode = "invalid-catalog"; message = "catalog Authenticode verification failed" },
      @{ mode = "wrong-catalog-signer"; message = "catalog publisher does not match" },
      @{ mode = "invalid-executable"; message = "Authenticode verification failed: graphcode.exe" },
      @{ mode = "wrong-executable-signer"; message = "code publisher does not match: graphcode.exe" },
      @{ mode = "invalid-setup"; message = "Authenticode verification failed: GraphCode-Setup.ps1" },
      @{ mode = "wrong-setup-signer"; message = "code publisher does not match: GraphCode-Setup.ps1" }
    )) {
    $signatureMode = $case.mode
    Assert-Rejected $case.mode { Verify-SignedPackage $root $signed } $case.message
  }
  $signatureMode = "valid"
  $TrustedSignerThumbprint = $null
  Assert-Rejected "publisher inferred from package" {
    Verify-SignedPackage $root $signed
  } "trusted publisher thumbprint is required"
  $TrustedSignerThumbprint = "invalid"
  Assert-Rejected "malformed trusted thumbprint" {
    Verify-SignedPackage $root $signed
  } "trusted publisher thumbprint is invalid"
  $TrustedSignerThumbprint = ("A" * 40).ToLowerInvariant()
  Verify-SignedPackage $root $signed

  foreach ($file in @("metadata.json", "SIGNATURES.txt", "checksums.sha256", "manifest.json", "GraphCode-Setup.ps1")) {
    $root = New-TestPackage
    Add-Content (Join-Path $root $file) "tampered"
    Assert-Rejected "tampered $file" {
      Verify-SignedPackage $root $signed
    } "catalog contents do not match"
  }
  $root = New-TestPackage
  Set-Content (Join-Path $root "extra.txt") "not cataloged"
  Write-TestManifest $root
  Assert-Rejected "extra file with rewritten manifest" {
    Verify-SignedPackage $root $signed
  } "catalog contents do not match"
  $root = New-TestPackage
  Remove-Item (Join-Path $root "bin\swiftCore.dll")
  Assert-Rejected "missing cataloged file" {
    Verify-SignedPackage $root $signed
  } "catalog contents do not match"
  $root = New-TestPackage
  Remove-Item (Join-Path $root "package.cat")
  Assert-Rejected "missing catalog" { Verify-SignedPackage $root $signed } "signed package has no catalog"
  Assert-Rejected "signing metadata downgrade" {
    Verify-SignedPackage $root $unsigned
  } "trusted publisher verification requires a signed package"

  $TrustedSignerThumbprint = $null
  Verify-SignedPackage $root $unsigned
  $root = New-TestPackage
  Assert-Rejected "catalog in unsigned package" {
    Verify-SignedPackage $root $unsigned
  } "unsigned package contains a signing catalog"
  $TrustedSignerThumbprint = "A" * 40
  Remove-Item (Join-Path $root "package.cat")
  New-FileCatalog -Path $root -CatalogFilePath (Join-Path $root "package.cat") `
    -CatalogVersion 1.0 -WarningAction SilentlyContinue | Out-Null
  Assert-Rejected "SHA1 catalog" { Verify-SignedPackage $root $signed } "catalog must use SHA256"

  $root = New-TestPackage
  $hidden = Join-Path $root "bin\hidden.dll"
  Set-Content $hidden "hidden runtime fixture"
  (Get-Item $hidden).Attributes = [IO.FileAttributes]::Hidden
  Assert-Rejected "unmanifested hidden payload" {
    Verify-Manifest $root
  } "manifest file set differs"
  Write-TestManifest $root
  Verify-Manifest $root | Out-Null
  Remove-Item (Join-Path $root "package.cat")
  New-FileCatalog -Path $root -CatalogFilePath (Join-Path $root "package.cat") `
    -CatalogVersion 2.0 | Out-Null
  Verify-SignedPackage $root $signed

  $SignCertificate = "A" * 40
  $SignTimestampUrl = "https://timestamp.invalid"
  $signingExitCode = 0
  function Invoke-TestSigner {
    $script:signingArguments = @($args)
    $global:LASTEXITCODE = $signingExitCode
  }
  $signedPath = Join-Path $fixture "space path\package.cat"
  Sign-PackageFile "Invoke-TestSigner" $signedPath
  $expectedArguments = @("sign", "/sha1", $SignCertificate, "/fd", "sha256",
    "/tr", $SignTimestampUrl, "/td", "sha256", $signedPath)
  if (($signingArguments -join "`n") -cne ($expectedArguments -join "`n")) {
    throw "SHA-256 signing/timestamp arguments or path boundaries were lost"
  }
  $setupFile = @(Get-PackageCodeFiles $root | Where-Object Name -eq "GraphCode-Setup.ps1")
  if ($setupFile.Count -ne 1) { throw "Standalone setup was excluded from package code signing" }
  Sign-PackageFile "Invoke-TestSigner" $setupFile[0].FullName
  if ($signingArguments[-1] -ne $setupFile[0].FullName) { throw "Setup script signing arguments were lost" }
  $signingExitCode = 1
  Assert-Rejected "signing failure" {
    Sign-PackageFile "Invoke-TestSigner" $signedPath
  } "signtool failed for package.cat"
  $global:LASTEXITCODE = 0

  # Exercise the actual install transaction without changing tasks, PATH, or
  # shortcuts. The copied payload is corrupted after source verification.
  $Package = New-TestPackage
  $InstallRoot = Join-Path $fixture "existing-install"
  New-Item -ItemType Directory -Path $InstallRoot | Out-Null
  Set-Content (Join-Path $InstallRoot "sentinel.txt") "previous install"
  $versionWasProvided = $false
  $NoScheduledTask = $false
  $copyTree = (Get-Command Copy-Tree).ScriptBlock
  function Copy-Tree([string] $source, [string] $destination) {
    & $copyTree $source $destination
    Add-Content (Join-Path $destination "bin\swiftCore.dll") "modified during copy"
    Write-TestManifest $destination
  }
  function Open-Package([string] $path) { return $path }
  function Close-Package { $script:closedPackage = $true }
  function Assert-Package([string] $root) {
    Get-Content (Join-Path $root "metadata.json") -Raw | ConvertFrom-Json
  }
  function Read-ProviderProvenance { }
  function Stop-InstalledDaemon { throw "Installation changed the daemon before staged verification" }
  function Save-Shortcut { throw "Installation touched shortcuts before staged verification" }
  Assert-Rejected "staging tamper" { Install-Package $true } "catalog contents do not match"
  if (-not $closedPackage -or
      (Get-Content (Join-Path $InstallRoot "sentinel.txt")) -cne "previous install" -or
      @(Get-ChildItem $fixture -Directory -Filter ".GraphCode-*").Count -ne 0) {
    throw "Staged verification failure did not preserve the installation and clean up"
  }

  Write-Output "Signed package catalog integrity and publisher contracts: PASS"
} finally {
  Remove-Item -LiteralPath $fixture -Recurse -Force
}
