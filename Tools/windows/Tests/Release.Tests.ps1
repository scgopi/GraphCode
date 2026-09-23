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

try {
  New-Item -ItemType Directory -Path $fixture -Force | Out-Null
  Reset-Log

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
  Write-Output "Package verification: PASS"
  exit 0
}
$label = if ($env:GRAPHCODE_STUB_SIGNING_LABEL) {
  $env:GRAPHCODE_STUB_SIGNING_LABEL
} else {
  "UNSIGNED (not code signed)"
}
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

  # 2. The ordinary release artifact is explicitly unsigned, uses the stable
  #    versionless asset name, and can be published without a certificate gate.
  $output = Invoke-Release @{ Tag = "v0.1.74"; OutputDirectory = $out }
  $asset = Join-Path $out "publish\graphcode-windows-x86_64.zip"
  if (-not (Test-Path -LiteralPath $asset)) {
    throw "release build did not stage the standard asset: $output"
  }
  if (Test-Path -LiteralPath (Join-Path $out "publish\graphcode-windows-x86_64-unsigned.zip")) {
    throw "release build retained the obsolete unsigned-only asset name"
  }
  $sidecar = Get-Content -LiteralPath "$asset.sha256" -Raw
  $expected = (Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($sidecar.Trim() -ne "$expected  graphcode-windows-x86_64.zip") {
    throw "checksum sidecar does not describe the release asset: $sidecar"
  }
  $summary = Get-Content -LiteralPath (Join-Path $out "publish\release-summary.json") -Raw | ConvertFrom-Json
  if ($summary.signed -ne $false -or $summary.signing -notmatch "^UNSIGNED" -or
    $summary.published -ne $false -or $summary.asset -ne "graphcode-windows-x86_64.zip") {
    throw "unsigned release summary is not honest: $($summary | ConvertTo-Json -Compress)"
  }
  if ((Get-PackageCommands "Verify").Count -ne 1 -or
    (Get-PackageCommands "Verify")[0].PSObject.Properties.Name -contains "TrustedSignerThumbprint") {
    throw "release verification must not claim a trusted publisher pin"
  }
  Write-Output "Standard unsigned release artifact: PASS"

  # 3. Publishing uploads the standard ZIP and checksum without a signing
  #    override or certificate configuration.
  Invoke-Release @{ Tag = "v0.1.74"; OutputDirectory = $out; Publish = $true } | Out-Null
  $uploads = @(Get-Invocations | Where-Object tool -eq "gh")
  if ($uploads.Count -ne 1) { throw "release publish did not upload exactly once" }
  $arguments = @($uploads[0].arguments)
  if ($arguments[0] -ne "release" -or $arguments[1] -ne "upload" -or $arguments[2] -ne "v0.1.74" -or
    $arguments -notcontains "--clobber" -or
    ($arguments | Where-Object { $_ -like "*\graphcode-windows-x86_64.zip" }).Count -ne 1 -or
    ($arguments | Where-Object { $_ -like "*\graphcode-windows-x86_64.zip.sha256" }).Count -ne 1) {
    throw "unexpected upload argument vector: $($arguments -join ' ')"
  }
  Write-Output "Unsigned release publication: PASS"

  # 4. The orchestrator rejects a package that unexpectedly reports a signed
  #    state instead of silently changing release policy.
  $env:GRAPHCODE_STUB_SIGNING_LABEL = "signed"
  Invoke-Release @{ Tag = "v0.1.74"; OutputDirectory = $out; Publish = $true } `
    -ExpectFailure -Message "unsigned Windows release policy" | Out-Null
  if (@(Get-Invocations | Where-Object tool -eq "gh").Count -ne 0) {
    throw "a contradictory package was still uploaded"
  }
  $env:GRAPHCODE_STUB_SIGNING_LABEL = $null
  Write-Output "Unsigned release-state honesty gate: PASS"

  # 5. Build and upload failures propagate and never look like successful
  #    publication.
  $env:GRAPHCODE_STUB_BUILD_FAILS = "1"
  Invoke-Release @{ Tag = "v0.1.74"; OutputDirectory = $out; Publish = $true } `
    -ExpectFailure -Message "packaging" | Out-Null
  if (@(Get-Invocations | Where-Object tool -eq "gh").Count -ne 0) {
    throw "a failed build still uploaded a release asset"
  }
  $env:GRAPHCODE_STUB_BUILD_FAILS = $null
  $env:GRAPHCODE_STUB_GH_FAILS = "1"
  Invoke-Release @{ Tag = "v0.1.74"; OutputDirectory = $out; Publish = $true } `
    -ExpectFailure -Message "upload" | Out-Null
  $env:GRAPHCODE_STUB_GH_FAILS = $null
  Write-Output "Build and upload failure propagation: PASS"

  # 6. The workflow stays manual, action-pinned, and free of certificate or
  #    unsigned-override configuration.
  $workflow = Get-Content -LiteralPath (Join-Path $repoRoot ".github\workflows\windows-release.yml") -Raw
  foreach ($required in @("workflow_dispatch:", "Tools/windows/release.ps1", "actions/checkout@")) {
    if ($workflow -notmatch [regex]::Escape($required)) {
      throw "the release workflow no longer references $required"
    }
  }
  foreach ($removed in @("WINDOWS_SIGNING_", "GRAPHCODE_SIGNING_", "allow_unsigned_publish",
      "RELEASE_ALLOW_UNSIGNED_PUBLISH", "add-mask")) {
    if ($workflow -match [regex]::Escape($removed)) {
      throw "the release workflow retained obsolete signing configuration: $removed"
    }
  }
  $releaseSource = Get-Content -LiteralPath $releaseScript -Raw
  foreach ($removed in @("SigningCertificate", "SigningThumbprint", "SignTimestampUrl",
      "AllowUnsignedPublish", "Import-PfxCertificate")) {
    if ($releaseSource -match [regex]::Escape($removed)) {
      throw "the release orchestrator retained obsolete signing policy: $removed"
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
  $publishDefault = [regex]::Match($workflow, "(?ms)publish:.*?default:\s*(\S+)")
  if (-not $publishDefault.Success -or $publishDefault.Groups[1].Value -notmatch "^(false|'false'|`"false`")$") {
    throw "the publishing input no longer defaults to false"
  }
  Write-Output "Release workflow contract: PASS"

  # 7. The workflow's own invocation actually binds release.ps1's parameters.
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
  [switch] $Publish
)
([ordered]@{
  tag = $Tag
  outputDirectory = $OutputDirectory
  publish = [bool] $Publish
} | ConvertTo-Json -Compress) | Set-Content -LiteralPath $env:GRAPHCODE_PROBE_LOG -Encoding utf8
'@ | Set-Content -LiteralPath $probe -Encoding utf8

  $harness = $packageBlock -replace "\./Tools/windows/release\.ps1", "& `$probeScript"
  foreach ($publish in @("false", "true")) {
    Remove-Item -LiteralPath $probeLog -ErrorAction SilentlyContinue
    $env:GRAPHCODE_PROBE_LOG = $probeLog
    $env:RELEASE_TAG = "v0.1.74"
    $env:RELEASE_PUBLISH = $publish
    $script = "`$probeScript = `"$probe`"`n" + $harness
    $scriptFile = Join-Path $fixture "invocation-harness.ps1"
    Set-Content -LiteralPath $scriptFile -Value $script -Encoding utf8
    $probeOutput = & pwsh -NoProfile -File $scriptFile 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $probeLog)) {
      throw "the release workflow's invocation of release.ps1 failed: $probeOutput"
    }
    $received = Get-Content -LiteralPath $probeLog -Raw | ConvertFrom-Json
    if ($received.tag -ne "v0.1.74") {
      throw "the release workflow bound the wrong value to -Tag: '$($received.tag)'"
    }
    if ($received.outputDirectory -notlike "*release-publish*") {
      throw "the release workflow bound the wrong value to -OutputDirectory: '$($received.outputDirectory)'"
    }
    if ($received.publish -ne ($publish -eq "true")) {
      throw "the release workflow did not forward the publishing switch"
    }
  }
  Write-Output "Release workflow invocation binding: PASS"
} finally {
  foreach ($name in @("GRAPHCODE_STUB_LOG", "GRAPHCODE_STUB_SIGNING_LABEL",
      "GRAPHCODE_STUB_BUILD_FAILS", "GRAPHCODE_STUB_GH_FAILS",
      "GRAPHCODE_PROBE_LOG", "RELEASE_TAG", "RELEASE_PUBLISH")) {
    Remove-Item -LiteralPath "env:$name" -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $fixture) {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
  }
}
