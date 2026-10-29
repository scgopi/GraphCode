param(
    [string]$ScratchRoot = (Join-Path ([IO.Path]::GetTempPath()) ('ai' + [guid]::NewGuid().ToString('N').Substring(0,8)))
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$driverDirectory = Split-Path -Parent $PSScriptRoot
$workerPath = Join-Path $driverDirectory 'Invoke-UiCaptureWorker.ps1'
$caseRoot = [IO.Path]::GetFullPath($ScratchRoot)
if (Test-Path -LiteralPath $caseRoot) { throw "Refusing to replace import evidence: $caseRoot" }
$null = New-Item -ItemType Directory -Path $caseRoot
$authorizationPath = Join-Path $caseRoot 'action-authorization.json'
$authorizationSha256 = 'A' * 64
$expectedAuthorizationPath = $authorizationPath
$expectedAuthorizationSha256 = $authorizationSha256
. $workerPath -OwnedRoot $caseRoot -DefinitionsOnly
if ($authorizationPath -cne $expectedAuthorizationPath -or
    $authorizationSha256 -cne $expectedAuthorizationSha256) {
    throw "Worker definitions import reset caller authorization: path='$authorizationPath' hash='$authorizationSha256'."
}
Import-Module $modulePath -Force -WarningAction SilentlyContinue
Set-CapTracePath -Path (Join-Path $caseRoot 'calls.jsonl')
$results = [Collections.Generic.List[object]]::new()
$results.Add(@{name='caller authorization survives production definitions import';passed=$true})

function Assert-ImportCase {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) {throw $Message}
}

