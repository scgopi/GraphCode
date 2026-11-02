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
} elseif ($RequiredType -ceq "GraphCode.Validation.Ownership.OwnershipJobFixture" -or
    $RequiredType.StartsWith("GraphCode.Validation.TestFixtures.", [StringComparison]::Ordinal)) {
  "ValidationTestFixtures.dll"
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
$inputs = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($attribute in $assembly.GetCustomAttributesData()) {
  if ($attribute.AttributeType.FullName -cne "System.Reflection.AssemblyMetadataAttribute" -or
      $attribute.ConstructorArguments.Count -ne 2 -or
      $attribute.ConstructorArguments[0].Value -cne "GraphCode.Validation.Input") { continue }
  $value = [string]$attribute.ConstructorArguments[1].Value
  $parts = $value.Split('|')
  if ($parts.Count -ne 2 -or -not [IO.Path]::IsPathFullyQualified($parts[0]) -or
      $parts[1] -cnotmatch '^[0-9A-F]{64}$' -or -not $inputs.TryAdd($parts[0], $parts[1])) {
    throw "Compiled validation assembly has invalid or duplicate input provenance"
  }
}
$requiredInputs = [Collections.Generic.List[string]]::new()
$requiredInputs.Add((Join-Path $projectRoot "global.json"))
$requiredInputs.Add((Join-Path $projectRoot "BuildProvenance.targets"))
switch ($fileName) {
  "ValidationFixtureBindings.dll" {
    $requiredInputs.Add((Join-Path $projectRoot "Bindings\ValidationFixtureBindings.csproj"))
    $requiredInputs.Add((Join-Path $PSScriptRoot "ValidationFixtureDirectoryNative.cs"))
  }
  "ValidationTestFixtures.dll" {
    $requiredInputs.Add((Join-Path $projectRoot "Bindings\Fixtures\ValidationTestFixtures.csproj"))
    $requiredInputs.Add((Join-Path $projectRoot "Ownership\OwnershipJobFixture.cs"))
    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $projectRoot "Host\Fixtures") -Filter "*.cs" -File)) {
      $requiredInputs.Add($file.FullName)
    }
  }
  "WindowsValidationBindings.dll" {
    $requiredInputs.Add((Join-Path $projectRoot "Bindings\Windows\WindowsValidationBindings.csproj"))
    $requiredInputs.Add((Join-Path $PSScriptRoot "UiaWindowActivation.cs"))
    $requiredInputs.Add((Join-Path $PSScriptRoot "ShellOwnedProcess.cs"))
    foreach ($directory in @("Ui\Production", "Host\Production", "Ownership")) {
      foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $projectRoot $directory) -Filter "*.cs" -File)) {
        if ($directory -ceq "Ownership" -and
            ($file.Name -like "*Fixture.cs" -or $file.Name -ceq "SuiteRegistration.cs")) { continue }
        $requiredInputs.Add($file.FullName)
      }
    }
  }
}
foreach ($inputPath in $requiredInputs) {
  if (-not $inputs.ContainsKey([IO.Path]::GetFullPath($inputPath))) {
    throw "Compiled validation input manifest is incomplete; rebuild with Build-CompiledValidationRunner.ps1"
  }
}
if ($inputs.Count -le $requiredInputs.Count) {
  throw "Compiled validation input manifest omits compiler reference inputs"
}
foreach ($inputPath in $inputs.Keys) {
  if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf) -or
      (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash -cne $inputs[$inputPath]) {
    throw "Compiled validation inputs changed after build; rebuild with Build-CompiledValidationRunner.ps1"
  }
}
$file = [IO.File]::Open($selected, [IO.FileMode]::Open, [IO.FileAccess]::Read,
  [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
try {
  $pe = [Reflection.PortableExecutable.PEReader]::new($file)
  try {
    $metadata = [Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($pe)
    $fileMvid = $metadata.GetGuid($metadata.GetModuleDefinition().Mvid)
    if ($fileMvid -ne $assembly.ManifestModule.ModuleVersionId) {
      throw "An older validation assembly is already loaded at the current path; start a fresh PowerShell process"
    }
  } finally { $pe.Dispose() }
} finally { $file.Dispose() }
Write-Output $assembly
