param(
    [Parameter(Mandatory)][string]$OwnedRoot,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$JobPath,
    [Parameter()][string]$JobSha256,
    [Parameter()][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$FixtureMappingSha256,
    [ValidateSet('LIVE_CAPTURE', 'NO_DESKTOP_REAL_LAUNCH_REHEARSAL')]
    [string]$ExecutionMode = 'LIVE_CAPTURE',
    [Parameter()][string]$LeaseReceiptPath,
    [Parameter()][string]$LeaseReceiptSha256,
    [Parameter()][string]$PreflightReceiptPath,
    [Parameter()][string]$PreflightReceiptSha256,
    [switch]$TimeoutProbe
)
$ErrorActionPreference = 'Stop'
# Promoted from Invoke-BCapture.ps1, FSL-1.1-MIT.
# SHA256 9BFEF53FCC5FFF2334DEDABCA5245D81CBC70A6D8C0B2AE1E9E9C1529AC0D9BB.
$root = [IO.Path]::GetFullPath($OwnedRoot).TrimEnd('\')
$requestedOutputDirectory = $OutputDirectory
$modulePath = Join-Path $PSScriptRoot 'UiCaptureDriver.psm1'
$workerPath = Join-Path $PSScriptRoot 'Invoke-UiCaptureWorker.ps1'
$rehearsal = $ExecutionMode -ceq 'NO_DESKTOP_REAL_LAUNCH_REHEARSAL'
$fixtureMappingHashExpected = if ($FixtureMappingSha256) { $FixtureMappingSha256.ToUpperInvariant() }
    else { $null }
$jobIdentity = $null
$fixtureHashExpected = $null
$tracked = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
$untrackedJournalEntries = [Collections.Generic.List[object]]::new()
$workerRun = $null
$workerLaunchAttempted = $false
$workerJob = [IntPtr]::Zero
$workerJobReceipt = $null
$pendingLaunchesRemaining = @()
$workerWait = $null
$workerStdout = $null
$workerStderr = $null
$cleanupFailures = [Collections.Generic.List[string]]::new()
$releaseFailure = $null
$releaseWritten = $false
$cleanupProven = $false
$processJournalPath = $null
$journalState = $null
$journalProof = $null
$boundWorkerManifest = $null
$journalFailure = $null
$safeOutputInitialized = $false
$primaryFailure = $null
$recoveryReceipts = [Collections.Generic.List[object]]::new()
$survivors = [Collections.Generic.List[object]]::new()
$releaseReceiptPath = $null
$outputDirectory = $null
$runDirectory = $null
$authorizationPath = $null
$authorizationHash = $null
$deadlineUtc = [DateTime]::MinValue
$jobHash = $null
$moduleHash = $null
$workerHash = $null
$supervisorHash = $null
$leaseHash = $null
$leaseExpiresUtc = [DateTime]::MinValue
$preflightHash = $null
$lease = $null
$job = $null
$preflight = $null
$supervisorIdentity = $null
$dpiGeometryAdmission = $null
$thisProcess = [Diagnostics.Process]::GetCurrentProcess()
$supervisorExecutable = $thisProcess.MainModule.FileName
$startedUtc = [DateTime]::UtcNow

function Write-CapSupervisorLog {
    param([Parameter(Mandatory)][string]$Message)
    if (Get-Command Write-CapTrace -ErrorAction SilentlyContinue) {
        try { Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters }
        catch { $cleanupFailures.Add("Supervisor log trace failed: $($_.Exception.ToString())") }
    }

    Write-Output ('{0:o} {1}' -f [DateTime]::UtcNow, $Message)
}

function Test-CapMatchedAdapter {
    return $job.PSObject.Properties['sceneAdapter'] -and
        $job.sceneAdapter -cin @('S_MATCHED_V12_V1','S_MATCHED_V12_DPI_V1')
}

function Test-CapMatchedDpiAdapter {
    return $job.PSObject.Properties['sceneAdapter'] -and
        $job.sceneAdapter -ceq 'S_MATCHED_V12_DPI_V1'
}

function Assert-CapSupervisorPath {
    param([Parameter(Mandatory)][string]$Path)
    if (Get-Command Write-CapTrace -ErrorAction SilentlyContinue) { Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters }

    $full = [IO.Path]::GetFullPath($Path)
    $prefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or $Path -notmatch '^[A-Za-z]:\\' -or
        $Path.Substring(2).Contains(':') -or $Path -match '(^|\\)\.\.?($|\\)' -or
        -not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        $root -ieq [IO.Path]::GetPathRoot($root).TrimEnd('\') -or
        $root -match '^C:\\gcs\\(?:cap|ia|ib|ic|id|ie)(?:\\|$)') {
        throw "Authorization or artifact path escaped cap-owned root: $full"
    }
    $ancestor = $full
    while ($ancestor) {
        if ((Test-Path -LiteralPath $ancestor) -and
            ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Capture artifact has a reparse-point ancestor: $ancestor"
        }
        $ancestor = Split-Path -Parent $ancestor
    }
    return $full
}

function Write-CapJsonAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value, [switch]$FinalRelease)
    if (-not $FinalRelease -and (Get-Command Write-CapTrace -ErrorAction SilentlyContinue)) {
        Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    }

    $temporary = "$Path.tmp"
    [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth 40), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $Path, $true)
}

function Get-CapSupervisorFailureText {
    param([AllowNull()]$Failure)
    if (Get-Command Write-CapTrace -ErrorAction SilentlyContinue) {
        try { Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters }
        catch { $cleanupFailures.Add("Failure trace write failed: $($_.Exception.ToString())") }
    }

    if ($null -eq $Failure) { return $null }
    if ($Failure -is [Management.Automation.ErrorRecord]) { return $Failure.Exception.ToString() }
    if ($Failure -is [Exception]) { return $Failure.ToString() }
    throw 'Unexpected capture failure representation.'
}

function Assert-CapGreenJob {
    if (Get-Command Write-CapTrace -ErrorAction SilentlyContinue) { Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters }

    Assert-CapSceneContract -Job $job
    $mappingProof = Assert-CapFixtureMapping -Root $root -FixturePath (Join-Path $root 'fixtures\fixture.json') `
        -SourcePath (Join-Path $root 'inputs\fixture-source.json') -MappingPath (Join-Path $root 'reports\fixture-mapping.json') `
        -ExpectedMappingSha256 $fixtureMappingHashExpected `
        -ExpectedSourceSha256 $job.fixture.sha256 -OriginalRoot $job.fixture.originalRoot `
        -SceneAdapter $job.sceneAdapter -ExpectedPeerSha256 $job.fixture.offlinePeerReference.sha256
    $script:fixtureHashExpected = $mappingProof.FixtureSha256
    $inputHashes = @{
        fixture = @((Join-Path $root 'fixtures\fixture.json'), $fixtureHashExpected)
        fixtureSource = @((Join-Path $root 'inputs\fixture-source.json'), $job.fixture.sha256)
        fixtureMapping = @((Join-Path $root 'reports\fixture-mapping.json'), $fixtureMappingHashExpected)
        peer = @((Join-Path $root 'inputs\offline-peer-source.ps1'), $job.fixture.offlinePeerReference.sha256)
        zmx = @((Join-Path $root 'runtime\zmx.exe'), $job.binaries.offlineZmx.sha256)
        before = @((Join-Path $root 'inputs\graphcode-before.exe'), $job.binaries.before.sha256)
        after = @((Join-Path $root 'inputs\graphcode-after.exe'), $job.binaries.after.sha256)
    }
    if ($job.PSObject.Properties['sceneAdapter'] -and
        $job.sceneAdapter -cin @('S_MATCHED_V12_V1','S_MATCHED_V12_DPI_V1')) {
        $inputHashes.daemon=@((Join-Path $root 'runtime\graphcoded.exe'),$job.binaries.daemon.sha256)
        $inputHashes.backendFixture=@((Join-Path $root 'runtime\copilot.exe'),$job.binaries.backendFixture.sha256)
        $inputHashes.backendSource=@((Join-Path $root 'inputs\offline-backend.c'),$job.binaries.backendFixture.sourceSha256)
    }
    foreach ($key in $inputHashes.Keys) {
        $null = Assert-CapArtifactPath -Root $root -Path $inputHashes[$key][0]
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $inputHashes[$key][0]).Hash
        if ($actual -ne $inputHashes[$key][1]) { throw "Cap-owned $key input hash mismatch: $actual" }
    }
    return $jobIdentity.sourceRepository
}

function Assert-CapLiveNativeBindings {
    if (Get-Command Write-CapTrace -ErrorAction SilentlyContinue) { Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters }

    $requiredNames = @(Get-CapRequiredNativeBindingNames)
    $required = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $requiredNames) {
        if ([string]::IsNullOrWhiteSpace($name) -or -not $required.Add($name)) {
            throw 'Required native binding declarations must have distinct nonempty names.'
        }
    }
    if ($required.Count -eq 0) { throw 'No required native binding declarations were found.' }
    $native = @(Test-CapNativeBindings)
    $observed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($binding in $native) {
        Assert-CapDataRecord $binding @{ Name = [string] } 'Native binding'
        if (-not $required.Contains($binding.Name)) { throw "Unknown native binding '$($binding.Name)'." }
        if (-not $observed.Add($binding.Name)) { throw "Duplicate native binding '$($binding.Name)'." }
        $entryPoint = $binding.PSObject.Properties['EntryPoint']
        if ($null -eq $entryPoint -or $entryPoint.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace($entryPoint.Value)) { throw "Unresolved native binding '$($binding.Name)'." }
    }
    foreach ($name in $requiredNames) {
        if (-not $observed.Contains($name)) { throw "Missing required native binding '$name'." }
    }
    return @($native)
}

