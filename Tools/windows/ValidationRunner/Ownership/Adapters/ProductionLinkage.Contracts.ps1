[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $ArtifactRoot,
    [Parameter(Mandatory)][string] $AssemblyPath
)

. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')
Import-OwnershipBindings $RepositoryRoot $AssemblyPath
$windows = Join-Path $RepositoryRoot 'Tools\windows'
$gatePath = Join-Path $windows 'uia-live-gate.ps1'
$gate = Read-OwnershipProductionAst $gatePath
$gateText = [IO.File]::ReadAllText($gatePath)
$packagingPath = Join-Path $windows 'Tests\Packaging.Standalone.Tests.ps1'
$packaging = Read-OwnershipProductionAst $packagingPath
$packagingText = [IO.File]::ReadAllText($packagingPath)
$bindingPath = Join-Path ([IO.Path]::GetDirectoryName($AssemblyPath)) 'WindowsValidationBindings.dll'
$context = @{
    '$PSScriptRoot' = ("'" + $windows.Replace("'", "''") + "'")
    '$validationAssemblyPath' = ("'" + $AssemblyPath.Replace("'", "''") + "'")
}
. Import-OwnershipProductionFunctions $gate @('Initialize-MultiProjectProcessJob', 'Initialize-UiaOwnedStreamCapture') $context
function Assert-NoEmbeddedOwnedImplementation($Ast) {
    $copies = @($Ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
            $node.Value -match 'public\s+(?:static\s+)?class\s+(StandaloneProcessJob|UiaOwnedStreamCapture)\b'
    }, $true))
    Assert-Ownership ($copies.Count -eq 0) 'A legacy consumer retains an embedded duplicate owned implementation.'
}
Invoke-OwnershipCase 'packaging-shared-linkage' {
    Assert-NoEmbeddedOwnedImplementation $packaging
    Assert-Ownership ($packagingText.Contains('Import-CompiledValidationAssembly.ps1') -and
        $packagingText.Contains('-RequiredType "GraphCode.Validation.Ownership.StandaloneProcessJob"')) 'Packaging does not require the exact file-backed shared production type.'
    $setup = @($packaging.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-Setup'
    }, $true))
    Assert-Ownership ($setup.Count -eq 1) 'Actual standalone setup consumer missing or ambiguous.'
    foreach ($method in @('Create', 'Assign', 'Active', 'Summary', 'Processes', 'Terminate', 'WaitForEmpty', 'Close')) {
        Assert-Ownership ($setup[0].Extent.Text.Contains("[GraphCode.Validation.Ownership.StandaloneProcessJob]::$method(")) "Actual packaging consumer does not call shared production method $method"
    }
    Assert-Ownership ([GraphCode.Validation.Ownership.StandaloneProcessJob].Assembly.Location -ceq $bindingPath) 'Packaging helper was loaded from another implementation.'
}
Complete-OwnershipFamily 'ownership.legacy.packaging-shared-linkage' 1 @('source-and-loader-linkage')
Invoke-OwnershipCase 'uia-shared-linkage' {
    Assert-NoEmbeddedOwnedImplementation $gate
    Initialize-MultiProjectProcessJob ''
    Initialize-UiaOwnedStreamCapture
    Assert-Ownership ([GraphCode.Validation.Ownership.UiaOwnedStreamCapture].Assembly.Location -ceq $bindingPath -and
        [GraphCode.Validation.Ownership.StandaloneProcessJob].Assembly.Location -ceq $bindingPath) 'Actual UIA initializers loaded different copies of the shared production helpers.'
    foreach ($call in @('[GraphCode.Validation.Ownership.StandaloneProcessJob]::Assign(',
        '[GraphCode.Validation.Ownership.StandaloneProcessJob]::Terminate(',
        '[GraphCode.Validation.Ownership.StandaloneProcessJob]::WaitForEmpty(',
        '[GraphCode.Validation.Ownership.UiaOwnedStreamCapture]::Read(',
        '[GraphCode.Validation.Ownership.UiaOwnedStreamCapture]::RequireJobMember(')) {
        Assert-Ownership ($gateText.Contains($call)) "Actual gate is not routed through complete shared production call $call"
    }
    $jobSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\StandaloneProcessJob.cs'))
    $streamSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\UiaOwnedStreamCapture.cs'))
    Assert-Ownership ([regex]::Matches($jobSource, 'extern bool IsProcessInJob\(').Count -eq 1 -and
        -not $streamSource.Contains('extern bool IsProcessInJob') -and
        $streamSource.Contains('StandaloneProcessJob.Contains(job, process)') -and
        $streamSource.Contains('AutoFlush = true') -and $streamSource.Contains('new UTF8Encoding(false, true)')) 'Native membership or corrected encoder state was duplicated or bypassed.'
}
Complete-OwnershipFamily 'ownership.legacy.uia-shared-linkage' 1 @('source-and-loader-linkage')
if ($script:OwnershipAdapterFailed) { exit 1 }
