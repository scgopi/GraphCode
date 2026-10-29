param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$OwnedRoot,
    [Parameter(Mandatory)][string]$ActionPlanPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ActionPlanSha256
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
$authorization=[ordered]@{
    schemaVersion=1L
    authorizationId=[guid]::NewGuid().ToString()
    status='AUTHORIZED'
    authorizedAction='matched-action-supplement'
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
if ($plan.group -ceq 'FinalBoundedActions') {$authorization.pngAuthorized=$true}
$authorizationPath=Join-Path $root 'action-authorization.json'
if (Test-Path $authorizationPath) {throw 'Action supplement authorization already consumed.'}
[IO.File]::WriteAllText($authorizationPath,($authorization|ConvertTo-Json -Depth 20),
    [Text.UTF8Encoding]::new($false))
$output=Join-Path $root 'action-output'
if (Test-Path $output) {throw 'Action supplement output already exists.'}
$null=New-Item -ItemType Directory -Path $output

Import-Module $modulePath -Force -WarningAction SilentlyContinue
. $workerPath -OwnedRoot $root -DefinitionsOnly
$job=Get-Content $plan.jobPath -Raw | ConvertFrom-Json -DateKind String
$matchedCapturePlan=Get-CapMatchedCapturePlan -Job $job
$fixturePath=Join-Path $root 'fixtures\fixture.json'
$peerScript=Join-Path $root 'inputs\offline-peer-source.ps1'
$runDirectory=Join-Path $root ('action-runs\' + [guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $runDirectory
$journalPath=Join-Path $runDirectory 'process-journal'
$null=New-Item -ItemType Directory -Path $journalPath
$outputDirectory=$output
$workerLog=Join-Path $output 'action-worker.log'
[IO.File]::WriteAllText($workerLog,'',[Text.UTF8Encoding]::new($false))
Set-CapTracePath -Path (Join-Path $output 'action-calls.jsonl')
$leaseWindow=Get-CapLeaseWindow -GrantedUtc $authorization.grantedUtc `
    -ExpiresUtc $authorization.expiresUtc -MaximumMinutes ([double]$authorization.maxMinutes) `
    -NowUtc ([DateTime]::UtcNow)
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
    -Binding $journalBinding -DeadlineUtc $leaseWindow.ExpiresUtc.UtcDateTime
Write-CapWorkerJournalSnapshot -Kind 'Bootstrap'
$startedUtc=[DateTime]::UtcNow
$primaryFailure=$null
$independent=@()
try {
    $matchedFixture=Get-Content $fixturePath -Raw | ConvertFrom-Json -DateKind String
    Initialize-CapMatchedWorktrees -Fixture $matchedFixture
    if ($plan.group -ceq 'TerminalActions') {
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
    authorizationSha256=(Get-FileHash $authorizationPath -Algorithm SHA256).Hash
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
    failures=$(if ($primaryFailure) {@($primaryFailure.Exception.Message)} else {@()})
    pngCount=[long]@(Get-ChildItem $root -Recurse -File -Filter '*.png').Count
}
$manifestPath=Join-Path $output 'action-manifest.json'
[IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 50),
    [Text.UTF8Encoding]::new($false))
$release=[ordered]@{
    schemaVersion=1L
    status=$(if ($manifest.status -ceq 'COMPLETE') {'RELEASED_ZERO_SURVIVORS'}
        elseif ($independent.Count -eq 0) {'FAILED_ZERO_SURVIVORS'} else {'CLEANUP_UNPROVEN'})
    cleanupState=$(if ($independent.Count -eq 0 -and $cleanupFailures.Count -eq 0) {
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
if ($manifest.pngCount -ne [long]$plan.maximumResultPngs) {
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
