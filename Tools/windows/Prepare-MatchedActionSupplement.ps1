param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$OwnedRoot,
    [Parameter(Mandatory)][string]$FocusedPlanPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$FocusedPlanSha256,
    [Parameter(Mandatory)][ValidateSet('WireCompletion','TerminalActions')][string]$Group,
    [Parameter(Mandatory)][string]$ExistingSceneManifestPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExistingSceneManifestSha256,
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
} else {
    @(
        's-tabs-agent-unknown','s-tabs-backend-idle','s-tabs-goal-needs-you','s-tabs-loop-running',
        's-tabs-two-agent-selected','s-tabs-two-shell-selected','s-tabs-split-right-focused',
        's-tabs-many-first','s-tabs-overflow-last','s-tabs-hover-close','s-tabs-last-guard'
    )
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
    preflightReceiptPath=$focused.preflightReceiptPath
    preflightReceiptSha256=$focused.preflightReceiptSha256
    fixture=$focused.fixture
    binaries=$focused.binaries
    stubDaemonPath=$stubPath
    stubDaemonSha256=(Get-FileHash $stubPath -Algorithm SHA256).Hash
    existingSceneManifestPath=$sceneManifestPath
    existingSceneManifestSha256=$ExistingSceneManifestSha256.ToUpperInvariant()
    expectedScenes=$expectedScenes
    imageBindings=$bindings
    expectedReceiptCount=[long]$expectedScenes.Count
    expectedActions=$(if ($Group -ceq 'WireCompletion') {
        @('Wire it up','target selection','Create edge','graph readback')
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
