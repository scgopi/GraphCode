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
try {
  $fixtureBin = Join-Path $fixture "nested space\unicode-日本\bin"
  New-Item -ItemType Directory -Force -Path $fixtureBin | Out-Null
  foreach ($name in @("graphcode-windows.exe", "graphcoded.exe", "graphcode.exe", "zmx.exe")) {
    Set-Content (Join-Path $fixtureBin $name) "fixture $name" -Encoding ascii
  }
  Set-Content (Join-Path $fixtureBin "swiftCore.dll") "runtime" -Encoding ascii
  Set-Content (Join-Path $fixtureBin "winghostty-win32-host.lib") "host" -Encoding ascii
  Set-Content (Join-Path $fixtureBin "WINGHOSTTY-LICENSE.txt") "MIT License`r`nPermission is hereby granted...`r`nTHE SOFTWARE IS PROVIDED" -Encoding utf8
  Set-Content (Join-Path $fixtureBin "ZMX-LICENSE.txt") "MIT License`r`nPermission is hereby granted...`r`nTHE SOFTWARE IS PROVIDED" -Encoding utf8
  $pins = Get-Content (Join-Path $repoRoot "graphcode-windows\provider-pins.json") -Raw | ConvertFrom-Json
  $wingHash = (Get-FileHash (Join-Path $fixtureBin "winghostty-win32-host.lib") -Algorithm SHA256).Hash.ToLowerInvariant()
  $zmxHash = (Get-FileHash (Join-Path $fixtureBin "zmx.exe") -Algorithm SHA256).Hash.ToLowerInvariant()
  @{
    schemaVersion = 1
    winghostty = @{ repository = $pins.winghostty.repository; sha = $pins.winghostty.sha; packagePath = "bin/winghostty-win32-host.lib"; sha256 = $wingHash }
    zmx = @{ repository = $pins.zmx.repository; sha = $pins.zmx.sha; packagePath = "bin/zmx.exe"; sha256 = $zmxHash }
  } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $fixtureBin "provider-provenance.json") -Encoding utf8
  Invoke-Package "Build" @{ InputDirectory = $fixtureBin; OutputDirectory = $out; Version = "1.2.3" }
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
  $corrupt = Join-Path $artifact "bin\zmx.exe"
  Add-Content $corrupt "corrupt"
  try { Invoke-Package "Verify" @{ Package = $artifact }; throw "corrupt package was accepted" } catch { if ($_ -like "*corrupt package was accepted*") { throw } }
  Add-Content (Join-Path $artifact "extra.txt") "unexpected"
  try { Invoke-Package "Verify" @{ Package = $artifact }; throw "extra file was accepted" } catch { if ($_ -like "*extra file was accepted*") { throw } }
  Remove-Item (Join-Path $artifact "extra.txt")
  $manifestPath = Join-Path $artifact "manifest.json"
  $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
  $manifest.files[0].path = "../escape.txt"
  $manifest | ConvertTo-Json -Depth 10 | Set-Content $manifestPath
  try { Invoke-Package "Verify" @{ Package = $artifact }; throw "traversal manifest was accepted" } catch { if ($_ -like "*traversal manifest was accepted*") { throw } }
  $manifest.files[0].path = "/absolute.txt"
  $manifest | ConvertTo-Json -Depth 10 | Set-Content $manifestPath
  try { Invoke-Package "Verify" @{ Package = $artifact }; throw "absolute manifest was accepted" } catch { if ($_ -like "*absolute manifest was accepted*") { throw } }
  $graphcodeFile = Get-Item (Join-Path $artifact "bin\graphcode.exe")
  $manifest.files[0].path = "bin/graphcode.exe"
  $manifest.files[0].size = $graphcodeFile.Length
  $manifest.files[0].sha256 = (Get-FileHash $graphcodeFile -Algorithm SHA256).Hash.ToLowerInvariant()
  $metadataFile = Get-Item (Join-Path $artifact "metadata.json")
  $manifest.files += [ordered]@{
    path = "metadata.json"
    size = $metadataFile.Length
    sha256 = (Get-FileHash $metadataFile -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  $manifest | ConvertTo-Json -Depth 10 | Set-Content $manifestPath
  try { Invoke-Package "Verify" @{ Package = $artifact }; throw "duplicate manifest was accepted" } catch { if ($_ -like "*duplicate manifest was accepted*") { throw } }
  $prov = Get-Content (Join-Path $artifact "provider-provenance.json") -Raw | ConvertFrom-Json
  $prov.zmx.sha256 = ("0" * 64)
  $prov | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $artifact "provider-provenance.json")
  try { Invoke-Package "Verify" @{ Package = $artifact }; throw "provenance mismatch was accepted" } catch { if ($_ -like "*provenance mismatch was accepted*") { throw } }
  $notice = Get-Content (Join-Path $artifact "THIRD-PARTY-NOTICES.txt") -Raw
  if ($notice -notmatch "Winghostty" -or $notice -notmatch "zmx" -or $notice -notmatch "Permission is hereby granted") { throw "provider license attribution is incomplete" }
  Write-Output "Packaging executable install/upgrade/uninstall tests: PASS"
  exit 0
} finally {
  Remove-Item $fixture,$out,(Split-Path $install -Parent), `
    (Join-Path $env:USERPROFILE ".graphcode\packaging-test-$PID") `
    -Recurse -Force -ErrorAction SilentlyContinue
}
