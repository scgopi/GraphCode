param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$OwnedRoot,
    [Parameter(Mandatory)][string]$GraphCodeBinary,
    [Parameter(Mandatory)][string]$ZmxBinary,
    [Parameter(Mandatory)][string]$DaemonRuntimeRoot,
    [Parameter(Mandatory)][string]$BackendFixtureBinary,
    [Parameter(Mandatory)][string]$OfflinePeerSource,
    [Parameter(Mandatory)][string]$PreflightReport,
    [ValidateSet('TerminalChrome','PostFixCards')][string]$FocusedProfile = 'TerminalChrome',
    [switch]$PlanOnly,
    [ValidateRange(3,30)][long]$AuthorizationMinutes = 20
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($OwnedRoot).TrimEnd('\')
$repositoryRoot=[IO.Path]::GetFullPath($Repository).TrimEnd('\')
if (Test-Path -LiteralPath $root) {throw "Focused capture root already exists: $root"}
if ($root.Length -gt 5 -or $root -eq [IO.Path]::GetPathRoot($root).TrimEnd('\')) {
    throw 'Focused capture requires a fresh owned root of at most five characters.'
}
$head=(& git -C $repositoryRoot rev-parse HEAD).Trim()
$tree=(& git -C $repositoryRoot rev-parse 'HEAD^{tree}').Trim()
if ($head -cnotmatch '^[a-f0-9]{40}$' -or $tree -cnotmatch '^[a-f0-9]{40}$' -or
    @(& git -C $repositoryRoot status --porcelain --untracked-files=all).Count -ne 0) {
    throw 'Focused capture preparation requires a clean exact Git head and tree.'
}

$modulePath=Join-Path $repositoryRoot 'Tools\windows\UiCaptureDriver.psm1'
$workerPath=Join-Path $repositoryRoot 'Tools\windows\Invoke-UiCaptureWorker.ps1'
$supervisorPath=Join-Path $repositoryRoot 'Tools\windows\Invoke-UiCapture.ps1'
foreach ($path in @($modulePath,$workerPath,$supervisorPath,$GraphCodeBinary,$ZmxBinary,
    (Join-Path $DaemonRuntimeRoot 'graphcoded.exe'),$BackendFixtureBinary,$OfflinePeerSource,
    $PreflightReport)) {
    if (-not (Test-Path -LiteralPath $path)) {throw "Focused capture input is missing: $path"}
}
Import-Module $modulePath -Force -WarningAction SilentlyContinue
$focusedScenes=@(Get-CapMatchedFocusedSceneNames -Profile $FocusedProfile)
$focusedClassification=Get-CapMatchedFocusedClassification -Profile $FocusedProfile
$moduleHash=(Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash
$workerHash=(Get-FileHash -LiteralPath $workerPath -Algorithm SHA256).Hash
$supervisorHash=(Get-FileHash -LiteralPath $supervisorPath -Algorithm SHA256).Hash
$preflight=Get-Content -LiteralPath $PreflightReport -Raw | ConvertFrom-Json -DateKind String
$requiredRealZmxCases=@(
    'real zmx job lifecycle through actual command with target normal',
    'real zmx job lifecycle through actual command with target nonzero',
    'real zmx job lifecycle through actual command with target timeout'
)
if ($preflight.suite -cne 'UiCaptureDriver' -or $preflight.executed -ne 185 -or
    $preflight.passed -ne 185 -or $preflight.failed -ne 0 -or $preflight.skipped -ne 0 -or
    $preflight.mode -cne 'NO_DESKTOP_REAL_LAUNCH_REHEARSAL' -or
    $preflight.gui -cne 'NotExecuted' -or $preflight.images -ne 0 -or
    $preflight.backendTurns -ne 0 -or $preflight.cases.Count -ne 185 -or
    @($preflight.cases | Where-Object {$_.passed -cne $true}).Count -ne 0 -or
    $preflight.controls.moduleSha256 -ne $moduleHash -or
    $preflight.controls.workerSha256 -ne $workerHash -or
    $preflight.controls.supervisorSha256 -ne $supervisorHash) {
    throw 'Focused capture preparation requires the exact green 185-case no-desktop preflight for the current controls.'
}
foreach ($caseName in $requiredRealZmxCases) {
    if (@($preflight.cases | Where-Object name -CEQ $caseName).Count -ne 1) {
        throw "Focused capture preflight omitted or duplicated required case: $caseName"
    }
}

$inputs=Join-Path $root 'inputs'
$runtime=Join-Path $root 'runtime'
$fixtures=Join-Path $root 'fixtures'
$reports=Join-Path $root 'reports'
$null=New-Item -ItemType Directory -Path $inputs,$runtime,$fixtures,$reports
$null=Copy-Item -LiteralPath $GraphCodeBinary -Destination (Join-Path $inputs 'graphcode-before.exe')
$null=Copy-Item -LiteralPath $GraphCodeBinary -Destination (Join-Path $inputs 'graphcode-after.exe')
$null=Copy-Item -LiteralPath $ZmxBinary -Destination (Join-Path $runtime 'zmx.exe')
$null=Copy-Item -LiteralPath $BackendFixtureBinary -Destination (Join-Path $runtime 'copilot.exe')
$null=Copy-Item -LiteralPath $OfflinePeerSource -Destination (Join-Path $inputs 'offline-peer-source.ps1')
foreach ($file in Get-ChildItem -LiteralPath $DaemonRuntimeRoot -File) {
    if ($file.Name -cin @('zmx.exe','copilot.exe')) {continue}
    $null=Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $runtime $file.Name)
}
$fixtureSource=Join-Path $repositoryRoot 'Tools\windows\fixtures\matched-v12.json'
$copiedFixtureSource=Join-Path $inputs 'fixture-source.json'
$null=Copy-Item -LiteralPath $fixtureSource -Destination $copiedFixtureSource
$fixturePath=Join-Path $fixtures 'fixture.json'
$destinationProjectRoot=Join-Path $fixtures 'projects'
$null=New-Item -ItemType Directory -Path $destinationProjectRoot
$fixtureText=[IO.File]::ReadAllText($copiedFixtureSource).Replace(
    'C:\\fixture',(($destinationProjectRoot | ConvertTo-Json -Compress).Trim('"')))
[IO.File]::WriteAllText($fixturePath,$fixtureText,[Text.UTF8Encoding]::new($false))
$backendSourcePath=Join-Path $inputs 'offline-backend.c'
[IO.File]::WriteAllText($backendSourcePath,(Get-CapMatchedBackendSource),[Text.UTF8Encoding]::new($false))
$preflightPath=Join-Path $reports 'preflight-185.json'
$null=Copy-Item -LiteralPath $PreflightReport -Destination $preflightPath

$fixtureSourceHash=(Get-FileHash -LiteralPath $copiedFixtureSource -Algorithm SHA256).Hash
$fixtureHash=(Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
$mappingPath=Join-Path $reports 'fixture-mapping.json'
$mapping=[ordered]@{
    sourcePath='C:\fixture\fixture.json'
    sourceSha256=$fixtureSourceHash
    copiedSourcePath=$copiedFixtureSource
    rewrittenFixturePath=$fixturePath
    rewrittenFixtureSha256=$fixtureHash
    pathPrefixMap=[ordered]@{from='C:\fixture';to=$destinationProjectRoot}
    graphs=1L
    topLevelNodes=8L
    pathsRewritten=$true
}
[IO.File]::WriteAllText($mappingPath,($mapping | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
$mappingHash=(Get-FileHash -LiteralPath $mappingPath -Algorithm SHA256).Hash
$binaryHash=(Get-FileHash -LiteralPath (Join-Path $inputs 'graphcode-after.exe') -Algorithm SHA256).Hash
$zmxHash=(Get-FileHash -LiteralPath (Join-Path $runtime 'zmx.exe') -Algorithm SHA256).Hash
$daemonHash=(Get-FileHash -LiteralPath (Join-Path $runtime 'graphcoded.exe') -Algorithm SHA256).Hash
$backendHash=(Get-FileHash -LiteralPath (Join-Path $runtime 'copilot.exe') -Algorithm SHA256).Hash
$backendSourceHash=(Get-FileHash -LiteralPath $backendSourcePath -Algorithm SHA256).Hash
$peerHash=(Get-FileHash -LiteralPath (Join-Path $inputs 'offline-peer-source.ps1') -Algorithm SHA256).Hash
foreach ($caseName in $requiredRealZmxCases) {
    $case=@($preflight.cases | Where-Object name -CEQ $caseName)[0]
    if ($case.detail.evidenceMode -cne 'EXECUTED_CURRENT_REAL_ZMX' -or
        $case.detail.providerCommit -cne '785b3fd15dcafd1882b495c831a10f98c201b908' -or
        $case.detail.zmxSha256 -ne $zmxHash) {
        throw "Focused capture preflight real-zmx evidence differs for: $caseName"
    }
}

$scenes=@(Get-CapMatchedSceneNames | ForEach-Object {
    [ordered]@{name=$_;naturalWidthBeforeAfter=@(250L,250L)}
})
$identity=[ordered]@{
    sourceContract='GRAPHCODE_MAIN_WINDOW_V1';sourceCommit=$head;expectedWindowDpi=192L
    requestedOuterWH=@(1280L,820L);expectedInitialClientWH=@(1254L,710L)
    expectedInitialOuterWH=@(1280L,820L);expectedPhysicalClientWH=@(2880L,1800L)
    expectedAdjustedOuterWH=@(2906L,1910L);windowStyleForAdjustment=47120384L
    windowExStyleForAdjustment=0L;expectedRuntimeWindowStyle=382664704L
    expectedRuntimeWindowExStyle=256L;hasMenu=$true
    geometryDerivation='SOURCE_CREATEWINDOWEX_PLUS_WIN32_NORMALIZATION'
}
$job=[ordered]@{
    executionMode='FOCUSED_LIVE_CAPTURE'
    desktopAuthorized=$true
    evidenceClassification=$focusedClassification
    lane='S'
    sceneAdapter='S_MATCHED_V12_DPI_V1'
    head=$head
    base=$head
    captureTree=$tree
    sourceRepository=$repositoryRoot
    authority=[ordered]@{centralCaptureLeaseGrantedByThisArtifact=$false;sWorkerMayLaunchGui=$false}
    focusedCapture=[ordered]@{
        schemaVersion=1L
        profile=$FocusedProfile
        phases=@('after')
        sceneNames=$focusedScenes
        evidenceClassification=$focusedClassification
        officialParityEvidence=$false
    }
    captureContract=[ordered]@{
        geometrySchemaVersion=3L;phases=@('before','after');sceneCountPerPhase=18L
        placement='MEASURED_FIT_WORKAREA';logicalClientWH=@(1440L,900L)
        expectedWindowDpi=192L;dpiBase=96L;expectedPhysicalClientWH=@(2880L,1800L)
        minimumPhysicalWorkAreaWH=@(2906L,1910L)
        windowIdentities=[ordered]@{before=$identity;after=$identity}
        geometryDerivation='AdjustWindowRectExForDpi';canvasZoomPercentLogical=100L
        rawCaptureResamplingAllowed=$false;cleanupReserveSeconds=90L;estimatedSeconds=900L
    }
    scenes=$scenes
    fixture=[ordered]@{
        sha256=$fixtureSourceHash;mappingSha256=$mappingHash;originalRoot='C:\fixture'
        macSource='2ccf303a04f995184aae1d4b738a9eca0f71b79e'
        offlinePeerReference=[ordered]@{sha256=$peerHash}
    }
    binaries=[ordered]@{
        before=[ordered]@{path=(Join-Path $inputs 'graphcode-before.exe');sha256=$binaryHash
            source=$head;binaryBuiltAtSource=$head}
        after=[ordered]@{path=(Join-Path $inputs 'graphcode-after.exe');sha256=$binaryHash
            source=$head;binaryBuiltAtSource=$head}
        offlineZmx=[ordered]@{
            sha256=$zmxHash;providerCommit='785b3fd15dcafd1882b495c831a10f98c201b908'
            seedArgumentOrder=@('run','graphcode-11111111-1111-4111-8111-000000000001',
                '-d','cmd.exe','/Q','/K','echo Offline card fixture - no backend')
        }
        daemon=[ordered]@{path=(Join-Path $runtime 'graphcoded.exe');sha256=$daemonHash
            source=$head;binaryBuiltAtSource=$head}
        backendFixture=[ordered]@{path=(Join-Path $runtime 'copilot.exe');sha256=$backendHash
            sourceSha256=$backendSourceHash;networkAllowed=$false}
    }
}
$jobPath=Join-Path $root 'job.json'
[IO.File]::WriteAllText($jobPath,($job | ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false))
$jobHash=(Get-FileHash -LiteralPath $jobPath -Algorithm SHA256).Hash
$planPath=Join-Path $root 'focused-plan.json'
$plan=[ordered]@{
    schemaVersion=1L
    status='PREPARED_NO_AUTHORITY'
    preparedUtc=[DateTimeOffset]::UtcNow.ToString('o')
    ownedRoot=$root
    repository=$repositoryRoot
    sourceHead=$head
    sourceTree=$tree
    profile=$FocusedProfile
    evidenceClassification=$focusedClassification
    officialParityEvidence=$false
    phases=@('after')
    sceneNames=$focusedScenes
    sceneCount=[long]$focusedScenes.Count
    jobPath=$jobPath
    jobSha256=$jobHash
    modulePath=$modulePath
    moduleSha256=$moduleHash
    workerPath=$workerPath
    workerSha256=$workerHash
    supervisorPath=$supervisorPath
    supervisorSha256=$supervisorHash
    preflightReceiptPath=$preflightPath
    preflightReceiptSha256=(Get-FileHash -LiteralPath $preflightPath -Algorithm SHA256).Hash
    preflight=[ordered]@{
        executed=185L;passed=185L;failed=0L;skipped=0L
        gui='NotExecuted';images=0L;backendTurns=0L
        requiredRealZmxCases=$requiredRealZmxCases
    }
    fixture=[ordered]@{
        canonicalSourcePath=$copiedFixtureSource
        canonicalSourceSha256=$fixtureSourceHash
        rewrittenPath=$fixturePath
        rewrittenSha256=$fixtureHash
        mappingPath=$mappingPath
        mappingSha256=$mappingHash
        graphs=1L
        topLevelNodes=8L
        syntheticMatchedData=$true
    }
    binaries=[ordered]@{
        graphCodePath=(Join-Path $inputs 'graphcode-after.exe');graphCodeSha256=$binaryHash
        zmxPath=(Join-Path $runtime 'zmx.exe');zmxSha256=$zmxHash
        daemonPath=(Join-Path $runtime 'graphcoded.exe');daemonSha256=$daemonHash
        backendFixturePath=(Join-Path $runtime 'copilot.exe');backendFixtureSha256=$backendHash
        offlinePeerPath=(Join-Path $inputs 'offline-peer-source.ps1');offlinePeerSha256=$peerHash
    }
    geometry=$job.captureContract
    authorizationBounds=[ordered]@{
        status='NOT_GRANTED'
        requestedMaxMinutes=$AuthorizationMinutes
        cleanupReserveSeconds=90L
        minimumRemainingMinutesAtLaunch=1L
    }
    cleanupExpectations=[ordered]@{
        kernelExitAndEofRequired=$true
        pendingLaunchesExpected=0L
        ownedProcessSurvivorsExpected=0L
        cleanupFailuresExpected=0L
        independentZeroProcessCheckRequired=$true
    }
    pngArtifacts=0L
    processLaunches=0L
}
[IO.File]::WriteAllText($planPath,($plan | ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false))
$planHash=(Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash
if (@(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.png').Count -ne 0) {
    throw 'Focused plan preparation created an unauthorized PNG.'
}
if ($PlanOnly) {
    [ordered]@{
        ownedRoot=$root
        status='PREPARED_NO_AUTHORITY'
        focusedPlanPath=$planPath
        focusedPlanSha256=$planHash
        jobPath=$jobPath
        jobSha256=$jobHash
        fixtureMappingSha256=$mappingHash
        preflightReceiptPath=$preflightPath
        preflightReceiptSha256=$plan.preflightReceiptSha256
        outputDirectory=Join-Path $root 'outputs'
        sourceHead=$head
        sourceTree=$tree
        profile=$FocusedProfile
        sceneNames=$focusedScenes
        evidenceClassification=$focusedClassification
        pngArtifacts=0L
        processLaunches=0L
    } | ConvertTo-Json -Depth 10
    return
}
$now=[DateTimeOffset]::UtcNow
$granted=$now.AddSeconds(-1)
$authorization=[ordered]@{
    schemaVersion=1L
    authorizationId=[guid]::NewGuid().ToString()
    status='AUTHORIZED'
    authorizedAction='focused-matched-capture'
    evidenceClassification=$focusedClassification
    officialParityEvidence=$false
    desktopAuthorized=$true
    captureEvidenceAuthorized=$true
    pngAuthorized=$true
    lane='S'
    head=$head
    sourceTree=$tree
    jobManifestSha256=$jobHash
    moduleSha256=$moduleHash
    workerSha256=$workerHash
    supervisorSha256=$supervisorHash
    preflightReceiptSha256=(Get-FileHash -LiteralPath $preflightPath -Algorithm SHA256).Hash
    fixtureMappingSha256=$mappingHash
    beforeBinarySha256=$binaryHash
    afterBinarySha256=$binaryHash
    profile=$FocusedProfile
    sceneNames=$focusedScenes
    phases=@('after')
    grantedUtc=$granted.ToString('o')
    expiresUtc=$granted.AddMinutes($AuthorizationMinutes).ToString('o')
    maxMinutes=$AuthorizationMinutes
}
$authorizationPath=Join-Path $root 'focused-authorization.json'
[IO.File]::WriteAllText($authorizationPath,($authorization | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
$result=[ordered]@{
    ownedRoot=$root
    jobPath=$jobPath
    jobSha256=$jobHash
    fixtureMappingSha256=$mappingHash
    preflightReceiptPath=$preflightPath
    preflightReceiptSha256=$authorization.preflightReceiptSha256
    focusedAuthorizationPath=$authorizationPath
    focusedAuthorizationSha256=(Get-FileHash -LiteralPath $authorizationPath -Algorithm SHA256).Hash
    focusedPlanPath=$planPath
    focusedPlanSha256=$planHash
    outputDirectory=Join-Path $root 'outputs'
    sourceHead=$head
    sourceTree=$tree
    binarySha256=$binaryHash
    zmxSha256=$zmxHash
    profile=$FocusedProfile
    sceneNames=$focusedScenes
    evidenceClassification=$focusedClassification
}
$result | ConvertTo-Json -Depth 10
