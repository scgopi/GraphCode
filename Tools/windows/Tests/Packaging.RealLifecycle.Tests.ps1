[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $Package,
  [Parameter(Mandatory)][string] $RepositoryRoot
)

$ErrorActionPreference = "Stop"
$script = Join-Path $RepositoryRoot "Tools\windows\package.ps1"
$testHome = Join-Path $RepositoryRoot ".build\packaging-real-home-$PID"
$install = Join-Path $testHome "GraphCode\current"
$oldHome = $env:USERPROFILE
$pwsh = (Get-Command pwsh).Source
function Invoke-Package([string] $command, [hashtable] $extra = @{}) {
  $args = @("-NoProfile", "-File", $script, "-Command", $command)
  foreach ($key in $extra.Keys) { $args += @("-$key", [string] $extra[$key]) }
  & $pwsh @args
  if ($LASTEXITCODE -ne 0) { throw "real lifecycle $command failed" }
}
try {
  New-Item -ItemType Directory -Force $testHome | Out-Null
  $env:USERPROFILE = $testHome
  Invoke-Package "Install" @{ Package = $Package; InstallRoot = $install }
  $bin = Join-Path $install "bin"
  $env:PATH = "$bin;$env:SystemRoot\System32"
  $env:GRAPHCODE_SUPPORT_DIR = Join-Path $testHome ".graphcode"
  & (Join-Path $bin "graphcode.exe") projects
  if ($LASTEXITCODE -ne 0) { throw "scheduled daemon CLI reachability failed" }
  Set-Content (Join-Path $testHome ".graphcode\real-lifecycle.json") preserved -Force
  $expected = [IO.Path]::GetFullPath((Join-Path $bin "graphcoded.exe"))
  Invoke-Package "Upgrade" @{ Package = $Package; InstallRoot = $install }
  $running = @(Get-CimInstance Win32_Process | Where-Object {
      $_.Name -ieq "graphcoded.exe" -and $_.ExecutablePath -and
      [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $expected
    })
  if ($running.Count -ne 1) { throw "upgrade did not restart exactly one installed daemon" }
  $badReach = Join-Path $testHome "bad-reachability"
  Expand-Archive $Package -DestinationPath $badReach
  $badDaemon = Join-Path $badReach "GraphCode\bin\graphcoded.exe"
  Set-Content $badDaemon "not an executable"
  $manifestPath = Join-Path $badReach "GraphCode\manifest.json"
  $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
  $entry = @($manifest.files | Where-Object path -eq "bin/graphcoded.exe")[0]
  $entry.size = (Get-Item $badDaemon).Length
  $entry.sha256 = (Get-FileHash $badDaemon -Algorithm SHA256).Hash.ToLowerInvariant()
  $manifest | ConvertTo-Json -Depth 10 | Set-Content $manifestPath
  $priorDaemonHash = (Get-FileHash (Join-Path $bin "graphcoded.exe")).Hash
  & $pwsh -NoProfile -File $script -Command Upgrade `
    -Package (Join-Path $badReach "GraphCode") -InstallRoot $install
  if ($LASTEXITCODE -eq 0) { throw "daemon reachability failure was accepted" }
  $restoredDaemonHash = (Get-FileHash (Join-Path $bin "graphcoded.exe")).Hash
  $restored = @(Get-CimInstance Win32_Process | Where-Object {
      $_.Name -ieq "graphcoded.exe" -and $_.ExecutablePath -and
      [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $expected
    })
  if ($priorDaemonHash -ne $restoredDaemonHash -or $restored.Count -ne 1) {
    throw "daemon reachability failure did not restore and restart the prior installation"
  }
  $bad = Join-Path $testHome "bad-package"
  Expand-Archive $Package -DestinationPath $bad
  Add-Content (Join-Path $bad "GraphCode\bin\graphcode.exe") corrupt
  $before = (Get-FileHash (Join-Path $bin "graphcode.exe")).Hash
  & $pwsh -NoProfile -File $script -Command Upgrade `
    -Package (Join-Path $bad "GraphCode") -InstallRoot $install
  $failure = $LASTEXITCODE
  $after = (Get-FileHash (Join-Path $bin "graphcode.exe")).Hash
  if ($failure -eq 0 -or $before -ne $after) { throw "failed upgrade did not preserve the prior installation" }
  Invoke-Package "Uninstall" @{ InstallRoot = $install; RemoveUserData = $true }
  $left = @(Get-CimInstance Win32_Process | Where-Object {
      $_.Name -ieq "graphcoded.exe" -and $_.ExecutablePath -and
      [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $expected
    })
  if ((Test-Path $install) -or (Test-Path (Join-Path $testHome ".graphcode")) -or $left.Count -ne 0) {
    throw "uninstall left installed state, support data, or daemon process"
  }
  if (schtasks.exe /Query /TN "GraphCode daemon" 2>$null) {
    throw "uninstall left the GraphCode daemon task"
  }
  Write-Output "Real scheduled-task install/upgrade/rollback/uninstall: PASS"
} finally {
  $env:USERPROFILE = $oldHome
  Remove-Item $testHome -Recurse -Force -ErrorAction SilentlyContinue
}
