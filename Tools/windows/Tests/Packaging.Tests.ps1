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
  New-Item -ItemType Directory -Force -Path (Join-Path $fixture "nested space\unicode-日本\bin") | Out-Null
  foreach ($name in @("graphcode-windows.exe", "graphcoded.exe", "graphcode.exe", "zmx.exe")) {
    Set-Content (Join-Path $fixture "nested space\unicode-日本\bin\$name") "fixture $name" -Encoding ascii
  }
  Set-Content (Join-Path $fixture "nested space\unicode-日本\bin\swiftCore.dll") "runtime" -Encoding ascii
  Invoke-Package "Build" @{ InputDirectory = (Join-Path $fixture "nested space\unicode-日本\bin"); OutputDirectory = $out; Version = "1.2.3" }
  $artifact = Join-Path $out "GraphCode-1.2.3-windows-x86_64"
  Invoke-Package "Verify" @{ Package = $artifact }
  Invoke-Package "Install" @{ Package = $artifact; InstallRoot = $install; NoScheduledTask = $true }
  if (-not (Test-Path (Join-Path $install "bin\graphcode.exe"))) { throw "install did not place CLI" }
  $userData = Join-Path (Split-Path $install -Parent) "data\user.json"
  New-Item -ItemType Directory -Force -Path (Split-Path $userData -Parent) | Out-Null
  Set-Content $userData "preserve" -Force
  Invoke-Package "Upgrade" @{ Package = $artifact; InstallRoot = $install; NoScheduledTask = $true }
  Invoke-Package "Uninstall" @{ InstallRoot = $install; KeepUserData = $true }
  if (Test-Path $install) { throw "uninstall left installed binaries" }
  if (-not (Test-Path $userData)) { throw "uninstall removed user data" }
  $corrupt = Join-Path $artifact "bin\zmx.exe"
  Add-Content $corrupt "corrupt"
  try { Invoke-Package "Verify" @{ Package = $artifact }; throw "corrupt package was accepted" } catch { if ($_ -like "*corrupt package was accepted*") { throw } }
  Write-Output "Packaging executable install/upgrade/uninstall tests: PASS"
  exit 0
} finally {
  Remove-Item $fixture,$out,(Split-Path $install -Parent) -Recurse -Force -ErrorAction SilentlyContinue
}
