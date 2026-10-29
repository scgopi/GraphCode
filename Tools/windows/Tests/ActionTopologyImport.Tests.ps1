param(
    [string]$ScratchRoot = (Join-Path ([IO.Path]::GetTempPath()) ('at' + [guid]::NewGuid().ToString('N').Substring(0,8)))
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$driverDirectory = Split-Path -Parent $PSScriptRoot
$workerPath = Join-Path $driverDirectory 'Invoke-UiCaptureWorker.ps1'
$caseRoot = [IO.Path]::GetFullPath($ScratchRoot)
if (Test-Path -LiteralPath $caseRoot) {throw "Refusing to replace topology evidence: $caseRoot"}
$null = New-Item -ItemType Directory -Path $caseRoot
. $workerPath -OwnedRoot $caseRoot -DefinitionsOnly
Import-Module $modulePath -Force -WarningAction SilentlyContinue
Set-CapTracePath -Path (Join-Path $caseRoot 'calls.jsonl')
$results = [Collections.Generic.List[object]]::new()

function Assert-TopologyCase {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) {throw $Message}
}

function Reject-TopologyCase {
    param([string]$Name,[scriptblock]$Action,[string]$Message)
    $failure=$null
    try {& $Action | Out-Null} catch {$failure=$_}
    Assert-TopologyCase ($null -ne $failure -and $failure.Exception.Message.Contains($Message)) `
        "Expected $Name refusal '$Message'; actual=$failure"
    $results.Add(@{name=$Name;passed=$true;refusal=$failure.Exception.Message})
}

$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($workerPath,[ref]$null,[ref]$parseErrors)
Assert-TopologyCase ($parseErrors.Count -eq 0) 'Worker must parse.'
foreach ($name in @('Install-CapQualifiedActionTopology','Start-CapMatchedActionSeeds','Close-CapMatchedActionSeeds')) {
    $command=Get-Command $name -CommandType Function -ErrorAction SilentlyContinue
    Assert-TopologyCase ($null -ne $command) "Production DefinitionsOnly import did not expose $name."
    $results.Add(@{name="production import exposes $name";passed=$true})
    $definitions=@($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    },$true))
    Assert-TopologyCase ($definitions.Count -eq 1 -and $definitions[0].Parent.Parent -eq $ast) `
        "$name must have exactly one top-level definition, not an offline-seed-local definition."
    $results.Add(@{name="lexical top-level $name";passed=$true})
}

$inputRoot=Join-Path $caseRoot 'inputs'
$sessionRoot=Join-Path $inputRoot 'shell-sessions'
$null=New-Item -ItemType Directory -Path $sessionRoot
$layoutPath=Join-Path $inputRoot 'layout.json'
[IO.File]::WriteAllText($layoutPath,'{"schemaVersion":2}',[Text.UTF8Encoding]::new($false))
$sessionName='graphcode-11111111-1111-4111-8111-000000000001'
$loop='11111111-1111-4111-8111-000000000001'
$sessionPath=Join-Path $sessionRoot $sessionName
[IO.File]::WriteAllText($sessionPath,$loop,[Text.UTF8Encoding]::new($false))
$topology=[pscustomobject]@{
    scene='s-tabs-two-agent-selected';loop=$loop
    sourceLayoutSha256=('A'*64);preparedLayoutPath=$layoutPath
    preparedLayoutSha256=(Get-FileHash $layoutPath).Hash
    shellSessionsPath=$sessionRoot
    sessions=@(
        [pscustomobject]@{name=$sessionName;agent=$false;preparedSha256=(Get-FileHash $sessionPath).Hash},
        [pscustomobject]@{name='graphcode-22222222-2222-4222-8222-000000000002';agent=$true;preparedSha256=$null}
    )
}
$job=[pscustomobject]@{sceneAdapter='S_MATCHED_V12_DPI_V1'}
$roots=Initialize-CapPhaseRoot -PhaseRoot (Join-Path $caseRoot 'phase')
$installed=Install-CapQualifiedActionTopology -Roots $roots -Topology $topology
Assert-TopologyCase ($installed.layoutSha256 -ceq $topology.preparedLayoutSha256 -and
    $installed.sourceLayoutSha256 -ceq $topology.sourceLayoutSha256 -and
    $installed.sessionCount -eq 2 -and $installed.shellSessionCount -eq 1 -and
    [IO.File]::ReadAllText((Join-Path $roots.Root "shell-sessions\$sessionName")) -ceq $loop -and
    @(Get-ChildItem (Join-Path $roots.Root 'shell-sessions') -File).Count -eq 1) `
    'Qualified install did not preserve exact layout bytes and non-agent ownership.'
$results.Add(@{name='qualified topology installs exact bytes and shell ownership';passed=$true})
$originalLayoutHash=$topology.preparedLayoutSha256
$topology.preparedLayoutSha256='0'*64
Reject-TopologyCase 'changed layout hash' {Install-CapQualifiedActionTopology $roots $topology} 'Prepared qualified layout changed'
$topology.preparedLayoutSha256=$originalLayoutHash
$originalSessionHash=$topology.sessions[0].preparedSha256
$topology.sessions[0].preparedSha256='0'*64
Reject-TopologyCase 'changed session hash' {Install-CapQualifiedActionTopology $roots $topology} 'Prepared shell-session identity changed'
$topology.sessions[0].preparedSha256=$originalSessionHash
$topology.preparedLayoutPath=Join-Path $inputRoot 'missing.json'
Reject-TopologyCase 'missing layout' {Install-CapQualifiedActionTopology $roots $topology} 'missing.json'
$topology.preparedLayoutPath=$layoutPath

# Fail before any launcher can be created, even if prepare-only routing regresses.
$script:launcherCalls=0
function Start-CapJobLauncher {
    param($Root,$OutputDirectory,$FilePath,$ArgumentList,$WorkingDirectory,$Role,$Environment)
    $script:launcherCalls++
    throw 'TOPOLOGY_TEST_LAUNCH_INTERCEPTED'
}
$actionSeedHelperPath=Join-Path $driverDirectory 'Start-MatchedActionSessions.ps1'
$seedPlan=Start-CapMatchedActionSeeds -Roots $roots -Phase 'after-test' -Topology $topology -PrepareOnly
$seedManifest=Get-Content $seedPlan.sessionManifestPath -Raw | ConvertFrom-Json -DateKind String
Assert-TopologyCase ($seedPlan.status -ceq 'PREPARED_NO_LAUNCH' -and $script:launcherCalls -eq 0 -and
    $seedPlan.phase -ceq 'after-test' -and $seedManifest.schemaVersion -eq 1 -and
    ($seedManifest.sessions -join '|') -ceq ($topology.sessions.name -join '|') -and
    $seedPlan.sessionManifest.sha256 -ceq (Get-FileHash $seedPlan.sessionManifestPath).Hash -and
    $seedPlan.filePath -ieq (Join-Path $PSHOME 'pwsh.exe') -and
    ($seedPlan.argumentList -join '|') -ceq (
        @('-NoProfile','-NonInteractive','-File',$actionSeedHelperPath,
            '-ZmxPath',(Join-Path $caseRoot 'runtime\zmx.exe'),
            '-SessionManifestPath',$seedPlan.sessionManifestPath) -join '|') -and
    $runs.Count -eq 0 -and $actionSeedRuns.Count -eq 0 -and $zmxSeedReceipts.Count -eq 0) `
    'Prepare-only seed path launched, fabricated readiness, or changed the actual seed invocation.'
