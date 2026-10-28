param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$OwnedRoot,
    [Parameter(Mandatory)][string]$GraphCodeBinary,
    [Parameter(Mandatory)][string]$ZmxBinary,
    [Parameter(Mandatory)][string]$DaemonRuntimeRoot,
    [Parameter(Mandatory)][string]$BackendFixtureBinary,
    [Parameter(Mandatory)][string]$OfflinePeerSource,
    [Parameter(Mandatory)][string]$PreflightReport,
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
    evidenceClassification='F2_TERMINAL_CHROME_FOCUSED_VALIDATION_V2'
    lane='S'
    sceneAdapter='S_MATCHED_V12_DPI_V1'
    head=$head
    base=$head
    captureTree=$tree
    sourceRepository=$repositoryRoot
    authority=[ordered]@{centralCaptureLeaseGrantedByThisArtifact=$false;sWorkerMayLaunchGui=$false}
    focusedCapture=[ordered]@{
        schemaVersion=1L
        phases=@('after')
        sceneNames=@(Get-CapMatchedFocusedSceneNames)
        evidenceClassification='F2_TERMINAL_CHROME_FOCUSED_VALIDATION_V2'
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
$now=[DateTimeOffset]::UtcNow
$granted=$now.AddSeconds(-1)
$authorization=[ordered]@{
    schemaVersion=1L
    authorizationId=[guid]::NewGuid().ToString()
    status='AUTHORIZED'
    authorizedAction='focused-matched-capture'
    evidenceClassification='F2_TERMINAL_CHROME_FOCUSED_VALIDATION_V2'
    officialParityEvidence=$false
    desktopAuthorized=$true
    captureEvidenceAuthorized=$true
    pngAuthorized=$true
    lane='S'
    head=$head
    sourceTree=$tree
    jobManifestSha256=$jobHash
    moduleSha256=(Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash
    workerSha256=(Get-FileHash -LiteralPath $workerPath -Algorithm SHA256).Hash
    supervisorSha256=(Get-FileHash -LiteralPath $supervisorPath -Algorithm SHA256).Hash
    preflightReceiptSha256=(Get-FileHash -LiteralPath $preflightPath -Algorithm SHA256).Hash
    fixtureMappingSha256=$mappingHash
    beforeBinarySha256=$binaryHash
    afterBinarySha256=$binaryHash
    sceneNames=@(Get-CapMatchedFocusedSceneNames)
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
    outputDirectory=Join-Path $root 'outputs'
    sourceHead=$head
    sourceTree=$tree
    binarySha256=$binaryHash
    zmxSha256=$zmxHash
}
$result | ConvertTo-Json -Depth 10
