[CmdletBinding()]
param(
  [ValidateSet("Debug", "Release")][string] $Configuration = "Release"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "DotNetSdk.ps1")
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$projectRoot = Join-Path $PSScriptRoot "ValidationRunner"
$local = Join-Path $projectRoot ".local"
$names = @("DOTNET_CLI_HOME", "NUGET_PACKAGES", "TEMP", "TMP", "DOTNET_CLI_TELEMETRY_OPTOUT",
  "DOTNET_GENERATE_ASPNET_CERTIFICATE", "DOTNET_SKIP_FIRST_TIME_EXPERIENCE", "DOTNET_ROOT",
  "DOTNET_MULTILEVEL_LOOKUP", "DOTNET_ROLL_FORWARD", "DOTNET_NOLOGO")
$before = @{}
$environment = [Environment]::GetEnvironmentVariables("Process")
foreach ($name in $names) {
  $before[$name] = @{ present = $environment.Contains($name); value = $environment[$name] }
}
try {
  $env:DOTNET_CLI_HOME = Join-Path $local "dotnet"
  $env:NUGET_PACKAGES = Join-Path $local "nuget"
  $env:TEMP = Join-Path $local "temp"
  $env:TMP = $env:TEMP
  $env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
  $env:DOTNET_GENERATE_ASPNET_CERTIFICATE = "false"
  $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = "1"
  $env:DOTNET_NOLOGO = "1"
  [void][IO.Directory]::CreateDirectory($env:TEMP)
  # A loaded bootstrap environment supplies GRAPHCODE_DOTNET10403. The resolver
  # also admits an installed exact SDK, but never downloads during a build.
  $dotnet = Resolve-GraphCodeDotNetSdk -RepositoryRoot $repositoryRoot `
    -ToolRoot (Join-Path $repositoryRoot ".graphcode-tools")
  $expectedVersion = Get-GraphCodeDotNetPin $repositoryRoot
  $env:DOTNET_ROOT = [IO.Path]::GetDirectoryName($dotnet)
  $env:DOTNET_MULTILEVEL_LOOKUP = "0"
  $env:DOTNET_ROLL_FORWARD = "LatestPatch"
  Push-Location $projectRoot
  try {
    $version = & $dotnet --version
    if ($LASTEXITCODE -ne 0 -or $version -cne $expectedVersion) {
      throw "Compiled validation requires the pinned .NET SDK $expectedVersion; rerun Tools\windows\bootstrap.ps1"
    }
    & $dotnet build ValidationRunner.csproj --configuration $Configuration --nologo --verbosity quiet |
      ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "Compiled validation build failed: exit=$LASTEXITCODE" }
  } finally { Pop-Location }
  $assembly = Join-Path $projectRoot "bin\$Configuration\net10.0-windows\ValidationRunner.dll"
  if (-not (Test-Path -LiteralPath $assembly -PathType Leaf)) { throw "Compiled validation build produced no assembly" }
  Write-Output $assembly
} finally {
  foreach ($name in $names) {
    if ($before[$name].present) {
      [Environment]::SetEnvironmentVariable($name, $before[$name].value, "Process")
    } else {
      if ([Environment]::GetEnvironmentVariables("Process").Contains($name)) {
        Remove-Item -LiteralPath "Env:\$name" -ErrorAction Stop
      }
    }
  }
}
