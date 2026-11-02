[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $AssemblyPath,
  [Parameter(Mandatory)][string] $RequiredType
)

$ErrorActionPreference = "Stop"
if ($RequiredType -cne "GraphCode.ValidationFixtureDirectoryNative" -and [Environment]::Version.Major -lt 8) {
  throw "Compiled Windows bindings require PowerShell on .NET 8 or newer (PowerShell 7.4+); observed $([Environment]::Version)"
}
if (-not [IO.Path]::IsPathFullyQualified($AssemblyPath)) {
  throw "Compiled validation assembly must be an explicit absolute path"
}
$projectRoot = Join-Path $PSScriptRoot "ValidationRunner"
$fileName = if ($RequiredType -ceq "GraphCode.ValidationFixtureDirectoryNative") {
  "ValidationFixtureBindings.dll"
} else { "WindowsValidationBindings.dll" }
if ([IO.Path]::GetFileName($AssemblyPath) -ceq "ValidationRunner.dll") {
  $AssemblyPath = Join-Path ([IO.Path]::GetDirectoryName($AssemblyPath)) $fileName
}
$selected = (Resolve-Path -LiteralPath $AssemblyPath -ErrorAction Stop).Path
$expected = @("Debug", "Release") | ForEach-Object {
  [IO.Path]::GetFullPath((Join-Path $projectRoot "bin\$_\net10.0-windows\$fileName"))
}
if ($expected -cnotcontains $selected) {
  throw "Compiled validation assembly is not a build from this worktree: $selected"
}
$alreadyLoaded = $RequiredType -as [type]
if ($null -ne $alreadyLoaded -and $alreadyLoaded.Assembly.Location -cne $selected) {
  throw "Required validation type is already loaded from a different assembly: $RequiredType"
}
$assembly = [Reflection.Assembly]::LoadFrom($selected)
$type = $assembly.GetType($RequiredType, $false)
if ($null -eq $type -or $type.Assembly.Location -cne $selected) {
  throw "Expected file-backed validation type was not loaded: $RequiredType"
}
$sourceRoots = @($assembly.GetCustomAttributesData() | Where-Object {
    $_.AttributeType.FullName -ceq "System.Reflection.AssemblyMetadataAttribute" -and
      $_.ConstructorArguments.Count -eq 2 -and
      $_.ConstructorArguments[0].Value -ceq "GraphCode.Validation.SourceRoot"
  })
if ($sourceRoots.Count -ne 1 -or $sourceRoots[0].ConstructorArguments[1].Value -cne $projectRoot) {
  throw "Compiled validation assembly has no matching worktree build provenance"
}
Write-Output $assembly
