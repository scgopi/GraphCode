param(
    [string]$ScratchRoot = (Join-Path ([IO.Path]::GetTempPath()) ('ab' + [guid]::NewGuid().ToString('N').Substring(0,8))),
    [switch]$FunctionalOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$driverDirectory=Split-Path -Parent $PSScriptRoot
$caseRoot=[IO.Path]::GetFullPath($ScratchRoot)
if (Test-Path -LiteralPath $caseRoot) {throw "Refusing to replace binding evidence: $caseRoot"}
$null=New-Item -ItemType Directory -Path $caseRoot
. (Join-Path $driverDirectory 'Invoke-UiCaptureWorker.ps1') -OwnedRoot $caseRoot -DefinitionsOnly
Import-Module $modulePath -Force -WarningAction SilentlyContinue
Set-CapTracePath -Path (Join-Path $caseRoot 'calls.jsonl')
function Invoke-FunctionalWireContracts {
    $source=Join-Path $PSScriptRoot 'fixtures\c8r-window-after.zig'
    $contract=[pscustomobject]@{
        schemaVersion=1L;scene='s-goal-unwired-unselected'
        windowSourcePath=$source;windowSourceSha256=(Get-FileHash -LiteralPath $source).Hash
        placement='MEASURED_OWNED_WINDOW_FIT_WORKAREA';preferredLogicalClientWH=@(1280L,720L)
        pngAllowed=$false;visualParityClaimed=$false;applicationSourceTree=('b'*40)
    }
    $functional=[pscustomobject]@{
        head=('a'*40);sceneAdapter='S_FUNCTIONAL_W1_V1';functionalWireOnly=$true
        functionalWireContract=$contract
        binaries=[pscustomobject]@{after=[pscustomobject]@{source=('a'*40);binaryBuiltAtSource=('a'*40)}}
    }
    $binding=@(Get-CapActionWindowBindings -Job $functional -Group WireCompletion)
    if ($binding.Count -ne 1 -or $binding[0].actionPhase -cne 'wire-completion' -or
        ($binding[0].actionIds -join ',') -cne 'W1' -or
        $binding[0].identity.measurement -cne 'REQUIRED_AT_OWNED_WINDOW_STARTUP') {
        throw 'Functional W1 must resolve through the actual action binding without invented DPI/image evidence.'
    }
    $results.Add(@{name='functional W1 actual action binding requires owned runtime measurement';passed=$true})
    function Reject-FunctionalCase([string]$Name,[scriptblock]$Action) {
        $failure=$null
        try {& $Action|Out-Null} catch {$failure=$_}
        if ($null -eq $failure) {throw "Functional Wire accepted $Name."}
        $results.Add(@{name="functional W1 refuses $Name";passed=$true;refusal=$failure.Exception.Message})
    }
    foreach ($group in @('TerminalActions','FinalBoundedActions')) {
        Reject-FunctionalCase $group {Get-CapActionWindowBindings -Job $functional -Group $group}
    }
    foreach ($fault in @('opt-in','adapter','source','png','parity','build-source','app-tree')) {
        $changed=$functional|ConvertTo-Json -Depth 20|ConvertFrom-Json
        switch ($fault) {
            'opt-in' {$changed.functionalWireOnly=$false}
            'adapter' {$changed.sceneAdapter='S_MATCHED_V12_DPI_V1'}
            'source' {$changed.binaries.after.source='f'*40}
            'png' {$changed.functionalWireContract.pngAllowed=$true}
            'parity' {$changed.functionalWireContract.visualParityClaimed=$true}
            'build-source' {$changed.binaries.after.binaryBuiltAtSource='foreign'}
            'app-tree' {$changed.functionalWireContract.applicationSourceTree='foreign'}
        }
        Reject-FunctionalCase $fault {Get-CapActionWindowBindings -Job $changed -Group WireCompletion}
    }
    foreach ($dpi in @(96,144,192)) {
        $initial=Get-CapGraphCodeWindowIdentity -SourceText ([IO.File]::ReadAllText($source)) `
            -SourceCommit $functional.head -ExpectedDpi $dpi -LogicalClientWH @(96,96)
        $metrics=[pscustomobject]@{
            Dpi=[long]$dpi;Style=$initial.expectedRuntimeWindowStyle;ExStyle=$initial.expectedRuntimeWindowExStyle
            HasMenu=$true;OuterBounds=@(0L,0L,1280L,820L)
            ClientBounds=@(0L,0L,$initial.expectedInitialClientWH[0],$initial.expectedInitialClientWH[1])
        }
        $placement=Get-CapFunctionalWirePlacement -Identity $binding[0].identity -Metrics $metrics `
            -WorkArea @(0,0,1920,885)
        $bounds=$placement.Geometry.OuterBounds
        if ($placement.Geometry.Dpi -ne $dpi -or $bounds[0] -lt 0 -or $bounds[1] -lt 0 -or
            $bounds[2] -gt 1920 -or $bounds[3] -gt 885) {throw 'Functional measured-fit model escaped work area.'}
        $metrics.OuterBounds=$bounds
        $metrics.ClientBounds=@(0L,0L,$placement.Geometry.PhysicalClientWH[0],$placement.Geometry.PhysicalClientWH[1])
        $null=Assert-CapDpiWindowIdentity -Metrics $metrics -Identity $placement.Identity -ExpectedOuterBounds $bounds
        $results.Add(@{name="functional W1 fits injected DPI$dpi metrics without a192 visual contract";passed=$true
            evidence='INJECTED_COMPONENT_METRICS_NOT_LIVE_WINDOW_OR_DPI_CAPTURE'})
    }
    Reject-FunctionalCase 'invalid work area' {
        Get-CapFunctionalWirePlacement -Identity $binding[0].identity -Metrics $metrics -WorkArea @(0,0,0,0)
    }
    $wrongIdentity=$binding[0].identity|ConvertTo-Json|ConvertFrom-Json
    $wrongIdentity.sourceSha256='0'*64
    Reject-FunctionalCase 'changed window source' {
        Get-CapFunctionalWirePlacement -Identity $wrongIdentity -Metrics $metrics -WorkArea @(0,0,1920,885)
    }
    $root=$caseRoot
    $job=$functional
    $wire=Get-CapWireTargetBinding -Repository ([IO.Path]::GetFullPath((Join-Path $driverDirectory '..\..'))) -OwnedRoot $root
    $statePath=Join-Path $root 'functional-wire-state.json'
    $plan=[pscustomobject]@{group='WireCompletion';sourceHead=$functional.head;wireTargetBinding=$wire
        workerSha256=(Get-FileHash -LiteralPath (Join-Path $driverDirectory 'Invoke-UiCaptureWorker.ps1')).Hash
        stubDaemonSha256=(Get-FileHash -LiteralPath (Join-Path $driverDirectory 'Stub-Daemon.ps1')).Hash
        functionalWireState=[pscustomobject]@{path=$statePath;sha256=''}}
    $state=Get-CapFunctionalWireStatePlan -WireBinding $wire -SourceHead $plan.sourceHead `
        -WorkerSha256 $plan.workerSha256 -StubSha256 $plan.stubDaemonSha256
    # Only the outer authorization observation is modeled; execute the actual worker state reader.
    function Assert-CapActionWindowContext {}
    [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
    $plan.functionalWireState.sha256=(Get-FileHash -LiteralPath $statePath).Hash
    $read=Get-CapWorkerWireBinding
    if ($read.targetNodeId -cne $wire.targetNodeId) {throw 'Actual worker state reader changed target.'}
    $results.Add(@{name='functional W1 actual worker accepts exact fresh planned state without image';passed=$true})
    foreach ($fault in @('sourceHead','workerSha256','stubDaemonSha256','target','initial-edge')) {
        $changed=$state|ConvertTo-Json -Depth 30|ConvertFrom-Json
        switch ($fault) {
            'target' {$changed.wireBinding.targetNodeId='foreign'}
            'initial-edge' {$changed.expectedBefore.edges=1L}
            default {$changed.$fault='foreign'}
        }
        [IO.File]::WriteAllText($statePath,($changed|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
        $plan.functionalWireState.sha256=(Get-FileHash -LiteralPath $statePath).Hash
        Reject-FunctionalCase "rehashed state $fault" {Get-CapWorkerWireBinding}
    }
    & {
        $actionSupplementMode=$false
        $plan=$null
        $visualIdentity=Get-CapGraphCodeWindowIdentity -SourceText ([IO.File]::ReadAllText($source)) `
            -SourceCommit $functional.head -ExpectedDpi 96 -LogicalClientWH @(320,240)
        $job=[pscustomobject]@{sceneAdapter='S_MATCHED_V12_DPI_V1'
            captureContract=[pscustomobject]@{logicalClientWH=@(320L,240L);expectedWindowDpi=96L
                windowIdentities=[pscustomobject]@{after=$visualIdentity}}}
        $geometry=Get-CapMatchedWindowGeometry -Phase after
        if (($geometry.PhysicalClientWH -join ',') -cne '320,240') {throw 'Default visual geometry changed.'}
    }
    $results.Add(@{name='visual worker geometry remains independent of an action plan';passed=$true})
}
if ($FunctionalOnly) {
    $results=[Collections.Generic.List[object]]::new()
    Invoke-FunctionalWireContracts
    $report=[pscustomobject]@{suite='ActionWindowIdentityFunctional';executed=$results.Count
        passed=$results.Count;failed=0;skipped=0;runtimeWindowEvidence=$false;cases=@($results)}
    $report|ConvertTo-Json -Depth 15|Set-Content -LiteralPath (Join-Path $caseRoot 'report.json')
    $report|Select-Object suite,executed,passed,failed,skipped|ConvertTo-Json -Compress
    return
}
$sourceHead='a'*40
$identity=Get-CapGraphCodeWindowIdentity `
    -SourceText ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\c8r-window-after.zig'))) `
    -SourceCommit $sourceHead -ExpectedDpi 96 -LogicalClientWH @(320,240)
