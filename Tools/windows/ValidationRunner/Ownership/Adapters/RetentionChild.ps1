[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][ValidateSet('sentinel', 'receipt-only', 'ordinary', 'isolated')][string] $Mode,
    [Parameter(Mandatory)][int] $ExitCode
)

. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')
Import-Module (Join-Path $RepositoryRoot 'Tools\windows\ShellProcessOwnership.psm1') -Force -ErrorAction Stop
$gate = Read-OwnershipProductionAst (Join-Path $RepositoryRoot 'Tools\windows\uia-live-gate.ps1')
. Import-OwnershipProductionFunctions $gate @('New-UiaOwnershipFailure')
$snapshot = [Environment]::GetEnvironmentVariables('Process')
try {
    if ($Mode -ceq 'isolated') { Remove-OwnershipEnvironment 'GRAPHCODE_VALIDATION_ROOT' }
    $failure = $null
    try {
        if ($Mode -cne 'ordinary') {
            if ($Mode -in @('receipt-only', 'isolated')) {
                $ownership = New-UiaOwnershipFailure 'controlled UIA ownership refusal' 6>$null
                if ($Mode -ceq 'isolated') { Write-Output 'OWNERSHIP_EXPECTED_RETENTION_SIGNAL=observed' }
            } else { $ownership = New-UiaOwnershipFailure 'controlled UIA ownership refusal' }
            throw $ownership
        }
    } catch { $failure = $_.Exception }
    [ordered]@{
        validationRoot = [Environment]::GetEnvironmentVariable('GRAPHCODE_VALIDATION_ROOT', 'Process')
        tagged = $null -ne $failure -and $failure.Data['GraphCodeValidationRootRetentionRequired'] -eq $true
        booleanTag = $null -ne $failure -and $failure.Data['GraphCodeValidationRootRetentionRequired'] -is [bool]
        observedRoots = @($(if ($failure) { $failure.Data['GraphCodeValidationRetainedRoots'] }))
    } | ConvertTo-Json -Compress
} finally {
    Restore-OwnershipEnvironment $snapshot @('GRAPHCODE_VALIDATION_ROOT')
}
exit $ExitCode
