[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $ArtifactRoot,
    [Parameter(Mandatory)][string] $AssemblyPath
)

. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')
$script:OwnershipMockSignals = $true
Import-OwnershipBindings $RepositoryRoot $AssemblyPath
$consumer = Read-OwnershipProductionAst (Join-Path $RepositoryRoot 'Tools\windows\validate.ps1')
. Import-OwnershipProductionFunctions $consumer @('Invoke-Native', 'Get-WindowsShellProfileSnapshot',
    'Assert-WindowsShellProfileUnchanged', 'Invoke-WindowsShellValidationIsolation')
$keys = @('GRAPHCODE_VALIDATION_ROOT', 'GRAPHCODE_SUPPORT_DIR', 'LOCALAPPDATA', 'TEMP', 'TMP')
$before = [Environment]::GetEnvironmentVariables('Process')
$fixture = Join-Path $ArtifactRoot ('retention-boundary-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$child = Join-Path $PSScriptRoot 'RetentionChild.ps1'
$cases = @(
    @{ id = 'sentinel-exit17'; mode = 'sentinel'; code = 17 },
    @{ id = 'sentinel-exit0'; mode = 'sentinel'; code = 0 },
    @{ id = 'receipt-only-exit17'; mode = 'receipt-only'; code = 17 },
    @{ id = 'receipt-only-exit0'; mode = 'receipt-only'; code = 0 },
    @{ id = 'ordinary-exit17'; mode = 'ordinary'; code = 17 },
    @{ id = 'isolated-mock-exit0'; mode = 'isolated'; code = 0 }
)
try {
    foreach ($case in $cases) {
        Invoke-OwnershipCase $case.id {
            $state = @{ root = $null; output = [Collections.Generic.List[string]]::new() }
            $failure = $null
            try {
                Invoke-WindowsShellValidationIsolation -WorkspaceRoot $fixture -ValidationRootParent (Join-Path $fixture 'isolations') `
                    -UserProfileRoot (Join-Path $fixture 'profile') -LocalAppDataRoot (Join-Path $fixture 'local') -Action {
                    $state.root = $env:GRAPHCODE_VALIDATION_ROOT
                    Invoke-Native 'controlled actual UIA retention boundary' {
                        & $pwsh -NoProfile -NonInteractive -File $child -RepositoryRoot $RepositoryRoot -Mode $case.mode -ExitCode $case.code
                    } | ForEach-Object { $state.output.Add([string]$_) }
                }
            } catch { $failure = $_ }
            $sentinels = @($state.output | Where-Object { $_ -ceq 'GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven' })
            $observations = @($state.output | Where-Object { $_.StartsWith('{"validationRoot":', [StringComparison]::Ordinal) })
            Assert-Ownership ($observations.Count -eq 1) 'Child did not emit exactly one typed observation.'
            $observed = $observations[0] | ConvertFrom-Json
            $reportsOwnership = $case.mode -in @('sentinel', 'receipt-only')
            $tagged = $case.mode -cne 'ordinary'
            $retained = $reportsOwnership -or $case.code -ne 0
            $expectedRoot = if ($case.mode -ceq 'isolated') { $null } else { $state.root }
            Assert-Ownership (($null -ne $failure) -eq $retained -and $LASTEXITCODE -eq $case.code -and
                $sentinels.Count -eq [int]($case.mode -ceq 'sentinel') -and $observed.validationRoot -ceq $expectedRoot -and
                $observed.tagged -eq $tagged -and $observed.booleanTag -eq $tagged -and
                (Test-Path -LiteralPath $state.root) -eq $retained -and
                ($null -ne $failure -and $failure.Exception.Data['GraphCodeValidationRootRetentionRequired'] -eq $true) -eq $retained) `
                'Actual retention signal/receipt/exit/root disposition or LASTEXITCODE differs.'
            if ($reportsOwnership) {
                Assert-Ownership (@($observed.observedRoots).Count -eq 1 -and $observed.observedRoots[0] -ceq $state.root -and
                    $failure.Exception.Data['GraphCodeValidationRetainedRoots'] -contains $state.root) 'Exact root identity lost at actual consumer boundary.'
                $bytes = [IO.File]::ReadAllBytes((Join-Path $state.root 'ownership-unproven.json'))
                Assert-Ownership ($bytes.Length -gt 0 -and $bytes.Length -le 4096) 'Actual child did not publish bounded receipt.'
                $receipt = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) | ConvertFrom-Json
                Assert-Ownership ($receipt.schemaVersion -eq 1 -and $receipt.validationRoot -ceq $state.root -and
                    $receipt.reason -ceq 'ownership_unproven') 'Actual child receipt payload changed.'
            }
            if ($case.mode -ceq 'ordinary') {
                Assert-Ownership ($failure.Exception.Data['GraphCodeValidationRootRetentionReason'] -ceq 'workload_failed_without_cleanup_proof') 'Unclassified workload failure lost conservative disposition.'
            }
            if ($case.mode -ceq 'isolated') {
                Assert-Ownership (@($observed.observedRoots).Count -eq 0 -and
                    @($state.output | Where-Object { $_ -ceq 'OWNERSHIP_EXPECTED_RETENTION_SIGNAL=observed' }).Count -eq 1) 'Mock isolation leaked root authority or did not observe the exact retention signal.'
            }
            $after = [Environment]::GetEnvironmentVariables('Process')
            foreach ($key in $keys) {
                Assert-Ownership ($before.Contains($key) -eq $after.Contains($key) -and
                    (-not $before.Contains($key) -or [string]$before[$key] -ceq [string]$after[$key])) "Isolation changed environment membership/value: $key"
            }
        }
    }
} finally {
    Restore-OwnershipEnvironment $before $keys
}
Complete-OwnershipFamily 'ownership.legacy.retention-boundary' 6
if ($script:OwnershipAdapterFailed) { exit 1 }
