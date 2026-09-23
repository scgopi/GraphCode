[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$script = Join-Path $repoRoot "Tools\windows\package.ps1"
$fixture = Join-Path $repoRoot ".build\packaging-test-fixture-$PID"
$out = Join-Path $repoRoot ".build\packaging-test-output-$PID"
$installFixture = Join-Path $repoRoot ".build\packaging install $PID"
$install = Join-Path $installFixture "深い\GraphCode"
$oldProfile = $env:USERPROFILE
$oldAppData = $env:APPDATA
$oldSupport = $env:GRAPHCODE_SUPPORT_DIR
$oldModuleCache = $env:PSModuleAnalysisCachePath
$oldUserPath = [Environment]::GetEnvironmentVariable("Path", "User")

function Invoke-Package([string] $command, [hashtable] $extra = @{}) {
  $args = @("-NoProfile", "-File", $script, "-Command", $command)
  foreach ($key in $extra.Keys) { $args += @("-$key", [string] $extra[$key]) }
  & pwsh @args
  if ($LASTEXITCODE -ne 0) { throw "packaging $command failed" }
}
function Assert-VerifyReject([string] $label, [scriptblock] $mutate, [string] $message) {
  $copy = Join-Path $out "negative-$([guid]::NewGuid())"
  Copy-Item $artifact $copy -Recurse
  & $mutate $copy
  $output = & pwsh -NoProfile -File $script -Command Verify -Package $copy 2>&1 | Out-String
  $code = $LASTEXITCODE
  Remove-Item $copy -Recurse -Force -ErrorAction SilentlyContinue
  if ($code -eq 0 -or $output -notmatch [regex]::Escape($message)) {
    throw "$label did not fail specifically: $output"
  }
}
try {
  $depot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $wingRoot = if ($env:GRAPHCODE_WINGHOSTTY_ROOT) { $env:GRAPHCODE_WINGHOSTTY_ROOT } else { Join-Path $depot "Winghostty-worktrees\host-integration" }
  $zmxRoot = if ($env:GRAPHCODE_ZMX_ROOT) { $env:GRAPHCODE_ZMX_ROOT } else { Join-Path $depot "zmx-worktrees\quickchat-hang" }
  $zig0152 = $env:GRAPHCODE_ZIG0152
  $zig0160 = $env:GRAPHCODE_ZIG0160
  if (-not $zig0152) { $zig0152 = Join-Path $depot "GraphCode-worktrees\ghostty-winghostty-spike\zig-x86_64-windows-0.15.2\zig.exe" }
  if (-not $zig0160) { $zig0160 = Join-Path $depot "GraphCode-worktrees\ghostty-winghostty-spike\zig-x86_64-windows-0.16.0\zig.exe" }
  if (-not (Test-Path $wingRoot) -or -not (Test-Path $zmxRoot)) { throw "trusted provider roots are required" }
  New-Item -ItemType Directory -Force $fixture | Out-Null
  $env:PSModuleAnalysisCachePath = Join-Path $fixture "ModuleAnalysisCache"
  $env:USERPROFILE = Join-Path $fixture "user"
  $env:APPDATA = Join-Path $env:USERPROFILE "AppData\Roaming"
  $env:GRAPHCODE_SUPPORT_DIR = $null
  $testZmxRoot = Join-Path $fixture "zmx-provider"
  & git clone --no-checkout --local $zmxRoot $testZmxRoot *> $null
  if ($LASTEXITCODE -ne 0) { throw "could not clone isolated pinned zmx provider" }
  & git -C $testZmxRoot checkout --detach (git -C $zmxRoot rev-parse HEAD) *> $null
  if ($LASTEXITCODE -ne 0) { throw "could not pin isolated zmx provider" }
  if (-not (Test-Path (Join-Path $testZmxRoot "build.zig"))) { throw "isolated pinned zmx provider is incomplete" }
  Copy-Item (Join-Path $zmxRoot "zig-pkg") (Join-Path $testZmxRoot "zig-pkg") -Recurse -Force
  # uucode's generator runs with its dependency directory as cwd. Zig 0.16 can
  # otherwise emit a relative .zig-cache executable path and resolve it from
  # that cwd, looking two levels too shallow and failing with FileNotFound.
  $zmxCache = Join-Path $fixture "zmx-zig-cache"
  Push-Location $testZmxRoot
  try {
    & $zig0160 build -Dtarget=x86_64-windows-gnu --cache-dir $zmxCache
  } finally { Pop-Location }
  if ($LASTEXITCODE -ne 0) { throw "could not build isolated pinned zmx provider" }
  Push-Location (Join-Path $repoRoot "graphcode-windows")
  try {
    & $zig0152 build `
      "-Dwinghostty-dir=$wingRoot" `
      "-Dwinghostty-lib=$(Join-Path $wingRoot 'zig-out\lib\winghostty-win32-host.lib')" `
      "-Dversion=1.2.3" -Doptimize=ReleaseSafe
  } finally { Pop-Location }
  if ($LASTEXITCODE -ne 0) { throw "could not build versioned GraphCode Windows artifact" }
  $fixtureBin = Join-Path $fixture "nested space\unicode-日本\bin"
  New-Item -ItemType Directory -Force -Path $fixtureBin | Out-Null
  $release = $null
  foreach ($candidate in @(
      (Join-Path $repoRoot ".build\windows\release"),
      (Join-Path $repoRoot ".build\windows\release-artifact"),
      (Join-Path $repoRoot ".build\x86_64-unknown-windows-msvc\release"))) {
    if (Test-Path (Join-Path $candidate "graphcoded.exe")) {
      $release = $candidate
      break
    }
  }
  if (-not $release) { throw "staged Swift release products were not found" }
  foreach ($name in @("graphcode-windows.exe", "graphcoded.exe", "graphcode.exe")) {
    $candidate = if ($name -eq "graphcode-windows.exe") {
      Join-Path $repoRoot "graphcode-windows\zig-out\bin\$name"
    } else { Join-Path $release $name }
    if (-not (Test-Path $candidate)) { throw "real release executable missing: $candidate" }
    Copy-Item $candidate (Join-Path $fixtureBin $name)
  }
  Copy-Item (Join-Path $testZmxRoot "zig-out\bin\zmx.exe") (Join-Path $fixtureBin "zmx.exe")
  Get-ChildItem $release -Filter *.dll | Copy-Item -Destination $fixtureBin
  $hiddenFixture = Join-Path $fixtureBin "hidden-payload.txt"
  Set-Content $hiddenFixture "preserve hidden package contents"
  (Get-Item $hiddenFixture).Attributes = [IO.FileAttributes]::Hidden
  $untrusted = & pwsh -NoProfile -File $script -Command Build -InputDirectory $fixtureBin `
    -OutputDirectory $out -Version "untrusted" 2>&1 | Out-String
  if ($LASTEXITCODE -eq 0 -or $untrusted -notmatch "trusted pinned") {
    throw "untrusted provider input was accepted: $untrusted"
  }
  Invoke-Package "Build" @{ InputDirectory = $fixtureBin; OutputDirectory = $out; Version = "1.2.3"; WinghosttyRoot = $wingRoot; ZmxRoot = $testZmxRoot; Zig0152 = $zig0152; Zig0160 = $zig0160 }
  $providerZmx = Join-Path $testZmxRoot "zig-out\bin\zmx.exe"
  Set-Content $providerZmx stale-provider-output
  $staleZmxHash = (Get-FileHash $providerZmx -Algorithm SHA256).Hash
  Invoke-Package "Build" @{ InputDirectory = $fixtureBin; OutputDirectory = $out; Version = "1.2.3"; WinghosttyRoot = $wingRoot; ZmxRoot = $testZmxRoot; Zig0152 = $zig0152; Zig0160 = $zig0160 }
  $rebuiltZmxHash = (Get-FileHash $providerZmx -Algorithm SHA256).Hash
  if ($rebuiltZmxHash -eq $staleZmxHash) {
    throw "provider packaging did not rebuild stale ignored output"
  }
  $artifact = Join-Path $out "GraphCode-1.2.3-windows-x86_64"
  if ((Get-FileHash (Join-Path $artifact "bin\zmx.exe") -Algorithm SHA256).Hash -ne $rebuiltZmxHash) {
    throw "provider packaging did not use the rebuilt zmx artifact"
  }
  $zip = "$artifact.zip"
  Invoke-Package "Verify" @{ Package = $zip }
  Invoke-Package "Install" @{ Package = $zip; InstallRoot = $install; NoScheduledTask = $true }
  if (-not (Test-Path (Join-Path $install "bin\graphcode.exe"))) { throw "install did not place CLI" }
  if (-not (Test-Path -LiteralPath (Join-Path $install "bin\hidden-payload.txt"))) {
    throw "ZIP packaging lost a hidden manifest payload"
  }
  $installedHash = (Get-FileHash (Join-Path $install "bin\graphcode.exe")).Hash
  foreach ($command in @("Verify", "Install", "Upgrade")) {
    $rejected = & pwsh -NoProfile -File $script -Command $command -Package $zip `
      -InstallRoot $install -TrustedSignerThumbprint ("A" * 40) 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $rejected -notmatch "trusted publisher verification requires a signed package") {
      throw "$command did not reject an unsigned package under publisher policy: $rejected"
    }
    if ((Get-FileHash (Join-Path $install "bin\graphcode.exe")).Hash -ne $installedHash) {
      throw "$command changed the installed executable before publisher verification"
    }
  }
  $userData = Join-Path $env:USERPROFILE ".graphcode\packaging-test-$PID\user.json"
  New-Item -ItemType Directory -Force -Path (Split-Path $userData -Parent) | Out-Null
  Set-Content $userData "preserve" -Force
  Invoke-Package "Upgrade" @{ Package = $zip; InstallRoot = $install; NoScheduledTask = $true }
  $supportIdentity = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE ".graphcode")).TrimEnd([char]92).ToLowerInvariant()
  $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
  $identityBytes = [Text.Encoding]::UTF8.GetBytes(($sid + '|' + $supportIdentity))
  $identityHex = @()
  foreach ($byte in [Security.Cryptography.SHA256]::Create().ComputeHash($identityBytes)) {
    $identityHex += $byte.ToString('x2')
  }
  $identityHash = $identityHex -join ''
  $sentinelTask = 'GraphCode\graphcoded-' + $identityHash.Substring(0, 32)
  schtasks.exe /Create /TN $sentinelTask /TR "cmd.exe /c exit 0" /SC ONCE /ST (Get-Date).AddMinutes(2).ToString("HH:mm") /F *> $null
  if ($LASTEXITCODE -ne 0) { throw "could not create scoped task sentinel" }
  $sentinelBefore = (& schtasks.exe /Query /TN $sentinelTask /XML | Out-String)
  Invoke-Package "Uninstall" @{ InstallRoot = $install; KeepUserData = $true; NoScheduledTask = $true }
  $sentinelAfter = (& schtasks.exe /Query /TN $sentinelTask /XML | Out-String)
  if ($LASTEXITCODE -ne 0 -or $sentinelBefore -cne $sentinelAfter) { throw "portable uninstall changed a preexisting scoped task" }
  schtasks.exe /Delete /TN $sentinelTask /F *> $null
  if (Test-Path $install) { throw "uninstall left installed binaries" }
  if (-not (Test-Path $userData)) { throw "uninstall removed user data" }
  & pwsh -NoProfile -File (Join-Path $PSScriptRoot "Packaging.RealLifecycle.Tests.ps1") `
    -Package $zip -RepositoryRoot $repoRoot
  if ($LASTEXITCODE -ne 0) { throw "real scheduled lifecycle test failed" }
  & pwsh -NoProfile -File (Join-Path $PSScriptRoot "Packaging.RealLifecycle.Tests.ps1") `
    -Package $zip -RepositoryRoot $repoRoot -Standalone `
    -PowerShellExecutable (Get-Command powershell.exe).Source
  if ($LASTEXITCODE -ne 0) { throw "standalone Windows PowerShell lifecycle test failed" }
  Assert-VerifyReject "checksum" { param($p) Add-Content (Join-Path $p "bin\zmx.exe") corrupt } "size mismatch"
  Assert-VerifyReject "extra file" { param($p) Set-Content (Join-Path $p "extra.txt") unexpected } "manifest file set differs"
  Assert-VerifyReject "traversal" {
    param($p); $m=Get-Content (Join-Path $p "manifest.json") -Raw | ConvertFrom-Json
    $m.files[0].path="../escape.txt"; $m | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $p "manifest.json")
  } "unsafe path"
  Assert-VerifyReject "absolute" {
    param($p); $m=Get-Content (Join-Path $p "manifest.json") -Raw | ConvertFrom-Json
    $m.files[0].path="/absolute.txt"; $m | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $p "manifest.json")
  } "absolute path"
  Assert-VerifyReject "duplicate" {
    param($p); $m=Get-Content (Join-Path $p "manifest.json") -Raw | ConvertFrom-Json
    $m.files += $m.files[0]; $m | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $p "manifest.json")
  } "duplicate paths"
  Assert-VerifyReject "provenance" {
    param($p); $v=Get-Content (Join-Path $p "provider-provenance.json") -Raw | ConvertFrom-Json
    $path=Join-Path $p "provider-provenance.json"
    $v.zmx.sha256=("0"*64); $v | ConvertTo-Json -Depth 10 | Set-Content $path
    $m=Get-Content (Join-Path $p "manifest.json") -Raw | ConvertFrom-Json
    $entry=@($m.files | Where-Object path -eq "provider-provenance.json")[0]
    $entry.size=(Get-Item $path).Length
    $entry.sha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $m | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $p "manifest.json")
  } "provenance digest mismatch"
  Assert-VerifyReject "license traversal" {
    param($p); $v=Get-Content (Join-Path $p "provider-provenance.json") -Raw | ConvertFrom-Json
    $v.zmx.licensePath="../LICENSE"; $v | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $p "provider-provenance.json")
    $m=Get-Content (Join-Path $p "manifest.json") -Raw | ConvertFrom-Json
    $e=@($m.files | Where-Object path -eq "provider-provenance.json")[0]
    $e.size=(Get-Item (Join-Path $p "provider-provenance.json")).Length
    $e.sha256=(Get-FileHash (Join-Path $p "provider-provenance.json") -Algorithm SHA256).Hash.ToLowerInvariant()
    $m | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $p "manifest.json")
  } "unsafe path"
  Assert-VerifyReject "reserved nested name" {
    param($p); New-Item -ItemType Directory (Join-Path $p "nested") | Out-Null
    Set-Content (Join-Path $p "nested\manifest.json") reserved
  } "reserved filename"
  Write-Output "Packaging executable install/upgrade/uninstall tests: PASS"
  exit 0
} finally {
  $env:USERPROFILE = $oldProfile
  $env:APPDATA = $oldAppData
  $env:GRAPHCODE_SUPPORT_DIR = $oldSupport
  $env:PSModuleAnalysisCachePath = $oldModuleCache
  [Environment]::SetEnvironmentVariable("Path", $oldUserPath, "User")
  Remove-Item $fixture,$out,$installFixture -Recurse -Force -ErrorAction SilentlyContinue
}