function Assert-CapPreflightReport {
    if (Get-Command Write-CapTrace -ErrorAction SilentlyContinue) { Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters }

    if ($preflightHash -ne $PreflightReceiptSha256.ToUpperInvariant()) { throw 'Capture-preflight receipt hash mismatch.' }
    if ($preflight.suite -ceq 'UiCaptureDriver') {
        if ($preflight.executed -isnot [long] -or $preflight.executed -le 0 -or
            $preflight.passed -ne $preflight.executed -or $preflight.failed -ne 0 -or
            $preflight.mode -cne 'NO_DESKTOP_REAL_LAUNCH_REHEARSAL' -or
            $preflight.gui -cne 'NotExecuted' -or $preflight.images -ne 0 -or $preflight.backendTurns -ne 0 -or
            $preflight.controls.moduleSha256 -ne $moduleHash -or
            $preflight.controls.workerSha256 -ne $workerHash -or
            $preflight.controls.supervisorSha256 -ne $supervisorHash -or
            $preflight.fixture.compilerExitCode -ne 0 -or
            $preflight.cases.Count -ne $preflight.executed -or
            @($preflight.cases | Where-Object passed -NE $true).Count -ne 0) {
            throw 'The repaired-core preflight does not prove a nonempty successful exact-source offline rehearsal.'
        }
        $caseNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($case in $preflight.cases) {
            Assert-CapDataRecord $case @{ name = [string]; passed = [bool] } 'Preflight case'
            if (-not $caseNames.Add($case.name)) { throw 'Duplicate preflight case identity.' }
        }
        foreach ($required in @(
            'real capture command with nonempty arguments',
            'real capture command with genuine zero arguments',
            'same capture command refuses malformed lease and writes release',
            'same capture command handles target nonzero',
            'same capture command handles target timeout',
            'same capture command handles target primary-cleanup',
            'same capture command handles target receipt-block',
            'lease-bound admission accepted through actual capture command',
            'lease-bound admission lane-d through actual capture command',
            'lease-bound admission red-ci through actual capture command',
            'lease-bound admission binary-hash through actual capture command',
            'lease-bound admission product-diff through actual capture command',
            'lease-bound admission ci-head through actual capture command',
            'lease-bound admission empty-ci through actual capture command',
            'lease-bound admission source-bytes through actual capture command',
            'lease-bound admission lease-base through actual capture command',
            'lease-bound admission omitted-product-diff through actual capture command',
            'lease-bound admission phase-swap through actual capture command',
            'lease-bound admission unrelated-base through actual capture command',
            'actual immutable journal reader preserves held snapshots across concurrent numbered publications',
            'contained job launcher preserves target normal and proves closure',
            'contained job launcher preserves target nonzero and proves closure',
            'contained job launcher preserves target timeout and proves closure',
            'worker and contained launcher clear STD inheritance before target launch',
            'N1 owned output descendant fixture accepts closure and refuses foreign or stale bytes',
            'zmx rendezvous lease guard accepts240 and refuses241 before launch',
            'actual exit receipt reader retries sharing and partial JSON with typed deadline and identity refusal',
            'prebuilt fixture binder accepts exact artifacts and refuses missing or tampered bytes',
            'journal phase timing records open copy total without changing budget or retry limits',
            'umbrella safety-net kill refuses clean release for an unreceipted member',
            'never-appearing action target preserves cleanup reserve and proves zero-survivor release',
            'real zmx job lifecycle through actual command with target normal',
            'real zmx job lifecycle through actual command with target nonzero',
            'real zmx job lifecycle through actual command with target timeout'
        )) {
            if (@($preflight.cases | Where-Object name -CEQ $required).Count -ne 1) {
                throw "Repaired-core preflight is missing a unique required actual-command case: $required"
            }
        }
        foreach ($behavior in @('normal','nonzero','timeout')) {
            $case = @($preflight.cases | Where-Object name -CEQ "real zmx job lifecycle through actual command with target $behavior")[0]
            Assert-CapDataRecord $case.detail @{ zmxSha256 = [string]; providerCommit = [string]
                evidenceMode = [string]; phases = [long] } 'Real seed preflight case'
            if ($case.detail.zmxSha256 -cne $job.binaries.offlineZmx.sha256 -or
                $case.detail.providerCommit -cne '785b3fd15dcafd1882b495c831a10f98c201b908' -or
                $case.detail.evidenceMode -cne 'EXECUTED_CURRENT_REAL_ZMX' -or $case.detail.phases -ne 2) {
                throw 'Real seed preflight case does not bind the current pinned provider.'
            }
        }
        if ($job.PSObject.Properties['sceneAdapter'] -and
            $job.sceneAdapter -cin @('S_MATCHED_V12_V1','S_MATCHED_V12_DPI_V1')) {
            $expectedMatchedPreflight = 185L
            if ($preflight.executed -ne $expectedMatchedPreflight -or
                $preflight.skipped -isnot [long] -or $preflight.skipped -ne 0) {
                throw "Matched scene preflight requires exactly $expectedMatchedPreflight passing current contracts and zero skips."
            }
            foreach ($name in @(
                'matched v12 fixture binds exact node type wiring reason and outcome fields',
                'matched v12 fixture refuses identity type wiring selection reason and outcome mutations',
                'matched v12 complete scene inventory is admitted and missing scenes refuse',
                'matched S tab actual worker seed write preserves scene path and not-created cleanup',
                'matched all eighteen scenes across both phases create write and clean isolated seed paths',
                'matched tab observations preserve exact owned IDs parents selection and close bounds',
                'real restart transcript requires daemon confirmation resume and new owned attach',
                'real restart scene invokes existing UIA route and refuses offline peer authority',
                'matched transparent proxy relays unchanged real pipe frames with connection identity',
                'matched manifest seals scene inventory and refuses premature restart success'
            )) {
                if (@($preflight.cases | Where-Object name -CEQ $name).Count -ne 1) {throw "Matched scene preflight lacks its unique group: $name"}
            }
            foreach ($name in @(
                'DPI matched geometry derives exact 96 and 192 physical frames',
                'DPI matched geometry refuses insufficient work area and invalid scaling',
                'DPI matched logical zoom normalizes physical UIA width',
                'DPI matched manifest preserves raw logical physical metadata without resampling'
            )) {
                if (@($preflight.cases | Where-Object name -CEQ $name).Count -ne 1) {
                    throw "DPI matched preflight lacks its unique group: $name"
                }
            }
        }
        return
    }
    $seedPhases = @($preflight.actualPhaseSeedLifecycle | ForEach-Object phase | Sort-Object)
    $invalidSeeds = @($preflight.actualPhaseSeedLifecycle | Where-Object {
        $_.exitCode -ne 0 -or -not $_.daemonReady -or $_.cmdCount -lt 1 -or
        $_.cleanupStatus -ne 'CLEAN_ZERO_SURVIVORS_FILES_CLOSED' -or
        -not $_.outputProof.jobActive0 -or $_.stdoutEof -or $_.stderrEof -or
        $_.sourceJobSha256 -ne $jobHash -or $_.sourceModuleSha256 -ne $moduleHash -or
        $_.sourceWorkerSha256 -ne $workerHash -or
        $_.evidenceMode -cne $preflight.actualSeedEvidenceMode -or
        -not ([string]$_.zmxRoot).StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$_.supportRoot).StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)
    })
    if ($preflight.status -ne 'PASS_OFFLINE_CAPTURE_GUARDS' -or
        $preflight.jobSha256 -ne $jobHash -or
        $preflight.moduleSha256 -ne $moduleHash -or
        $preflight.workerSha256 -ne $workerHash -or
        $preflight.supervisorSha256 -ne $supervisorHash -or
        $preflight.fixtureSourceSha256 -ne $job.fixture.sha256 -or
        $preflight.fixtureMappingSha256 -ne $fixtureMappingHashExpected -or
        $preflight.guiLaunched -ne $false -or $preflight.desktopUsed -ne $false -or
        $preflight.zmxCycle -ne $true -or $preflight.backendTurns -ne 0 -or
        $preflight.actualSeedEvidenceMode -notin @('EXECUTED_CURRENT', 'REUSED_HASH_PINNED') -or
        $preflight.zmxCycleExecutedThisInvocation -ne
            ($preflight.actualSeedEvidenceMode -eq 'EXECUTED_CURRENT') -or
        $preflight.startFailureRollback.result -ne 'TERMINATED_GUARDED_HANDLE' -or
        -not $preflight.startFailureRollback.kernelExited -or
        -not $preflight.startFailureRollback.stdoutEof -or
        -not $preflight.startFailureRollback.stderrEof -or
        $preflight.timeoutControl.cleanup -ne 'TERMINATED_GUARDED_HANDLE' -or
        -not $preflight.timeoutControl.kernelExited -or
        -not $preflight.timeoutControl.stdoutEof -or -not $preflight.timeoutControl.stderrEof) {
        throw 'Offline preflight does not accept these exact controls or prove the bounded no-GUI watchdog.'
    }
    if ($preflight.actualPhaseSeedLifecycle.Count -ne 2 -or $invalidSeeds.Count -ne 0 -or
        ($seedPhases -join ',') -cne 'after,before' -or
        @($preflight.actualPhaseSeedLifecycle | ForEach-Object zmxRoot | Sort-Object -Unique).Count -ne 2 -or
        @($preflight.actualPhaseSeedLifecycle | ForEach-Object supportRoot | Sort-Object -Unique).Count -ne 2) {
        throw 'Offline preflight lacks two fresh, isolated, no-backend zmx seed cleanup proofs.'
    }
    $seedEvidenceRoot = Assert-CapSupervisorPath ([string]$preflight.actualSeedEvidenceReuse.sourceRoot)
    if (-not $preflight.actualSeedEvidenceReuse.PSObject.Properties['journalProof']) {
        throw 'LegacyJournalProtocol: mutable seed journal proof must be regenerated as an exact numbered terminal reference.'
    }
    $seedReference = $preflight.actualSeedEvidenceReuse.journalProof
    $seedJournalPath = Assert-CapSupervisorPath ([string]$seedReference.directory)
    if ($preflight.actualSeedEvidenceReuse.mode -cne $preflight.actualSeedEvidenceMode -or
        $preflight.actualSeedEvidenceReuse.sourceRunId -cne
            $preflight.actualPhaseSeedLifecycle[0].evidenceRunId -or
        $seedReference.binding.runId -cne $preflight.actualSeedEvidenceReuse.sourceRunId) {
        throw 'Offline actual-seed evidence source root or process journal does not match its hash-bound receipt.'
    }
    $seedProof = Read-CapNumberedSeedProof -Root $root -Reference $seedReference `
        -JobSha256 $jobHash -ModuleSha256 $moduleHash -WorkerSha256 $workerHash -DeadlineUtc $leaseExpiresUtc
    $seedJournal = $seedProof.Terminal.Payload.data
    $seedArguments = @($job.binaries.offlineZmx.seedArgumentOrder)
    foreach ($seedEvidence in $preflight.actualPhaseSeedLifecycle) {
        $receiptPath = Assert-CapSupervisorPath ([string]$seedEvidence.receiptPath)
        if (-not $receiptPath.StartsWith($seedEvidenceRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $seedEvidence.processJournalPath -cne $seedJournalPath -or
            $seedEvidence.processJournalSha256 -cne $seedReference.record.terminal.sha256 -or
            -not (Test-Path -LiteralPath $receiptPath -PathType Leaf) -or
            (Get-FileHash -Algorithm SHA256 -LiteralPath $receiptPath).Hash -ne $seedEvidence.receiptSha256) {
            throw "Actual $($seedEvidence.phase) zmx seed receipt is outside or inconsistent with its bound evidence root."
        }
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        if ($receipt.phase -cne $seedEvidence.phase -or $receipt.exitCode -ne 0 -or
            ($receipt.argumentList -join [char]0) -cne ($seedArguments -join [char]0) -or
            -not $receipt.daemonReady -or $receipt.daemonCount -lt 1 -or $receipt.cmdCount -lt 1 -or
            $receipt.descendants.Count -lt 2 -or $receipt.cleanup.Count -lt ($receipt.descendants.Count + 1) -or
            $receipt.cleanupStatus -ne 'CLEAN_ZERO_SURVIVORS_FILES_CLOSED' -or
            -not $receipt.outputProof.jobActive0 -or $receipt.stdoutEof -or $receipt.stderrEof -or
            $receipt.seedPid -ne $seedEvidence.seedPid -or
            $receipt.seedCreationFileTimeUtc -ne $seedEvidence.seedCreationFileTimeUtc -or
            $receipt.zmxRoot -cne $seedEvidence.zmxRoot -or $receipt.supportRoot -cne $seedEvidence.supportRoot) {
            throw "Actual $($seedEvidence.phase) zmx seed receipt does not match its preflight summary."
        }
        $processRecords = @(
            [pscustomobject]@{
                role = 'zmx-launcher'; pid = $receipt.launcherPid
                creationFileTimeUtc = $receipt.launcherCreationFileTimeUtc
                expectedImagePath = (Join-Path $PSHOME 'pwsh.exe')
            }
        ) + @($receipt.descendants)
        foreach ($record in $processRecords) {
            $journalEntry = @($seedJournal.entries | Where-Object {
                $_.phase -ceq $seedEvidence.phase -and $_.role -ceq $record.role -and
                $_.pid -eq $record.pid -and $_.creationFileTimeUtc -eq $record.creationFileTimeUtc -and
                $_.expectedImagePath -ieq $record.expectedImagePath
            })
            if ($journalEntry.Count -ne 1) {
                throw "Actual seed journal does not bind $($seedEvidence.phase)/$($record.role) to its saved process generation."
            }
            $current = Get-CapCurrentMetadata -Pid ([int]$record.pid)
            if ($current -and
                [Math]::Abs([double]([long]$current.CreationFileTimeUtc - [long]$record.creationFileTimeUtc)) -le
                    [TimeSpan]::FromMilliseconds(100).Ticks -and
                $current.ImagePath -ieq $record.expectedImagePath) {
                throw "Actual seed process remains live at capture authorization: $($record.role) PID $($record.pid)."
            }
        }
    }
    if ($preflight.actionMockCount -lt 5 -or $preflight.observationMockCount -ne 3 -or
        $preflight.negativeGuards.Count -lt 8) {
        throw 'Offline preflight did not exercise the required positive and negative UIA guard paths.'
    }
    $priorLifecyclePath = Join-Path $root 'reports\preflight-08.json'
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $priorLifecyclePath).Hash -ne $job.admission.priorLifecycleSha256) {
        throw 'Preserved real no-GUI preflight-08 lifecycle evidence changed.'
    }
    $priorLifecycle = Get-Content -LiteralPath $priorLifecyclePath -Raw | ConvertFrom-Json
    if ($priorLifecycle.status -ne 'PREFLIGHT_READY_NO_DESKTOP_CI_PENDING' -or
        $priorLifecycle.desktopLaunched -ne $false -or $priorLifecycle.graphCodeAppLaunches -ne 0 -or
        $priorLifecycle.pendingLaunchesRemaining -ne 0) {
        throw 'Preserved preflight-08 is not valid prior no-GUI lifecycle evidence.'
    }
}

function Assert-CapLease {
    if (Get-Command Write-CapTrace -ErrorAction SilentlyContinue) { Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters }

    if (-not $LeaseReceiptPath -or -not $LeaseReceiptSha256) {
        throw 'No coordinator lease was supplied. Offline preflight readiness does not authorize desktop use.'
    }
    $leasePath = Assert-CapSupervisorPath $LeaseReceiptPath
    if (-not (Test-Path -LiteralPath $leasePath -PathType Leaf)) { throw "Coordinator lease receipt is missing: $leasePath" }
    $leaseHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $leasePath).Hash
    $script:leaseHash = $leaseHash
    if ($leaseHash -ne $LeaseReceiptSha256.ToUpperInvariant()) { throw 'Coordinator lease receipt hash mismatch.' }
    $lease = Read-CapBoundJson -Root $root -Reference ([pscustomobject]@{ path = $leasePath; sha256 = $leaseHash })
    Assert-CapDataRecord $lease @{ schemaVersion = [long]; leaseId = [string]; lane = [string]
        status = [string]; authorizedAction = [string]; head = [string]; jobManifestSha256 = [string]
        moduleSha256 = [string]; workerSha256 = [string]; supervisorSha256 = [string]
        grantedUtc = [string]; expiresUtc = [string]; maxMinutes = [long] } 'Coordinator lease'
    if ($rehearsal) {
        Assert-CapDataRecord $lease @{ desktopAuthorized = [bool] } 'Rehearsal lease'
    } else {
        Assert-CapDataRecord $lease @{ centralPreflightAccepted = [bool]; preflightReceiptSha256 = [string]
            fixtureMappingSha256 = [string] } 'Capture lease'
    }
    $expectedStatus = if ($rehearsal) { 'REHEARSAL_ONLY' } else { 'GRANTED' }
    $expectedAction = if ($rehearsal) { 'no-desktop-real-launch-rehearsal' } else { 'central-cap-capture' }
    if ($lease.schemaVersion -ne 1 -or $lease.status -ne $expectedStatus -or
        $lease.lane -cne $job.lane -or $lease.authorizedAction -ne $expectedAction -or
        (-not $rehearsal -and $lease.centralPreflightAccepted -ne $true) -or
        ($rehearsal -and $lease.desktopAuthorized -ne $false) -or
        $lease.head -ne $job.head -or $lease.jobManifestSha256 -ne $jobHash -or
        $lease.moduleSha256 -ne $moduleHash -or $lease.workerSha256 -ne $workerHash -or
        $lease.supervisorSha256 -ne $supervisorHash -or $lease.preflightReceiptSha256 -ne $preflightHash) {
        throw 'Coordinator lease does not bind the job lane/head and exact worker/preflight hashes.'
    }
    if (-not $rehearsal -and $lease.fixtureMappingSha256 -ne $fixtureMappingHashExpected) {
        throw 'Live lease does not bind the exact owned-root fixture mapping.'
    }
    $null = [guid]::Parse([string]$lease.leaseId)
    $leaseWindow = Get-CapLeaseWindow -GrantedUtc $lease.grantedUtc -ExpiresUtc $lease.expiresUtc `
        -MaximumMinutes ([double]$lease.maxMinutes) -NowUtc ([DateTime]::UtcNow)
    $script:leaseExpiresUtc = $leaseWindow.ExpiresUtc
    $script:deadlineUtc = $leaseWindow.WorkerDeadlineUtc
    if ($script:deadlineUtc -le $leaseWindow.NowUtc.AddMinutes(1)) {
        throw 'Lease has insufficient remaining time after the reserved 90-second cleanup margin.'
    }
    $script:lease = $lease
    $script:leaseHash = $leaseHash
    return $leasePath
}

