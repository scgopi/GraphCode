[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $ArtifactRoot,
    [Parameter(Mandatory)][string] $AssemblyPath
)

. (Join-Path $PSScriptRoot 'AdapterSupport.ps1')
[Reflection.Assembly]::LoadFrom($AssemblyPath) | Out-Null
$source = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'Tools\windows\validate.ps1'))
$region = [regex]::Match($source,
    '(?s)      \$preUiaProcesses =.*?(?=      Invoke-Native "Native UI Automation live gate")')
if (-not $region.Success) { throw 'Actual pre-UIA advisory isolation guard is missing.' }
$guard = [scriptblock]::Create($region.Value + "`n`$state.gateEntries++")
$repoRoot = Join-Path $ArtifactRoot 'pre-uia-repo'
$created = [datetime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
function New-IsolationObservation([int] $PidValue, [string] $Path, [datetime] $Creation) {
    [pscustomobject]@{
        ProcessId = $PidValue; ParentProcessId = 4000; ExecutablePath = $Path
        CreationDate = $Creation; Name = [IO.Path]::GetFileName($Path); SessionId = 1
    }
}
$shell = New-IsolationObservation 4242 (Join-Path $repoRoot 'graphcode-windows.exe') $created
$daemon = New-IsolationObservation 4243 (Join-Path $repoRoot 'graphcoded.exe') $created
$foreign = New-IsolationObservation 4244 (Join-Path $ArtifactRoot 'foreign\graphcoded.exe') $created
$sibling = New-IsolationObservation 4245 (Join-Path ($repoRoot + '-other') 'graphcoded.exe') $created
$reused = New-IsolationObservation 4242 $shell.ExecutablePath $created.AddSeconds(1)
$uppercase = New-IsolationObservation 4246 $shell.ExecutablePath.ToUpperInvariant() $created
$cases = @(
    @{ id = 'unexpected-shell'; rows = @($shell); baseline = @(); refused = @(4242) },
    @{ id = 'unexpected-daemon'; rows = @($daemon); baseline = @(); refused = @(4243) },
    @{ id = 'empty-inventory'; rows = @(); baseline = @(); refused = @() },
    @{ id = 'baseline-generation'; rows = @($shell); baseline = @($shell); refused = @() },
    @{ id = 'foreign-repository'; rows = @($foreign); baseline = @(); refused = @() },
    @{ id = 'sibling-prefix'; rows = @($sibling); baseline = @(); refused = @() },
    @{ id = 'reused-baseline-pid'; rows = @($reused); baseline = @($shell); refused = @(4242) },
    @{ id = 'multiple-candidates'; rows = @($shell, $daemon); baseline = @(); refused = @(4242, 4243) },
    @{ id = 'case-insensitive-repository'; rows = @($uppercase); baseline = @(); refused = @(4246) },
    @{ id = 'baseline-and-unexpected'; rows = @($shell, $daemon); baseline = @($shell); refused = @(4243) }
)
function Get-CimInstance {
    param($ClassName, $Filter, $ErrorAction)
    $state.probes++
    Assert-Ownership ($ClassName -ceq 'Win32_Process' -and
        $Filter -ceq "Name = 'graphcode-windows.exe' OR Name = 'graphcoded.exe'") 'Guard changed its single advisory query.'
    return $state.rows
}
function Stop-Process { $state.terminations++; throw 'Forbidden CIM-only termination.' }
function Get-Process { throw 'Advisory guard must not acquire or terminate a process.' }
function Start-Sleep { throw 'Advisory guard must not poll.' }
function Write-Host { param($Object) $state.messages.Add([string]$Object) }
foreach ($case in $cases) {
    Invoke-OwnershipCase $case.id {
        $state = @{ rows = $case.rows; probes = 0; terminations = 0; gateEntries = 0; messages = [Collections.Generic.List[string]]::new() }
        $uiaProductProcessBaseline = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $case.baseline) {
            $null = $uiaProductProcessBaseline.Add("$([int]$entry.ProcessId)|$($entry.CreationDate.ToUniversalTime().ToString('o'))")
        }
        $failure = $null
        try { & $guard | Out-Null } catch { $failure = $_ }
        Assert-Ownership ($state.probes -eq 1 -and $state.terminations -eq 0) 'Advisory query was repeated or used as termination authority.'
        $snapshots = @($state.messages | Where-Object { $_.StartsWith('WINDOWS_SHELL_PRE_UIA_PROCESS_SNAPSHOT=', [StringComparison]::Ordinal) })
        Assert-Ownership ($snapshots.Count -eq 1) 'Advisory snapshot missing or duplicated.'
        $snapshot = @($snapshots[0].Substring('WINDOWS_SHELL_PRE_UIA_PROCESS_SNAPSHOT='.Length) | ConvertFrom-Json)
        Assert-Ownership ($snapshot.Count -eq $case.rows.Count) 'Snapshot lost original observations.'
        if ($case.refused.Count -gt 0) {
            Assert-Ownership ($failure -and $failure.Exception.Message.Contains('not attested as run-owned') -and
                $failure.Exception.Message.Contains('no processes were terminated') -and
                $failure.Exception.Data['GraphCodeValidationRootRetentionRequired'] -ceq $true -and
                $state.gateEntries -eq 0) 'Guard did not refuse before gate with exact retention and authority diagnostics.'
            foreach ($observedPid in $case.refused) {
                Assert-Ownership ($failure.Exception.Message -match "(?<![0-9])$observedPid(?![0-9])") 'Guard omitted a refused PID.'
            }
            Assert-Ownership (@($state.messages | Where-Object { $_.StartsWith('WINDOWS_SHELL_PRE_UIA_CLEANUP=') }).Count -eq 0) 'Refusal claimed cleanup success.'
        } else {
            Assert-Ownership (-not $failure -and $state.gateEntries -eq 1 -and
                @($state.messages | Where-Object { $_ -ceq 'WINDOWS_SHELL_PRE_UIA_CLEANUP=no_candidates_observed terminated=0' }).Count -eq 1) 'No-candidate branch changed.'
        }
    }
}
Complete-OwnershipFamily 'ownership.legacy.pre-uia-isolation' 10
if ($script:OwnershipAdapterFailed) { exit 1 }
