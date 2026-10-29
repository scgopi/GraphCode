param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$OwnedRoot,
    [Parameter(Mandatory)][string]$ActionPlanPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ActionPlanSha256,
    [switch]$DryRun
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($OwnedRoot).TrimEnd('\')
$repositoryRoot=[IO.Path]::GetFullPath($Repository).TrimEnd('\')
$planPath=[IO.Path]::GetFullPath($ActionPlanPath)
if (-not $planPath.StartsWith($root + '\',[StringComparison]::OrdinalIgnoreCase) -or
    (Get-FileHash $planPath -Algorithm SHA256).Hash -ne $ActionPlanSha256.ToUpperInvariant()) {
    throw 'Action supplement plan path or hash mismatch.'
}
$plan=Get-Content $planPath -Raw | ConvertFrom-Json -DateKind String
if ($plan.status -cne 'PREPARED_NO_AUTHORITY' -or $plan.pngArtifacts -ne 0 -or
    $plan.processLaunches -ne 0 -or @(Get-ChildItem $root -Recurse -File -Filter '*.png').Count -ne 0) {
    throw 'Action supplement plan no-authority boundary differs.'
}
$head=(& git -C $repositoryRoot rev-parse HEAD).Trim()
$tree=(& git -C $repositoryRoot rev-parse 'HEAD^{tree}').Trim()
if ($head -cne $plan.sourceHead -or $tree -cne $plan.sourceTree -or
    @(& git -C $repositoryRoot status --porcelain --untracked-files=all).Count -ne 0) {
    throw 'Action supplement requires unchanged clean planned source.'
}
$modulePath=Join-Path $repositoryRoot 'Tools\windows\UiCaptureDriver.psm1'
$workerPath=Join-Path $repositoryRoot 'Tools\windows\Invoke-UiCaptureWorker.ps1'
$stubPath=Join-Path $repositoryRoot 'Tools\windows\Stub-Daemon.ps1'
$actionRunnerPath=$PSCommandPath
$actionSeedHelperPath=Join-Path $repositoryRoot 'Tools\windows\Start-MatchedActionSessions.ps1'
foreach ($binding in @(
    @($modulePath,$plan.moduleSha256),
    @($workerPath,$plan.workerSha256),
    @($stubPath,$plan.stubDaemonSha256),
    @($actionRunnerPath,$plan.actionRunnerSha256),
    @($actionSeedHelperPath,$plan.actionSeedHelperSha256),
    @($plan.jobPath,$plan.jobSha256),
    @($plan.preflightReceiptPath,$plan.preflightReceiptSha256),
    @($plan.existingSceneManifestPath,$plan.existingSceneManifestSha256)
)) {
    if (-not (Test-Path $binding[0] -PathType Leaf) -or
        (Get-FileHash $binding[0] -Algorithm SHA256).Hash -ne [string]$binding[1]) {
        throw "Action supplement bound input changed: $($binding[0])"
    }
}
$granted=[DateTimeOffset]::UtcNow.AddSeconds(-1)
$actionRunDirectory=Join-Path $root ($(if ($DryRun) {'dry-run-runs\'} else {'action-runs\'}) +
    [guid]::NewGuid().ToString('N'))
$authorizationPath=Join-Path $root $(if ($DryRun) {'dry-run-binding.json'} else {'action-authorization.json'})
$authorization=[ordered]@{
    schemaVersion=1L
    authorizationId=[guid]::NewGuid().ToString()
    status=$(if ($DryRun) {'DRY_RUN_NO_AUTHORITY'} else {'AUTHORIZED'})
    authorizedAction=$(if ($DryRun) {'no-product-import-dry-run'} else {'matched-action-supplement'})
    ownedRoot=$root
    authorizationPath=$authorizationPath
    runDirectory=$actionRunDirectory
    processJournalPath=(Join-Path $actionRunDirectory 'process-journal')
    group=$plan.group
    sourceHead=$head
    sourceTree=$tree
    actionPlanSha256=$ActionPlanSha256.ToUpperInvariant()
    moduleSha256=$plan.moduleSha256
    workerSha256=$plan.workerSha256
    actionRunnerSha256=$plan.actionRunnerSha256
    jobSha256=$plan.jobSha256
    preflightReceiptSha256=$plan.preflightReceiptSha256
    pngAuthorized=$false
    grantedUtc=$granted.ToString('o')
    expiresUtc=$granted.AddMinutes(
        [long]$plan.authorizationBounds.requestedMaxMinutes).ToString('o')
    maxMinutes=[long]$plan.authorizationBounds.requestedMaxMinutes
}
if (-not $DryRun -and $plan.group -ceq 'FinalBoundedActions') {$authorization.pngAuthorized=$true}
if (Test-Path $authorizationPath) {throw 'Action supplement authorization already consumed.'}
[IO.File]::WriteAllText($authorizationPath,($authorization|ConvertTo-Json -Depth 20),
    [Text.UTF8Encoding]::new($false))
$authorizationSha256=(Get-FileHash -LiteralPath $authorizationPath -Algorithm SHA256).Hash
$output=Join-Path $root $(if ($DryRun) {'dry-run-output'} else {'action-output'})
if (Test-Path $output) {throw 'Action supplement output already exists.'}
$null=New-Item -ItemType Directory -Path $output

Import-Module $modulePath -Force -WarningAction SilentlyContinue
. $workerPath -OwnedRoot $root -DefinitionsOnly
$authorizationHandle=Open-CapActionAuthorization -Path $authorizationPath -Sha256 $authorizationSha256 `
    -Expected ([pscustomobject]$authorization) -DryRun:$DryRun
$selfProcess=$null
try {
$job=Get-Content $plan.jobPath -Raw | ConvertFrom-Json -DateKind String
if (-not $DryRun) {$matchedCapturePlan=Get-CapMatchedCapturePlan -Job $job}
$fixturePath=Join-Path $root 'fixtures\fixture.json'
$peerScript=Join-Path $root 'inputs\offline-peer-source.ps1'
$runDirectory=$actionRunDirectory
$null=New-Item -ItemType Directory -Path $runDirectory
$journalPath=Join-Path $runDirectory 'process-journal'
$null=New-Item -ItemType Directory -Path $journalPath
$outputDirectory=$output
$workerLog=Join-Path $output 'action-worker.log'
[IO.File]::WriteAllText($workerLog,'',[Text.UTF8Encoding]::new($false))
Set-CapTracePath -Path (Join-Path $output 'action-calls.jsonl')
$leaseWindow=$authorizationHandle.Window
$leaseDeadlineUtc=$leaseWindow.WorkerDeadlineUtc
$focusedCapture=$true
$actionSupplementMode=$true
$rehearsal=$false
$transitionRehearsal=$false
$fixtureHash=(Get-FileHash $fixturePath -Algorithm SHA256).Hash
$fixtureSourceHash=$plan.fixture.canonicalSourceSha256
$fixtureMappingHash=$plan.fixture.mappingSha256
$moduleHash=$plan.moduleSha256
$workerHash=$plan.workerSha256
$supervisorHash=$plan.actionRunnerSha256
$selfProcess=[Diagnostics.Process]::GetCurrentProcess()
$selfIdentity=Get-CapProcessIdentity -Process $selfProcess `
    -ExpectedImagePath $selfProcess.MainModule.FileName -Role 'matched-action-runner'
$journalBinding=New-CapJournalBinding -RunId ([IO.Path]::GetFileName($runDirectory)) `
    -LeaseId $authorization.authorizationId -JobSha256 $plan.jobSha256 `
    -ModuleSha256 $moduleHash -WorkerSha256 $workerHash `
    -SupervisorSha256 $supervisorHash -Identity $selfIdentity
$journalState=New-CapJournalState -Root $root -Directory $journalPath `
    -Binding $journalBinding -DeadlineUtc $leaseWindow.ExpiresUtc
Write-CapWorkerJournalSnapshot -Kind 'Bootstrap'
$startedUtc=[DateTime]::UtcNow
$primaryFailure=$null
$independent=@()
$dryRunLauncher=$null
$dryRunProof=$null
try {
    Assert-CapWorkerDeadline 'action entry'
    $boundWindows=@(Assert-CapActionWindowContext)
    $windowPreflight=@(foreach ($binding in $boundWindows) {
        foreach ($scene in $binding.sceneNames) {
            $identity=Get-CapWorkerWindowIdentity -Phase $binding.actionPhase -SceneName $scene
            $geometry=Get-CapMatchedWindowGeometry -Phase $binding.actionPhase -SceneName $scene
            [pscustomobject]@{
                actionPhase=$binding.actionPhase;capturePhase=$binding.capturePhase
                sceneName=$scene;actionIds=@($binding.actionIds);identity=$identity;geometry=$geometry
                validation='NONNULL_SOURCE_BOUND_IDENTITY_BEFORE_LAUNCH'
            }
        }
    })
    if ($DryRun) {
        # Exercise the real custody gate with a harmless child, never a product/provider image.
        $dryRunLauncher=Start-CapJobLauncher -Root $root -OutputDirectory $outputDirectory `
            -FilePath (Join-Path $PSHOME 'pwsh.exe') `
            -ArgumentList @('-NoProfile','-NonInteractive','-Command','exit 0') `
            -WorkingDirectory $root -Role 'import-dry-run-launcher' `
            -Environment @{TEMP=$runDirectory;TMP=$runDirectory}
        $runs.Add($dryRunLauncher)
        Write-CapProcessJournal -Identity $dryRunLauncher.Identity -Phase 'dry-run'
        $releaseSequence=$journalState.Sequence
        $target=Release-CapJobLauncher -Run $dryRunLauncher -JournalState $journalState
        $dryRunProof=[ordered]@{
            authorizationPath=$authorizationPath
            authorizationSha256=$authorizationSha256
            journalDirectory=$journalState.Directory
            journalBinding=$journalState.Binding
            releaseSequence=$releaseSequence
            target=$target
            productLaunches=0L
            providerLaunches=0L
            windowIdentityValidation='SOURCE_PHASE_BINDINGS_VALIDATED_BEFORE_LAUNCH_RUNTIME_WINDOW_NOT_EXECUTED'
            windowBindings=$windowPreflight
            toolingSourceHead=$head
            captureSourceHead=$job.head
            geometry=$null
            preconditionsEvaluated=$true
        }
        if (-not (Test-CapMatchedDpiAdapter)) {throw 'Action dry run requires the production matched DPI contract.'}
        $dryRunProof.geometry=$windowPreflight[0].geometry
    } else {
        $matchedFixture=Get-Content $fixturePath -Raw | ConvertFrom-Json -DateKind String
        Initialize-CapMatchedWorktrees -Fixture $matchedFixture
    }
    if ($DryRun) {
        Assert-CapWorkerDeadline 'dry-run preconditions evaluated'
    } elseif ($plan.group -ceq 'TerminalActions') {
        $bindings=@{}
        foreach ($property in $plan.imageBindings.PSObject.Properties) {
            $bindings[$property.Name]=[string]$property.Value
        }
        Invoke-CapMatchedScenes -Phase 'after' -SceneNames @($plan.expectedScenes) `
            -SkipRestart -ActionSupplement -ImageBindings $bindings
        if ($actionSupplementReceipts.Count -ne [long]$plan.expectedReceiptCount -or
            $zmxSeedReceipts.Count -ne [long]$plan.expectedReceiptCount) {
            throw 'Terminal action supplement receipt or provider count differs.'
        }
    } elseif ($plan.group -ceq 'WireCompletion') {
        $receipt=Invoke-CapWireCompletionSupplement -StubDaemonPath $stubPath
        $receipt | Add-Member -NotePropertyName actionIds -NotePropertyValue @('W1')
        $receipt | Add-Member -NotePropertyName imageBindingSha256 `
            -NotePropertyValue ([string]$plan.imageBindings.'s-goal-unwired-unselected')
        $actionSupplementReceipts.Add($receipt)
    } else {
        $wireReceipt=Invoke-CapWireCompletionSupplement -StubDaemonPath $stubPath
        $wireReceipt | Add-Member -NotePropertyName actionIds -NotePropertyValue @('W1')
        $wireReceipt | Add-Member -NotePropertyName imageBindingSha256 `
            -NotePropertyValue ([string]$plan.imageBindings.'s-goal-unwired-unselected')
        $actionSupplementReceipts.Add($wireReceipt)
        $bindings=@{}
        foreach ($property in $plan.imageBindings.PSObject.Properties) {
            $bindings[$property.Name]=[string]$property.Value
        }
        $terminalScenes=@(
            's-tabs-two-agent-selected',
            's-tabs-split-right-focused',
            's-tabs-last-guard',
            's-tabs-many-first',
            's-tabs-hover-close'
        )
        Invoke-CapMatchedScenes -Phase 'after' -SceneNames $terminalScenes `
            -SkipRestart -ActionSupplement -ImageBindings $bindings
        if ($actionSupplementReceipts.Count -ne 6 -or $zmxSeedReceipts.Count -ne 5) {
            throw 'Final bounded action or provider receipt count differs.'
        }
    }
} catch {
    $primaryFailure=$_
} finally {
    if ($dryRunLauncher) {
        try {$null=Close-CapMatchedJob -Run $dryRunLauncher -Phase 'dry-run'}
        catch {$cleanupFailures.Add("Dry-run launcher cleanup failed: $($_.Exception.Message)")}
    }
    foreach ($appRun in @($applicationRuns | Sort-Object {$_.Run.StartedUtc} -Descending)) {
        if (-not $appRun.CleanupComplete) {
            try {Close-CapGraphCodeApp -AppRun $appRun}
            catch {$cleanupFailures.Add("Final app cleanup failed: $($_.Exception.Message)")}
        }
    }
    foreach ($seedRun in @($seedRuns)) {
        if (-not $seedRun.CleanupComplete) {
            try {Close-CapOfflineSeed -SeedRun $seedRun}
            catch {$cleanupFailures.Add("Final seed cleanup failed: $($_.Exception.Message)")}
        }
    }
    foreach ($seedRun in @($actionSeedRuns)) {
        if (-not $seedRun.CleanupComplete) {
            try {Close-CapMatchedActionSeeds -SeedRun $seedRun}
            catch {$cleanupFailures.Add("Final action-seed cleanup failed: $($_.Exception.Message)")}
        }
    }
    $independent=@(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith($root + '\',
            [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object ProcessId,Name,ExecutablePath)
}
$terminalOutcome=if (-not $primaryFailure -and $cleanupFailures.Count -eq 0 -and
    $independent.Count -eq 0) {'COMPLETE'} else {'FAILED'}
try {
    Write-CapWorkerJournalSnapshot -Kind 'Terminal' -Outcome $terminalOutcome
} catch {
    if (-not $primaryFailure) {$primaryFailure=$_}
    else {$cleanupFailures.Add("Final action journal publication failed: $($_.Exception.Message)")}
}
$manifest=[ordered]@{
    schemaVersion=1L
    status=$(if (-not $primaryFailure -and $cleanupFailures.Count -eq 0 -and
        $independent.Count -eq 0) {'COMPLETE'} else {'FAILED'})
    group=$plan.group
    sourceHead=$head
    sourceTree=$tree
    actionPlanSha256=$ActionPlanSha256.ToUpperInvariant()
    authorizationSha256=$authorizationHandle.Sha256
    executionMode=$(if ($DryRun) {'DRY_RUN_NO_AUTHORITY'} else {'MATCHED_ACTION_SUPPLEMENT'})
    dryRun=$dryRunProof
    startedUtc=$startedUtc.ToString('o')
    finishedUtc=[DateTime]::UtcNow.ToString('o')
    imageBindings=$plan.imageBindings
    receipts=@($actionSupplementReceipts)
    receiptCount=[long]$actionSupplementReceipts.Count
    providerReceipts=@($zmxSeedReceipts)
    resultImages=@($images)
    processJournal=@($journalEntries)
    numberedJournal=[ordered]@{
        binding=$journalState.Binding
        directory=$journalPath
        terminal=$journalState.Terminal
        published=@($journalState.Published.ToArray())
    }
    cleanup=@($cleanupReceipts)
    cleanupFailures=@($cleanupFailures)
    independentSurvivors=@($independent)
    failures=@(if ($primaryFailure) {$primaryFailure.Exception.Message})
    pngCount=[long]@(Get-ChildItem $root -Recurse -File -Filter '*.png').Count
}
$manifestPath=Join-Path $output 'action-manifest.json'
[IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 50),
    [Text.UTF8Encoding]::new($false))
$release=[ordered]@{
    schemaVersion=1L
    status=$(if ($manifest.status -ceq 'COMPLETE') {'RELEASED_ZERO_SURVIVORS'}
        elseif ($independent.Count -eq 0) {'FAILED_ZERO_SURVIVORS'} else {'CLEANUP_UNPROVEN'})
    cleanupState=$(if ($runs.Count -eq 0 -and $independent.Count -eq 0 -and $cleanupFailures.Count -eq 0) {
        'NO_PROCESS_LAUNCHES'
    } elseif ($independent.Count -eq 0 -and $cleanupFailures.Count -eq 0) {
        'HELD_EXIT_AND_EOF_PROVEN'
    } else {'UNPROVEN'})
    group=$plan.group
    manifestSha256=(Get-FileHash $manifestPath -Algorithm SHA256).Hash
    receiptCount=[long]$actionSupplementReceipts.Count
    journalPublicationCount=[long]$journalState.Published.Count
    journalTerminalSha256=$(if ($journalState.Terminal) {$journalState.Terminal.sha256} else {$null})
    cleanupFailures=[long]$cleanupFailures.Count
    independentSurvivors=[long]$independent.Count
    releasedUtc=[DateTime]::UtcNow.ToString('o')
}
$releasePath=Join-Path $output 'action-release.json'
[IO.File]::WriteAllText($releasePath,($release|ConvertTo-Json -Depth 20),
    [Text.UTF8Encoding]::new($false))
if ($manifest.status -cne 'COMPLETE' -or $release.status -cne 'RELEASED_ZERO_SURVIVORS') {
    throw "Action supplement failed: $($manifest.failures -join '; ') cleanup=$($cleanupFailures -join '; ') survivors=$($independent.Count)"
}
if ($manifest.pngCount -ne $(if ($DryRun) {0L} else {[long]$plan.maximumResultPngs})) {
    throw "Action supplement result image count differs: expected=$($plan.maximumResultPngs) actual=$($manifest.pngCount)"
}
[ordered]@{
    group=$plan.group
    manifestPath=$manifestPath
    manifestSha256=$release.manifestSha256
    releasePath=$releasePath
    releaseSha256=(Get-FileHash $releasePath -Algorithm SHA256).Hash
    receiptCount=$manifest.receiptCount
    providerReceiptCount=[long]$manifest.providerReceipts.Count
    cleanupState=$release.cleanupState
    pngCount=$manifest.pngCount
} | ConvertTo-Json -Depth 10
} finally {
    $authorizationHandle.Pin.Dispose()
    if ($selfProcess) {$selfProcess.Dispose()}
}
