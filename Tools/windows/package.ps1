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
  [string] $SignToolPath,
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
function Save-Shortcut([string] $destination) {
  foreach ($path in @(
      (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\GraphCode.lnk"),
      (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\GraphCode.url")
    )) {
    if (Test-Path $path) {
      Copy-Item $path (Join-Path $destination (Split-Path $path -Leaf)) -Force
    }
  }
}
function Restore-Shortcut([string] $source) {
  Set-Shortcut $false
  foreach ($name in @("GraphCode.lnk", "GraphCode.url")) {
    $path = Join-Path $source $name
    if (Test-Path $path) {
      Copy-Item $path (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$name") -Force
    }
  }
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
    Where-Object {
      $_.FullName -ne (Join-Path $root "manifest.json") -and
      $_.FullName -ne (Join-Path $root "checksums.sha256")
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
function Normalize-ManifestPath([string] $path) {
  Require (-not [string]::IsNullOrWhiteSpace($path)) "manifest contains an empty path"
  $normalized = $path.Replace("\", "/")
  Require (-not [IO.Path]::IsPathRooted($normalized) -and
    $normalized -notmatch "^[A-Za-z]:/" -and $normalized -notmatch "://" ) `
    "manifest contains an absolute path: $path"
  $parts = $normalized.Split("/")
  $leaf = $parts[-1]
  Require ($parts -notcontains "" -and $parts -notcontains "." -and $parts -notcontains "..") `
    "manifest contains an unsafe path: $path"
  Require ($leaf -notin @("manifest.json", "checksums.sha256")) `
    "manifest contains a reserved filename: $path"
  Require ($normalized -notmatch "[<>:`"|?*]") "manifest contains an invalid path: $path"
  return $normalized
}
function Get-ActualPackageFiles([string] $root) {
  @(Get-ChildItem -LiteralPath $root -File -Recurse |
    Where-Object {
      $_.FullName -ne (Join-Path $root "manifest.json") -and
      $_.FullName -ne (Join-Path $root "checksums.sha256")
    } |
    ForEach-Object {
      Normalize-ManifestPath $_.FullName.Substring($root.Length).TrimStart("\", "/")
    } | Sort-Object -Unique)
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
    userData = "%USERPROFILE%/.graphcode (preserved by uninstall)"
    providerProvenance = "provider-provenance.json"
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
  Require (Test-Path -LiteralPath (Join-Path $root "licenses\WINGHOSTTY-LICENSE.txt")) "Winghostty license is missing"
  Require (Test-Path -LiteralPath (Join-Path $root "licenses\ZMX-LICENSE.txt")) "zmx license is missing"
  Require (Test-Path -LiteralPath (Join-Path $root "provider-provenance.json")) "provider provenance is missing"
  Require ($metadata.platform -eq "windows-x86_64") "unsupported package platform"
  return $metadata
}
function Verify-Manifest([string] $root) {
  $manifestPath = Join-Path $root "manifest.json"
  Require (Test-Path -LiteralPath $manifestPath) "manifest.json is missing"
  $expected = Get-Content $manifestPath -Raw | ConvertFrom-Json
  $entries = @($expected.files)
  $normalizedEntries = @()
  foreach ($entry in $entries) {
    $normalized = Normalize-ManifestPath ([string] $entry.path)
    Require ($entry.size -is [int] -or $entry.size -is [long] -or $entry.size -is [double]) "manifest size is invalid: $normalized"
    Require ([string] $entry.sha256 -match "^[0-9a-fA-F]{64}$") "manifest hash is invalid: $normalized"
    Require ($normalizedEntries -notcontains $normalized.ToLowerInvariant()) "manifest contains duplicate paths"
    $normalizedEntries += $normalized.ToLowerInvariant()
    $file = Join-Path $root ($normalized -replace "/", "\")
    Require (Test-Path -LiteralPath $file -PathType Leaf) "manifest file is missing: $($entry.path)"
    $item = Get-Item -LiteralPath $file
    Require ($item.Length -eq [int64]$entry.size) "size mismatch: $normalized"
    $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    Require ($actual -eq ([string]$entry.sha256).ToLowerInvariant()) "checksum mismatch: $normalized"
  }
  $actualFiles = @(Get-ActualPackageFiles $root | ForEach-Object { $_.ToLowerInvariant() })
  $expectedFiles = @($normalizedEntries | Sort-Object -Unique)
  Require (($actualFiles -join "`n") -eq ($expectedFiles -join "`n")) "manifest file set differs from package contents"
  return $expected
}
function Read-ProviderProvenance([string] $root) {
  $path = Join-Path $root "provider-provenance.json"
  $provenance = Get-Content $path -Raw | ConvertFrom-Json
  $pins = Get-Content (Join-Path $shellRoot "provider-pins.json") -Raw | ConvertFrom-Json
  foreach ($provider in @("winghostty", "zmx")) {
    $p = $provenance.$provider
    $pin = $pins.$provider
    Require ($p.sha -eq $pin.sha -and $p.repository -eq $pin.repository) "$provider provenance pin mismatch"
    Require ([string]$p.sha256 -match "^[0-9a-fA-F]{64}$") "$provider provenance digest is missing"
    $normalizedPath = Normalize-ManifestPath ([string]$p.packagePath)
    Require ($normalizedPath -eq $p.packagePath) "$provider provenance path is not normalized"
    $artifact = Join-Path $root ($p.packagePath -replace "/", "\")
    Require (Test-Path $artifact -PathType Leaf) "$provider provenance artifact is missing"
    Require ((Get-FileHash $artifact -Algorithm SHA256).Hash.ToLowerInvariant() -eq $p.sha256.ToLowerInvariant()) "$provider provenance digest mismatch"
    $normalizedLicensePath = Normalize-ManifestPath ([string]$p.licensePath)
    Require ($normalizedLicensePath -eq $p.licensePath) "$provider license path is not normalized"
    $licensePath = Join-Path $root ($normalizedLicensePath -replace "/", "\")
    Require (Test-Path $licensePath -PathType Leaf) "$provider license file is missing"
    Require ((Get-FileHash $licensePath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $p.licenseSha256.ToLowerInvariant()) "$provider license digest mismatch"
  }
  return $provenance
}
function Verify-SignedPackage([string] $root, [object] $metadata) {
  if ($metadata.signing -ne "signed") { return }
  Require (Test-Path (Join-Path $root "SIGNATURES.txt")) "signed package has no signature record"
  $tool = if ($SignToolPath) { $SignToolPath } else { (Get-Command signtool.exe -ErrorAction SilentlyContinue).Source }
  foreach ($file in @(Get-ChildItem (Join-Path $root "bin") -Filter *.exe)) {
    $authenticode = Get-AuthenticodeSignature -FilePath $file.FullName
    Require ($authenticode.Status -eq "Valid") "clean-machine Authenticode verification failed: $($file.Name)"
    if ($tool -and (Test-Path $tool)) {
      & $tool verify /pa $file.FullName *> $null
      Require ($LASTEXITCODE -eq 0) "optional signtool diagnostic failed: $($file.Name)"
    }
  }
}
function Get-TaskIdentity([string] $support) {
  $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
  $resolved = [IO.Path]::GetFullPath($support).TrimEnd("\").ToLowerInvariant()
  $bytes = [Text.Encoding]::UTF8.GetBytes("$sid|$resolved")
  $hash = ([Security.Cryptography.SHA256]::Create().ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
  return @{ sid = $sid; name = "GraphCode\graphcoded-$($hash.Substring(0, 32))" }
}
function Xml-Escape([string] $value) {
  return [System.Security.SecurityElement]::Escape($value)
}
function Build-Package {
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
  foreach ($name in $required + "graphcode-windows.exe") {
    Require (Test-Path (Join-Path $root "bin\$name")) "$name was not found; pass -InputDirectory with release outputs"
  }
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
  Write-Metadata $root $Version
  if ($SignCertificate) {
    $signtool = if ($SignToolPath) { (Resolve-Path $SignToolPath).Path } else { (Get-Command signtool.exe -ErrorAction SilentlyContinue).Source }
    Require $signtool "signtool.exe was not found; signed packaging requires Windows SDK"
    Get-ChildItem (Join-Path $root "bin") -Filter *.exe | ForEach-Object {
      $args = @("sign", "/sha1", $SignCertificate)
      if ($SignTimestampUrl) { $args += @("/tr", $SignTimestampUrl, "/td", "sha256") }
      $args += $_.FullName
      & $signtool @args
      Require ($LASTEXITCODE -eq 0) "signtool failed for $($_.Name)"
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
  $archive = Join-Path $out "GraphCode-$Version-windows-x86_64.zip"
  if (Test-Path $archive) { Remove-Item $archive -Force }
  Compress-Archive -Path $root -DestinationPath $archive -CompressionLevel Optimal
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
  $script:PackageExtraction = $extract
  $entries = @(Get-ChildItem $extract)
  $nested = @($entries | Where-Object { $_.PSIsContainer })
  if ($nested.Count -eq 1 -and $nested[0].Name -eq "GraphCode" -and
    @($entries | Where-Object { -not $_.PSIsContainer }).Count -eq 0) { return $nested[0].FullName }
  if ((Test-Path (Join-Path $extract "manifest.json")) -and (Test-Path (Join-Path $extract "metadata.json"))) { return $extract }
  Fail "ZIP must contain one GraphCode directory or a verified flat package root"
}
function Close-Package {
  if ($script:PackageExtraction) {
    Remove-Item -LiteralPath $script:PackageExtraction -Recurse -Force -ErrorAction SilentlyContinue
    $script:PackageExtraction = $null
  }
}
function Set-UserPath([string] $bin, [bool] $add) {
  $current = [Environment]::GetEnvironmentVariable("Path", "User")
  $parts = @($current -split ";" | Where-Object { $_ -and $_ -ne $bin })
  if ($add) { $parts += $bin }
  [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")
}
function Set-Shortcut([bool] $create) {
  $shortcut = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\GraphCode.lnk"
  $fallback = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\GraphCode.url"
  if (-not $create) {
    Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fallback -Force -ErrorAction SilentlyContinue
    return
  }
  $directory = Split-Path $shortcut -Parent
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  try {
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($shortcut)
    $link.TargetPath = Join-Path $InstallRoot "bin\graphcode-windows.exe"
    $link.WorkingDirectory = Join-Path $InstallRoot "bin"
    $link.Description = "GraphCode Windows shell"
    $link.Save()
  } catch {
    $target = [Uri]::new((Join-Path $InstallRoot "bin\graphcode-windows.exe")).AbsoluteUri
    @"
[InternetShortcut]
URL=$target
IconFile=$(Join-Path $InstallRoot "bin\graphcode-windows.exe")
IconIndex=0
"@ | Set-Content -LiteralPath $fallback -Encoding ascii
  }
}
function Get-InstalledDaemons {
  $expected = [IO.Path]::GetFullPath((Join-Path $InstallRoot "bin\graphcoded.exe"))
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      $_.Name -ieq "graphcoded.exe" -and $_.ExecutablePath -and
      ([IO.Path]::GetFullPath($_.ExecutablePath) -ieq $expected)
    })
}
function Stop-InstalledDaemon {
  $support = if ($env:GRAPHCODE_SUPPORT_DIR) { $env:GRAPHCODE_SUPPORT_DIR } else { Join-Path $env:USERPROFILE ".graphcode" }
  $identity = Get-TaskIdentity $support
  & schtasks.exe /End /TN $identity.name *> $null
  $deadline = [DateTime]::UtcNow.AddSeconds(8)
  while (@(Get-InstalledDaemons).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 200
  }
  foreach ($process in @(Get-InstalledDaemons)) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(4)
  while (@(Get-InstalledDaemons).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 200
  }
  Require (@(Get-InstalledDaemons).Count -eq 0) "installed graphcoded process did not stop"
}
function Remove-DaemonTask {
  $support = if ($env:GRAPHCODE_SUPPORT_DIR) { $env:GRAPHCODE_SUPPORT_DIR } else { Join-Path $env:USERPROFILE ".graphcode" }
  $identity = Get-TaskIdentity $support
  & schtasks.exe /End /TN $identity.name *> $null
  & schtasks.exe /Delete /TN $identity.name /F *> $null
}
function Start-DaemonTask {
  $support = if ($env:GRAPHCODE_SUPPORT_DIR) { $env:GRAPHCODE_SUPPORT_DIR } else { Join-Path $env:USERPROFILE ".graphcode" }
  $identity = Get-TaskIdentity $support
  New-Item -ItemType Directory -Force $support | Out-Null
  $xmlPath = Join-Path (Split-Path $InstallRoot -Parent) "GraphCode-daemon-task.xml"
  $taskName = Xml-Escape $identity.name
  $sid = Xml-Escape $identity.sid
  $command = Xml-Escape (Join-Path $env:SystemRoot "System32\cmd.exe")
  $arguments = Xml-Escape "/d /s /c `"set `"GRAPHCODE_SUPPORT_DIR=$support`"`&`&`"$InstallRoot\bin\graphcoded.exe`"`""
  $workingDirectory = Xml-Escape (Join-Path $InstallRoot "bin")
  $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>GraphCode daemon for $sid</Description></RegistrationInfo>
  <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>$sid</UserId></LogonTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>$sid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><StartWhenAvailable>true</StartWhenAvailable><ExecutionTimeLimit>PT0S</ExecutionTimeLimit></Settings>
  <Actions Context="Author"><Exec><Command>$command</Command><Arguments>$arguments</Arguments><WorkingDirectory>$workingDirectory</WorkingDirectory></Exec></Actions>
</Task>
"@
  [IO.File]::WriteAllText($xmlPath, $xml, [Text.Encoding]::Unicode)
  & schtasks.exe /Create /TN $identity.name /XML $xmlPath /F *> $null
  Require ($LASTEXITCODE -eq 0) "scheduled-task registration failed"
  Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
  & schtasks.exe /Run /TN $identity.name *> $null
  Require ($LASTEXITCODE -eq 0) "scheduled-task start failed"
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  while ([DateTime]::UtcNow -lt $deadline) {
    if (@(Get-InstalledDaemons).Count -gt 0) {
      $cli = Join-Path $InstallRoot "bin\graphcode.exe"
      $env:GRAPHCODE_SUPPORT_DIR = $support
      & $cli projects *> $null
      if ($LASTEXITCODE -eq 0) { return }
    }
    Start-Sleep -Milliseconds 300
  }
  throw "scheduled graphcoded endpoint did not become reachable"
}
function Install-Package([bool] $upgrade) {
  try {
    $root = Open-Package ($(if ($Package) { $Package } else { Fail "-Package is required" }))
    $metadata = Assert-Package $root
    Verify-Manifest $root | Out-Null
    Read-ProviderProvenance $root | Out-Null
    Verify-SignedPackage $root $metadata
    if ($Version -ne "0.0.0-dev" -and $metadata.version -ne $Version) { Fail "version mismatch: expected $Version, package is $($metadata.version)" }
  $parent = Split-Path $InstallRoot -Parent
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $stage = Join-Path $parent ".GraphCode-install-$([guid]::NewGuid())"
  Copy-Tree $root $stage
  $backup = Join-Path $parent ".GraphCode-rollback-$([guid]::NewGuid())"
  $shortcutBackup = Join-Path $parent ".GraphCode-shortcut-$([guid]::NewGuid())"
  New-Item -ItemType Directory -Force $shortcutBackup | Out-Null
  Save-Shortcut $shortcutBackup
  $oldPath = [Environment]::GetEnvironmentVariable("Path", "User")
  try {
    if (-not $NoScheduledTask) { Stop-InstalledDaemon; Remove-DaemonTask }
    if (Test-Path $InstallRoot) { Move-Item $InstallRoot $backup }
    Move-Item $stage $InstallRoot
    Set-UserPath (Join-Path $InstallRoot "bin") $true
    Set-Shortcut $true
    if (-not $NoScheduledTask) {
      Start-DaemonTask
    }
  } catch {
    if (-not $NoScheduledTask) {
      try { Stop-InstalledDaemon } catch { }
      if (-not $NoScheduledTask) { Remove-DaemonTask }
    }
    if (Test-Path $InstallRoot) { Remove-Item $InstallRoot -Recurse -Force }
    if (Test-Path $backup) { Move-Item $backup $InstallRoot }
    [Environment]::SetEnvironmentVariable("Path", $oldPath, "User")
    Restore-Shortcut $shortcutBackup
    if (-not $NoScheduledTask -and (Test-Path (Join-Path $InstallRoot "bin\graphcoded.exe"))) {
      Start-DaemonTask
    }
    throw
  } finally {
    Remove-Item $stage,$backup,$shortcutBackup -Recurse -Force -ErrorAction SilentlyContinue
  }
    Write-Output "Installed GraphCode $($metadata.version) at $InstallRoot"
  } finally {
    Close-Package
  }
}
function Uninstall-Package {
  if (-not $NoScheduledTask) { Stop-InstalledDaemon; Remove-DaemonTask }
  $bin = Join-Path $InstallRoot "bin"
  Set-UserPath $bin $false
  Set-Shortcut $false
  if (Test-Path $InstallRoot) { Remove-Item $InstallRoot -Recurse -Force }
  $data = Join-Path $env:USERPROFILE ".graphcode"
  if ($RemoveUserData -and -not $KeepUserData) {
    Remove-Item $data -Recurse -Force -ErrorAction SilentlyContinue
  } else {
    Write-Output "User data preserved under $data"
  }
}

switch ($Command) {
  "Build" { Build-Package }
  "Verify" { try { $root = Open-Package $Package; $metadata = Assert-Package $root; Verify-Manifest $root | Out-Null; Read-ProviderProvenance $root | Out-Null; Verify-SignedPackage $root $metadata; Write-Output "Package verification: PASS" } finally { Close-Package } }
  "Install" { Install-Package $false }
  "Upgrade" { Install-Package $true }
  "Uninstall" { Uninstall-Package }
  "CleanMachine" { $RemoveUserData = $true; Uninstall-Package; Remove-Item (Join-Path $env:ProgramData "GraphCode") -Recurse -Force -ErrorAction SilentlyContinue }
}
