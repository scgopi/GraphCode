[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $ArtifactRoot,
    [Parameter(Mandatory)][string] $AssemblyPath
)

. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')
$script:OwnershipMockSignals = $true
Import-OwnershipBindings $RepositoryRoot $AssemblyPath
Import-Module (Join-Path $RepositoryRoot 'Tools\windows\ShellProcessOwnership.psm1') -Force -ErrorAction Stop
$gate = Read-OwnershipProductionAst (Join-Path $RepositoryRoot 'Tools\windows\uia-live-gate.ps1')
. Import-OwnershipProductionFunctions $gate @('New-UiaOwnershipFailure')
$saved = [Environment]::GetEnvironmentVariables('Process')
function Invoke-ReceiptMock([scriptblock] $Action) {
    $snapshot = [Environment]::GetEnvironmentVariables('Process')
    try {
        Remove-OwnershipEnvironment 'GRAPHCODE_VALIDATION_ROOT'
        & $Action 6>&1 | ForEach-Object {
            if ([string]$_ -ceq 'GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven') {
                'OWNERSHIP_EXPECTED_RETENTION_SIGNAL=observed'
            } else { $_ }
        }
    } finally { Restore-OwnershipEnvironment $snapshot @('GRAPHCODE_VALIDATION_ROOT') }
}
$fixture = Join-Path $ArtifactRoot ('receipt-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture -ErrorAction Stop
try {
    foreach ($variant in @('valid', 'existing', 'missing', 'file', 'empty', 'absent', 'isolated')) {
        Invoke-OwnershipCase $variant {
            $root = Join-Path $fixture $variant
            if ($variant -in @('valid', 'existing', 'isolated')) {
                $null = New-Item -ItemType Directory -Path $root
            }
            if ($variant -ceq 'file') { [IO.File]::WriteAllText($root, 'not a directory') }
            $path = Join-Path $root 'ownership-unproven.json'
            if ($variant -ceq 'existing') { [IO.File]::WriteAllText($path, 'preserve-existing-receipt') }
            if ($variant -ceq 'absent') {
                Remove-OwnershipEnvironment 'GRAPHCODE_VALIDATION_ROOT'
            } else {
                [Environment]::SetEnvironmentVariable('GRAPHCODE_VALIDATION_ROOT', $(if ($variant -ceq 'empty') { '' } else { $root }), 'Process')
            }
            $records = @(
                if ($variant -ceq 'isolated') { Invoke-ReceiptMock { New-UiaOwnershipFailure 'controlled receipt refusal' } }
                else { New-UiaOwnershipFailure 'controlled receipt refusal' 6>&1 }
            )
            $failures = @($records | Where-Object { $_ -is [Exception] })
            $signals = @($records | Where-Object {
                [string]$_ -ceq 'GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven'
            })
            Assert-Ownership ($failures.Count -eq 1 -and $signals.Count -eq [int]($variant -cne 'isolated')) 'Producer changed exception or exact information stream signal.'
            $failure = $failures[0]
            Assert-Ownership ($failure.GetType() -eq [InvalidOperationException] -and
                $failure.Message -ceq 'controlled receipt refusal' -and
                $failure.Data['GraphCodeValidationRootRetentionRequired'] -is [bool] -and
                $failure.Data['GraphCodeValidationRootRetentionRequired']) 'Producer lost exact exception type/message/boolean retention intent.'
            $roots = @($failure.Data['GraphCodeValidationRetainedRoots'])
            $expectedRoots = [int]($variant -in @('valid', 'existing'))
            Assert-Ownership ($roots.Count -eq $expectedRoots -and
                ($expectedRoots -eq 0 -or $roots[0] -ceq $root)) 'Producer retained-root identity differs.'
            $writeFailed = -not [string]::IsNullOrWhiteSpace($failure.Data['GraphCodeValidationRetentionReceiptFailure'])
            Assert-Ownership ($writeFailed -eq ($variant -in @('existing', 'missing', 'file', 'empty'))) 'Receipt write failure was lost or fabricated.'
            if ($variant -ceq 'valid') {
                $bytes = [IO.File]::ReadAllBytes($path)
                Assert-Ownership ($bytes.Length -gt 0 -and $bytes.Length -le 4096 -and $bytes[0] -ne 0xEF) 'Receipt is not bounded BOM-free UTF-8.'
                $receipt = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) | ConvertFrom-Json
                Assert-Ownership ($receipt.schemaVersion -eq 1 -and $receipt.validationRoot -ceq $root -and
                    $receipt.reason -ceq 'ownership_unproven') 'Receipt schema/root/reason mismatch.'
            }
            if ($variant -ceq 'existing') {
                Assert-Ownership ([IO.File]::ReadAllText($path) -ceq 'preserve-existing-receipt') 'Producer overwrote an existing receipt.'
            }
            if ($variant -ceq 'isolated') {
                Assert-Ownership (-not [IO.File]::Exists($path) -and $roots.Count -eq 0 -and
                    [Environment]::GetEnvironmentVariable('GRAPHCODE_VALIDATION_ROOT', 'Process') -ceq $root -and
                    @($records | Where-Object { [string]$_ -ceq 'OWNERSHIP_EXPECTED_RETENTION_SIGNAL=observed' }).Count -eq 1) 'Mock authority escaped, exact signal filtering changed, or environment not restored.'
            }
        }
    }
} finally {
    Restore-OwnershipEnvironment $saved @('GRAPHCODE_VALIDATION_ROOT')
}
Complete-OwnershipFamily 'ownership.legacy.ownership-receipts' 7
if ($script:OwnershipAdapterFailed) { exit 1 }
