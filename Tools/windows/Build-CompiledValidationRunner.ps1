[CmdletBinding()]
param(
  [ValidateSet("Debug", "Release")][string] $Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$projectRoot = Join-Path $PSScriptRoot "ValidationRunner"
$local = Join-Path $projectRoot ".local"
$names = @("DOTNET_CLI_HOME", "NUGET_PACKAGES", "TEMP", "TMP", "DOTNET_CLI_TELEMETRY_OPTOUT",
  "DOTNET_GENERATE_ASPNET_CERTIFICATE", "DOTNET_SKIP_FIRST_TIME_EXPERIENCE")
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
  [void][IO.Directory]::CreateDirectory($env:TEMP)
  Push-Location $projectRoot
  try {
    $dotnet = (Get-Command dotnet -CommandType Application -ErrorAction Stop).Source
    $version = & $dotnet --version
    if ($LASTEXITCODE -ne 0 -or $version -cne "10.0.403") {
      throw "Compiled validation requires the pinned .NET SDK 10.0.403; install it before building"
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
      [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
  }
}
