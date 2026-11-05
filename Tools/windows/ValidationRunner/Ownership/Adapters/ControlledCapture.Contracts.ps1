[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $ArtifactRoot,
    [Parameter(Mandatory)][string] $AssemblyPath
)

. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')
Import-OwnershipBindings $RepositoryRoot $AssemblyPath 'GraphCodeUiaGateState'
Import-Module (Join-Path $RepositoryRoot 'Tools\windows\ShellProcessOwnership.psm1') -Force -ErrorAction Stop
$gatePath = Join-Path $RepositoryRoot 'Tools\windows\uia-live-gate.ps1'
$gate = Read-OwnershipProductionAst $gatePath
$windows = Join-Path $RepositoryRoot 'Tools\windows'
$sourceContext = @{
    '$PSScriptRoot' = ("'" + $windows.Replace("'", "''") + "'")
    '$validationAssemblyPath' = ("'" + $AssemblyPath.Replace("'", "''") + "'")
}
. Import-OwnershipProductionFunctions $gate @('Initialize-MultiProjectProcessJob', 'Initialize-UiaOwnedStreamCapture') $sourceContext
. Import-OwnershipProductionFunctions $gate @('New-UiaOwnershipFailure', 'Protect-UiaStartupDiagnosticText',
    'Get-UiaOwnedProcessDescendants', 'Stop-UiaOwnedProcessTrees', 'Start-MultiProjectOwnedProcess',
    'Wait-MultiProjectCapture', 'Complete-MultiProjectCapture')