$job=[pscustomobject]@{
    sceneAdapter='S_MATCHED_V12_DPI_V1'
    head=$sourceHead
    binaries=[pscustomobject]@{after=[pscustomobject]@{source=$sourceHead;binaryBuiltAtSource=$sourceHead}}
    captureContract=[pscustomobject]@{
        logicalClientWH=@(320L,240L);expectedWindowDpi=96L
        windowIdentities=[pscustomobject]@{before=$identity;after=$identity}
    }
}
$baseJob=$job|ConvertTo-Json -Depth 30
$results=[Collections.Generic.List[object]]::new()
function Write-BindingJson {
    param([string]$Path,$Value)
    [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 50),[Text.UTF8Encoding]::new($false))
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
function Save-BindingCase {
    $script:plan.jobSha256=Write-BindingJson $plan.jobPath $job
    $script:authorization.jobSha256=$plan.jobSha256
    $script:authorization.actionPlanSha256=Write-BindingJson $planPath $plan
    $script:authorizationSha256=Write-BindingJson $authorizationPath $authorization
}
function Initialize-BindingCase {
    param([string]$Group='WireCompletion')
    $script:job=$baseJob|ConvertFrom-Json -DateKind String
    $bindings=@(Get-CapActionWindowBindings -Job $job -Group $Group)
    $script:plan=[pscustomobject]@{
        group=$Group;sourceHead=$sourceHead;sourceTree=('b'*40)
        expectedScenes=@($bindings|ForEach-Object {$_.sceneNames})
        actionWindowBindings=$bindings;jobPath=(Join-Path $caseRoot 'job.json');jobSha256=''
        wireTargetBinding=(Get-CapWireTargetBinding `
            -Repository ([IO.Path]::GetFullPath((Join-Path $driverDirectory '..\..'))) -OwnedRoot $caseRoot)
    }
    $script:planPath=Join-Path $caseRoot 'plan.json'
    $script:authorizationPath=Join-Path $caseRoot 'authorization.json'
    $script:runDirectory=Join-Path $caseRoot 'runs\one'
    $now=[DateTimeOffset]::UtcNow.AddSeconds(-1)
    $script:authorization=[pscustomobject]@{
        authorizationId=[guid]::NewGuid().ToString()
        ownedRoot=$caseRoot;authorizationPath=$authorizationPath;runDirectory=$runDirectory
        processJournalPath=(Join-Path $runDirectory 'process-journal')
        actionPlanSha256='';jobSha256='';moduleSha256=('C'*64)
        workerSha256=('D'*64);actionRunnerSha256=('E'*64)
        sourceHead=$sourceHead;sourceTree=('b'*40);group=$Group
        grantedUtc=$now.ToString('o');expiresUtc=$now.AddMinutes(3).ToString('o');maxMinutes=3L
        status='DRY_RUN_NO_AUTHORITY';authorizedAction='no-product-import-dry-run';pngAuthorized=$false
    }
    Save-BindingCase
}
function Assert-BindingCase {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) {throw $Message}
}
function Reject-BindingCase {
    param([string]$Name,[scriptblock]$Mutation,[string]$Message,[switch]$Persist)
    Initialize-BindingCase
    & $Mutation
    if ($Persist) {Save-BindingCase}
    $failure=$null
    try {Get-CapMatchedWindowGeometry -Phase 'wire-completion' -SceneName 's-goal-unwired-unselected'|Out-Null}
    catch {$failure=$_}
    Assert-BindingCase ($null -ne $failure -and $failure.Exception.Message.Contains($Message)) `
        "Expected $Name refusal '$Message'; actual=$failure"
    $results.Add(@{name=$Name;passed=$true;refusal=$failure.Exception.Message})
}
$actionSupplementMode=$true
foreach ($group in @('WireCompletion','TerminalActions','FinalBoundedActions')) {
    Initialize-BindingCase $group
    foreach ($binding in $plan.actionWindowBindings) {
        foreach ($scene in $binding.sceneNames) {
            $bound=Get-CapWorkerWindowIdentity -Phase $binding.actionPhase -SceneName $scene
            $geometry=Get-CapMatchedWindowGeometry -Phase $binding.actionPhase -SceneName $scene
            Assert-BindingCase ($null -ne $bound -and $bound.sourceCommit -ceq $sourceHead -and
                ($geometry.PhysicalClientWH -join ',') -ceq '320,240') 'Action identity/geometry differs.'
            $results.Add(@{name="$group/$($binding.actionPhase)/$scene";passed=$true})
        }
    }
}
foreach ($field in @('actionPhase','capturePhase','sourceCommit')) {
    Reject-BindingCase "foreign $field" {$plan.actionWindowBindings[0].$field='foreign'} 'binding differs' -Persist
}
Reject-BindingCase 'wrong scene' {$plan.actionWindowBindings[0].sceneNames=@('foreign')} 'binding differs' -Persist
Reject-BindingCase 'wrong action' {$plan.actionWindowBindings[0].actionIds=@('W6')} 'binding differs' -Persist
Reject-BindingCase 'missing binding' {$plan.PSObject.Properties.Remove('actionWindowBindings')} 'binding differs' -Persist
Reject-BindingCase 'duplicate binding' {$plan.actionWindowBindings+= $plan.actionWindowBindings[0]} 'binding differs' -Persist
Reject-BindingCase 'mismatched known capture phase' {$plan.actionWindowBindings[0].capturePhase='before'} 'binding differs' -Persist
Reject-BindingCase 'missing identity' {$job.captureContract.windowIdentities.PSObject.Properties.Remove('after')} 'identity is missing' -Persist
Reject-BindingCase 'null identity' {$job.captureContract.windowIdentities.after=$null} 'identity is missing' -Persist
Reject-BindingCase 'foreign identity source' {$job.captureContract.windowIdentities.after.sourceCommit='f'*40} 'identity differs' -Persist
Reject-BindingCase 'foreign binary source' {$job.binaries.after.source='f'*40} 'identity differs' -Persist
Reject-BindingCase 'wrong source head' {$plan.sourceHead='f'*40} 'run/authority/source/plan/job differs' -Persist
Reject-BindingCase 'wrong source tree' {$plan.sourceTree='f'*40} 'run/authority/source/plan/job differs' -Persist
Reject-BindingCase 'wrong group' {$plan.group='TerminalActions'} 'run/authority/source/plan/job differs' -Persist
Reject-BindingCase 'noncanonical empty group' {
    $plan.group='wirecompletion';$authorization.group=$plan.group
    $plan.actionWindowBindings=@();$plan.expectedScenes=@()
} 'ValidateSet' -Persist
Reject-BindingCase 'wrong run' {$script:runDirectory=Join-Path $caseRoot 'runs\foreign'} 'run/authority/source/plan/job differs'
Reject-BindingCase 'wrong authority' {$authorization.authorizationId=[guid]::NewGuid().ToString()} 'binding differs: authorizationId'
Reject-BindingCase 'wrong authority hash' {$script:authorizationSha256='0'*64} 'hash mismatch'
Reject-BindingCase 'authorized source mismatch' {
    $authorization.status='AUTHORIZED';$authorization.authorizedAction='matched-action-supplement'
    $plan.sourceHead='c'*40;$authorization.sourceHead=$plan.sourceHead
} 'run/authority/source/plan/job differs' -Persist
Reject-BindingCase 'wrong job hash' {[IO.File]::AppendAllText($plan.jobPath,' ')} 'hash mismatch'
Reject-BindingCase 'replaced plan' {[IO.File]::WriteAllText($planPath,'{}')} 'hash mismatch'
Reject-BindingCase 'stale authorization' {
    $authorization.expiresUtc=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
    $authorization.grantedUtc=[DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o')
} 'expired' -Persist
Reject-BindingCase 'in-memory identity drift on reacquire' {
    $null=Get-CapWorkerWindowIdentity -Phase 'wire-completion' -SceneName 's-goal-unwired-unselected'
    $job.captureContract.windowIdentities.after.expectedRuntimeWindowStyle++
} 'in-memory plan/job differs'
Initialize-BindingCase
$plan.sourceHead='c'*40;$authorization.sourceHead=$plan.sourceHead
Save-BindingCase
$historical=Get-CapWorkerWindowIdentity -Phase 'wire-completion' -SceneName 's-goal-unwired-unselected'
Assert-BindingCase ($historical.sourceCommit -ceq $sourceHead -and
    $authorization.status -ceq 'DRY_RUN_NO_AUTHORITY') 'No-authority historical inspection lost its explicit source.'
$results.Add(@{name='no-authority historical inspection preserves distinct capture source';passed=$true})
Initialize-BindingCase
foreach ($request in @(@('foreign','s-goal-unwired-unselected'),@('after','s-goal-unwired-unselected'),
    @('wire-completion','foreign'),@('wire-completion',''))) {
    $failure=$null
    try {Start-CapGraphCodeApp -Roots @{} -Phase $request[0] -SceneName $request[1] `
        -PipeName 'NO_LAUNCH' -SessionPrefix 'NO_LAUNCH'|Out-Null} catch {$failure=$_}
    Assert-BindingCase ($failure.Exception.Message.Contains('Unknown or foreign action phase/scene')) `
        "Actual app startup did not reject before launch: $failure"
    $results.Add(@{name="startup rejects $($request -join '/') before launch";passed=$true})
}
$bound=Get-CapWorkerWindowIdentity -Phase 'wire-completion' -SceneName 's-goal-unwired-unselected'
$metrics=[pscustomobject]@{
    Dpi=96L;Style=$bound.expectedRuntimeWindowStyle;ExStyle=$bound.expectedRuntimeWindowExStyle
    HasMenu=$bound.hasMenu;OuterBounds=@(0L,0L,1280L,820L)
    ClientBounds=@(0L,0L,[long]$bound.expectedInitialClientWH[0],[long]$bound.expectedInitialClientWH[1])
}
$null=Assert-CapDpiWindowIdentity -Metrics $metrics -Identity $bound -Initial
$results.Add(@{name='bound initial identity guard accepts source-derived metrics model';passed=$true})
foreach ($field in @('Dpi','Style','ExStyle','HasMenu','OuterBounds','ClientBounds')) {
    $changed=$metrics|ConvertTo-Json|ConvertFrom-Json
    switch ($field) {
        'HasMenu' {$changed.HasMenu=-not $changed.HasMenu}
        'OuterBounds' {$changed.OuterBounds[2]++}
        'ClientBounds' {$changed.ClientBounds[2]++}
        default {$changed.$field++}
    }
    $failure=$null
    try {$null=Assert-CapDpiWindowIdentity -Metrics $changed -Identity (
        Get-CapWorkerWindowIdentity -Phase 'wire-completion' -SceneName 's-goal-unwired-unselected') -Initial}
    catch {$failure=$_}
    Assert-BindingCase ($null -ne $failure -and $failure.Exception.Message.Contains('differs')) "Guard accepted $field drift."
    $results.Add(@{name="reacquired identity guard rejects $field drift in metrics model";passed=$true})
}
$geometry=Get-CapMatchedWindowGeometry -Phase 'wire-completion' -SceneName 's-goal-unwired-unselected'
$metrics.OuterBounds=@($geometry.OuterBounds|ForEach-Object {[long]$_})
$metrics.ClientBounds=@(0L,0L,[long]$geometry.PhysicalClientWH[0],[long]$geometry.PhysicalClientWH[1])
$null=Assert-CapDpiWindowIdentity -Metrics $metrics -Identity $bound -ExpectedOuterBounds $geometry.OuterBounds
$results.Add(@{name='placed guard accepts bound physical metrics model';passed=$true})
$metrics.Style++
$failure=$null
try {$null=Assert-CapDpiWindowIdentity -Metrics $metrics -Identity (
    Get-CapWorkerWindowIdentity -Phase 'wire-completion' -SceneName 's-goal-unwired-unselected') `
    -ExpectedOuterBounds $geometry.OuterBounds} catch {$failure=$_}
Assert-BindingCase ($null -ne $failure -and $failure.Exception.Message.Contains('identity differs')) 'Placed guard accepted drift.'
$results.Add(@{name='placed guard rejects drift after identity reacquire in metrics model';passed=$true})
foreach ($fault in @('missing','null','targetNodeId','sourceNodeId','sourceHashes')) {
    Initialize-BindingCase
    switch ($fault) {
        'missing' {$plan.PSObject.Properties.Remove('wireTargetBinding')}
        'null' {$plan.wireTargetBinding=$null}
        default {$plan.wireTargetBinding.$fault='foreign'}
    }
    Save-BindingCase
    $failure=$null
    try {Start-CapGraphCodeApp -Roots @{} -Phase 'wire-completion' `
        -SceneName 's-goal-unwired-unselected' -PipeName 'NO_LAUNCH' -SessionPrefix 'NO_LAUNCH'|Out-Null}
    catch {$failure=$_}
    Assert-BindingCase ($null -ne $failure -and $failure.Exception.Message.Contains('planned source/target binding')) `
        "Startup did not reject $fault wire target before launch: $failure"
    $results.Add(@{name="startup rejects $fault wire target before launch";passed=$true})
}
Initialize-BindingCase
$reachedLaunch=$false
& {
    function Start-CapJobLauncher {
        param($Root,$OutputDirectory,$FilePath,$ArgumentList,$WorkingDirectory,$Role,$Environment)
        $script:reachedLaunch=$true
        throw 'TEST_LAUNCH_INTERCEPTED_NO_PROCESS_STARTED'
    }
    $roots=Initialize-CapPhaseRoot -PhaseRoot (Join-Path $runDirectory 'launch-intercept')
    $failure=$null
    try {Start-CapGraphCodeApp -Roots $roots -Phase 'wire-completion' `
        -SceneName 's-goal-unwired-unselected' -PipeName 'NO_LAUNCH' -SessionPrefix 'NO_LAUNCH'|Out-Null}
    catch {$failure=$_}
    Assert-BindingCase ($failure.Exception.Message.Contains('TEST_LAUNCH_INTERCEPTED_NO_PROCESS_STARTED')) `
        "Valid production startup failed before intercepted launch: $failure"
}
Assert-BindingCase $reachedLaunch 'Valid production startup did not reach the intercepted launcher.'
$results.Add(@{name='actual production startup resolves binding before intercepted launcher';passed=$true})
Invoke-FunctionalWireContracts
$report=[ordered]@{suite='ActionWindowIdentity';executed=$results.Count;passed=$results.Count;failed=0;skipped=0
    productLaunches=0;providerLaunches=0;runtimeWindowEvidence=$false;cases=@($results)}
$null=Write-BindingJson (Join-Path $caseRoot 'report.json') $report
[pscustomobject]$report|Select-Object suite,executed,passed,failed,skipped|ConvertTo-Json -Compress
if ($results.Count -ne 84) {throw "Unexpected binding contract count: $($results.Count)"}