function Add-CapTrackedIdentity {
    param([Parameter(Mandatory)]$Entry)
    if (Get-Command Write-CapTrace -ErrorAction SilentlyContinue) { Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters }

    $key = '{0}:{1}:{2}' -f $Entry.pid, $Entry.creationFileTimeUtc, $Entry.phase
    if ($tracked.ContainsKey($key)) {
        if ($Entry.windowHandle -gt 0) { $tracked[$key].WindowHandle = [IntPtr]::new([long]$Entry.windowHandle) }
        return $tracked[$key]
    }
    $process = $null
    try { $process = [Diagnostics.Process]::GetProcessById([int]$Entry.pid) }
    catch [ArgumentException] {
        $untrackedJournalEntries.Add([pscustomobject]@{
            role = [string]$Entry.role
            pid = [int]$Entry.pid
            phase = [string]$Entry.phase
            creationFileTimeUtc = [long]$Entry.creationFileTimeUtc
            disposition = 'PID_NOT_PRESENT_AT_SUPERVISOR_SNAPSHOT; WORKER_KERNEL_RECEIPT_REQUIRED'
        })
        return $null
    }
    try {
        $identity = Get-CapProcessIdentity -Process $process -ExpectedImagePath $Entry.expectedImagePath `
            -Role $Entry.role -ExpectedParentPid ([int]$Entry.expectedParentPid) `
            -ExpectedSessionId ([int]$Entry.expectedSessionId)
        if ($identity.CreationFileTimeUtc -ne [long]$Entry.creationFileTimeUtc) {
            throw "Journal PID $($Entry.pid) was reused; refusing to bind a new generation."
        }
        $record = [pscustomobject]@{
            Identity = $identity
            Phase = [string]$Entry.phase
            Role = [string]$Entry.role
            WindowHandle = if ($Entry.windowHandle -gt 0) { [IntPtr]::new([long]$Entry.windowHandle) } else { [IntPtr]::Zero }
        }
        $tracked.Add($key, $record)
        return $record
    } catch {
        $process.Dispose()
        throw
    }
}

function Refresh-CapJournal {
    param([Parameter(Mandatory)][string]$Path, [DateTime]$ReadDeadlineUtc = $deadlineUtc)
    if (Get-Command Write-CapTrace -ErrorAction SilentlyContinue) { Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters }
    if (-not $journalState -or $journalState.Directory -ine $Path) {
        throw 'JournalIdentity: polling state is not bound to the authorized numbered directory.'
    }
    $journalState.DeadlineUtc = $ReadDeadlineUtc
    try {
        $reading = Read-CapJournalSnapshot -State $journalState
        if ($reading.State -ceq 'PendingFirstPublication') { return }
        foreach ($entry in $reading.Snapshot.Payload.data.entries) { $null = Add-CapTrackedIdentity -Entry $entry }
    } catch {
        if ($null -eq $journalFailure) {
            $script:journalFailure = $_.Exception
            $cleanupFailures.Add("Journal observation failed: $($_.Exception.Message)")
        }
        throw
    }
}