$childScript = Join-Path $PSScriptRoot 'ControlledCaptureChild.ps1'
$hostPath = Join-Path $PSHOME 'pwsh.exe'
$jobSource = Join-Path $windows 'Tests\Packaging.Standalone.Tests.ps1'
function Start-ControlledCapture([string] $Root, [string] $Mode, [switch] $Register) {
    return Start-MultiProjectOwnedProcess -file $hostPath `
        -arguments @('-NoProfile', '-NonInteractive', '-File', $childScript, '-Root', $Root, '-Mode', $Mode) `
        -environment @{ TEMP = $Root; TMP = $Root } -stem 'controlled' -jobSourcePath $jobSource -RegisterForUia:$Register
}
function Wait-ControlledReady([string] $Root) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists((Join-Path $Root 'ready'))) {
        if ($clock.ElapsedMilliseconds -ge 5000) { throw 'Controlled root did not become ready within its original deadline.' }
        [Threading.Thread]::Sleep(10)
    }
}
foreach ($mode in @('normal', 'stop', 'inherited', 'abrupt', 'timeout', 'inherited-timeout', 'primary-secondary', 'cleanup-only')) {
    Invoke-OwnershipCase $mode {
        $root = Join-Path $env:TEMP ('owned-capture-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root
        $capture = $null
        $lock = $null
        $primary = $null
        try {
            $capture = Start-ControlledCapture $root $mode
            Wait-ControlledReady $root
            if ($mode -in @('timeout', 'inherited-timeout')) {
                try { Wait-MultiProjectCapture $capture 500 } catch { $primary = $_ }
                $expected = if ($mode -ceq 'timeout') { 'MULTIPROJECT_CAPTURE_EXIT' } else { 'MULTIPROJECT_CAPTURE_DRAIN' }
                Assert-Ownership ($primary -and $primary.Exception.Message.StartsWith($expected, [StringComparison]::Ordinal)) "Actual $expected timeout path did not run."
            } elseif ($mode -ceq 'inherited') {
                Assert-Ownership ($capture.rootProcess.WaitForExit(5000) -and -not $capture.stdout.IsCompleted -and
                    [GraphCode.Validation.Ownership.StandaloneProcessJob]::Active($capture.job) -gt 0) 'No actual inherited-open-pipe/job condition was exercised.'
            } elseif ($mode -cne 'stop') {
                Wait-MultiProjectCapture $capture 5000
                Assert-Ownership ($capture.rootProcess.ExitCode -eq $(if ($mode -ceq 'abrupt') { 23 } else { 0 })) 'Actual controlled root exit code differs.'
            }
            if ($mode -in @('primary-secondary', 'cleanup-only')) {
                $lock = [IO.File]::Open((Join-Path $root 'controlled-stdout.log'), [IO.FileMode]::OpenOrCreate,
                    [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                if ($mode -ceq 'primary-secondary') {
                    try { throw [IO.IOException]::new('controlled original primary failure') } catch { $primary = $_ }
                }
            }
            $original = $primary
            $clock = [Diagnostics.Stopwatch]::StartNew()
            if ($mode -ceq 'cleanup-only') {
                $failure = $null
                try { $null = Complete-MultiProjectCapture $capture $root 3000 } catch { $failure = $_ }
                Assert-Ownership ($failure -and $failure.Exception.Message.StartsWith('MULTIPROJECT_TEARDOWN:', [StringComparison]::Ordinal) -and
                    $failure.Exception.Message.Contains('stdout capture persistence') -and $failure.Exception.Message.Contains('pid=') -and
                    $failure.Exception.Message.Contains('start=') -and $failure.Exception.Message.Contains('job=') -and $capture.cleaned) 'Cleanup-only error lost exact identity, persistence failure, or completed ownership proof.'
            } else {
                $diagnostic = Complete-MultiProjectCapture $capture $root 3000 $primary
                Assert-Ownership ($diagnostic.rootExited -and $diagnostic.ownedJobEmpty -and
                    $diagnostic.redirectedReadersDrained -and $clock.ElapsedMilliseconds -lt 5000 -and $capture.cleaned) 'Actual shared bounded teardown did not prove root/job/both reader completion.'
                if ($mode -ceq 'primary-secondary') {
                    Assert-Ownership ([Object]::ReferenceEquals($primary, $original) -and $primary.Exception.Message -ceq 'controlled original primary failure' -and
                        $primary.Exception.Data['MultiProjectTeardown:controlled'].Contains('stdout capture persistence')) 'Cleanup replaced the actual primary ErrorRecord or lost explicit secondary persistence diagnostics.'
                } elseif ($primary) {
                    Assert-Ownership ([Object]::ReferenceEquals($primary, $original) -and $diagnostic.failures.Count -eq 0 -and
                        $primary.Exception.Data['MultiProjectCapture:controlled'].redirectedReadersDrained) 'Timeout primary lost its identity or positive post-teardown drain diagnostics.'
                }
            }
            [IO.File]::WriteAllText((Join-Path $root 'capture-task-text.json'), (@{
                stdoutType = $capture.stdout.GetType().FullName
                stdoutResult = $capture.stdout.Result
                stdoutAwait = $capture.stdout.GetAwaiter().GetResult()
                stderrResult = $capture.stderr.Result
                stderrAwait = $capture.stderr.GetAwaiter().GetResult()
            } | ConvertTo-Json -Compress))
            $capture = $null
            if ($mode -notin @('primary-secondary', 'cleanup-only')) {
                Assert-Ownership ([IO.File]::ReadAllText((Join-Path $root 'controlled-stdout.log')).Contains('owned-capture-stdout') -and
                    [IO.File]::ReadAllText((Join-Path $root 'controlled-stderr.log')).Contains('owned-capture-stderr')) 'Actual independent stdout/stderr evidence was lost.'
            }
        } finally {
            if ($lock) { $lock.Dispose() }
            if ($capture -and -not $capture.cleaned) { $null = Complete-MultiProjectCapture $capture $root 3000 $primary }
        }
    }
    $groups = @('controlled-native', 'bounded-capture-eight-modes')
    if ($mode -in @('primary-secondary', 'cleanup-only')) { $groups += 'primary-and-cleanup-errors' }
    Complete-OwnershipFamily ("ownership.mixed-capture." + $mode) 1 $groups
}
$treeRoot = Join-Path $env:TEMP ('owned-tree-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $treeRoot
$tree = $null
try {
    $script:UiaGateOwnedCaptures = [Collections.Generic.List[object]]::new()
    Invoke-OwnershipCase 'controlled-child' {
        $script:OwnershipControlledTree = Start-ControlledCapture $treeRoot 'tree' -Register
        $tree = $script:OwnershipControlledTree
        Wait-ControlledReady $treeRoot
        $descendants = @(Get-UiaOwnedProcessDescendants @($tree.process.Id))
        Assert-Ownership ($descendants.Count -gt 0) 'Actual advisory traversal missed the controlled child.'
        Assert-Ownership ([GraphCode.Validation.Ownership.StandaloneProcessJob]::Contains($tree.job, $tree.process.Handle) -and
            [GraphCode.Validation.Ownership.StandaloneProcessJob]::Active($tree.job) -ge 2) 'Actual retained target lacks native job membership or a positive owned census.'
    }
    $tree = $script:OwnershipControlledTree
    Complete-OwnershipFamily 'ownership.ui-process-tree.controlled-child' 1 @('controlled-native')
    Invoke-OwnershipCase 'cleanup-complete' {
        Assert-Ownership ($null -ne $tree) 'Controlled tree prerequisite did not launch.'
        Stop-UiaOwnedProcessTrees @($tree.process)
        Assert-Ownership $tree.cleaned 'Actual registered gate tree cleanup returned without completing root/job/readers.'
    }
    Complete-OwnershipFamily 'ownership.ui-process-tree.cleanup-complete' 1 @('controlled-native')
} finally {
    if ($tree -and -not $tree.cleaned) { Stop-UiaOwnedProcessTrees @($tree.process) }
}
if ($script:OwnershipAdapterFailed) { exit 1 }