$results.Add(@{name='prepare-only plans exact seed manifest and invocation without launch or receipts';passed=$true})
$defaultRoots=Initialize-CapPhaseRoot -PhaseRoot (Join-Path $caseRoot 'default')
Reject-TopologyCase 'default seed still reaches real launcher' {
    Start-CapMatchedActionSeeds -Roots $defaultRoots -Phase 'after-test' -Topology $topology
} 'TOPOLOGY_TEST_LAUNCH_INTERCEPTED'
Assert-TopologyCase ($script:launcherCalls -eq 1) 'Default seed must reach launcher exactly once.'
foreach ($fault in @('empty','duplicate')) {
    $bad=$topology | ConvertTo-Json -Depth 20 | ConvertFrom-Json -DateKind String
    if ($fault -ceq 'empty') {$bad.sessions=@()}
    else {$bad.sessions=@($topology.sessions[0],$topology.sessions[0])}
    Reject-TopologyCase "$fault sessions" {
        Start-CapMatchedActionSeeds -Roots $roots -Phase 'after-test' -Topology $bad -PrepareOnly
    } 'missing or duplicate sessions'
}
Assert-TopologyCase ($script:launcherCalls -eq 1) 'Invalid seed inventory reached launcher.'

$script:closeCalls=0
function Close-CapJobLauncher {
    param($Run)
    $script:closeCalls++
    return [pscustomobject]@{kind='TEST_ONLY_NO_PROCESS';jobActive0=$true}
}
$seedRun=[pscustomobject]@{CleanupComplete=$false;OutputProof=$null
    SeedReceipt=[pscustomobject]@{cleanupStatus='PENDING';outputProof=$null}}
$proof=Close-CapMatchedActionSeeds -SeedRun $seedRun
Assert-TopologyCase ($script:closeCalls -eq 1 -and $seedRun.SeedReceipt.cleanupStatus -ceq 'CLOSED' -and
    $seedRun.SeedReceipt.outputProof -eq $proof -and $cleanupReceipts.Count -eq 1) `
    'Imported cleanup helper did not preserve lifecycle receipt.'
$results.Add(@{name='imported seed cleanup preserves existing lifecycle receipt';passed=$true})
$seedRun.CleanupComplete=$true
$seedRun.OutputProof=$proof
$again=Close-CapMatchedActionSeeds -SeedRun $seedRun
Assert-TopologyCase ($script:closeCalls -eq 1 -and $again -eq $proof -and $cleanupReceipts.Count -eq 1) `
    'Completed seed cleanup must not close or publish twice.'
$results.Add(@{name='completed seed cleanup remains idempotent';passed=$true})

$report=[ordered]@{suite='ActionTopologyImport';executed=$results.Count;passed=$results.Count;failed=0;skipped=0
    productLaunches=0;providerLaunches=0;cases=@($results)}
[IO.File]::WriteAllText((Join-Path $caseRoot 'report.json'),($report|ConvertTo-Json -Depth 30),
    [Text.UTF8Encoding]::new($false))
[pscustomobject]$report | Select-Object suite,executed,passed,failed,skipped | ConvertTo-Json -Compress
if ($results.Count -ne 16) {throw "Unexpected action topology contract count: $($results.Count)"}