function Read-CapQuiescentWorkerProof {
    if (-not [CapNative]::IsExited($workerRun.Identity.Process.Handle, $workerRun.Identity.Pid) -or
        -not $workerRun.StdoutTask.IsCompleted -or -not $workerRun.StderrTask.IsCompleted -or
        $workerRun.StdoutTask.IsFaulted -or $workerRun.StderrTask.IsFaulted) {
        throw 'JournalCleanupUnproven: worker kernel exit and successful both-stream EOF are required first.'
    }
    $journalState.DeadlineUtc = $leaseExpiresUtc
    $record = Read-CapJournalFinalRecord -Stdout ([string]$workerRun.StdoutTask.Result) -Binding $journalState.Binding
    if ($record.manifest.name -cne 'manifest.json') { throw 'JournalFinalBinding: final manifest name differs.' }
    $script:journalProof = Read-CapJournalFinalProof -State $journalState `
        -OutputDirectory $outputDirectory -Record $record -RetainStreams
    $script:boundWorkerManifest = $journalProof.Manifest
    if ($boundWorkerManifest.ownedProcessSurvivors.Count -ne 0 -or
        $boundWorkerManifest.pendingLaunchesRemaining.Count -ne 0 -or
        $boundWorkerManifest.cleanupFailures.Count -ne 0) {
        throw 'JournalCleanupUnproven: final owned cleanup arrays are not empty.'
    }
    Assert-CapDataRecord $boundWorkerManifest @{
        leaseId = [string]; jobManifestSha256 = [string]; moduleSha256 = [string]
        workerSha256 = [string]; supervisorSha256 = [string]; leaseReceiptSha256 = [string]
    } 'Proven worker manifest identity'
    if ($boundWorkerManifest.leaseId -cne $journalState.Binding.leaseId -or
        $boundWorkerManifest.jobManifestSha256 -cne $journalState.Binding.jobSha256 -or
        $boundWorkerManifest.moduleSha256 -cne $journalState.Binding.moduleSha256 -or
        $boundWorkerManifest.workerSha256 -cne $journalState.Binding.workerSha256 -or
        $boundWorkerManifest.supervisorSha256 -cne $journalState.Binding.supervisorSha256 -or
        $boundWorkerManifest.leaseReceiptSha256 -cne $leaseHash) {
        throw 'JournalIdentity: final manifest source/lease fields differ from the proven binding.'
    }
    if ($workerRun.Identity.Process.ExitCode -ne 0 -and $boundWorkerManifest.status -ceq 'COMPLETE') {
        throw 'JournalFinalBinding: failed worker cannot supply a COMPLETE final manifest.'
    }
    $null = Assert-CapNoWorkerTransientArtifacts -Directories @($runDirectory, $outputDirectory)
    if (-not $primaryFailure -and $workerRun.Identity.Process.ExitCode -eq 0) {
        $jobFailure = Get-CapWorkerJobFailure
        if ($null -ne $jobFailure) {
            $script:primaryFailure = $jobFailure
            Write-CapSupervisorLog "WORKER_JOB_ASSERTION_FAILURE=$($jobFailure.Exception.ToString())"
        }
    }
}

function Get-CapWorkerJobFailure {
    param()
    if (Get-Command Write-CapTrace -ErrorAction SilentlyContinue) {
        Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    }
    try { Assert-CapWorkerManifest }
    catch { return $_ }
    return $null
}

function Get-CapAppSessionPrefix {
    param([Parameter(Mandatory)]$Record)
    if (Get-Command Write-CapTrace -ErrorAction SilentlyContinue) { Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters }

    $shortLease = $lease.leaseId.Replace('-', '').Substring(0, 8)
    if ($Record.Role -like '*-actions') { return "gc-cap-actions-$shortLease-$($Record.Phase)-" }
    return "gc-cap-$shortLease-$($Record.Phase)-"
}

function Recover-CapGuiRoots {
    param([Parameter(Mandatory)][DateTime]$CleanupDeadlineUtc)
    if (Get-Command Write-CapTrace -ErrorAction SilentlyContinue) { Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters }

    foreach ($record in @($tracked.Values | Where-Object Role -like 'graphcode-app-*')) {
        $identity = $record.Identity
        if ([CapNative]::IsExited($identity.Process.Handle, $identity.Pid)) { continue }
        $window = $record.WindowHandle
        if ($window -ne [IntPtr]::Zero) {
            try {
                $null = Assert-CapRootProcess -RootHandle $window -ProcessIdentity $identity
                $null = Invoke-CapAction -Action 'file-exit' -RootHandle $window -ProcessIdentity $identity
                $recoveryReceipts.Add([pscustomobject]@{
                    role = $identity.Role; pid = $identity.Pid; action = 'FILE_EXIT_POSTED'; utc = [DateTime]::UtcNow.ToString('o')
                })
            } catch {
                $recoveryReceipts.Add([pscustomobject]@{
                    role = $identity.Role; pid = $identity.Pid; action = 'FILE_EXIT_REFUSED'; reason = $_.Exception.Message
                })
            }
        }
        $run = [pscustomobject]@{ Identity = $identity }
        $graceDeadline = [DateTime]::UtcNow.AddSeconds($(if ($window -eq [IntPtr]::Zero) { 1 } else { 4 }))
        if ($graceDeadline -gt $CleanupDeadlineUtc) { $graceDeadline = $CleanupDeadlineUtc }
        $wait = Wait-CapManagedProcess -Run $run -DeadlineUtc $graceDeadline -PollMilliseconds 100
        if ($wait.State -eq 'Exited') {
            $recoveryReceipts.Add([pscustomobject]@{
                role = $identity.Role; pid = $identity.Pid; action = 'FILE_EXITED'; exitCode = $wait.ExitCode
            })
            continue
        }
        $prefix = Get-CapAppSessionPrefix -Record $record
        $dSessions=@{}
        if ($job.sceneAdapter -ceq 'D_QUICK_CHAT_V1') {
            $dSessions.ExactSessionNames=@('graphcode-33333333-3333-4333-8333-333333333333','graphcode-44444444-4444-4444-8444-444444444444')
        }
        $tree = @(Get-CapOwnedDescendants -Roots @($identity) `
            -ZmxPath (Join-Path $root 'runtime\zmx.exe') `
            -CmdPath (Join-Path ([Environment]::SystemDirectory) 'cmd.exe') `
            -ConhostPath (Join-Path ([Environment]::SystemDirectory) 'conhost.exe') `
            -SessionName $prefix -CommandMarker $prefix -AllowGraphCodeRoot -AllowUnmarkedCmd @dSessions)
        foreach ($child in $tree) {
            $null = $tracked.TryAdd(
                ('{0}:{1}:{2}' -f $child.Pid, $child.CreationFileTimeUtc, $record.Phase),
                [pscustomobject]@{ Identity = $child; Phase = $record.Phase; Role = $child.Role; WindowHandle = [IntPtr]::Zero }
            )
        }
        foreach ($child in @($tree | Sort-Object CreationFileTimeUtc -Descending)) {
            $result = Stop-CapManagedProcess -Identity $child -TimeoutMilliseconds 5000
            $recoveryReceipts.Add($result)
        }
        if (-not [CapNative]::IsExited($identity.Process.Handle, $identity.Pid)) {
            $result = Stop-CapManagedProcess -Identity $identity -TimeoutMilliseconds 5000
            $recoveryReceipts.Add($result)
        }
    }
}

function Stop-CapTrackedPeers {
    if (Get-Command Write-CapTrace -ErrorAction SilentlyContinue) { Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters }

    foreach ($record in @($tracked.Values | Where-Object Role -like 'offline-fixture-peer-*')) {
        $identity = $record.Identity
        if ([CapNative]::IsExited($identity.Process.Handle, $identity.Pid)) { continue }
        $result = Stop-CapManagedProcess -Identity $identity -TimeoutMilliseconds 5000
        $recoveryReceipts.Add($result)
    }
}

function Write-CapProcessOutput {
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$Prefix)
    if (Get-Command Write-CapTrace -ErrorAction SilentlyContinue) { Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters }

    foreach ($streamName in @('Stdout', 'Stderr')) {
        $task = $Run."${streamName}Task"
        if (-not $task.Wait(2000)) { throw "Worker $streamName reader failed bounded EOF after stop." }
        $path = Join-Path $outputDirectory "$Prefix-$($streamName.ToLowerInvariant()).log"
        $content = [string]$task.Result
        if (Test-Path -LiteralPath $path) {
            if ([IO.File]::ReadAllText($path) -cne $content) { throw "Worker stream log content changed: $path" }
        } else {
            [IO.File]::WriteAllText($path, $content, [Text.UTF8Encoding]::new($false))
        }
        if ($streamName -eq 'Stdout') { $script:workerStdout = [Text.Encoding]::UTF8.GetByteCount($content) }
        else { $script:workerStderr = [Text.Encoding]::UTF8.GetByteCount($content) }
    }
}

function Stop-CapWorkerIfNeeded {
    if (Get-Command Write-CapTrace -ErrorAction SilentlyContinue) { Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters }

    if (-not $workerRun) { return }
    if (-not [CapNative]::IsExited($workerRun.Identity.Process.Handle, $workerRun.Identity.Pid)) {
        $result = Stop-CapManagedProcess -Identity $workerRun.Identity -TimeoutMilliseconds 5000
        $recoveryReceipts.Add($result)
    }
}

function Assert-CapNoTrackedSurvivors {
    if (Get-Command Write-CapTrace -ErrorAction SilentlyContinue) { Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters }

    foreach ($record in $tracked.Values) {
        if (-not [CapNative]::IsExited($record.Identity.Process.Handle, $record.Identity.Pid)) {
            $survivors.Add([pscustomobject]@{ role = $record.Role; pid = $record.Identity.Pid; phase = $record.Phase })
        }
    }
    if ($workerRun -and -not [CapNative]::IsExited($workerRun.Identity.Process.Handle, $workerRun.Identity.Pid)) {
        $survivors.Add([pscustomobject]@{ role = 'b-capture-worker'; pid = $workerRun.Identity.Pid; phase = 'worker' })
    }
    if ($survivors.Count) { throw "Kernel-live owned process survivors remain: $($survivors | ConvertTo-Json -Compress)." }
}

function Assert-CapMatchedWorkerManifest {
    Assert-CapMatchedManifest -Manifest $manifest -Job $job
    if ($manifest.head -cne $job.head -or $manifest.base -cne $job.base -or
        $manifest.moduleSha256 -ne $moduleHash -or $manifest.workerSha256 -ne $workerHash -or
        $manifest.supervisorSha256 -ne $supervisorHash -or $manifest.jobManifestSha256 -ne $jobHash -or
        $manifest.leaseReceiptSha256 -ne $leaseHash -or $manifest.preflightReceiptSha256 -ne $preflightHash -or
        $manifest.fixtureSourceSha256 -ne $job.fixture.sha256 -or $manifest.fixtureSha256 -ne $fixtureHashExpected -or
        $manifest.fixtureMappingSha256 -ne $fixtureMappingHashExpected -or $manifest.failures.Count -ne 0) {
        throw 'Matched manifest provenance differs from its lease-bound job.'
    }
    foreach ($field in @('cleanupFailures','ownedProcessSurvivors','pendingLaunchesRemaining')) {
        if ($manifest.$field -isnot [array] -or $manifest.$field.Count -ne 0) {throw "Matched manifest has unproved $field."}
    }
    $isDpi=Test-CapMatchedDpiAdapter
    if ($isDpi -and ($manifest.evidenceClassification -cne 'C8R_RDP_DPI192_QUALIFIED' -or
        $manifest.geometrySchemaVersion -ne 2 -or
        ($manifest.logicalClientWH -join ',') -cne ($job.captureContract.logicalClientWH -join ',') -or
        $manifest.expectedWindowDpi -ne $job.captureContract.expectedWindowDpi -or
        $manifest.rawCaptureResamplingAllowed -cne $false)) {
        throw 'DPI-parametric matched manifest classification or geometry contract differs.'
    }
    foreach ($image in $manifest.images) {
        $binary=$job.binaries.($image.phase)
        if ($image.sceneAdapter -cne $job.sceneAdapter -or $image.sourceHead -cne $binary.source -or
            $image.binaryBuiltAtSource -cne $binary.binaryBuiltAtSource -or $image.binarySha256 -ne $binary.sha256 -or
            $image.fixtureSha256 -ne $fixtureHashExpected -or $image.fixtureSourceSha256 -ne $job.fixture.sha256 -or
            $image.fixtureMappingSha256 -ne $fixtureMappingHashExpected -or
            $image.privacyStatus -cne 'CAPTURED_PENDING_INDIVIDUAL_REVIEW' -or
            $image.sampledColors -lt 4 -or $image.nonMagentaSamples -lt 20 -or
            $image.width -ne ($image.outerBounds[2]-$image.outerBounds[0]) -or
            $image.height -ne ($image.outerBounds[3]-$image.outerBounds[1])) {throw 'Matched image geometry, state or provenance differs.'}
        if ($isDpi) {
            $contract=$job.captureContract
            $null=Assert-CapMatchedDpiImage -Image $image -Contract $contract
        } elseif (($image.clientBounds -join ',') -cne '0,0,1440,900' -or $image.dpi -ne 96) {
            throw 'Matched V1 image geometry differs.'
        }
        if ($image.scene -cmatch '^s-(?:goal-unwired|main-cycle|main-stopped|goal-done)' -and
            ($null -eq $image.zoom -or [Math]::Abs($image.zoom.ZoomPercent-100) -gt 1)) {throw 'Matched card scene lacks actual-size evidence.'}
        $path=Assert-CapSupervisorPath $image.path
        if ((Get-FileHash $path -Algorithm SHA256).Hash -ne $image.sha256) {throw 'Matched image bytes changed.'}
    }
    $expectedSeeds=@(foreach ($phase in @('before','after')) {foreach ($scene in (Get-CapMatchedSceneNames)[6..16]) {"$phase-$scene"}})
    $actualSeeds=@($manifest.zmxSeeds | ForEach-Object phase)
    if ($actualSeeds.Count -ne 22 -or @($actualSeeds | Sort-Object -Unique).Count -ne 22 -or
        (($actualSeeds | Sort-Object) -join ',') -cne (($expectedSeeds | Sort-Object) -join ',')) {throw 'Matched seed inventory differs.'}
    foreach ($seed in $manifest.zmxSeeds) {
        if ($seed.exitCode -ne 0 -or -not $seed.daemonReady -or $seed.cmdCount -lt 1 -or
            $seed.cleanupStatus -cne 'CLEAN_ZERO_SURVIVORS_FILES_CLOSED' -or
            $seed.stdoutEof -or $seed.stderrEof) {throw 'Matched cmd seed readiness/cleanup is unproved.'}
        $null=Assert-CapJobOutputProof -Root $root -Proof $seed.outputProof
    }
    foreach ($restart in $manifest.realRestarts) {
        $matchedFixture=Get-Content -LiteralPath (Join-Path $root 'fixtures\fixture.json') -Raw | ConvertFrom-Json -DateKind String
        if ($restart.evidence.projectPath -cne $matchedFixture.graphs[0].project.path.Replace('\','/')) {throw 'Matched restart owner differs from the admitted fixture project.'}
        $path=Assert-CapSupervisorPath $restart.transcriptPath
        if ((Get-FileHash $path -Algorithm SHA256).Hash -ne $restart.transcriptSha256) {throw 'Matched restart transcript bytes changed.'}
        $rows=@(Read-CapRestartTranscript -Path $path)
        if ($rows.Count -lt $restart.evidence.rows.Count -or
            (ConvertTo-Json -InputObject @($rows[0..($restart.evidence.rows.Count-1)]) -Depth 40 -Compress) -cne
            (ConvertTo-Json -InputObject @($restart.evidence.rows) -Depth 40 -Compress)) {throw 'Matched restart evidence differs from its real recorded frame prefix.'}
        $null=Assert-CapJobOutputProof -Root $root -Proof $restart.daemonCleanup
    }
}

function Assert-CapWorkerManifest {
    if (Get-Command Write-CapTrace -ErrorAction SilentlyContinue) { Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters }

    if ($null -eq $boundWorkerManifest -or $null -eq $journalProof) {
        throw 'Worker exited without exact quiescent manifest/terminal binding.'
    }
    $manifest = $boundWorkerManifest
    if ($rehearsal) {
        if ($manifest.status -cne 'COMPLETE' -or $manifest.executionMode -cne $ExecutionMode -or
            $manifest.guiLaunches.Count -ne 0 -or $manifest.images.Count -ne 0 -or
            $manifest.rehearsalLaunches.Count -ne 1 -or $manifest.failures.Count -ne 0 -or
            $manifest.ownedProcessSurvivors.Count -ne 0 -or
            $manifest.moduleSha256 -ne $moduleHash -or $manifest.workerSha256 -ne $workerHash -or
            $manifest.supervisorSha256 -ne $supervisorHash -or $manifest.jobManifestSha256 -ne $jobHash -or
            $manifest.leaseReceiptSha256 -ne $leaseHash) {
            throw 'Offline real-launch manifest is incomplete or has incorrect source/lease bindings.'
        }
        $launch = $manifest.rehearsalLaunches[0]
        if ($launch.exitCode -ne 0 -or -not $launch.ready -or -not $launch.stdinClosed -or
            -not $launch.stdoutEof -or -not $launch.stderrEof -or -not $launch.kernelExited -or
            $launch.executableSha256 -ne $job.rehearsalTarget.sha256 -or
            $launch.argumentCount -ne $job.rehearsalTarget.arguments.Count -or
            ($launch.arguments -join [char]0) -cne ($job.rehearsalTarget.arguments -join [char]0)) {
            throw 'Offline target did not prove exact arguments, readiness, zero exit, held-kernel exit and EOF.'
        }
        if ($job.PSObject.Properties['seedDependencies']) {
            if ($manifest.zmxSeeds.Count -ne 2 -or @($manifest.zmxSeeds | Where-Object {
                $_.exitCode -ne 0 -or -not $_.daemonReady -or $_.daemonCount -lt 1 -or $_.cmdCount -lt 1 -or
                $_.cleanupStatus -cne 'CLEAN_ZERO_SURVIVORS_FILES_CLOSED' -or
                $_.stdoutEof -or $_.stderrEof -or -not $_.outputProof.jobActive0
            }).Count -ne 0) { throw 'Real seed rehearsal lacks two ready, job-empty, closed-file phases.' }
            foreach ($seed in $manifest.zmxSeeds) { $null = Assert-CapJobOutputProof -Root $root -Proof $seed.outputProof }
        }
        return
    }
    if (Test-CapMatchedAdapter) {
        Assert-CapMatchedWorkerManifest
        return
    }
    if ($job.sceneAdapter -ceq 'D_QUICK_CHAT_V1') {
        $expected=@(foreach ($phase in @('before','after')) {foreach ($scene in Get-CapDSceneNames) {"${phase}:$scene"}})
        $actual=@($manifest.images | ForEach-Object {"$($_.phase):$($_.scene)"})
        if ($manifest.sceneAdapter -cne $job.sceneAdapter -or $manifest.lane -cne 'D' -or
            $manifest.status -cne 'COMPLETE' -or $manifest.executionMode -cne 'LIVE_CAPTURE' -or
            $manifest.images.Count -ne 20 -or @($actual | Sort-Object -Unique).Count -ne 20 -or
            (($actual | Sort-Object) -join ',') -cne (($expected | Sort-Object) -join ',') -or
            $manifest.head -cne $job.head -or $manifest.base -cne $job.base -or
            $manifest.moduleSha256 -ne $moduleHash -or $manifest.workerSha256 -ne $workerHash -or
            $manifest.supervisorSha256 -ne $supervisorHash -or $manifest.jobManifestSha256 -ne $jobHash -or
            $manifest.leaseReceiptSha256 -ne $leaseHash -or $manifest.preflightReceiptSha256 -ne $preflightHash -or
            $manifest.fixtureSourceSha256 -ne $job.fixture.sha256 -or $manifest.fixtureSha256 -ne $fixtureHashExpected -or
            $manifest.fixtureMappingSha256 -ne $fixtureMappingHashExpected -or $manifest.backendTurns -ne 0 -or
            $manifest.backendAgentAttach -ne $false -or $manifest.restartInvoked -ne $false -or $manifest.failures.Count -ne 0) {
            throw 'D manifest requires twenty unique real captures with exact source, fixture and lease bindings.'
        }
        foreach ($field in @('cleanupFailures','ownedProcessSurvivors','pendingLaunchesRemaining')) {
            if ($manifest.$field -isnot [array] -or $manifest.$field.Count -ne 0) { throw "D manifest has unproved $field." }
        }
        if ($manifest.uncoveredLiveObligations.Count -ne 2 -or
            @($manifest.uncoveredLiveObligations | Where-Object status -CNE 'NotExecuted').Count -ne 0 -or
            (($manifest.uncoveredLiveObligations | ForEach-Object name | Sort-Object) -join ',') -cne
                'missing-bound-chat-workspace-tabs,saved-Agent-Split-role-labels') { throw 'D manifest hid uncovered live obligations.' }
        foreach ($image in $manifest.images) {
            $phase=$job.binaries.($image.phase)
            if ($image.sceneAdapter -cne $job.sceneAdapter -or $image.captureMode -cne 'PRINTWINDOW' -or
                $image.privacyStatus -cne 'CAPTURED_PENDING_INDIVIDUAL_REVIEW' -or
                $image.observedState.evidenceMode -cne 'OWNED_UIA_READ_NOT_VISUAL_PARITY' -or
                -not $image.observedState.readSucceeded -or -not $image.observedState.healthyRoot -or
                $image.sourceHead -cne $phase.source -or $image.binaryBuiltAtSource -cne $phase.binaryBuiltAtSource -or
                $image.binarySha256 -ne $phase.sha256 -or $image.fixtureSha256 -ne $fixtureHashExpected -or
                $image.fixtureMappingSha256 -ne $fixtureMappingHashExpected -or $image.fixtureSourceSha256 -ne $job.fixture.sha256 -or
                ($image.clientBounds -join ',') -cne '0,0,1440,952' -or $image.dpi -ne 96 -or
                $image.sampledColors -lt 4 -or $image.nonMagentaSamples -lt 20 -or
                $image.width -ne ($image.outerBounds[2]-$image.outerBounds[0]) -or
                $image.height -ne ($image.outerBounds[3]-$image.outerBounds[1])) { throw 'D image has invalid live observation, geometry or provenance.' }
            if ($image.zoomApplicable -and ($null -eq $image.zoom -or [Math]::Abs($image.zoom.ZoomPercent-100) -gt 1)) { throw 'D canvas lacks actual-size zoom evidence.' }
            $imagePath=Assert-CapSupervisorPath $image.path
            if ((Get-FileHash -LiteralPath $imagePath -Algorithm SHA256).Hash -ne $image.sha256) { throw 'D image bytes changed.' }
        }
        if ($manifest.zmxSeeds.Count -ne 4 -or
            (($manifest.zmxSeeds | ForEach-Object phase | Sort-Object) -join ',') -cne 'after-history,after-primary,before-history,before-primary' -or
            @($manifest.zmxSeeds | ForEach-Object zmxRoot | Sort-Object -Unique).Count -ne 2) { throw 'D seed phase/session inventory differs.' }
        foreach ($seed in $manifest.zmxSeeds) {
            $id=if ($seed.phase.EndsWith('-primary')) {'33333333-3333-4333-8333-333333333333'} else {'44444444-4444-4444-8444-444444444444'}
            $arguments=@('run',"graphcode-$id",'-d',(Join-Path ([Environment]::SystemDirectory) 'cmd.exe'),'/Q','/K','echo D_OFFLINE_QUICKCHAT_FIXTURE')
            if ($seed.sessionName -cne "graphcode-$id" -or ($seed.argumentList -join [char]0) -cne ($arguments -join [char]0) -or
                $seed.exitCode -ne 0 -or -not $seed.daemonReady -or $seed.daemonCount -lt 1 -or $seed.cmdCount -lt 1 -or
                $seed.stdoutEof -or $seed.stderrEof -or $seed.cleanupStatus -cne 'CLEAN_ZERO_SURVIVORS_FILES_CLOSED' -or
                $seed.descendants.Count -lt 2 -or $seed.cleanup.Count -lt ($seed.descendants.Count+1)) { throw 'D seed readiness or cleanup is unproved.' }
            $null=Assert-CapJobOutputProof -Root $root -Proof $seed.outputProof
            $null=Assert-CapSupervisorPath $seed.zmxRoot
            $null=Assert-CapSupervisorPath $seed.supportRoot
        }
        return
    }
    $expectedImages = @(
        'before:project-alpha', 'before:project-beta', 'before:overview', 'before:workspace', 'before:actions',
        'after:project-alpha', 'after:project-beta', 'after:overview', 'after:workspace', 'after:actions'
    )
    $actualImages = @($manifest.images | ForEach-Object { "$($_.phase):$($_.scene)" })
    $imageDifference = Compare-Object ($expectedImages | Sort-Object) ($actualImages | Sort-Object)
    $imageProvenanceInvalid = @($manifest.images | Where-Object {
        if ($_.phase -eq 'before') {
            $_.sourceHead -ne $job.binaries.before.source -or
            $_.binaryBuiltAtSource -ne $job.binaries.before.binaryBuiltAtSource -or
            $_.binarySha256 -ne $job.binaries.before.sha256
        } else {
            $_.phase -ne 'after' -or
            $_.sourceHead -ne $job.binaries.after.source -or
            $_.binaryBuiltAtSource -ne $job.binaries.after.binaryBuiltAtSource -or
            $_.binarySha256 -ne $job.binaries.after.sha256
        }
    }).Count -gt 0
    $invalidSeeds = @($manifest.zmxSeeds | Where-Object {
        $_.exitCode -ne 0 -or -not $_.daemonReady -or $_.cmdCount -lt 1 -or
        $_.cleanupStatus -ne 'CLEAN_ZERO_SURVIVORS_FILES_CLOSED' -or
        -not $_.outputProof.jobActive0 -or $_.stdoutEof -or $_.stderrEof -or $_.descendants.Count -lt 2 -or
        $_.cleanup.Count -lt ($_.descendants.Count + 1) -or
        -not ([string]$_.zmxRoot).StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$_.supportRoot).StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)
    })
    $seedPhases = @($manifest.zmxSeeds | ForEach-Object phase | Sort-Object)
    if ($manifest.status -ne 'COMPLETE' -or $manifest.executionMode -ne 'LIVE_CAPTURE' -or
        $manifest.head -ne $job.head -or
        $manifest.jobManifestSha256 -ne $jobHash -or
        $manifest.moduleSha256 -ne $moduleHash -or $manifest.workerSha256 -ne $workerHash -or
        $manifest.supervisorSha256 -ne $supervisorHash -or
        $manifest.preflightReceiptSha256 -ne $preflightHash -or
        $manifest.fixtureSourceSha256 -ne $job.fixture.sha256 -or
        $manifest.fixtureSha256 -ne $fixtureHashExpected -or
        $manifest.fixtureMappingSha256 -ne $fixtureMappingHashExpected -or
        $manifest.zmxSeeds.Count -ne 2 -or $invalidSeeds.Count -ne 0 -or
        ($seedPhases -join ',') -cne 'after,before' -or
        @($manifest.zmxSeeds | ForEach-Object zmxRoot | Sort-Object -Unique).Count -ne 2 -or
        @($manifest.zmxSeeds | ForEach-Object supportRoot | Sort-Object -Unique).Count -ne 2 -or
        ($manifest.zmxSeedExitCodes -join ',') -cne '0,0' -or
        @($manifest.images | Where-Object {
            $_.captureMode -ne 'PRINTWINDOW' -or $_.privacyStatus -ne 'CAPTURED_PENDING_INDIVIDUAL_REVIEW'
        }).Count -ne 0 -or
        $manifest.images.Count -ne 10 -or $manifest.failures.Count -ne 0 -or
        $manifest.ownedProcessSurvivors.Count -ne 0 -or $imageDifference -or $imageProvenanceInvalid) {
        throw 'Final worker manifest does not prove ten exact-head captures and zero owned-process survivors.'
    }
}

function Invoke-CapTimeoutProbe {
    if (Get-Command Write-CapTrace -ErrorAction SilentlyContinue) { Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters }

    $probeId = 'watchdog-' + [guid]::NewGuid().ToString('N')
    $probeRoot = Join-Path $root "runs\$probeId"
    New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null
    $pwshPath = Join-Path $PSHOME 'pwsh.exe'
    $run = Start-CapManagedProcess -FilePath $pwshPath -ArgumentList @(
        '-NoProfile', '-Command', 'Start-Sleep -Seconds 30'
    ) -WorkingDirectory $probeRoot -Role 'offline-watchdog-timeout-probe'
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(1.5)
        $wait = Wait-CapManagedProcess -Run $run -DeadlineUtc $deadline -PollMilliseconds 50
        if ($wait.State -ne 'TimedOut') { throw "Watchdog probe unexpectedly completed: $($wait.State)." }
        $stop = Stop-CapManagedProcess -Identity $run.Identity -TimeoutMilliseconds 3000
        if ($stop.Result -ne 'TERMINATED_GUARDED_HANDLE' -or
            -not $run.StdoutTask.Wait(2000) -or -not $run.StderrTask.Wait(2000) -or
            -not [CapNative]::IsExited($run.Identity.Process.Handle, $run.Identity.Pid)) {
            throw 'Watchdog probe failed guarded stop, kernel exit, or bounded EOF.'
        }
        $reportPath = Join-Path $root "reports\$probeId.json"
        $report = [ordered]@{
            status = 'PASS_OFFLINE_WATCHDOG'
            runId = $probeId
            guiLaunched = $false
            desktopUsed = $false
            zmxCycle = $false
            waitState = $wait.State
            stopResult = $stop.Result
            kernelExited = $true
            stdoutEof = $true
            stderrEof = $true
            processPid = $run.Identity.Pid
            creationFileTimeUtc = $run.Identity.CreationFileTimeUtc
            expectedImagePath = $run.Identity.ExpectedImagePath
            startedUtc = $startedUtc.ToString('o')
            finishedUtc = [DateTime]::UtcNow.ToString('o')
        }
        Write-CapJsonAtomic -Path $reportPath -Value $report
        Write-CapSupervisorLog "WATCHDOG_PROBE=PASS report=$reportPath sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $reportPath).Hash)"
    } finally {
        if (-not [CapNative]::IsExited($run.Identity.Process.Handle, $run.Identity.Pid)) {
            $null = Stop-CapManagedProcess -Identity $run.Identity -TimeoutMilliseconds 3000
        }
        $run.Identity.Process.Dispose()
    }
}

try {
    $outputDirectory = Assert-CapSupervisorPath $requestedOutputDirectory
    if (Test-Path -LiteralPath $outputDirectory) { throw "Refusing to replace a prior capture output: $outputDirectory" }
    $null = New-Item -ItemType Directory -Path $outputDirectory
    $releaseReceiptPath = Join-Path $outputDirectory 'lease-release.json'
    $safeOutputInitialized = $true
    $moduleHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $modulePath).Hash
    $workerHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $workerPath).Hash
    $supervisorHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $PSCommandPath).Hash
    Import-Module $modulePath -Force -WarningAction SilentlyContinue
    Set-CapTracePath -Path (Join-Path $outputDirectory 'supervisor-calls.jsonl')
    Write-CapTrace -Command 'Invoke-UiCapture' -Parameters $PSBoundParameters
    if ($TimeoutProbe) {
        Invoke-CapTimeoutProbe
        return
    }
    if (-not $LeaseReceiptPath -or -not $LeaseReceiptSha256 -or
        (-not $rehearsal -and (-not $PreflightReceiptPath -or -not $PreflightReceiptSha256))) {
        throw 'No coordinator lease or accepted preflight receipt was supplied; no desktop slot is authorized.'
    }
    $JobPath = Assert-CapSupervisorPath $JobPath
    $preflightPath = if ($rehearsal) { $null } else { Assert-CapSupervisorPath $PreflightReceiptPath }
    if (-not (Test-Path -LiteralPath $JobPath -PathType Leaf) -or
        (-not $rehearsal -and -not (Test-Path -LiteralPath $preflightPath -PathType Leaf))) {
        throw 'Exact green job or offline preflight receipt is missing.'
    }
    $jobHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $JobPath).Hash
    if ($JobSha256 -and $jobHash -ne $JobSha256.ToUpperInvariant()) { throw 'Job does not match the explicitly supplied hash.' }
    $job = Read-CapBoundJson -Root $root -Reference ([pscustomobject]@{ path = $JobPath; sha256 = $jobHash })
    if (-not $rehearsal) {
        if ($job.fixture.mappingSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
            ($FixtureMappingSha256 -and $FixtureMappingSha256 -ne $job.fixture.mappingSha256)) {
            throw 'Job fixture mapping digest is missing or differs from the supplied mapping digest.'
        }
        $fixtureMappingHashExpected = $job.fixture.mappingSha256
    }
    if ($rehearsal) {
        if ($job.executionMode -cne $ExecutionMode -or $job.desktopAuthorized -ne $false -or
            $job.rehearsalTarget.arguments -isnot [array] -or
            $job.rehearsalTarget.behavior -notin @(
                'normal', 'nonzero', 'timeout', 'primary-cleanup', 'receipt-block', 'trace-readonly',
                'action-target-absent'
            )) {
            throw 'Expected an explicitly no-desktop rehearsal job with an exact target argument vector.'
        }
        $targetPath = Assert-CapSupervisorPath $job.rehearsalTarget.path
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $targetPath).Hash -ne $job.rehearsalTarget.sha256) {
            throw 'Harmless rehearsal target executable hash mismatch.'
        }
        $sourceRoot = $PSScriptRoot
    } else {
        $preflightHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $preflightPath).Hash
        $preflight = Read-CapBoundJson -Root $root -Reference ([pscustomobject]@{ path = $preflightPath; sha256 = $preflightHash })
    }
    $null = Assert-CapLease
    if (-not $rehearsal -or $null -ne $job.PSObject.Properties['admission']) {
        $jobIdentity = Assert-CapJobIdentity -Root $root -Job $job -Lease $lease -JobSha256 $jobHash -OfflineTestData:$rehearsal
    }
    if ($rehearsal -and $null -ne $job.PSObject.Properties['sceneAdapter'] -and
        $job.sceneAdapter -ceq 'D_QUICK_CHAT_V1') {
        Assert-CapSceneContract -Job $job
        $fixtureMappingHashExpected=$job.fixture.mappingSha256
        $proof=Assert-CapFixtureMapping -Root $root -FixturePath (Join-Path $root 'fixtures\fixture.json') `
            -SourcePath (Join-Path $root 'inputs\fixture-source.json') -MappingPath (Join-Path $root 'reports\fixture-mapping.json') `
            -ExpectedMappingSha256 $fixtureMappingHashExpected -ExpectedSourceSha256 $job.fixture.sha256 `
            -OriginalRoot $job.fixture.originalRoot -SceneAdapter $job.sceneAdapter -ExpectedPeerSha256 $job.fixture.offlinePeerReference.sha256
        $fixtureHashExpected=$proof.FixtureSha256
    }
    if (-not $rehearsal) {
        $sourceRoot = Assert-CapGreenJob
        $null = Assert-CapPreflightReport
    }
    $exports = @(Get-Command -Module UiCaptureDriver | Sort-Object Name)
    if ($exports.Count -lt 30) { throw "Capture driver exports unavailable: count=$($exports.Count)." }
    if (-not $rehearsal) {
        $native = @(Assert-CapLiveNativeBindings)
    }
    if (-not $rehearsal -and (Test-CapMatchedDpiAdapter)) {
        $area=Get-CapPrimaryPhysicalWorkArea
        $contract=$job.captureContract
        $workArea=@($area.Left,$area.Top,$area.Right,$area.Bottom)
        if (($area.Width -lt $contract.minimumPhysicalWorkAreaWH[0]) -or
            ($area.Height -lt $contract.minimumPhysicalWorkAreaWH[1])) {
            throw "DPI-parametric physical work area is insufficient: $($area.Width)x$($area.Height)."
        }
        $dpiGeometryAdmission=Get-CapDpiGeometry -LogicalClientWH @($contract.logicalClientWH) `
            -ExpectedDpi ([uint32]$contract.expectedWindowDpi) `
            -WindowStyle ([long]$contract.windowStyleForAdjustment) `
            -WindowExStyle ([long]$contract.windowExStyle) -HasMenu ([bool]$contract.hasMenu) `
            -WorkArea $workArea -ExpectedAdjustedOuterWH @($contract.expectedAdjustedOuterWH)
    }
    if (@(Get-CapPendingLaunches).Count -ne 0) { throw 'Unreturned capture worker launches remain before run authorization.' }

    $shortLease = $lease.leaseId.Replace('-', '').Substring(0, 8)
    if (-not $rehearsal) {
        if ($root.Length -gt 5) {
            $pathFailure = [IO.PathTooLongException]::new(
                'BCaptureRootTooLong: live B capture requires a fresh owned root of at most 5 characters.')
            $pathFailure.Data['CapCaptureCode'] = 'BCaptureRootTooLong'
            throw $pathFailure
        }
        $longestSession = 'graphcode-gc-cap-actions-' + $shortLease + '-before--' + [guid]::Empty.ToString('D')
        $null = Assert-CapZmxLeasePath -ZmxDir (Join-Path $root '00000') -SessionName $longestSession `
            -Sid ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    }
    $runDirectory = Join-Path $root ('runs\' + [guid]::NewGuid().ToString('N'))
    $authorizationPath = Join-Path $runDirectory 'supervisor-authorization.json'
    $processJournalPath = Join-Path $runDirectory 'process-journal'
    $manifestPath = Join-Path $outputDirectory 'manifest.json'
    $workerLogPath = Join-Path $outputDirectory 'worker.log'
    $releaseReceiptPath = Join-Path $outputDirectory 'lease-release.json'
    foreach ($path in @($runDirectory)) {
        if (Test-Path -LiteralPath $path) { throw "Refusing to reuse prior capture run path: $path" }
    }
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    $null = New-Item -ItemType Directory -Path $processJournalPath
    $diagnosticsDirectory = Join-Path $outputDirectory 'diagnostics'
    $null = New-Item -ItemType Directory -Path $diagnosticsDirectory
    $supervisorIdentity = Get-CapProcessIdentity -Process $thisProcess `
        -ExpectedImagePath $supervisorExecutable -Role 'b-capture-supervisor'
    $auth = [ordered]@{
        schemaVersion = 1
        executionMode = $ExecutionMode
        ownedRoot = $root
        leaseId = $lease.leaseId
        leaseReceiptPath = $LeaseReceiptPath
        leaseReceiptSha256 = $leaseHash
        jobPath = $JobPath
        jobSha256 = $jobHash
        modulePath = $modulePath
        moduleSha256 = $moduleHash
        workerPath = $workerPath
        workerSha256 = $workerHash
        supervisorPath = $PSCommandPath
        supervisorSha256 = $supervisorHash
        supervisorExecutable = $supervisorExecutable
        supervisorPid = $supervisorIdentity.Pid
        supervisorCreationFileTimeUtc = $supervisorIdentity.CreationFileTimeUtc
        preflightReceiptPath = $preflightPath
        preflightReceiptSha256 = $preflightHash
        fixtureMappingSha256 = $fixtureMappingHashExpected
        sourceRoot = $sourceRoot
        jobIdentity = $jobIdentity
        dpiGeometryAdmission = $dpiGeometryAdmission
        runDirectory = $runDirectory
        outputDirectory = $outputDirectory
        processJournalPath = $processJournalPath
        manifestPath = $manifestPath
        workerLogPath = $workerLogPath
        workerDeadlineUtc = $deadlineUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        authorizationPath = $authorizationPath
    }
    Write-CapJsonAtomic -Path $authorizationPath -Value $auth
    $authorizationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $authorizationPath).Hash
    $releaseReceiptPath = Join-Path $outputDirectory 'lease-release.json'
    Write-CapSupervisorLog "LEASE_ACCEPTED lease=$($lease.leaseId) head=$($job.head) remaining=$([Math]::Round(($leaseExpiresUtc - [DateTime]::UtcNow).TotalSeconds, 1))s reserve=90s"
    Write-CapSupervisorLog "STARTING_WORKER path=$workerPath sha256=$workerHash authorization=$authorizationHash"

    if (@(Get-CapTraceFailures).Count -gt 0) { throw 'Capture tracing failed before worker launch.' }
    $pwshPath = Join-Path $PSHOME 'pwsh.exe'
    $workerLaunchAttempted = $true
    [CapProcessJob]::ClearStandardHandleInheritance()
    $workerJob = [CapProcessJob]::Create()
    $workerRun = Start-CapManagedProcess -FilePath $pwshPath -ArgumentList @(
        '-NoProfile', '-File', $workerPath,
        '-AuthorizationPath', $authorizationPath,
        '-AuthorizationSha256', $authorizationHash, '-OwnedRoot', $root, '-AwaitSupervisorGate'
    ) -WorkingDirectory $runDirectory -Role 'b-capture-worker' -HoldStdin
    [CapProcessJob]::Assign($workerJob, $workerRun.Identity.Process.Handle)
    $journalBinding = New-CapJournalBinding -RunId ([IO.Path]::GetFileName($runDirectory)) `
        -LeaseId $lease.leaseId -JobSha256 $jobHash -ModuleSha256 $moduleHash `
        -WorkerSha256 $workerHash -SupervisorSha256 $supervisorHash -Identity $workerRun.Identity
    $journalState = New-CapJournalState -Root $root -Directory $processJournalPath -Binding $journalBinding `
        -DeadlineUtc $deadlineUtc -ObservationPath (Join-Path $diagnosticsDirectory 'journal-read-observations.jsonl')
    $null = Write-CapImmutableJson -Root $root -Path (Join-Path $runDirectory 'worker-gate.json') -Value ([pscustomobject]@{
        binding = $journalBinding; authorizationSha256 = $authorizationHash
        assignedBeforeGateRelease = $true; containment = 'KILL_ON_CLOSE_NO_ESCAPE_FLAGS'
    })
    $workerRun.Identity.Process.StandardInput.WriteLine($authorizationHash)
    $workerRun.Identity.Process.StandardInput.Flush()
    $workerRun.Identity.Process.StandardInput.Close()
    $lastJournalRead = [DateTime]::MinValue
    while ([DateTime]::UtcNow -lt $deadlineUtc) {
        if (@(Get-CapTraceFailures).Count -gt 0) { throw 'Capture tracing failed; supervisor is beginning guarded cleanup.' }
        $workerWait = Wait-CapManagedProcess -Run $workerRun `
            -DeadlineUtc ([DateTime]::UtcNow.AddMilliseconds(200)) -PollMilliseconds 50
        if ($workerWait.State -eq 'Exited') { break }
        if (([DateTime]::UtcNow - $lastJournalRead).TotalMilliseconds -ge 200) {
            Refresh-CapJournal -Path $processJournalPath
            $lastJournalRead = [DateTime]::UtcNow
        }
    }
    if ($workerWait.State -ne 'Exited') {
        $primaryFailure = [TimeoutException]::new('Worker reached the bounded capture deadline; supervisor is beginning guarded cleanup.')
        Write-CapSupervisorLog "WORKER_DEADLINE=REACHED utc=$([DateTime]::UtcNow.ToString('o'))"
        Refresh-CapJournal -Path $processJournalPath -ReadDeadlineUtc $leaseExpiresUtc
        if (-not $rehearsal) {
            Recover-CapGuiRoots -CleanupDeadlineUtc $leaseExpiresUtc
            Stop-CapTrackedPeers
        }
        $workerGrace = Wait-CapManagedProcess -Run $workerRun `
            -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(3)) -PollMilliseconds 100
        if ($workerGrace.State -eq 'Exited') { $workerWait = $workerGrace }
        else { Stop-CapWorkerIfNeeded }
    } else {
        Refresh-CapJournal -Path $processJournalPath -ReadDeadlineUtc $leaseExpiresUtc
        $workerExitCode = $workerWait.ExitCode
        if ($workerExitCode -ne 0) { $primaryFailure = [InvalidOperationException]::new("Capture worker exited with code $workerExitCode.") }
    }
} catch {
    if (-not $primaryFailure) { $primaryFailure = $_ }
    Write-CapSupervisorLog "SUPERVISOR_FAILURE=$($_.Exception.ToString())"
} finally {
    if (Get-Command Resolve-CapPendingLaunches -ErrorAction SilentlyContinue) {
        try {
            foreach ($receipt in @(Resolve-CapPendingLaunches)) { $recoveryReceipts.Add($receipt) }
            $pendingLaunchesRemaining = @(Get-CapPendingLaunches)
        } catch { $cleanupFailures.Add("Pending launch rollback failed: $(Get-CapSupervisorFailureText $_)") }
    }
    if ($workerRun) {
        # A journal or log failure must not bypass the remaining guarded stops.
        foreach ($step in @(
            { if ($journalState) { Refresh-CapJournal -Path $processJournalPath -ReadDeadlineUtc $leaseExpiresUtc } },
            {
                if (-not $rehearsal -and $tracked.Count -gt 0) {
                    Recover-CapGuiRoots -CleanupDeadlineUtc ([DateTime]::UtcNow.AddSeconds(30))
                    Stop-CapTrackedPeers
                }
            },
            {
                foreach ($record in $tracked.Values) {
                    try {
                        $result = Stop-CapManagedProcess -Identity $record.Identity -TimeoutMilliseconds 5000
                        $recoveryReceipts.Add($result)
                    } catch { $cleanupFailures.Add((Get-CapSupervisorFailureText $_)) }
                }
            },
            { Stop-CapWorkerIfNeeded },
            {
                if ($workerJob -eq [IntPtr]::Zero) { throw 'Supervisor job owner handle is absent.' }
                $membersBeforeStop = @([CapProcessJob]::Members($workerJob))
                $exemptWorkerPid = $null
                if ($membersBeforeStop -contains $workerRun.Identity.Pid) {
                    try {
                        $access = Read-CapProcessAccess -Process $workerRun.Identity.Process -Role $workerRun.Identity.Role `
                            -CallSite 'Supervisor.UmbrellaWorkerSnapshot' -ExpectedPid $workerRun.Identity.Pid
                        $workerSnapshot = [CapNative]::Snapshot($access.Handle, $access.Pid)
                        if (-not $workerSnapshot.IsExited -and
                            $workerSnapshot.CreationFileTimeUtc -eq $workerRun.Identity.CreationFileTimeUtc -and
                            $workerSnapshot.ImagePath -ieq $workerRun.Identity.ExpectedImagePath) {
                            $exemptWorkerPid = $workerSnapshot.ProcessId
                        }
                    } catch {
                        $cleanupFailures.Add("Umbrella worker exemption could not attest its held generation: $($_.Exception.Message)")
                    }
                }
                [CapProcessJob]::Terminate($workerJob)
                [CapProcessJob]::WaitForEmpty($workerJob, 5000)
                $active = [CapProcessJob]::Active($workerJob)
                if ($active -ne 0) { throw 'Supervisor job not empty before close.' }
                $script:workerJobReceipt = [pscustomobject]@{ kind = 'KILL_ON_CLOSE_JOB'
                    membersBeforeStop = $membersBeforeStop; activeProcesses = [long]$active
                    jobActive0 = $true; observedBeforeHandleClose = $true }
                [CapProcessJob]::Close($workerJob)
                $script:workerJob = [IntPtr]::Zero
                foreach ($memberPid in $membersBeforeStop) {
                    if ($null -ne $exemptWorkerPid -and $memberPid -eq $exemptWorkerPid) { continue }
                    $recoveryReceipts.Add([pscustomobject]@{
                        kind = 'SAFETY_NET_KILLED'; pid = [long]$memberPid
                        identityAttested = $false; evidence = 'UMBRELLA_JOB_MEMBERSHIP_PID_ONLY'
                        jobActive0 = $true; cleanReleaseProven = $false
                    })
                    $cleanupFailures.Add("SAFETY_NET_KILLED: umbrella member PID $memberPid lacked an exact exempt worker generation; cleanup remains unproved.")
                }
            },
            { Write-CapProcessOutput -Run $workerRun -Prefix 'supervisor-worker' },
            { Assert-CapNoTrackedSurvivors },
            { Read-CapQuiescentWorkerProof }
        )) {
            try { & $step }
            catch {
                $cleanupFailures.Add((Get-CapSupervisorFailureText $_))
                Write-CapSupervisorLog "SUPERVISOR_CLEANUP_FAILURE=$($_.Exception.ToString())"
            }
        }
        $cleanupProven = $cleanupFailures.Count -eq 0
    }
    if ($workerJob -ne [IntPtr]::Zero) {
        try {
            [CapProcessJob]::Terminate($workerJob)
            [CapProcessJob]::WaitForEmpty($workerJob, 5000)
            if ([CapProcessJob]::Active($workerJob) -ne 0) { throw 'Unreturned worker job remains active.' }
            [CapProcessJob]::Close($workerJob)
            $workerJob = [IntPtr]::Zero
        } catch { $cleanupFailures.Add("Supervisor job cleanup failed: $(Get-CapSupervisorFailureText $_)") }
    }
    foreach ($record in $tracked.Values) {
        try { $record.Identity.Process.Dispose() }
        catch { $cleanupFailures.Add("Handle disposal failed: $(Get-CapSupervisorFailureText $_)") }
    }
    if ($workerRun) {
        try { $workerRun.Identity.Process.Dispose() }
        catch { $cleanupFailures.Add("Worker handle disposal failed: $(Get-CapSupervisorFailureText $_)") }
    }
    try {
        if ($safeOutputInitialized) {
            # Construction, parsing, serialization and the actual write are all protected.
            if (Get-Command Write-CapTrace -ErrorAction SilentlyContinue) {
                try { Write-CapTrace -Command 'Write-CapJsonAtomic' -Parameters @{ Path = $releaseReceiptPath; FinalRelease = $true } }
                catch { $cleanupFailures.Add("Release trace write failed: $(Get-CapSupervisorFailureText $_)") }
            }
            $manifest = $boundWorkerManifest
            if ($workerRun -and (-not $manifest -or
                -not $manifest.PSObject.Properties['ownedProcessSurvivors'] -or
                -not $manifest.PSObject.Properties['pendingLaunchesRemaining'] -or
                -not $manifest.PSObject.Properties['cleanupFailures'] -or
                $manifest.ownedProcessSurvivors -isnot [array] -or
                $manifest.pendingLaunchesRemaining -isnot [array] -or
                $manifest.cleanupFailures -isnot [array] -or
                $manifest.ownedProcessSurvivors.Count -ne 0 -or
                $manifest.pendingLaunchesRemaining.Count -ne 0 -or $manifest.cleanupFailures.Count -ne 0)) {
                $cleanupFailures.Add('Worker final kernel-cleanup evidence is absent or has survivors.')
            }
            $primaryText = Get-CapSupervisorFailureText $primaryFailure
            $traceFailures = if (Get-Command Get-CapTraceFailures -ErrorAction SilentlyContinue) { @(Get-CapTraceFailures) } else { @() }
            foreach ($failure in $traceFailures) { $cleanupFailures.Add("Call tracing failed: $($failure.failure)") }
            $cleanupProven = $workerRun -and $cleanupProven -and $cleanupFailures.Count -eq 0
            $release = [ordered]@{
            schemaVersion = 1
            status = if (-not $workerLaunchAttempted -and $cleanupFailures.Count -eq 0) { 'REFUSED_NO_WORKER' }
                elseif (-not $cleanupProven -or $survivors.Count) { 'CLEANUP_UNPROVEN' }
                elseif ($primaryFailure) { 'FAILED_ZERO_SURVIVORS' } else { 'RELEASED_ZERO_SURVIVORS' }
            executionMode = $ExecutionMode
            cleanupState = if (-not $workerLaunchAttempted -and $cleanupFailures.Count -eq 0) { 'NO_WORKER_STARTED' }
                elseif ($cleanupProven) { 'KERNEL_EXIT_AND_EOF_PROVEN' } else { 'UNPROVEN' }
            workerStarted = $null -ne $workerRun
            workerLaunchAttempted = $workerLaunchAttempted
            pendingLaunchesRemaining = @($pendingLaunchesRemaining)
            guiOperations = if ($rehearsal) { 'NotExecuted: no-desktop real-launch rehearsal' } else { 'See worker manifest' }
            leaseId = if ($lease) { $lease.leaseId } else { $null }
            leaseReceiptSha256 = $leaseHash
            jobSha256 = $jobHash
            head = if ($job) { $job.head } else { $null }
            moduleSha256 = $moduleHash
            workerSha256 = $workerHash
            supervisorSha256 = $supervisorHash
            preflightReceiptSha256 = $preflightHash
            startedUtc = $startedUtc.ToString('o')
            releasedUtc = [DateTime]::UtcNow.ToString('o')
            leaseDeadlineUtc = if ($lease) {
                $leaseExpiresUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            } else { $null }
            workerExitCode = if ($workerWait) { $workerWait.ExitCode } else { $null }
            workerStdoutEof = if ($workerRun) { $workerRun.StdoutTask.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion } else { $false }
            workerStderrEof = if ($workerRun) { $workerRun.StderrTask.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion } else { $false }
            journalEntriesWithoutHeldKernelHandle = @($untrackedJournalEntries)
            kernelVerifiedSurvivors = @($survivors)
            recovery = @($recoveryReceipts)
            cleanupFailures = @($cleanupFailures)
            traceFailures = @($traceFailures)
            primaryFailure = $primaryText
            workerPrimaryFailure = if ($manifest) { ,@($manifest.failures) } else { ,@() }
            workerCleanupFailures = if ($manifest -and $manifest.PSObject.Properties['cleanupFailures'] -and $manifest.cleanupFailures -is [array]) { ,@($manifest.cleanupFailures) } else { $null }
            workerPendingLaunchesRemaining = if ($manifest -and $manifest.PSObject.Properties['pendingLaunchesRemaining'] -and $manifest.pendingLaunchesRemaining -is [array]) { ,@($manifest.pendingLaunchesRemaining) } else { $null }
            workerOwnedProcessSurvivors = if ($manifest -and $manifest.PSObject.Properties['ownedProcessSurvivors'] -and $manifest.ownedProcessSurvivors -is [array]) { ,@($manifest.ownedProcessSurvivors) } else { $null }
            journalFinalBinding = if ($journalProof) { $journalProof.Record } else { $null }
            containmentJob = $workerJobReceipt
            journalPublishedInventory = if ($journalProof) { ,@($journalProof.Inventory) } else { $null }
            captures = if ($manifest) { $manifest.images.Count } else { 0 }
            sourceHashesBeforeImport = [ordered]@{ module = $moduleHash; worker = $workerHash; supervisor = $supervisorHash }
            }
            Write-CapJsonAtomic -Path $releaseReceiptPath -Value $release -FinalRelease
            $releaseWritten = $true
        }
    } catch {
        $releaseFailure = $_
        [Console]::Error.WriteLine("LEASE_RELEASE_WRITE_FAILED: $(Get-CapSupervisorFailureText $_)")
    }
}

if ($journalProof) { foreach ($stream in $journalProof.HeldStreams) { $stream.Dispose() } }

if ($cleanupFailures.Count -or $releaseFailure -or -not $releaseWritten) {
    throw "Capture supervisor failed. Primary=$(Get-CapSupervisorFailureText $primaryFailure); cleanup=$($cleanupFailures -join '; '); release=$(Get-CapSupervisorFailureText $releaseFailure); releaseWritten=$releaseWritten"
}
if ($primaryFailure) { throw $primaryFailure }
Write-Output ('{0:o} CAPTURE_COMPLETE output={1} release={2}' -f [DateTime]::UtcNow, $outputDirectory, $releaseReceiptPath)
