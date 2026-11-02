[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $ArtifactRoot,
    [Parameter(Mandatory)][string] $AssemblyPath
)

. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')
$script:OwnershipMockSignals = $true
Import-OwnershipBindings $RepositoryRoot $AssemblyPath
Import-OwnershipBindings $RepositoryRoot $AssemblyPath 'GraphCode.Validation.Ownership.OwnershipJobFixture'
Import-Module (Join-Path $RepositoryRoot 'Tools\windows\ShellProcessOwnership.psm1') -Force -ErrorAction Stop
$gate = Read-OwnershipProductionAst (Join-Path $RepositoryRoot 'Tools\windows\uia-live-gate.ps1')
$jobReplacements = @{
    '[StandaloneProcessJob]' = '[GraphCode.Validation.Ownership.OwnershipJobFixture]'
    '[GraphCode.Validation.Ownership.StandaloneProcessJob]' = '[GraphCode.Validation.Ownership.OwnershipJobFixture]'
}
. Import-OwnershipProductionFunctions $gate @('New-UiaOwnershipFailure', 'Complete-MultiProjectCapture',
    'Start-UiaOwnedProcess', 'Invoke-UiaCleanupActions') $jobReplacements
$saved = [Environment]::GetEnvironmentVariables('Process')
Remove-OwnershipEnvironment 'GRAPHCODE_VALIDATION_ROOT'
try {
    Invoke-OwnershipCase 'cleanup-all-actions-preserve-first-and-retention' {
        $state = @{ calls = 0 }
        $first = [IO.IOException]::new('original cleanup error')
        $tagged = New-UiaOwnershipFailure 'later ownership refusal' 6>$null
        $failure = $null
        try {
            Invoke-UiaCleanupActions @(
                { $state.calls++; throw $first },
                { $state.calls++; throw $tagged },
                { $state.calls++ }
            )
        } catch { $failure = $_ }
        Assert-Ownership ($state.calls -eq 3 -and $failure -and
            [Object]::ReferenceEquals($failure.Exception.InnerExceptions[0], $first) -and
            $failure.Exception.Data['GraphCodeValidationRootRetentionRequired'] -eq $true) 'Cleanup skipped an action, replaced first exception identity, or lost later retention.'
    }
    $boundaries = @($gate.FindAll({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Extent.Text.StartsWith('if ($cleanupFailures.Count -gt 0) {', [StringComparison]::Ordinal)
    }, $true))
    if ($boundaries.Count -ne 1) { throw 'Expected one actual late multi-project cleanup boundary.' }
    foreach ($hasPrimary in @($false, $true)) {
        Invoke-OwnershipCase "late-cleanup-primary-$hasPrimary" {
            $cleanupFailures = [Collections.Generic.List[Exception]]::new()
            $first = [IO.IOException]::new('first phase cleanup error')
            $cleanupFailures.Add($first)
            $cleanupFailures.Add((New-UiaOwnershipFailure 'later phase ownership refusal' 6>$null))
            $primaryError = if ($hasPrimary) {
                [Management.Automation.ErrorRecord]::new([IO.IOException]::new('original phase error'), 'Phase', 'NotSpecified', $null)
            } else { $null }
            $original = $primaryError
            $failure = $null
            try { . ([scriptblock]::Create($boundaries[0].Extent.Text)) } catch { $failure = $_ }
            $reported = if ($hasPrimary) { $primaryError.Exception } else { $failure.Exception }
            Assert-Ownership ($reported -and $reported.Data['GraphCodeValidationRootRetentionRequired'] -eq $true -and
                ((-not $hasPrimary -and [Object]::ReferenceEquals($reported.InnerExceptions[0], $first)) -or
                ($hasPrimary -and -not $failure -and [Object]::ReferenceEquals($primaryError, $original) -and
                    $reported.Message -ceq 'original phase error'))) 'Late cleanup lost ErrorRecord/original exception identity or retention intent.'
        }
    }
    foreach ($variant in @('assigned-success', 'unassigned-barrier', 'root-survivor', 'job-survivor', 'reader-fault', 'primary-and-survivor')) {
        Invoke-OwnershipCase $variant {
            $state = @{ kills = 0; disposed = 0 }
            $root = [pscustomobject]@{
                HasExited = $false
                ExitVerified = $variant -cne 'root-survivor'
                StandardOutput = [IO.StreamReader]::new([IO.MemoryStream]::new())
                StandardError = [IO.StreamReader]::new([IO.MemoryStream]::new())
            }
            $root | Add-Member ScriptMethod Kill { $state.kills++; $this.HasExited = $true }
            $root | Add-Member ScriptMethod WaitForExit { $this.ExitVerified }
            $root | Add-Member ScriptMethod Dispose { $state.disposed++ }
            [GraphCode.Validation.Ownership.OwnershipJobFixture]::Empty = $variant -notin @('job-survivor', 'primary-and-survivor')
            [GraphCode.Validation.Ownership.OwnershipJobFixture]::Terminated = 0
            [GraphCode.Validation.Ownership.OwnershipJobFixture]::Closed = 0
            $capture = [ordered]@{
                process = $root; rootProcess = $root; rootPID = 44; rootStartUtcTicks = 1
                targetPID = 44; targetStartUtcTicks = 1; job = [IntPtr]12
                assigned = $variant -cne 'unassigned-barrier'; stem = 'controlled'; streamingLogs = $true; cleaned = $false
                stdout = [Threading.Tasks.Task]::FromResult[string]('stdout')
                stderr = [Threading.Tasks.Task]::FromResult[string]('stderr')
            }
            if ($variant -ceq 'reader-fault') {
                $capture.stdout = [Threading.Tasks.Task]::FromException[string]([IO.IOException]::new('original reader failure'))
            }
            $primary = if ($variant -ceq 'primary-and-survivor') {
                [Management.Automation.ErrorRecord]::new([IO.IOException]::new('original error'), 'Original', 'NotSpecified', $null)
            } else { $null }
            $originalPrimary = $primary
            $failure = $null
            try { $null = Complete-MultiProjectCapture $capture $ArtifactRoot 1000 $primary } catch { $failure = $_ }
            $succeeded = $variant -in @('assigned-success', 'unassigned-barrier')
            if ($succeeded) {
                Assert-Ownership (-not $failure -and $capture.cleaned -and
                    [GraphCode.Validation.Ownership.OwnershipJobFixture]::Closed -eq 1 -and $state.disposed -eq 1 -and
                    $state.kills -eq [int]($variant -ceq 'unassigned-barrier')) 'Assigned job or unreleased retained barrier cleanup changed.'
            } else {
                $reported = if ($primary) { $primary.Exception } else { $failure.Exception }
                Assert-Ownership ($reported -and $reported.Data['GraphCodeValidationRootRetentionRequired'] -eq $true -and
                    -not $capture.cleaned -and [GraphCode.Validation.Ownership.OwnershipJobFixture]::Closed -eq 0 -and
                    $state.disposed -eq 0 -and $state.kills -eq 0) 'UNKNOWN cleanup released authority/readers or lost retention.'
                if ($primary) {
                    Assert-Ownership (-not $failure -and [Object]::ReferenceEquals($primary, $originalPrimary) -and
                        $primary.Exception.Message -ceq 'original error') 'Cleanup replaced the original ErrorRecord.'
                }
                $root.StandardOutput.Dispose()
                $root.StandardError.Dispose()
            }
        }
    }
    $path = Join-Path $ArtifactRoot ('capture-' + [guid]::NewGuid().ToString('N') + '.log')
    $reader = [IO.StreamReader]::new([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes("first`nsecond")))
    try {
        Invoke-OwnershipCase 'shared-raw-stream' {
            $task = [GraphCode.Validation.Ownership.UiaOwnedStreamCapture]::Read($reader, $path)
            $text = $task.GetAwaiter().GetResult()
            Assert-Ownership ($text -ceq "first`nsecond" -and [IO.File]::ReadAllText($path) -ceq $text) 'Complete production stream capture changed raw output.'
        }
        Invoke-OwnershipCase 'shared-create-new-evidence' {
            $failure = $null
            try { $null = [GraphCode.Validation.Ownership.UiaOwnedStreamCapture]::Read($reader, $path) } catch { $failure = $_ }
            Assert-Ownership ($failure -and [IO.File]::ReadAllText($path) -ceq "first`nsecond") 'Production stream capture overwrote evidence.'
        }
    } finally { $reader.Dispose() }
    $launch = @{}
    function Start-MultiProjectOwnedProcess {
        param($file, $arguments, $environment, $stem, [switch]$Visible, [switch]$RegisterForUia,
            $standardOutputPath, $standardErrorPath, $logDirectory, $targetWorkingDirectory)
        $launch.arguments = $arguments; $launch.environment = $environment
        $launch.visible = $Visible; $launch.registered = $RegisterForUia
        $launch.cwd = $targetWorkingDirectory; $launch.stdout = $standardOutputPath
        return @{ process = 'controlled-owned-target' }
    }
    foreach ($hidden in @($false, $true)) {
        Invoke-OwnershipCase "owned-routing-hidden-$hidden" {
            $stderr = Join-Path $ArtifactRoot 'fixture-stderr.log'
            $result = Start-UiaOwnedProcess -file 'controlled.exe' -arguments @('space argument', '', '"literal"') -standardErrorPath $stderr -Hidden:$hidden
            Assert-Ownership ($result -ceq 'controlled-owned-target' -and $launch.arguments.Count -eq 3 -and
                $launch.arguments[0] -ceq 'space argument' -and $launch.arguments[1] -ceq '' -and
                $launch.arguments[2] -ceq '"literal"' -and $launch.visible -eq (-not $hidden) -and
                $launch.registered -and $launch.cwd -ceq (Get-Location).ProviderPath -and
                $launch.environment.TEMP -ceq $env:TEMP -and
                $launch.stdout -ceq (Join-Path $ArtifactRoot 'fixture-stdout.log')) 'Actual launch wrapper changed argv/environment/cwd/visibility/stdio/registry routing.'
        }
    }
    Invoke-OwnershipCase 'actual-assignment-membership-retain-order' {
        $definition = $gate.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Start-MultiProjectOwnedProcess'
        }, $true)
        Assert-Ownership ($null -ne $definition) 'Actual owned launcher missing.'
        $source = $definition.Extent.Text
        $assign = $source.IndexOf('::Assign')
        $release = $source.IndexOf('[IO.File]::WriteAllText($gate, "assigned")')
        $member = $source.IndexOf('::RequireJobMember')
        $retain = $source.IndexOf('[GraphCodeUiaGateState]::RetainProcess')
        Assert-Ownership ($assign -ge 0 -and $release -gt $assign -and $member -gt $release -and $retain -gt $member) 'Actual gate lost job assignment, native membership or retained input authority order.'
    }
} finally {
    Restore-OwnershipEnvironment $saved @('GRAPHCODE_VALIDATION_ROOT')
}
Complete-OwnershipFamily 'ownership.legacy.capture-ownership' 14
if ($script:OwnershipAdapterFailed) { exit 1 }
