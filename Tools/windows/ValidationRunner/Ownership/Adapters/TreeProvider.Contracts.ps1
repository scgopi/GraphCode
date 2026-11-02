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
$gatePath = Join-Path $RepositoryRoot 'Tools\windows\uia-live-gate.ps1'
$gate = Read-OwnershipProductionAst $gatePath
. Import-OwnershipProductionFunctions $gate @('New-UiaOwnershipFailure', 'Get-UiaOwnedProcessDescendants', 'Stop-UiaOwnedProcessTrees',
    'Stop-UiaOwnedProviderProcesses') @{ '[Diagnostics.Process[]]' = '[object[]]' }
$saved = [Environment]::GetEnvironmentVariables('Process')
Remove-OwnershipEnvironment 'GRAPHCODE_VALIDATION_ROOT'
try {
    function Protect-UiaStartupDiagnosticText { param($text) return $text }
    $state = @{ childKills = 0; rootKills = 0; completions = [Collections.Generic.List[string]]::new(); refuse = $false }
    function Complete-MultiProjectCapture($capture, $logDirectory) {
        $state.completions.Add($capture.stem)
        if ($state.refuse -and $capture.stem -ceq 'first') { throw (New-UiaOwnershipFailure 'controlled job survivor') }
        $capture.cleaned = $true
    }
    $created = [datetime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    function Get-CimInstance {
        param($ClassName, $Filter)
        @(
            [pscustomobject]@{ ProcessId = 44; ParentProcessId = 1; CreationDate = $created; Name = 'root.exe'; ExecutablePath = 'D:\root.exe' }
            [pscustomobject]@{ ProcessId = 9931; ParentProcessId = 44; CreationDate = $created.AddSeconds(1); Name = 'child.exe'; ExecutablePath = 'D:\child.exe' }
        ) | Where-Object { -not $Filter -or $_.ProcessId -eq 9931 }
    }
    function Get-Process {
        $child = [pscustomobject]@{ HasExited = $false }
        $child | Add-Member ScriptMethod Kill { $state.childKills++ }
        $child | Add-Member ScriptMethod WaitForExit { $true }
        $child | Add-Member ScriptMethod Dispose {}
        return $child
    }
    $root = [pscustomobject]@{ Id = 44; HasExited = $false }
    $root | Add-Member ScriptMethod Kill { $state.rootKills++ }
    $root | Add-Member ScriptMethod WaitForExit { $true }
    Invoke-OwnershipCase 'unowned-root' {
        $script:UiaGateOwnedCaptures = @()
        $failure = $null
        try { Stop-UiaOwnedProcessTrees @($root) } catch { $failure = $_ }
        Assert-Ownership ($failure -and $failure.Exception.Data['GraphCodeValidationRootRetentionRequired'] -eq $true -and
            $state.rootKills -eq 0 -and $state.childKills -eq 0) 'Advisory process observations supplied termination authority.'
    }
    Invoke-OwnershipCase 'no-launch' {
        $script:UiaGateOwnedCaptures = @()
        $output = @(Stop-UiaOwnedProcessTrees @() 6>&1) -join "`n"
        Assert-Ownership ($output.Contains('CLEANUP=not_needed') -and -not $output.Contains('CLEANUP=verified')) 'Empty registry claimed verified cleanup.'
    }
    foreach ($refuse in @($true, $false)) {
        Invoke-OwnershipCase "owned-jobs-refusal-$refuse" {
            $state.refuse = $refuse
            $state.completions.Clear()
            $other = [pscustomobject]@{ Id = 45; HasExited = $false }
            $script:UiaGateOwnedCaptures = @(
                @{ process = $root; stem = 'first'; logDirectory = $ArtifactRoot; cleaned = $false },
                @{ process = $other; stem = 'second'; logDirectory = $ArtifactRoot; cleaned = $false }
            )
            $failure = $null
            try { Stop-UiaOwnedProcessTrees @($root, $other) } catch { $failure = $_ }
            Assert-Ownership (($state.completions -join ',') -ceq 'first,second' -and
                ($null -ne $failure) -eq $refuse -and
                (-not $refuse -or $failure.Exception.Data['GraphCodeValidationRootRetentionRequired'] -eq $true) -and
                $state.rootKills -eq 0 -and $state.childKills -eq 0) 'Later owned lease skipped, primary retention lost, or CIM-only target killed.'
        }
    }
    Complete-OwnershipFamily 'ownership.legacy.tree-ownership' 4
    $expected = 'D:\ownership-provider\zmx.exe'
    $candidate = [pscustomobject]@{
        Name = 'zmx.exe'; ProcessId = 9931; ExecutablePath = $expected; CreationDate = $created
    }
    Invoke-OwnershipCase 'foreign-window-hiding-removed' {
        Assert-Ownership (-not [IO.File]::ReadAllText($gatePath).Contains('Hide-TestProviderZmxWindows')) 'Unattested global provider-window hiding remains reachable.'
    }
    foreach ($variant in @('unattested-provider', 'baseline-provider', 'empty-inventory')) {
        Invoke-OwnershipCase $variant {
            $provider = @{ kills = 0; rows = @($candidate) }
            if ($variant -ceq 'empty-inventory') { $provider.rows = @() }
            $baseline = [Collections.Generic.HashSet[string]]::new()
            if ($variant -ceq 'baseline-provider') { $null = $baseline.Add("$($candidate.ProcessId)|$([string]$candidate.CreationDate)") }
            function Get-CimInstance { return $provider.rows }
            function Get-Process {
                $process = [pscustomobject]@{ HasExited = $false }
                $process | Add-Member ScriptMethod Kill { $provider.kills++ }
                $process | Add-Member ScriptMethod WaitForExit { $true }
                $process | Add-Member ScriptMethod Dispose {}
                return $process
            }
            $failure = $null
            try { Stop-UiaOwnedProviderProcesses $expected $baseline } catch { $failure = $_ }
            $mustRefuse = $variant -ceq 'unattested-provider'
            Assert-Ownership ($provider.kills -eq 0 -and ($null -ne $failure) -eq $mustRefuse -and
                (-not $mustRefuse -or ($failure.Exception.Data['GraphCodeValidationRootRetentionRequired'] -is [bool] -and
                    $failure.Exception.Data['GraphCodeValidationRootRetentionRequired']))) 'Provider advisory inventory was elevated to authority or its refusal/tag changed.'
        }
    }
    Complete-OwnershipFamily 'ownership.legacy.provider-ownership' 4
} finally {
    Restore-OwnershipEnvironment $saved @('GRAPHCODE_VALIDATION_ROOT')
}
if ($script:OwnershipAdapterFailed) { exit 1 }
