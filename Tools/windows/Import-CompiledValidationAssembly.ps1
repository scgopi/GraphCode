[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $AssemblyPath,
  [Parameter(Mandatory)][string] $RequiredType
)

$ErrorActionPreference = "Stop"
function Assert-CompiledUiaProviderProvenance([Collections.IDictionary] $Observed) {
  foreach ($key in @('expectedPath','loadedPath','name','version','clientVersion','fileVersion',
      'clientFileVersion','token','signature','signer','fileMvid','loadedMvid',
      'fileHash','loadedHash','publicEntry')) {
    if ([string]::IsNullOrWhiteSpace([string]$Observed[$key])) {
      throw [InvalidOperationException]::new("UIA provider provenance: missing $key")
    }
  }
  if (-not [string]::Equals([IO.Path]::GetFullPath($Observed.expectedPath),
        [IO.Path]::GetFullPath($Observed.loadedPath),[StringComparison]::OrdinalIgnoreCase) -or
      $Observed.name -ine 'UIAutomationClientSideProviders' -or
      $Observed.version -cne $Observed.clientVersion -or
      $Observed.fileVersion -cne $Observed.clientFileVersion -or
      $Observed.token -cne 'B77A5C561934E089' -or
      $Observed.signature -cne 'Valid' -or
      $Observed.signer -cne 'CN=.NET, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' -or
      $Observed.fileMvid -cne $Observed.loadedMvid -or
      $Observed.fileHash -cne $Observed.loadedHash -or
      -not $Observed.Contains('reference') -or $Observed.reference -ne $false -or
      $Observed.publicEntry -cne 'UIAutomationClientsideProviders.UIAutomationClientSideProviders') {
    throw [InvalidOperationException]::new('UIA provider provenance: wrong runtime component, signature, public entry, bytes or loaded identity')
  }
}
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
if ($RequiredType -cin @("GraphCodeUiaGateState", "GraphCodeUiaAttribution")) {
  $uiFrameworkAssemblies = @{}
  foreach ($runtimeName in @("WindowsBase", "UIAutomationTypes", "UIAutomationClient")) {
    $runtimePath = Join-Path $PSHOME "$runtimeName.dll"
    $runtimeIdentity = [Reflection.AssemblyName]::GetAssemblyName($runtimePath)
    if ($runtimeIdentity.Version.Major -ne [Environment]::Version.Major) {
      throw "UIA runtime dependency $runtimePath does not match PowerShell CLR $([Environment]::Version); reference-pack assemblies are not supported"
    }
    $runtimeAssembly = [Reflection.Assembly]::LoadFrom($runtimePath)
    if (-not [string]::Equals([IO.Path]::GetFullPath($runtimeAssembly.Location),
          [IO.Path]::GetFullPath($runtimePath),[StringComparison]::OrdinalIgnoreCase) -or
        $runtimeAssembly.GetName().Version -ne $runtimeIdentity.Version -or
        [Convert]::ToHexString($runtimeAssembly.GetName().GetPublicKeyToken()) -cne
          [Convert]::ToHexString($runtimeIdentity.GetPublicKeyToken()) -or
        @($runtimeAssembly.GetCustomAttributesData() | Where-Object {
          $_.AttributeType.FullName -ceq "System.Runtime.CompilerServices.ReferenceAssemblyAttribute"
        }).Count -ne 0) {
      throw "UIA dependency is not a compatible runtime assembly: $runtimePath"
    }
    $uiFrameworkAssemblies[$runtimeName] = $runtimeAssembly
  }
  if ([System.Windows.Rect].Assembly -ne $uiFrameworkAssemblies.WindowsBase -or
      [System.Windows.Automation.ControlType].Assembly -ne $uiFrameworkAssemblies.UIAutomationTypes -or
      [System.Windows.Automation.InvokePattern].Assembly -ne $uiFrameworkAssemblies.UIAutomationClient) {
    throw "UIA types do not belong to the explicitly selected PowerShell runtime assemblies"
  }
  $providerPath = Join-Path $PSHOME 'UIAutomationClientsideProviders.dll'
  $providerHash = (Get-FileHash -LiteralPath $providerPath -Algorithm SHA256).Hash
  $providerSignature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -FilePath $providerPath
  if ($providerSignature.Status -ne 'Valid' -or $providerSignature.SignerCertificate.Subject -cne
      'CN=.NET, O=Microsoft Corporation, L=Redmond, S=Washington, C=US') {
    throw [InvalidOperationException]::new('UIA provider provenance: normal signed Microsoft runtime component is required')
  }
  $providerAssembly = [Reflection.Assembly]::LoadFrom($providerPath)
  $providerEntry = $providerAssembly.GetType('UIAutomationClientsideProviders.UIAutomationClientSideProviders',$false)
  $providerFile = [IO.File]::OpenRead($providerPath)
  try {
    $providerPe = [Reflection.PortableExecutable.PEReader]::new($providerFile)
    try {
      $providerMetadata = [Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($providerPe)
      $providerMvid = $providerMetadata.GetGuid($providerMetadata.GetModuleDefinition().Mvid)
    } finally { $providerPe.Dispose() }
  } finally { $providerFile.Dispose() }
  Assert-CompiledUiaProviderProvenance @{
    expectedPath=$providerPath; loadedPath=$providerAssembly.Location
    name=$providerAssembly.GetName().Name; version=$providerAssembly.GetName().Version.ToString()
    clientVersion=$uiFrameworkAssemblies.UIAutomationClient.GetName().Version.ToString()
    fileVersion=(Get-Item -LiteralPath $providerPath).VersionInfo.FileVersion
    clientFileVersion=(Get-Item -LiteralPath $uiFrameworkAssemblies.UIAutomationClient.Location).VersionInfo.FileVersion
    token=[Convert]::ToHexString($providerAssembly.GetName().GetPublicKeyToken())
    signature=[string]$providerSignature.Status; signer=$providerSignature.SignerCertificate.Subject
    fileMvid=$providerMvid.ToString(); loadedMvid=$providerAssembly.ManifestModule.ModuleVersionId.ToString()
    fileHash=$providerHash; loadedHash=(Get-FileHash -LiteralPath $providerAssembly.Location -Algorithm SHA256).Hash
    reference=(@($providerAssembly.GetCustomAttributesData() | Where-Object {
      $_.AttributeType.FullName -ceq 'System.Runtime.CompilerServices.ReferenceAssemblyAttribute'
    }).Count -ne 0)
    publicEntry=$(if ($null -ne $providerEntry -and $providerEntry.IsPublic) { $providerEntry.FullName } else { '' })
  }
  $registrationName = [Reflection.AssemblyName]::new($providerAssembly.FullName)
  $registrationName.Name = $providerEntry.Namespace
  [GraphCodeUiaGateState]::RegisterClientSideProviderAssembly($registrationName)
}
Write-Output $assembly
