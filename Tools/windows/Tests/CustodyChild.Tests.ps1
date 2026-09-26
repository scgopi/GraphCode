[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string] $ZigExecutable,
  [string] $WinghosttyRoot
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$shellRoot = Join-Path $repoRoot "graphcode-windows"
if (-not $WinghosttyRoot) { $WinghosttyRoot = $env:GRAPHCODE_WINGHOSTTY_ROOT }
if (-not $WinghosttyRoot) {
  $depotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
  $WinghosttyRoot = Join-Path $depotRoot "Winghostty-worktrees\host-integration"
}
$include = Join-Path $WinghosttyRoot "include"
$pin = (Get-Content (Join-Path $shellRoot "provider-pins.json") -Raw | ConvertFrom-Json).winghostty.sha
$actualPin = & git -C $WinghosttyRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $actualPin -ne $pin) { throw "Custody tests require the pinned Winghostty source $pin" }
$version = & $ZigExecutable version
if ($LASTEXITCODE -ne 0 -or $version -ne "0.15.2") { throw "Custody tests require Zig 0.15.2" }

$names = @("GRAPHCODE_UIA_DAEMON_COMMAND_LOG", "ZIG_GLOBAL_CACHE_DIR", "ZIG_LOCAL_CACHE_DIR")
$saved = @{}
foreach ($name in $names) {
  $saved[$name] = @{
    Present = Test-Path "Env:$name"
    Value = [Environment]::GetEnvironmentVariable($name, "Process")
  }
}
try {
  Remove-Item -LiteralPath "Env:GRAPHCODE_UIA_DAEMON_COMMAND_LOG" -ErrorAction SilentlyContinue
  if (Test-Path "Env:GRAPHCODE_UIA_DAEMON_COMMAND_LOG") { throw "Custody tests require command logging to be absent" }
  $env:ZIG_GLOBAL_CACHE_DIR = Join-Path $repoRoot ".graphcode-tools\custody-global-cache"
  $env:ZIG_LOCAL_CACHE_DIR = Join-Path $repoRoot ".graphcode-tools\custody-local-cache"
  Push-Location $shellRoot
  try {
    $cases = @(
      @{ Root = "src\GraphContextMenu.zig"; Filter = "custody child"; Count = 2; Extra = @() },
      @{ Root = "src\NativeForms.zig"; Filter = "custody child"; Count = 4; Extra = @() },
      @{ Root = "src\GraphModel.zig"; Filter = "custody selection"; Count = 2; Extra = @() },
      @{ Root = "src\App.zig"; Filter = "custody child"; Count = 27; Extra = @("src\AccessibilityProvider.cpp", "-lgdi32", "-ladvapi32", "-loleaut32", "-luiautomationcore", "-lwinhttp") }
    )
    foreach ($case in $cases) {
      $arguments = @("test", $case.Root, "-target", "x86_64-windows-msvc", "-lc", "-luser32", "-I$include", "--test-filter", $case.Filter) + $case.Extra
      $output = @(& $ZigExecutable @arguments 2>&1)
      $exitCode = $LASTEXITCODE
      $output | ForEach-Object { Write-Host "$_" }
      if ($exitCode -ne 0) { throw "$($case.Root) custody tests failed with exit code $exitCode" }
      $summary = [regex]::Match(($output -join "`n"), "All ([1-9][0-9]*) tests passed\.")
      if (-not $summary.Success -or [int]$summary.Groups[1].Value -ne $case.Count) {
        throw "$($case.Root) custody test count mismatch: expected $($case.Count)"
      }
    }
  } finally { Pop-Location }
} finally {
  foreach ($name in $names) {
    if ($saved[$name].Present) {
      [Environment]::SetEnvironmentVariable($name, $saved[$name].Value, "Process")
    } else {
      Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
  }
}
