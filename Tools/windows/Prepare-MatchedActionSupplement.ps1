param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$OwnedRoot,
    [Parameter(Mandatory)][string]$FocusedPlanPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$FocusedPlanSha256,
    [Parameter(Mandatory)][ValidateSet('WireCompletion','TerminalActions','FinalBoundedActions')][string]$Group,
    [Parameter(Mandatory)][string]$ExistingSceneManifestPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExistingSceneManifestSha256,
    [string]$QualifiedCaptureRoot = '',
    [string]$QualifiedRunId = '',
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$QualifiedManifestSha256 = ('0' * 64),
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$QualifiedReleaseSha256 = ('0' * 64),
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$QualifiedTerminalJournalSha256 = ('0' * 64),
    [ValidateRange(3,30)][long]$AuthorizationMinutes = 20
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($OwnedRoot).TrimEnd('\')
$repositoryRoot=[IO.Path]::GetFullPath($Repository).TrimEnd('\')
$focusedPath=[IO.Path]::GetFullPath($FocusedPlanPath)
$sceneManifestPath=[IO.Path]::GetFullPath($ExistingSceneManifestPath)
if (-not $focusedPath.StartsWith($root + '\',[StringComparison]::OrdinalIgnoreCase) -or
    (Get-FileHash $focusedPath -Algorithm SHA256).Hash -ne $FocusedPlanSha256.ToUpperInvariant()) {
    throw 'Action supplement requires the exact focused no-authority plan below its owned root.'
}
if ((Get-FileHash $sceneManifestPath -Algorithm SHA256).Hash -ne
    $ExistingSceneManifestSha256.ToUpperInvariant()) {
    throw 'Action supplement existing scene manifest hash mismatch.'
}
$focused=Get-Content $focusedPath -Raw | ConvertFrom-Json -DateKind String
$scenes=Get-Content $sceneManifestPath -Raw | ConvertFrom-Json -DateKind String
$expectedProfile=if ($Group -ceq 'WireCompletion') {'PostFixCards'} else {'TerminalChrome'}
if ($focused.status -cne 'PREPARED_NO_AUTHORITY' -or $focused.profile -cne $expectedProfile -or
    $focused.pngArtifacts -ne 0 -or $focused.processLaunches -ne 0 -or
    @(Get-ChildItem $root -Recurse -File -Filter '*.png').Count -ne 0) {
    throw 'Action supplement focused plan profile or no-launch/no-PNG boundary differs.'
}
$head=(& git -C $repositoryRoot rev-parse HEAD).Trim()
$tree=(& git -C $repositoryRoot rev-parse 'HEAD^{tree}').Trim()
if ($head -cne $focused.sourceHead -or $tree -cne $focused.sourceTree -or
    @(& git -C $repositoryRoot status --porcelain --untracked-files=all).Count -ne 0) {
    throw 'Action supplement requires unchanged clean focused-plan source.'
}
$expectedScenes=if ($Group -ceq 'WireCompletion') {
    @('s-goal-unwired-unselected')
} elseif ($Group -ceq 'FinalBoundedActions') {
    @(
        's-goal-unwired-unselected',
        's-tabs-two-agent-selected',
        's-tabs-split-right-focused',
        's-tabs-last-guard',
        's-tabs-many-first',
        's-tabs-hover-close'
    )
} else {
    @(
        's-tabs-agent-unknown','s-tabs-backend-idle','s-tabs-goal-needs-you','s-tabs-loop-running',
        's-tabs-two-agent-selected','s-tabs-two-shell-selected','s-tabs-split-right-focused',
        's-tabs-many-first','s-tabs-overflow-last','s-tabs-hover-close','s-tabs-last-guard'
    )
}
$qualifiedTopologies=@()
if ($Group -ceq 'FinalBoundedActions') {
    $qualifiedRoot=[IO.Path]::GetFullPath($QualifiedCaptureRoot).TrimEnd('\')
    if ($QualifiedRunId -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Final bounded actions require the exact qualified capture run ID.'
    }
    $qualifiedManifest=Join-Path $qualifiedRoot 'outputs\manifest.json'
    $qualifiedRelease=Join-Path $qualifiedRoot 'outputs\focused-release.json'
    $qualifiedJournal=Join-Path $qualifiedRoot "runs\$QualifiedRunId\process-journal\000370.json"
    foreach ($binding in @(
        @($qualifiedManifest,$QualifiedManifestSha256),
        @($qualifiedRelease,$QualifiedReleaseSha256),
        @($qualifiedJournal,$QualifiedTerminalJournalSha256)
    )) {
        if (-not (Test-Path -LiteralPath $binding[0] -PathType Leaf) -or
            (Get-FileHash -LiteralPath $binding[0] -Algorithm SHA256).Hash -cne
                ([string]$binding[1]).ToUpperInvariant()) {
            throw "Qualified bounded-action authority differs: $($binding[0])"
        }
    }
    $qualifiedInputs=Join-Path $root 'inputs\qualified-actions'
    $null=New-Item -ItemType Directory -Path $qualifiedInputs -Force
    $layoutSpecs=@(
        [pscustomobject]@{scene='s-tabs-two-agent-selected';loop='20000000-0000-4000-8000-000000000001'
            layoutSha256='5EA9171DFE71E8C9C140C7A05B1FEEE578174558A1A52013EC1ED9317DC71790'
            expectedTabs=2L;expectedSelected=0L},
        [pscustomobject]@{scene='s-tabs-split-right-focused';loop='11111111-1111-4111-8111-000000000001'
            layoutSha256='42D99B227C024BB36EF260E2BACC7B27AFC96D82DDC9B535246593174CCD32D5'
            expectedTabs=3L;expectedSelected=2L},
        [pscustomobject]@{scene='s-tabs-last-guard';loop='11111111-1111-4111-8111-000000000001'
            layoutSha256='289522E51B2F7B1F2695623115CAAFF80026C7B72A545B3E7EC5981BCD8AA70F'
            expectedTabs=1L;expectedSelected=0L},
        [pscustomobject]@{scene='s-tabs-many-first';loop='11111111-1111-4111-8111-000000000001'
            layoutSha256='386A5DB78AAEAA63DE0AA4E83A8150B4CDB022F3E73E18F119DCCAECEA0BF2EE'
            expectedTabs=12L;expectedSelected=0L},
        [pscustomobject]@{scene='s-tabs-hover-close';loop='11111111-1111-4111-8111-000000000001'
            layoutSha256='10EC1E1E144AEFC36E243DAF0299A40350EB1EAD64971CEB3A206767C63F93C5'
            expectedTabs=2L;expectedSelected=0L}
    )
    $sourceProject=Join-Path $qualifiedRoot 'fixtures\projects\Matched'
    $targetProject=Join-Path $root 'fixtures\projects\Matched'
    foreach ($spec in $layoutSpecs) {
        $sourceDirectory=Join-Path $qualifiedRoot "runs\$QualifiedRunId\phases\after\$($spec.scene)"
        $sourceLayout=Join-Path $sourceDirectory "$($spec.loop).json"
        if ((Get-FileHash -LiteralPath $sourceLayout -Algorithm SHA256).Hash -cne $spec.layoutSha256) {
            throw "Qualified topology layout differs: $($spec.scene)"
        }
        $layout=Get-Content -LiteralPath $sourceLayout -Raw | ConvertFrom-Json -DateKind String
        if ($layout.schemaVersion -ne 2 -or $layout.project -cne $sourceProject -or
            $layout.loop -cne $spec.loop -or $layout.tabs.Count -lt 1) {
            throw "Qualified topology schema or source binding differs: $($spec.scene)"
        }
        $destination=Join-Path $qualifiedInputs $spec.scene
        $sessionDestination=Join-Path $destination 'shell-sessions'
        $null=New-Item -ItemType Directory -Path $sessionDestination -Force
        Copy-Item -LiteralPath $sourceLayout -Destination (Join-Path $destination 'layout-source.json')
        $layout.project=$targetProject
        $rewrittenLayout=Join-Path $destination 'layout.json'
        [IO.File]::WriteAllText($rewrittenLayout,($layout|ConvertTo-Json -Depth 20 -Compress),
            [Text.UTF8Encoding]::new($false))
        $sessions=@()
        foreach ($pane in @($layout.tabs.panes)) {
            $sessionName="graphcode-$($pane.id)"
            $sourceSession=Join-Path $sourceDirectory "shell-sessions\$sessionName"
            if ($pane.agent) {
                $sessions+= [pscustomobject]@{name=$sessionName;paneId=$pane.id;agent=$true
                    sourceSha256=$null;preparedSha256=$null}
                continue
            }
            if (-not (Test-Path -LiteralPath $sourceSession -PathType Leaf) -or
                [IO.File]::ReadAllText($sourceSession) -cne $spec.loop) {
                throw "Qualified shell-session ownership differs: $sessionName"
            }
            $sessionHash=(Get-FileHash -LiteralPath $sourceSession -Algorithm SHA256).Hash
            $preparedSession=Join-Path $sessionDestination $sessionName
            Copy-Item -LiteralPath $sourceSession -Destination $preparedSession
            $sessions+= [pscustomobject]@{name=$sessionName;paneId=$pane.id;agent=$false
                sourceSha256=$sessionHash
                preparedSha256=(Get-FileHash -LiteralPath $preparedSession -Algorithm SHA256).Hash}
        }
        $qualifiedTopologies+= [pscustomobject]@{
            scene=$spec.scene
            loop=$spec.loop
            sourceLayoutSha256=$spec.layoutSha256
            preparedLayoutPath=$rewrittenLayout
            preparedLayoutSha256=(Get-FileHash -LiteralPath $rewrittenLayout -Algorithm SHA256).Hash
            shellSessionsPath=$sessionDestination
            sessions=$sessions
            expectedTabs=$spec.expectedTabs
            expectedSelected=$spec.expectedSelected
        }
    }
}
$bindings=[ordered]@{}
foreach ($scene in $expectedScenes) {
    $rows=@($scenes.scenes | Where-Object canonicalScene -CEQ $scene)
    if ($rows.Count -ne 1 -or $rows[0].sha256 -cnotmatch '^[A-Fa-f0-9]{64}$') {
        throw "Action supplement existing image binding missing or duplicated: $scene"
    }
    $bindings[$scene]=[string]$rows[0].sha256
}
$stubPath=Join-Path $repositoryRoot 'Tools\windows\Stub-Daemon.ps1'
$actionRunnerPath=Join-Path $repositoryRoot 'Tools\windows\Invoke-MatchedActionSupplement.ps1'
Import-Module (Join-Path $repositoryRoot 'Tools\windows\UiCaptureDriver.psm1') -Force -WarningAction SilentlyContinue
if ((Get-FileHash -LiteralPath $focused.jobPath -Algorithm SHA256).Hash -cne $focused.jobSha256) {
    throw 'Action window binding job hash mismatch.'
}
$actionJob=Get-Content -LiteralPath $focused.jobPath -Raw | ConvertFrom-Json -DateKind String
$actionWindowBindings=@(Get-CapActionWindowBindings -Job $actionJob -Group $Group)
$plan=[ordered]@{
    schemaVersion=1L
    status='PREPARED_NO_AUTHORITY'
    preparedUtc=[DateTimeOffset]::UtcNow.ToString('o')
    group=$Group
    ownedRoot=$root
    repository=$repositoryRoot
    sourceHead=$head
    sourceTree=$tree
    focusedPlanPath=$focusedPath
    focusedPlanSha256=$FocusedPlanSha256.ToUpperInvariant()
    focusedProfile=$focused.profile
    jobPath=$focused.jobPath
    jobSha256=$focused.jobSha256
    moduleSha256=$focused.moduleSha256
    workerSha256=$focused.workerSha256
    supervisorSha256=$focused.supervisorSha256
    actionRunnerSha256=(Get-FileHash $actionRunnerPath -Algorithm SHA256).Hash
    actionSeedHelperSha256=(Get-FileHash (Join-Path $repositoryRoot 'Tools\windows\Start-MatchedActionSessions.ps1') -Algorithm SHA256).Hash
    preflightReceiptPath=$focused.preflightReceiptPath
    preflightReceiptSha256=$focused.preflightReceiptSha256
    fixture=$focused.fixture
    binaries=$focused.binaries
    stubDaemonPath=$stubPath
    stubDaemonSha256=(Get-FileHash $stubPath -Algorithm SHA256).Hash
    existingSceneManifestPath=$sceneManifestPath
    existingSceneManifestSha256=$ExistingSceneManifestSha256.ToUpperInvariant()
    expectedScenes=$expectedScenes
    actionWindowBindings=$actionWindowBindings
    wireTargetBinding=$(if ($Group -cne 'TerminalActions') {
        Get-CapWireTargetBinding -Repository $repositoryRoot -OwnedRoot $root
    } else {$null})
    imageBindings=$bindings
    expectedReceiptCount=[long]$expectedScenes.Count
    qualifiedAuthority=$(if ($Group -ceq 'FinalBoundedActions') {
        [ordered]@{
            runId=$QualifiedRunId
            manifestSha256=$QualifiedManifestSha256.ToUpperInvariant()
            releaseSha256=$QualifiedReleaseSha256.ToUpperInvariant()
            terminalJournalSha256=$QualifiedTerminalJournalSha256.ToUpperInvariant()
            topologies=$qualifiedTopologies
        }
    } else {$null})
    expectedActions=$(if ($Group -ceq 'WireCompletion') {
        @('Wire it up','target selection','Create edge','graph readback')
    } elseif ($Group -ceq 'FinalBoundedActions') {
        @(
            'W1 complete Wire once',
            'W2 Split Down from qualified persisted Split Right topology',
            'W3 final unsplit-tab close with destructive confirmation cancellation',
            'W4 native shell-computed nonce PID arithmetic across agent Shell right and Down focus',
            'W5 existing offscreen-last selection from qualified many-first topology',
            'W6 real native pointer hover over alternate close target'
        )
    } else {
        @('New Tab','Split Right','Split Down','alternate selection/focus','per-tab close',
            'final-tab close','many-first','overflow-last','native input/output')
    })
    authorizationBounds=[ordered]@{
        status='NOT_GRANTED'
        requestedMaxMinutes=$AuthorizationMinutes
        cleanupReserveSeconds=90L
    }
    cleanupExpectations=[ordered]@{
        heldExitAndEofRequired=$true
        cleanupFailuresExpected=0L
        pendingLaunchesExpected=0L
        survivorsExpected=0L
    }
    pngArtifacts=0L
    maximumResultPngs=$(if ($Group -ceq 'FinalBoundedActions') {1L} else {0L})
    processLaunches=0L
}
$planPath=Join-Path $root 'action-plan.json'
if (Test-Path $planPath) {throw 'Action supplement plan already exists.'}
[IO.File]::WriteAllText($planPath,($plan|ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false))
[ordered]@{
    status=$plan.status
    group=$Group
    actionPlanPath=$planPath
    actionPlanSha256=(Get-FileHash $planPath -Algorithm SHA256).Hash
    sourceHead=$head
    sourceTree=$tree
    expectedScenes=$expectedScenes
    expectedReceiptCount=$plan.expectedReceiptCount
    pngArtifacts=0L
    processLaunches=0L
} | ConvertTo-Json -Depth 10
