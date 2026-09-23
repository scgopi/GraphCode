[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$releaseScript = Join-Path $repoRoot "Tools\windows\release.ps1"
if (-not (Test-Path -LiteralPath $releaseScript -PathType Leaf)) {
  throw "Windows release orchestrator is missing: $releaseScript"
}
$tokens = $null
$errors = $null
foreach ($script in @($releaseScript, (Join-Path $repoRoot "Tools\windows\stage-swift-products.ps1"))) {
  if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
    throw "Windows release tooling is missing: $script"
  }
  [void] [Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
  if ($errors.Count) { throw "$script has parse errors: $errors" }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) "graphcode-release-$([guid]::NewGuid())"
$stubPackage = Join-Path $fixture "stub-package.ps1"
$stubGh = Join-Path $fixture "stub-gh.ps1"
$log = Join-Path $fixture "invocations.log"
$installedThumbprint = $null

function Reset-Log { Set-Content -LiteralPath $log -Value "" -Encoding utf8 }
function Get-Invocations {
  @(Get-Content -LiteralPath $log | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}
function Get-PackageCommands([string] $command) {
  @(Get-Invocations | Where-Object { $_.tool -eq "package" -and $_.Command -eq $command })
}
function Invoke-Release([hashtable] $parameters, [switch] $ExpectFailure, [string] $Message) {
  Reset-Log
  $arguments = @("-NoProfile", "-File", $releaseScript,
    "-PackageScript", $stubPackage, "-GitHubCli", $stubGh)
  foreach ($key in $parameters.Keys) {
    $value = $parameters[$key]
    if ($value -is [bool] -or $value -is [switch]) {
      if ($value) { $arguments += "-$key" }
    } else {
      $arguments += @("-$key", [string] $value)
    }
  }
  $output = & pwsh @arguments 2>&1 | Out-String
  $code = $LASTEXITCODE
  if ($ExpectFailure) {
    if ($code -eq 0) { throw "RED: release was accepted but should have failed: $output" }
    if ($Message -and $output -notmatch [regex]::Escape($Message)) {
      throw "release failed for the wrong reason (expected '$Message'): $output"
    }
  } elseif ($code -ne 0) {
    throw "release failed unexpectedly: $output"
  }
  return $output
}
function New-EphemeralCertificate {
  $key = [Security.Cryptography.RSA]::Create(2048)
  try {
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
      "CN=GraphCode release publishing fixture", $key,
      [Security.Cryptography.HashAlgorithmName]::SHA256,
      [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $usages = [Security.Cryptography.OidCollection]::new()
    [void] $usages.Add([Security.Cryptography.Oid]::new("1.3.6.1.5.5.7.3.3"))
    $request.CertificateExtensions.Add(
      [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($usages, $false))
    $request.CertificateExtensions.Add(
      [Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
        [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature, $true))
    return $request.CreateSelfSigned(
      [DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddHours(1))
  } finally { $key.Dispose() }
}

try {
  New-Item -ItemType Directory -Path $fixture -Force | Out-Null
  Reset-Log

  # The stub stands in for package.ps1: it records the exact argument vector and
  # produces a package whose metadata.json reports the signing state it was told
  # to report, so mislabeling can be simulated without a certificate.
  @'
[CmdletBinding()]
param(
  [string] $Command = "Build",
  [string] $InputDirectory,
  [string] $OutputDirectory,
  [string] $Package,
  [string] $InstallRoot,
  [string] $Version,
  [string] $SignCertificate,
  [string] $SignTimestampUrl,
  [string] $SignToolPath,
  [string] $TrustedSignerThumbprint,
  [string] $WinghosttyRoot,
  [string] $ZmxRoot,
  [string] $Zig0152,
  [string] $Zig0160
)
$ErrorActionPreference = "Stop"
$record = [ordered]@{ tool = "package" }
foreach ($entry in $PSBoundParameters.GetEnumerator()) { $record[$entry.Key] = [string] $entry.Value }
$record | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:GRAPHCODE_STUB_LOG
if ($env:GRAPHCODE_STUB_BUILD_FAILS -eq "1" -and $Command -eq "Build") {
  Write-Error "stub package build failure"
  exit 3
}
if ($Command -eq "Verify") {
  $root = $Package
  if ([IO.Path]::GetExtension($root) -eq ".zip") { $root = $root.Substring(0, $root.Length - 4) }
  $metadata = Get-Content -LiteralPath (Join-Path $root "metadata.json") -Raw | ConvertFrom-Json
  if ($TrustedSignerThumbprint -and $metadata.signing -ne "signed") {
    Write-Error "stub verify rejected an unsigned package under a trusted publisher pin"
    exit 4
  }
  Write-Output "Package verification: PASS"
  exit 0
}
$label = if ($env:GRAPHCODE_STUB_SIGNING_LABEL) {
  $env:GRAPHCODE_STUB_SIGNING_LABEL
} elseif ($SignCertificate) { "signed" } else { "UNSIGNED (development artifact; not code signed)" }
$root = Join-Path $OutputDirectory "GraphCode-$Version-windows-x86_64"
if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $root "bin") -Force | Out-Null
Set-Content -LiteralPath (Join-Path $root "bin\graphcode-windows.exe") "stub payload $Version"
[ordered]@{ schemaVersion = 1; version = $Version; platform = "windows-x86_64"; signing = $label } |
  ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root "metadata.json") -Encoding utf8
$archive = Join-Path $OutputDirectory "GraphCode-$Version-windows-x86_64.zip"
if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
[IO.Compression.ZipFile]::CreateFromDirectory($root, $archive)
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$archive.sha256" -Value "$hash  $(Split-Path $archive -Leaf)" -Encoding ascii
Write-Output $archive
'@ | Set-Content -LiteralPath $stubPackage -Encoding utf8

  @'
$ErrorActionPreference = "Stop"
([ordered]@{ tool = "gh"; arguments = @($args) } | ConvertTo-Json -Compress) |
  Add-Content -LiteralPath $env:GRAPHCODE_STUB_LOG
if ($env:GRAPHCODE_STUB_GH_FAILS -eq "1") { exit 7 }
exit 0
'@ | Set-Content -LiteralPath $stubGh -Encoding utf8

  $env:GRAPHCODE_STUB_LOG = $log
  $out = Join-Path $fixture "out"

  # 1. A release tag becomes the package version, and junk tags are refused
  #    before anything is built.
  Invoke-Release @{ Tag = "v0.1.74"; OutputDirectory = $out } | Out-Null
  $build = Get-PackageCommands "Build"
  if ($build.Count -ne 1 -or $build[0].Version -ne "0.1.74") {
    throw "stable tag did not resolve to its package version: $($build | ConvertTo-Json -Compress)"
  }
  Invoke-Release @{ Tag = "0.1.74-beta1"; OutputDirectory = $out } | Out-Null
  if ((Get-PackageCommands "Build")[0].Version -ne "0.1.74-beta1") {
    throw "prerelease tag did not resolve to its package version"
  }
  foreach ($tag in @("release", "v1.2", "v1.2.3.4", "v1.2.3 && whoami", "vdev", "v0.0.0-dev")) {
    Invoke-Release @{ Tag = $tag; OutputDirectory = $out } -ExpectFailure -Message "release tag" | Out-Null
    if (@(Get-Invocations).Count -ne 0) { throw "invalid tag '$tag' still invoked packaging" }
  }
  Write-Output "Release tag resolution and rejection: PASS"

  # 2. Without signing material the artifact is built, labeled unsigned, and
  #    never published.
  $output = Invoke-Release @{ Tag = "v0.1.74"; OutputDirectory = $out }
  $unsignedAsset = Join-Path $out "publish\graphcode-windows-x86_64-unsigned.zip"
  if (-not (Test-Path -LiteralPath $unsignedAsset)) {
    throw "unsigned build did not stage a clearly labeled asset: $output"
  }
  if (Test-Path -LiteralPath (Join-Path $out "publish\graphcode-windows-x86_64.zip")) {
    throw "unsigned build staged the signed asset name"
  }
  $sidecar = Get-Content -LiteralPath "$unsignedAsset.sha256" -Raw
  $expected = (Get-FileHash -LiteralPath $unsignedAsset -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($sidecar.Trim() -ne "$expected  graphcode-windows-x86_64-unsigned.zip") {
    throw "checksum sidecar does not describe the published asset name: $sidecar"
  }
  $summary = Get-Content -LiteralPath (Join-Path $out "publish\release-summary.json") -Raw | ConvertFrom-Json
  if ($summary.signed -ne $false -or $summary.signing -notmatch "^UNSIGNED" -or
    $summary.published -ne $false -or $summary.tag -ne "v0.1.74" -or $summary.version -ne "0.1.74") {
    throw "unsigned summary is not honest: $($summary | ConvertTo-Json -Compress)"
  }
  if (@(Get-Invocations | Where-Object tool -eq "gh").Count -ne 0) {
    throw "a build-only run contacted the release API"
  }
  if ((Get-PackageCommands "Verify").Count -ne 1 -or (Get-PackageCommands "Verify")[0].PSObject.Properties.Name -contains "TrustedSignerThumbprint") {
    throw "unsigned verification must not claim a trusted publisher pin"
  }
  Write-Output "Unsigned development artifact labeling: PASS"

  # 3. Publishing an unsigned artifact requires an explicit opt-in, and even
  #    then keeps the unsigned asset name.
  Invoke-Release @{ Tag = "v0.1.74"; OutputDirectory = $out; Publish = $true } `
    -ExpectFailure -Message "refusing to publish an unsigned artifact" | Out-Null
  if (@(Get-Invocations | Where-Object tool -eq "gh").Count -ne 0) {
    throw "a refused unsigned publish still contacted the release API"
  }
  Invoke-Release @{ Tag = "v0.1.74"; OutputDirectory = $out; Publish = $true; AllowUnsignedPublish = $true } | Out-Null
  $uploads = @(Get-Invocations | Where-Object tool -eq "gh")
  if ($uploads.Count -ne 1) { throw "explicit unsigned publish did not upload exactly once" }
  $arguments = @($uploads[0].arguments)
  if ($arguments[0] -ne "release" -or $arguments[1] -ne "upload" -or $arguments[2] -ne "v0.1.74" -or
    $arguments -notcontains "--clobber" -or
    ($arguments | Where-Object { $_ -like "*\graphcode-windows-x86_64-unsigned.zip" }).Count -ne 1 -or
    ($arguments | Where-Object { $_ -like "*\graphcode-windows-x86_64-unsigned.zip.sha256" }).Count -ne 1) {
    throw "unexpected upload argument vector: $($arguments -join ' ')"
  }
  if (($arguments | Where-Object { $_ -like "*graphcode-windows-x86_64.zip*" -and $_ -notlike "*unsigned*" }).Count -ne 0) {
    throw "an unsigned artifact was uploaded under the signed asset name"
  }
  Write-Output "Unsigned publication gate: PASS"

  # 4. Partial signing material is a hard failure, never a silent downgrade to
  #    an unsigned build.
  $certificate = New-EphemeralCertificate
  try {
    $password = [guid]::NewGuid().ToString("N")
    $pfxBytes = $certificate.Export(
      [Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $password)
    $pfx = [Convert]::ToBase64String($pfxBytes)
    $thumbprint = $certificate.Thumbprint
    $partials = @(
      @{ SigningThumbprint = $thumbprint },
      @{ SigningCertificateBase64 = $pfx },
      @{ SigningCertificateBase64 = $pfx; SigningCertificatePassword = $password },
      @{ SigningCertificateBase64 = $pfx; SigningThumbprint = $thumbprint },
      @{ SigningCertificatePassword = $password; SigningThumbprint = $thumbprint }
    )
    foreach ($partial in $partials) {
      $parameters = @{ Tag = "v0.1.74"; OutputDirectory = $out } + $partial
      Invoke-Release $parameters -ExpectFailure -Message "incomplete signing material" | Out-Null
      if (@(Get-Invocations).Count -ne 0) { throw "incomplete signing material still invoked packaging" }
    }
    Invoke-Release @{ Tag = "v0.1.74"; OutputDirectory = $out
      SigningCertificateBase64 = $pfx; SigningCertificatePassword = $password
      SigningThumbprint = ("A" * 40) } -ExpectFailure -Message "does not match" | Out-Null
    if (@(Get-Invocations).Count -ne 0) { throw "a thumbprint mismatch still invoked packaging" }
    Invoke-Release @{ Tag = "v0.1.74"; OutputDirectory = $out
      SigningCertificateBase64 = $pfx; SigningCertificatePassword = $password
      SigningThumbprint = "not-a-thumbprint" } -ExpectFailure -Message "thumbprint" | Out-Null
    Write-Output "Signing material completeness and thumbprint pinning: PASS"

    # 5. Complete signing material signs, verifies under the publisher pin, and
    #    publishes under the macOS-consistent versionless asset name.
    $installedThumbprint = $thumbprint
    Invoke-Release @{ Tag = "v0.1.74"; OutputDirectory = $out
      SigningCertificateBase64 = $pfx; SigningCertificatePassword = $password
      SigningThumbprint = $thumbprint
      SignTimestampUrl = "https://timestamp.example/rfc3161"
      Publish = $true } | Out-Null
    $installedThumbprint = $null
    $build = Get-PackageCommands "Build"
    if ($build.Count -ne 1 -or $build[0].SignCertificate -ne $thumbprint -or
      $build[0].SignTimestampUrl -ne "https://timestamp.example/rfc3161") {
      throw "signed build did not receive the pinned certificate and timestamp service"
    }
    $verify = Get-PackageCommands "Verify"
    if ($verify.Count -ne 1 -or $verify[0].TrustedSignerThumbprint -ne $thumbprint) {
      throw "signed package was not re-verified against the expected publisher"
    }
    $signedAsset = Join-Path $out "publish\graphcode-windows-x86_64.zip"
    if (-not (Test-Path -LiteralPath $signedAsset)) { throw "signed asset name was not produced" }
    if (Test-Path -LiteralPath (Join-Path $out "publish\graphcode-windows-x86_64-unsigned.zip")) {
      throw "a signed run left an unsigned asset name behind"
    }
    $summary = Get-Content -LiteralPath (Join-Path $out "publish\release-summary.json") -Raw | ConvertFrom-Json
    if ($summary.signed -ne $true -or $summary.signing -ne "signed" -or $summary.published -ne $true) {
      throw "signed summary is not honest: $($summary | ConvertTo-Json -Compress)"
    }
    if (@(Get-ChildItem "Cert:\CurrentUser\My" |
          Where-Object Thumbprint -eq $thumbprint).Count -ne 0) {
      throw "the imported signing certificate was left in the user store"
    }
    Write-Output "Signed publication path and certificate cleanup: PASS"

    # 6. A package whose own metadata contradicts the requested signing state is
    #    never published under either name.
    $env:GRAPHCODE_STUB_SIGNING_LABEL = "signed"
    Invoke-Release @{ Tag = "v0.1.74"; OutputDirectory = $out } `
      -ExpectFailure -Message "signing state" | Out-Null
    $env:GRAPHCODE_STUB_SIGNING_LABEL = "UNSIGNED (development artifact; not code signed)"
    $installedThumbprint = $thumbprint
    Invoke-Release @{ Tag = "v0.1.74"; OutputDirectory = $out
      SigningCertificateBase64 = $pfx; SigningCertificatePassword = $password
      SigningThumbprint = $thumbprint; Publish = $true } `
      -ExpectFailure -Message "signing state" | Out-Null
    $installedThumbprint = $null
    if (@(Get-Invocations | Where-Object tool -eq "gh").Count -ne 0) {
      throw "a mislabeled package was still uploaded"
    }
    $env:GRAPHCODE_STUB_SIGNING_LABEL = $null
    Write-Output "Package signing-state honesty gate: PASS"
  } finally {
    if ($installedThumbprint) {
      Get-ChildItem "Cert:\CurrentUser\My" |
        Where-Object Thumbprint -eq $installedThumbprint |
        Remove-Item -Force -ErrorAction SilentlyContinue
    }
    $certificate.Dispose()
  }

  # 7. A failed package build never reaches publication.
  $env:GRAPHCODE_STUB_BUILD_FAILS = "1"
  Invoke-Release @{ Tag = "v0.1.74"; OutputDirectory = $out; Publish = $true; AllowUnsignedPublish = $true } `
    -ExpectFailure -Message "packaging" | Out-Null
  if (@(Get-Invocations | Where-Object tool -eq "gh").Count -ne 0) {
    throw "a failed build still uploaded a release asset"
  }
  $env:GRAPHCODE_STUB_BUILD_FAILS = $null
  $env:GRAPHCODE_STUB_GH_FAILS = "1"
  Invoke-Release @{ Tag = "v0.1.74"; OutputDirectory = $out; Publish = $true; AllowUnsignedPublish = $true } `
    -ExpectFailure -Message "upload" | Out-Null
  $env:GRAPHCODE_STUB_GH_FAILS = $null
  Write-Output "Build and upload failure propagation: PASS"

  # 8. The workflow that drives this script keeps the same guarantees.
  $workflow = Get-Content -LiteralPath (Join-Path $repoRoot ".github\workflows\windows-release.yml") -Raw
  foreach ($required in @(
      "workflow_dispatch:", "Tools/windows/release.ps1", "actions/checkout@", "add-mask",
      "GRAPHCODE_SIGNING_CERTIFICATE", "GRAPHCODE_SIGNING_CERTIFICATE_PASSWORD",
      "GRAPHCODE_SIGNING_THUMBPRINT", "GRAPHCODE_SIGNING_TIMESTAMP_URL")) {
    if ($workflow -notmatch [regex]::Escape($required)) {
      throw "the release workflow no longer references $required"
    }
  }
  if ($workflow -match "(?m)^on:\s*$\s*(.*\n)*?\s*(push|release|schedule):") {
    throw "the release workflow gained an automatic publishing trigger"
  }
  foreach ($uses in [regex]::Matches($workflow, "(?m)uses:\s*(\S+)")) {
    if ($uses.Groups[1].Value -notmatch "@[0-9a-f]{40}$") {
      throw "the release workflow uses an unpinned action: $($uses.Groups[1].Value)"
    }
  }
  foreach ($default in [regex]::Matches($workflow, "(?ms)(publish|allow_unsigned_publish):.*?default:\s*(\S+)")) {
    if ($default.Groups[2].Value -notmatch "^(false|'false'|`"false`")$") {
      throw "a publishing input no longer defaults to false: $($default.Groups[0].Value)"
    }
  }
  Write-Output "Release workflow contract: PASS"

  # 9. The workflow's own invocation actually binds release.ps1's parameters.
  # Contract 8 only proves the workflow mentions the script. It cannot catch a
  # call that reaches the script with everything bound to the wrong parameter,
  # which is what array splatting does: @("-Tag", $tag) is passed positionally,
  # so "-Tag" itself lands in $Tag. This runs the workflow's real argument
  # construction against a probe that reports what it received.
  $workflowLines = $workflow -split "\r?\n"
  $packageBlock = $null
  for ($i = 0; $i -lt $workflowLines.Count; $i++) {
    if ($workflowLines[$i] -notmatch "^(?<indent>\s*)run:\s*\|\s*$") { continue }
    $keyIndent = $Matches["indent"].Length
    $body = @()
    for ($j = $i + 1; $j -lt $workflowLines.Count; $j++) {
      $line = $workflowLines[$j]
      if ($line.Trim().Length -eq 0) { $body += ""; continue }
      $indent = $line.Length - $line.TrimStart().Length
      if ($indent -le $keyIndent) { break }
      $body += $line
    }
    if (($body -join "`n") -match "release\.ps1") {
      $packageBlock = ($body -join "`n")
      break
    }
  }
  if (-not $packageBlock) { throw "the release workflow no longer invokes release.ps1 from a run block" }

  $probe = Join-Path $fixture "invocation-probe.ps1"
  $probeLog = Join-Path $fixture "invocation-probe.json"
  # Mirrors release.ps1's own parameter block, including the several optional
  # [string] parameters that let a positionally-splatted array bind silently
  # instead of failing outright.
  @'
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $Tag,
  [string] $OutputDirectory,
  [string] $WinghosttyRoot,
  [string] $ZmxRoot,
  [string] $Zig0152,
  [string] $Zig0160,
  [string] $PackageScript,
  [string] $GitHubCli = "gh",
  [switch] $Publish,
  [switch] $AllowUnsignedPublish
)
([ordered]@{
  tag = $Tag
  outputDirectory = $OutputDirectory
  publish = [bool] $Publish
  allowUnsignedPublish = [bool] $AllowUnsignedPublish
} | ConvertTo-Json -Compress) | Set-Content -LiteralPath $env:GRAPHCODE_PROBE_LOG -Encoding utf8
'@ | Set-Content -LiteralPath $probe -Encoding utf8

  # Run the workflow's own lines, with the script path redirected at the probe.
  $harness = $packageBlock -replace "\./Tools/windows/release\.ps1", "& `$probeScript"
  foreach ($case in @(
      @{ publish = "false"; unsigned = "false" },
      @{ publish = "true"; unsigned = "true" })) {
    Remove-Item -LiteralPath $probeLog -ErrorAction SilentlyContinue
    $env:GRAPHCODE_PROBE_LOG = $probeLog
    $env:RELEASE_TAG = "v0.1.74"
    $env:RELEASE_PUBLISH = $case.publish
    $env:RELEASE_ALLOW_UNSIGNED_PUBLISH = $case.unsigned
    $script = "`$probeScript = `"$probe`"`n" + $harness
    $scriptFile = Join-Path $fixture "invocation-harness.ps1"
    Set-Content -LiteralPath $scriptFile -Value $script -Encoding utf8
    $probeOutput = & pwsh -NoProfile -File $scriptFile 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $probeLog)) {
      throw "the release workflow's invocation of release.ps1 failed: $probeOutput"
    }
    $received = Get-Content -LiteralPath $probeLog -Raw | ConvertFrom-Json
    if ($received.tag -ne "v0.1.74") {
      throw ("the release workflow bound the wrong value to -Tag: '" + $received.tag +
        "' (array splatting passes elements positionally; use a hashtable)")
    }
    if ($received.outputDirectory -notlike "*release-publish*") {
      throw "the release workflow bound the wrong value to -OutputDirectory: '$($received.outputDirectory)'"
    }
    $wantPublish = $case.publish -eq "true"
    $wantUnsigned = $case.unsigned -eq "true"
    if ($received.publish -ne $wantPublish -or $received.allowUnsignedPublish -ne $wantUnsigned) {
      throw ("the release workflow did not forward the publishing switches: " +
        ($received | ConvertTo-Json -Compress))
    }
  }
  foreach ($name in @("GRAPHCODE_PROBE_LOG", "RELEASE_TAG", "RELEASE_PUBLISH",
      "RELEASE_ALLOW_UNSIGNED_PUBLISH")) {
    Remove-Item -LiteralPath "env:$name" -ErrorAction SilentlyContinue
  }
  Write-Output "Release workflow invocation binding: PASS"
} finally {
  foreach ($name in @("GRAPHCODE_STUB_LOG", "GRAPHCODE_STUB_SIGNING_LABEL",
      "GRAPHCODE_STUB_BUILD_FAILS", "GRAPHCODE_STUB_GH_FAILS",
      "GRAPHCODE_PROBE_LOG", "RELEASE_TAG", "RELEASE_PUBLISH",
      "RELEASE_ALLOW_UNSIGNED_PUBLISH")) {
    Remove-Item -LiteralPath "env:$name" -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $fixture) {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
  }
}