function Write-ImportJson {
    param([string]$Path,$Value)
    [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false))
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Reject-ImportCase {
    param([string]$Name,[scriptblock]$Action,[string]$Message)
    $failure=$null
    try {& $Action | Out-Null} catch {$failure=$_}
    Assert-ImportCase ($null -ne $failure -and $failure.Exception.Message.Contains($Message)) `
        "Expected $Name refusal '$Message'; actual=$failure"
    $results.Add(@{name=$Name;passed=$true;refusal=$failure.Exception.Message})
}

$now=[DateTimeOffset]::UtcNow.AddSeconds(-1)
$expected=[pscustomobject][ordered]@{
    authorizationId=[guid]::NewGuid().ToString()
    ownedRoot=$caseRoot
    authorizationPath=$authorizationPath
    runDirectory=(Join-Path $caseRoot 'runs\one')
    processJournalPath=(Join-Path $caseRoot 'runs\one\process-journal')
    actionPlanSha256=('A'*64);jobSha256=('B'*64);moduleSha256=('C'*64)
    workerSha256=('D'*64);actionRunnerSha256=('E'*64)
    sourceHead=('a'*40);sourceTree=('b'*40);group='FinalBoundedActions'
    grantedUtc=$now.ToString('o');expiresUtc=$now.AddMinutes(3).ToString('o');maxMinutes=3L
    status='AUTHORIZED';authorizedAction='matched-action-supplement';pngAuthorized=$true
}
$hash=Write-ImportJson $authorizationPath $expected
Reject-ImportCase 'null path' {Open-CapActionAuthorization -Path $null -Sha256 $hash -Expected $expected} 'null or empty'
Reject-ImportCase 'empty path' {Open-CapActionAuthorization -Path '' -Sha256 $hash -Expected $expected} 'null or empty'
Reject-ImportCase 'reset path' {
    $reset=$null
    Open-CapActionAuthorization -Path $reset -Sha256 $hash -Expected $expected
} 'null or empty'
Reject-ImportCase 'foreign path' {
    Open-CapActionAuthorization -Path (Join-Path (Split-Path -Parent $caseRoot) 'foreign.json') -Sha256 $hash -Expected $expected
} 'escaped'
Reject-ImportCase 'wrong hash' {Open-CapActionAuthorization -Path $authorizationPath -Sha256 ('0'*64) -Expected $expected} 'hash mismatch'
foreach ($field in @('runDirectory','processJournalPath','authorizationId','status','authorizedAction')) {
    $record=$expected | ConvertTo-Json | ConvertFrom-Json -DateKind String
    $record.$field='foreign'
    $changedHash=Write-ImportJson $authorizationPath $record
    Reject-ImportCase "wrong $field" {
        Open-CapActionAuthorization -Path $authorizationPath -Sha256 $changedHash -Expected $expected
    } $(if ($field -in @('status','authorizedAction')) {'authority differs'} else {"binding differs: $field"})
}
foreach ($timing in @('stale','deadline')) {
    $record=$expected | ConvertTo-Json | ConvertFrom-Json -DateKind String
    $expiry=if ($timing -ceq 'stale') {[DateTimeOffset]::UtcNow.AddMinutes(-1)} else {[DateTimeOffset]::UtcNow.AddSeconds(60)}
    $record.grantedUtc=$expiry.AddMinutes(-3).ToString('o')
    $record.expiresUtc=$expiry.ToString('o')
    $changedHash=Write-ImportJson $authorizationPath $record
    Reject-ImportCase $timing {
        Open-CapActionAuthorization -Path $authorizationPath -Sha256 $changedHash -Expected $record
    } $(if ($timing -ceq 'stale') {'expired'} else {'deadline expired'})
}
$hash=Write-ImportJson $authorizationPath $expected
$held=Open-CapActionAuthorization -Path $authorizationPath -Sha256 $hash -Expected $expected
try {
    Reject-ImportCase 'replacement while held' {
        [IO.File]::Move($authorizationPath,($authorizationPath+'.replaced'))
    } 'used by another process'
    Reject-ImportCase 'write while held' {[IO.File]::WriteAllText($authorizationPath,'{}')} 'used by another process'
} finally {$held.Pin.Dispose()}
[IO.File]::WriteAllText($authorizationPath,'{}')
Reject-ImportCase 'replaced bytes before open' {
    Open-CapActionAuthorization -Path $authorizationPath -Sha256 $hash -Expected $expected
} 'hash mismatch'

# A clean fixture repository binds unmodified production entry scripts, not a wrapper or AST projection.
$fixtureRepository=Join-Path $caseRoot 'repository'
$fixtureTools=Join-Path $fixtureRepository 'Tools\windows'
$null=New-Item -ItemType Directory -Path $fixtureTools
foreach ($name in @('Invoke-MatchedActionSupplement.ps1','Invoke-UiCaptureWorker.ps1','UiCaptureDriver.psm1',
    'Stub-Daemon.ps1','Start-MatchedActionSessions.ps1')) {
    Copy-Item -LiteralPath (Join-Path $driverDirectory $name) -Destination (Join-Path $fixtureTools $name)
}
& git init --quiet $fixtureRepository
& git -C $fixtureRepository config core.autocrlf false
& git -C $fixtureRepository add .
& git -C $fixtureRepository -c user.name=Contract -c user.email=contract@example.invalid `
    -c commit.gpgsign=false commit --quiet -s -m 'Production entry fixture'
if ($LASTEXITCODE -ne 0) {throw 'Could not commit production entry fixture.'}
$fixtureHead=(& git -C $fixtureRepository rev-parse HEAD).Trim()
$fixtureTree=(& git -C $fixtureRepository rev-parse 'HEAD^{tree}').Trim()
foreach ($scenario in @('accepted','setup-refusal')) {
    $owned=Join-Path $caseRoot $scenario
    $null=New-Item -ItemType Directory -Path (Join-Path $owned 'fixtures'),(Join-Path $owned 'inputs')
    $fixtureHashValue=Write-ImportJson (Join-Path $owned 'fixtures\fixture.json') @{}
    $jobFile=Join-Path $owned 'job.json'
    $windowIdentity=Get-CapGraphCodeWindowIdentity `
        -SourceText ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\c8r-window-after.zig'))) `
        -SourceCommit $fixtureHead -ExpectedDpi 96 -LogicalClientWH @(320,240)
    if ($scenario -ceq 'setup-refusal') {$windowIdentity.expectedAdjustedOuterWH=@(1L,1L)}
    $jobValue=@{sceneAdapter='S_MATCHED_V12_DPI_V1';head=$fixtureHead
        binaries=@{after=@{source=$fixtureHead;binaryBuiltAtSource=$fixtureHead}}
        captureContract=@{
        logicalClientWH=@(320L,240L);expectedWindowDpi=96L
        windowIdentities=@{before=$windowIdentity;after=$windowIdentity}
    }}
    $jobValue=$jobValue|ConvertTo-Json -Depth 30|ConvertFrom-Json -DateKind String
    $windowBindings=@(Get-CapActionWindowBindings -Job $jobValue -Group FinalBoundedActions)
    $jobDigest=Write-ImportJson $jobFile $jobValue
    $preflightFile=Join-Path $owned 'preflight.json'
    $preflightDigest=Write-ImportJson $preflightFile @{status='FILE_ONLY_TEST_NOT_LIVE_PREFLIGHT'}
    $sceneFile=Join-Path $owned 'scenes.json'
    $sceneDigest=Write-ImportJson $sceneFile @{}
    $actionPlan=[ordered]@{
        status='PREPARED_NO_AUTHORITY';pngArtifacts=0L;processLaunches=0L
        sourceHead=$fixtureHead;sourceTree=$fixtureTree;group='FinalBoundedActions'
        expectedScenes=@($windowBindings|ForEach-Object {$_.sceneNames})
        actionWindowBindings=$windowBindings
        moduleSha256=(Get-FileHash (Join-Path $fixtureTools 'UiCaptureDriver.psm1')).Hash
        workerSha256=(Get-FileHash (Join-Path $fixtureTools 'Invoke-UiCaptureWorker.ps1')).Hash
        stubDaemonSha256=(Get-FileHash (Join-Path $fixtureTools 'Stub-Daemon.ps1')).Hash
        actionRunnerSha256=(Get-FileHash (Join-Path $fixtureTools 'Invoke-MatchedActionSupplement.ps1')).Hash
        actionSeedHelperSha256=(Get-FileHash (Join-Path $fixtureTools 'Start-MatchedActionSessions.ps1')).Hash
        jobPath=$jobFile;jobSha256=$jobDigest
        preflightReceiptPath=$preflightFile;preflightReceiptSha256=$preflightDigest
        existingSceneManifestPath=$sceneFile;existingSceneManifestSha256=$sceneDigest
        authorizationBounds=@{requestedMaxMinutes=3L}
        fixture=@{canonicalSourceSha256=$fixtureHashValue;mappingSha256=$fixtureHashValue}
        imageBindings=@{};maximumResultPngs=1L
    }
    $planFile=Join-Path $owned 'action-plan.json'
    $planDigest=Write-ImportJson $planFile $actionPlan
    $entryOutput=@(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File `
        (Join-Path $fixtureTools 'Invoke-MatchedActionSupplement.ps1') `
        -Repository $fixtureRepository -OwnedRoot $owned -ActionPlanPath $planFile -ActionPlanSha256 $planDigest -DryRun 2>&1)
    $entryExit=$LASTEXITCODE
    $entryOutput | Set-Content -LiteralPath (Join-Path $owned 'entry.log') -Encoding utf8NoBOM
    $manifestFile=Join-Path $owned 'dry-run-output\action-manifest.json'
    Assert-ImportCase (Test-Path -LiteralPath $manifestFile) "Production entry did not publish manifest: $entryOutput"
    $manifest=Get-Content $manifestFile -Raw | ConvertFrom-Json -DateKind String
    $release=Get-Content (Join-Path $owned 'dry-run-output\action-release.json') -Raw | ConvertFrom-Json -DateKind String
    $launchSpecs=@(Get-ChildItem (Join-Path $owned 'dry-run-output') -File -Filter '*-launch.json')
    if ($scenario -ceq 'setup-refusal') {
        Assert-ImportCase ($entryExit -ne 0 -and $manifest.status -ceq 'FAILED' -and
            $release.status -ceq 'FAILED_ZERO_SURVIVORS' -and $manifest.failures.Count -eq 1 -and
            $release.cleanupState -ceq 'NO_PROCESS_LAUNCHES' -and
            $manifest.failures[0].Contains('adjusted outer size differs') -and
            ($entryOutput -join "`n").Contains('adjusted outer size differs') -and
            $launchSpecs.Count -eq 0 -and $manifest.processJournal.Count -eq 0 -and
            $manifest.receiptCount -eq 0 -and $manifest.providerReceipts.Count -eq 0 -and
            $manifest.cleanupFailures.Count -eq 0 -and $manifest.independentSurvivors.Count -eq 0 -and
            $manifest.pngCount -eq 0) 'Primary prelaunch setup refusal was masked or launched a process.'
        $results.Add(@{name="production entry $scenario";passed=$true;manifestPath=$manifestFile
            manifestSha256=(Get-FileHash $manifestFile).Hash;publications=$manifest.numberedJournal.published.Count})
        continue
    }
    Assert-ImportCase ($launchSpecs.Count -eq 1) 'Dry run must have exactly one harmless target specification.'
    $launchSpec=Get-Content $launchSpecs[0].FullName -Raw | ConvertFrom-Json -DateKind String
    Assert-ImportCase ($launchSpec.filePath -ieq (Join-Path $PSHOME 'pwsh.exe') -and
        ($launchSpec.arguments -join '|') -ceq '-NoProfile|-NonInteractive|-Command|exit 0' -and
        $manifest.processJournal.Count -ge 1 -and
        @($manifest.processJournal | Where-Object {
            $_.expectedImagePath -ine (Join-Path $PSHOME 'pwsh.exe') -and
            -not ($_.role -ceq 'job-member' -and
                $_.expectedImagePath -ieq (Join-Path ([Environment]::SystemDirectory) 'conhost.exe'))
        }).Count -eq 0) 'Dry run launched or journaled a non-harmless image.'
    Assert-ImportCase ($manifest.executionMode -ceq 'DRY_RUN_NO_AUTHORITY' -and
        $manifest.dryRun.preconditionsEvaluated -and $manifest.dryRun.productLaunches -eq 0 -and
        $manifest.dryRun.providerLaunches -eq 0 -and $manifest.receiptCount -eq 0 -and
        $manifest.dryRun.windowBindings.Count -eq 6 -and
        $manifest.dryRun.windowBindings[0].actionPhase -ceq 'wire-completion' -and
        $manifest.dryRun.windowBindings[0].capturePhase -ceq 'after' -and
        $null -ne $manifest.dryRun.windowBindings[0].identity -and
        @($manifest.dryRun.windowBindings | Where-Object {
            $_.validation -cne 'NONNULL_SOURCE_BOUND_IDENTITY_BEFORE_LAUNCH' -or
            $null -eq $_.identity -or $_.identity.sourceCommit -cne $fixtureHead
        }).Count -eq 0 -and
        $manifest.providerReceipts.Count -eq 0 -and $manifest.pngCount -eq 0 -and
        $manifest.cleanupFailures.Count -eq 0 -and $manifest.independentSurvivors.Count -eq 0 -and
        $manifest.cleanup.Count -eq 1 -and $manifest.cleanup[0].jobActive0 -and
        $manifest.cleanup[0].launcherStdoutEof -and $manifest.cleanup[0].launcherStderrEof -and
        $manifest.numberedJournal.published.Count -ge 3 -and $null -ne $manifest.numberedJournal.terminal -and
        $manifest.dryRun.journalDirectory -ceq $manifest.numberedJournal.directory -and
        $manifest.dryRun.releaseSequence -ge 2 -and $release.journalPublicationCount -ge 3 -and
        $release.manifestSha256 -ceq (Get-FileHash $manifestFile).Hash -and
        -not (Test-Path (Join-Path $owned 'action-authorization.json'))) 'Dry-run custody/no-authority/cleanup evidence differs.'
    $binding=Get-Content (Join-Path $owned 'dry-run-binding.json') -Raw | ConvertFrom-Json -DateKind String
    Assert-ImportCase ($binding.status -ceq 'DRY_RUN_NO_AUTHORITY' -and
        $binding.pngAuthorized -eq $false -and $binding.authorizationPath -ceq $manifest.dryRun.authorizationPath -and
        $binding.authorizationId -ceq $manifest.numberedJournal.binding.leaseId -and
        (Split-Path -Leaf $binding.runDirectory) -ceq $manifest.numberedJournal.binding.runId) 'Dry-run authorization/run binding differs.'
    if ($scenario -ceq 'accepted') {
        Assert-ImportCase ($entryExit -eq 0 -and $manifest.status -ceq 'COMPLETE' -and
            $release.status -ceq 'RELEASED_ZERO_SURVIVORS' -and
            $manifest.dryRun.geometry.GeometryDerivation -ceq 'AdjustWindowRectExForDpi') "Dry-run failed: $entryOutput"
    }
    $results.Add(@{name="production entry $scenario";passed=$true;manifestPath=$manifestFile
        manifestSha256=(Get-FileHash $manifestFile).Hash;publications=$manifest.numberedJournal.published.Count})
}
$report=[ordered]@{suite='ActionWorkerImport';executed=$results.Count;passed=$results.Count;failed=0;skipped=0
    productLaunches=0;providerLaunches=0;cases=@($results)}
$null=Write-ImportJson (Join-Path $caseRoot 'report.json') $report
[pscustomobject]$report | Select-Object suite,executed,passed,failed,skipped | ConvertTo-Json -Compress
if ($results.Count -ne 18) {throw "Unexpected action import contract count: $($results.Count)"}
