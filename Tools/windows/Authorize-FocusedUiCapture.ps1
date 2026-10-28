param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$OwnedRoot,
    [Parameter(Mandatory)][string]$FocusedPlanPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$FocusedPlanSha256,
    [ValidateRange(3,30)][long]$AuthorizationMinutes = 20
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($OwnedRoot).TrimEnd('\')
$repositoryRoot=[IO.Path]::GetFullPath($Repository).TrimEnd('\')
$planPath=[IO.Path]::GetFullPath($FocusedPlanPath)
if (-not $planPath.StartsWith($root + '\',[StringComparison]::OrdinalIgnoreCase) -or
    -not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
    throw 'Focused plan must be an existing file below the exact owned root.'
}
if ((Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash -ne
    $FocusedPlanSha256.ToUpperInvariant()) {
    throw 'Focused plan hash mismatch.'
}
$plan=Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -DateKind String
if ($plan.schemaVersion -ne 1 -or $plan.status -cne 'PREPARED_NO_AUTHORITY' -or
    $plan.ownedRoot -ine $root -or $plan.repository -ine $repositoryRoot -or
    $plan.officialParityEvidence -cne $false -or $plan.phases.Count -ne 1 -or
    $plan.phases[0] -cne 'after' -or $plan.sceneCount -ne $plan.sceneNames.Count -or
    $plan.sceneCount -le 0 -or $plan.pngArtifacts -ne 0 -or $plan.processLaunches -ne 0) {
    throw 'Focused plan shape or no-authority boundary differs.'
}
if (@(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.png').Count -ne 0) {
    throw 'Focused authorization refuses a prepared root containing PNG artifacts.'
}
$modulePath=Join-Path $repositoryRoot 'Tools\windows\UiCaptureDriver.psm1'
$workerPath=Join-Path $repositoryRoot 'Tools\windows\Invoke-UiCaptureWorker.ps1'
$supervisorPath=Join-Path $repositoryRoot 'Tools\windows\Invoke-UiCapture.ps1'
Import-Module $modulePath -Force -WarningAction SilentlyContinue
$jobPath=[IO.Path]::GetFullPath([string]$plan.jobPath)
$preflightPath=[IO.Path]::GetFullPath([string]$plan.preflightReceiptPath)
foreach ($binding in @(
    @($modulePath,$plan.modulePath,$plan.moduleSha256),
    @($workerPath,$plan.workerPath,$plan.workerSha256),
    @($supervisorPath,$plan.supervisorPath,$plan.supervisorSha256),
    @($jobPath,$plan.jobPath,$plan.jobSha256),
    @($preflightPath,$plan.preflightReceiptPath,$plan.preflightReceiptSha256),
    @($plan.fixture.mappingPath,$plan.fixture.mappingPath,$plan.fixture.mappingSha256),
    @($plan.fixture.canonicalSourcePath,$plan.fixture.canonicalSourcePath,$plan.fixture.canonicalSourceSha256),
    @($plan.fixture.rewrittenPath,$plan.fixture.rewrittenPath,$plan.fixture.rewrittenSha256),
    @($plan.binaries.graphCodePath,$plan.binaries.graphCodePath,$plan.binaries.graphCodeSha256),
    @($plan.binaries.zmxPath,$plan.binaries.zmxPath,$plan.binaries.zmxSha256),
    @($plan.binaries.daemonPath,$plan.binaries.daemonPath,$plan.binaries.daemonSha256),
    @($plan.binaries.backendFixturePath,$plan.binaries.backendFixturePath,$plan.binaries.backendFixtureSha256),
    @($plan.binaries.offlinePeerPath,$plan.binaries.offlinePeerPath,$plan.binaries.offlinePeerSha256)
)) {
    $actual=[IO.Path]::GetFullPath([string]$binding[0])
    $declared=[IO.Path]::GetFullPath([string]$binding[1])
    if ($actual -ine $declared -or -not (Test-Path -LiteralPath $actual -PathType Leaf) -or
        (Get-FileHash -LiteralPath $actual -Algorithm SHA256).Hash -ne [string]$binding[2]) {
        throw "Focused prepared input changed: $declared"
    }
}
$head=(& git -C $repositoryRoot rev-parse HEAD).Trim()
$tree=(& git -C $repositoryRoot rev-parse 'HEAD^{tree}').Trim()
if ($head -cne $plan.sourceHead -or $tree -cne $plan.sourceTree -or
    @(& git -C $repositoryRoot status --porcelain --untracked-files=all).Count -ne 0) {
    throw 'Focused authorization requires the unchanged clean prepared source head and tree.'
}
$job=Get-Content -LiteralPath $jobPath -Raw | ConvertFrom-Json -DateKind String
Assert-CapSceneContract -Job $job
$capturePlan=Get-CapMatchedCapturePlan -Job $job
if ($capturePlan.profile -cne $plan.profile -or
    $capturePlan.evidenceClassification -cne $plan.evidenceClassification -or
    ($capturePlan.sceneNames -join ',') -cne ($plan.sceneNames -join ',') -or
    ($capturePlan.phases -join ',') -cne ($plan.phases -join ',') -or
    $plan.authorizationBounds.requestedMaxMinutes -ne $AuthorizationMinutes -or
    $plan.authorizationBounds.cleanupReserveSeconds -ne 90 -or
    $plan.cleanupExpectations.kernelExitAndEofRequired -cne $true -or
    $plan.cleanupExpectations.pendingLaunchesExpected -ne 0 -or
    $plan.cleanupExpectations.ownedProcessSurvivorsExpected -ne 0 -or
    $plan.cleanupExpectations.cleanupFailuresExpected -ne 0) {
    throw 'Focused authorization plan, geometry, deadline or cleanup expectations differ.'
}
$preflight=Get-Content -LiteralPath $preflightPath -Raw | ConvertFrom-Json -DateKind String
if ($preflight.executed -ne 185 -or $preflight.passed -ne 185 -or
    $preflight.failed -ne 0 -or $preflight.skipped -ne 0 -or
    $preflight.gui -cne 'NotExecuted' -or $preflight.images -ne 0 -or
    @($preflight.cases | Where-Object {$_.passed -cne $true}).Count -ne 0 -or
    $preflight.controls.moduleSha256 -ne $plan.moduleSha256 -or
    $preflight.controls.workerSha256 -ne $plan.workerSha256 -or
    $preflight.controls.supervisorSha256 -ne $plan.supervisorSha256) {
    throw 'Focused authorization preflight no longer proves the prepared controls.'
}
$now=[DateTimeOffset]::UtcNow
$granted=$now.AddSeconds(-1)
$authorization=[ordered]@{
    schemaVersion=1L
    authorizationId=[guid]::NewGuid().ToString()
    status='AUTHORIZED'
    authorizedAction='focused-matched-capture'
    evidenceClassification=$plan.evidenceClassification
    officialParityEvidence=$false
    desktopAuthorized=$true
    captureEvidenceAuthorized=$true
    pngAuthorized=$true
    lane='S'
    head=$head
    sourceTree=$tree
    jobManifestSha256=$plan.jobSha256
    moduleSha256=$plan.moduleSha256
    workerSha256=$plan.workerSha256
    supervisorSha256=$plan.supervisorSha256
    preflightReceiptSha256=$plan.preflightReceiptSha256
    fixtureMappingSha256=$plan.fixture.mappingSha256
    beforeBinarySha256=$plan.binaries.graphCodeSha256
    afterBinarySha256=$plan.binaries.graphCodeSha256
    profile=$plan.profile
    sceneNames=@($plan.sceneNames)
    phases=@($plan.phases)
    focusedPlanSha256=$FocusedPlanSha256.ToUpperInvariant()
    grantedUtc=$granted.ToString('o')
    expiresUtc=$granted.AddMinutes($AuthorizationMinutes).ToString('o')
    maxMinutes=$AuthorizationMinutes
}
$authorizationPath=Join-Path $root 'focused-authorization.json'
if (Test-Path -LiteralPath $authorizationPath) {
    throw 'Focused authorization has already been granted for this prepared root.'
}
[IO.File]::WriteAllText($authorizationPath,($authorization | ConvertTo-Json -Depth 20),
    [Text.UTF8Encoding]::new($false))
[ordered]@{
    ownedRoot=$root
    focusedAuthorizationPath=$authorizationPath
    focusedAuthorizationSha256=(Get-FileHash -LiteralPath $authorizationPath -Algorithm SHA256).Hash
    focusedPlanPath=$planPath
    focusedPlanSha256=$FocusedPlanSha256.ToUpperInvariant()
    jobPath=$jobPath
    jobSha256=$plan.jobSha256
    fixtureMappingSha256=$plan.fixture.mappingSha256
    preflightReceiptPath=$preflightPath
    preflightReceiptSha256=$plan.preflightReceiptSha256
    outputDirectory=Join-Path $root 'outputs'
    sourceHead=$head
    sourceTree=$tree
    profile=$plan.profile
    sceneNames=@($plan.sceneNames)
    evidenceClassification=$plan.evidenceClassification
} | ConvertTo-Json -Depth 10
