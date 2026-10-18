param(
    [string]$ScratchRoot = (Join-Path ([IO.Path]::GetTempPath()) ('gc-capture-' + [guid]::NewGuid().ToString('N'))),
    [switch]$LaunchContractOnly,
    [switch]$JournalContractOnly,
    [switch]$ReceiptContractOnly,
    [switch]$ReceiptExclusiveOnly,
    [switch]$PrepareFixturesOnly,
    [switch]$FixtureContractOnly,
    [switch]$JournalTimingContractOnly,
    [switch]$JournalFirstOpenContractOnly,
    [switch]$JournalObservationContractOnly,
    [switch]$PreflightReportContractOnly,
    [switch]$SelectorRefusalContractOnly,
    [switch]$IdentityContractOnly,
    [switch]$AppChildContractOnly,
    [switch]$DAdapterContractOnly,
    [ValidateSet('All','SceneContract','ActualAdmission','FixtureDirectory')][string]$DAdapterCase = 'All',
    [string]$PrebuiltFixtureManifest = '',
    [string]$PrebuiltFixtureManifestSha256 = '',
    [switch]$RequireRealSeed,
    [string]$RealSeedZmxPath = '',
    [string]$RealSeedZmxSha256 = '',
    [ValidateSet('','Writer','Reader')][string]$JournalActor = '',
    [string]$JournalActorConfig = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$driverDirectory = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $driverDirectory 'UiCaptureDriver.psm1'
$supervisorPath = Join-Path $driverDirectory 'Invoke-UiCapture.ps1'
$workerPath = Join-Path $driverDirectory 'Invoke-UiCaptureWorker.ps1'

function Write-JournalContractJson {
    param([string]$Path, $Value)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json $Value -Depth 40 -Compress) + "`n")
    $file = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
}

function Read-JournalContractJson {
    param([string]$Path)
    try { $file = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read) }
    catch {
        $exception = $_.Exception
        while ($exception.InnerException) { $exception = $exception.InnerException }
        $native = '{0:X8}' -f ([long]$exception.HResult -band 4294967295L)
        if ($native -in @('80070002','80070003','80070020','80070021')) { return $null }
        throw
    }
    try {
        $reader = [IO.StreamReader]::new($file, [Text.UTF8Encoding]::new($false, $true), $false)
        try { return ConvertFrom-Json $reader.ReadToEnd() -Depth 40 -DateKind String }
        finally { $reader.Dispose() }
    } finally { $file.Dispose() }
}

function Format-JournalActorCleanupFailure {
    param([string]$Root, [string[]]$CleanupErrors)
    $primaries = foreach ($name in @('Reader-failed.json','Writer-failed.json')) {
        $path = Join-Path $Root $name
        $file = $null
        try {
            $file = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
            $bytes = [byte[]]::new(16385)
            $count = 0
            while ($count -lt $bytes.Length) {
                $read = $file.Read($bytes,$count,$bytes.Length-$count)
                if ($read -eq 0) { break }
                $count += $read
            }
            $text = [Text.Encoding]::UTF8.GetString($bytes,0,[Math]::Min($count,16384))
            if ($count -gt 16384) { $text += ' [TRUNCATED at 16384 bytes]' }
            "${name}: $text"
        } catch {
            $cause = $_.Exception
            while ($cause.InnerException) { $cause = $cause.InnerException }
            $status = if ($cause -is [IO.FileNotFoundException] -or $cause -is [IO.DirectoryNotFoundException]) {
                'MISSING'
            } else { 'READ_ERROR' }
            "${name}: $status $($cause.Message)"
        } finally { if ($null -ne $file) { $file.Dispose() } }
    }
    return "Empty/incomplete actual actor cleanup: $($CleanupErrors -join '; '); actor primaries: $($primaries -join '; ')"
}

function Wait-JournalContractFile {
    param([string]$Path, [DateTime]$Deadline)
    while ([DateTime]::UtcNow -lt $Deadline) {
        foreach ($failureName in @('Writer-failed.json','Reader-failed.json')) {
            $failure = Read-JournalContractJson (Join-Path (Split-Path -Parent $Path) $failureName)
            if ($failure) { throw "HARNESSFAIL: contract actor: $($failure.error)" }
        }
        $value = Read-JournalContractJson $Path
        if ($null -ne $value) { return $value }
        Start-Sleep -Milliseconds 5
    }
    throw "HARNESSFAIL: barrier/observer deadline at $Path"
}

function New-JournalContractStamp {
    param([string]$Role, [string]$Event)
    return [ordered]@{
        role = $Role; event = $Event; pid = $PID; utc = [DateTime]::UtcNow.ToString('o')
        monotonicTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
        monotonicFrequency = [Diagnostics.Stopwatch]::Frequency
    }
}

if ($JournalActor) {
    $contractConfiguration = Read-JournalContractJson $JournalActorConfig
    Import-Module $modulePath -Force -WarningAction SilentlyContinue
    $contractDeadline = [DateTime]::Parse($contractConfiguration.deadlineUtc,
        [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    $contractHome = $contractConfiguration.root
    Set-CapTracePath -Path (Join-Path $contractHome ($JournalActor + '-calls.jsonl'))
    try {
        if ($JournalActor -ceq 'Writer') {
            $self = [Diagnostics.Process]::GetCurrentProcess()
            $identity = Get-CapProcessIdentity -Process $self -ExpectedImagePath $self.MainModule.FileName -Role 'journal-contract-writer'
            $binding = New-CapJournalBinding -RunId $contractConfiguration.runId `
                -LeaseId $contractConfiguration.leaseId -JobSha256 ('A' * 64) `
                -ModuleSha256 $contractConfiguration.moduleSha256 -WorkerSha256 $contractConfiguration.workerSha256 `
                -SupervisorSha256 $contractConfiguration.supervisorSha256 -Identity $identity
            $state = New-CapJournalState -Root $contractHome -Directory (Join-Path $contractHome 'snapshots') `
                -Binding $binding -DeadlineUtc $contractDeadline
            Write-JournalContractJson (Join-Path $contractHome 'writer-ready.json') @{
                stamp = New-JournalContractStamp 'Writer' 'ready'; binding = $binding
            }
            $null = Wait-JournalContractFile (Join-Path $contractHome 'publish-one.json') $contractDeadline
            $first = Publish-CapJournalSnapshot -State $state -Kind Bootstrap -Value ([pscustomobject]@{ entries = @(); counter = 1L })
            Write-JournalContractJson (Join-Path $contractHome 'published-one.json') @{
                stamp = New-JournalContractStamp 'Writer' 'published1'; reference = $first
            }
            $null = Wait-JournalContractFile (Join-Path $contractHome 'publish-rest.json') $contractDeadline
            Write-JournalContractJson (Join-Path $contractHome 'writer-attempt.json') @{
                stamp = New-JournalContractStamp 'Writer' 'attempt2'
            }
            for ($sequence = 2; $sequence -le $contractConfiguration.publications; $sequence++) {
                $last = Publish-CapJournalSnapshot -State $state -Kind Progress -Value ([pscustomobject]@{
                    entries = @(); counter = [long]$sequence
                })
            }
            Write-JournalContractJson (Join-Path $contractHome 'published-rest.json') @{
                stamp = New-JournalContractStamp 'Writer' 'publishedLast'; reference = $last
            }
        } else {
            $binding = (Wait-JournalContractFile (Join-Path $contractHome 'writer-ready.json') $contractDeadline).binding
            $state = New-CapJournalState -Root $contractHome -Directory (Join-Path $contractHome 'snapshots') `
                -Binding $binding -DeadlineUtc $contractDeadline `
                -ObservationPath (Join-Path $contractHome 'journal-read-observations.jsonl')
            Write-JournalContractJson (Join-Path $contractHome 'reader-ready.json') @{
                stamp = New-JournalContractStamp 'Reader' 'ready'
            }
            $null = Wait-JournalContractFile (Join-Path $contractHome 'read-one.json') $contractDeadline
            $reading = Read-CapJournalSnapshot $state
            Write-JournalContractJson (Join-Path $contractHome 'reader-accepted.json') @{
                stamp = New-JournalContractStamp 'Reader' 'accepted'; reading = $reading
            }
        }
        $null = Wait-JournalContractFile (Join-Path $contractHome 'finish.json') $contractDeadline
        if (@(Get-CapTraceFailures).Count -ne 0) { throw 'Contract actor trace failed.' }
        exit 0
    } catch {
        [Console]::Error.WriteLine($_.Exception.ToString())
        Write-JournalContractJson (Join-Path $contractHome ($JournalActor + '-failed.json')) @{
            stamp = New-JournalContractStamp $JournalActor 'HARNESSFAIL'
            error = $_.Exception.ToString()
        }
        exit 1
    }
}

$mode = 'NO_DESKTOP_REAL_LAUNCH_REHEARSAL'
$results = [Collections.Generic.List[object]]::new()
$scratch = [IO.Path]::GetFullPath($ScratchRoot)
if (Test-Path -LiteralPath $scratch) { throw "Refusing to replace capture test evidence: $scratch" }
$null = New-Item -ItemType Directory -Path $scratch
$sourceHashesBefore = [ordered]@{}
foreach ($path in @($modulePath, $supervisorPath, $workerPath, $PSCommandPath)) {
    $sourceHashesBefore[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
Import-Module $modulePath -Force -WarningAction SilentlyContinue
Set-CapTracePath -Path (Join-Path $scratch 'test-calls.jsonl')

function Assert-CapTest {
    param([bool]$Condition, [string]$Message, $Detail = $null)
    if (-not $Condition) {
        $failure = [InvalidOperationException]::new($Message)
        if ($null -ne $Detail) { $failure.Data['CapTestDetail'] = $Detail }
        throw $failure
    }
}

function Invoke-CapTest {
    param([string]$Name, [scriptblock]$Action)
    try {
        $detail = & $Action
        $results.Add([ordered]@{ name = $Name; passed = $true; detail = $detail })
        Write-Host "PASS $Name"
    } catch {
        $row = [ordered]@{ name = $Name; passed = $false; error = $_.Exception.ToString(); stack = $_.ScriptStackTrace }
        if ($_.Exception.Data.Contains('CapTestDetail')) { $row.detail = $_.Exception.Data['CapTestDetail'] }
        $results.Add($row)
        Write-Host "FAIL $Name`: $($_.Exception.Message)"
    }
}

function Assert-CapRejects {
    param([scriptblock]$Action, [string]$Expected)
    try { & $Action | Out-Null }
    catch {
        Assert-CapTest ($_.Exception.Message.Contains($Expected)) "Wrong refusal: $($_.Exception.Message)"
        return $_.Exception.Message
    }
    throw "Expected refusal containing '$Expected'."
}

    function New-JournalContractContext {
        param([string]$Name)
        $contractRoot = Join-Path $scratch ('journal-contracts\' + $Name)
        $null = New-Item -ItemType Directory -Path (Join-Path $contractRoot 'snapshots')
        $self = [Diagnostics.Process]::GetCurrentProcess()
        try {
            $identity = Get-CapProcessIdentity -Process $self -ExpectedImagePath $self.MainModule.FileName -Role 'journal-contract'
            $binding = New-CapJournalBinding -RunId ([guid]::NewGuid().ToString()) -LeaseId ([guid]::NewGuid().ToString()) `
                -JobSha256 ('A' * 64) -ModuleSha256 $sourceHashesBefore[$modulePath] `
                -WorkerSha256 $sourceHashesBefore[$workerPath] -SupervisorSha256 $sourceHashesBefore[$supervisorPath] `
                -Identity $identity
        } finally { $self.Dispose() }
        $state = New-CapJournalState -Root $contractRoot -Directory (Join-Path $contractRoot 'snapshots') `
            -Binding $binding -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(2))
        return [pscustomobject]@{ Root = $contractRoot; State = $state; Binding = $binding }
    }

    function Invoke-JournalConcurrentContract {
        param([string]$Name, [switch]$LockedFirst, [int]$Publications = 128)
        $contractRoot = Join-Path $scratch ('journal-contracts\' + $Name)
        $null = New-Item -ItemType Directory -Path (Join-Path $contractRoot 'snapshots')
        $configuration = Join-Path $contractRoot 'actors.json'
        $deadline = [DateTime]::UtcNow.AddSeconds(90)
        Write-JournalContractJson $configuration @{
            root = $contractRoot; deadlineUtc = $deadline.ToString('o'); runId = [guid]::NewGuid().ToString()
            leaseId = [guid]::NewGuid().ToString(); publications = $Publications
            moduleSha256 = $sourceHashesBefore[$modulePath]; workerSha256 = $sourceHashesBefore[$workerPath]
            supervisorSha256 = $sourceHashesBefore[$supervisorPath]
        }
        $actors = [Collections.Generic.List[object]]::new()
        $cleanup = [Collections.Generic.List[object]]::new()
        $cleanupErrors = [Collections.Generic.List[string]]::new()
        $held = $null
        $setupLock = $null
        try {
            foreach ($childKind in @('Writer','Reader')) {
                $actor = Start-CapManagedProcess -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @(
                    '-NoProfile','-File',$PSCommandPath,'-JournalActor',$childKind,'-JournalActorConfig',$configuration
                ) -WorkingDirectory $contractRoot -Role ('journal-contract-' + $childKind.ToLowerInvariant()) -CloseStdin
                $actors.Add($actor)
            }
            $writerReady = Wait-JournalContractFile (Join-Path $contractRoot 'writer-ready.json') $deadline
            $readerReady = Wait-JournalContractFile (Join-Path $contractRoot 'reader-ready.json') $deadline
            Assert-CapTest ($writerReady.binding.workerPid -eq $actors[0].Identity.Pid -and
                $writerReady.binding.workerCreationFileTimeUtc -eq $actors[0].Identity.CreationFileTimeUtc) 'Actual writer binding differs from held generation.'
            Write-JournalContractJson (Join-Path $contractRoot 'publish-one.json') (New-JournalContractStamp 'Observer' 'publish1')
            $first = Wait-JournalContractFile (Join-Path $contractRoot 'published-one.json') $deadline
            $path = Join-Path $contractRoot 'snapshots\000001.json'
            $held = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $beforeHash = (Get-FileHash -InputStream $held -Algorithm SHA256).Hash
            Assert-CapTest ($beforeHash -ceq $first.reference.sha256) 'Consumer first bytes differ from publisher expected bytes.'
            $held.Position = 0
            $lockStamp = New-JournalContractStamp 'Observer' 'lock'
            if ($LockedFirst) {
                $held.Dispose(); $held = $null
                $setupLock = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            }
            Write-JournalContractJson (Join-Path $contractRoot 'read-one.json') (New-JournalContractStamp 'Observer' 'read')
            $nativeObservation = $null
            if ($LockedFirst) {
                while ([DateTime]::UtcNow -lt $deadline) {
                    $failure = Read-JournalContractJson (Join-Path $contractRoot 'Reader-failed.json')
                    if ($failure) { throw "HARNESSFAIL: observer/reader missed fixed retry window: $($failure.error)" }
                    $observationPath = Join-Path $contractRoot 'journal-read-observations.jsonl'
                    try {
                        $stream = [IO.File]::Open($observationPath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                    } catch {
                        $inner = $_.Exception.GetBaseException()
                        if ($inner -isnot [IO.FileNotFoundException]) { throw }
                        Start-Sleep -Milliseconds 5
                        continue
                    }
                    try {
                        $textReader = [IO.StreamReader]::new($stream)
                        try { $text = $textReader.ReadToEnd() } finally { $textReader.Dispose() }
                    } finally { $stream.Dispose() }
                    $lastLine = $text.LastIndexOf("`n")
                    if ($lastLine -ge 0) {
                        $observations = @($text.Substring(0, $lastLine + 1) -split "`n" | Where-Object { $_ } |
                            ForEach-Object { ConvertFrom-Json $_ -DateKind String })
                        $nativeObservation = @($observations | Where-Object {
                            $_.sequence -eq 1 -and $_.attempt -eq 1 -and $_.decision -ceq 'OpenFailed' -and
                            $_.nativeHresult -in @('80070020','80070021')
                        }) | Select-Object -First 1
                        if ($nativeObservation) { break }
                    }
                    Start-Sleep -Milliseconds 5
                }
                Assert-CapTest ($null -ne $nativeObservation) 'HARNESSFAIL: no actual first-sequence native Open error.'
            }
            $observerSeen = New-JournalContractStamp 'Observer' 'error-seen'
            Write-JournalContractJson (Join-Path $contractRoot 'publish-rest.json') $observerSeen
            $published = Wait-JournalContractFile (Join-Path $contractRoot 'published-rest.json') $deadline
            $accepted = Wait-JournalContractFile (Join-Path $contractRoot 'reader-accepted.json') $deadline
            if ($LockedFirst) {
                Assert-CapTest ($accepted.reading.State -ceq 'Published' -and
                    $accepted.reading.Snapshot.Reference.sequence -eq 2 -and
                    $accepted.reading.Snapshot.Reference.sha256 -ceq $published.reference.sha256 -and
                    $accepted.reading.Snapshot.Reference.length -eq $published.reference.length -and
                    $null -ne $setupLock) 'Reader did not verify actual2 under held lock1.'
                $observations = @(Get-Content -LiteralPath (Join-Path $contractRoot 'journal-read-observations.jsonl') |
                    ForEach-Object { ConvertFrom-Json $_ -DateKind String })
                Assert-CapTest (@($observations | Where-Object {
                    $_.sequence -eq 2 -and $_.decision -ceq 'AcceptedLiveSequenceOnly' -and $_.retries -ge 1
                }).Count -eq 1) 'Actual retry-to2 telemetry missing.'
            } else {
                $afterHash = (Get-FileHash -InputStream $held -Algorithm SHA256).Hash
                Assert-CapTest ($afterHash -ceq $beforeHash) 'Held immutable first snapshot changed.'
            }
            $readerState = New-CapJournalState -Root $contractRoot -Directory (Join-Path $contractRoot 'snapshots') `
                -Binding $writerReady.binding -DeadlineUtc $deadline
            $latest = Read-CapJournalSnapshot $readerState
            Assert-CapTest ($latest.Snapshot.Reference.sequence -eq $Publications -and
                $latest.Snapshot.Reference.sha256 -ceq $published.reference.sha256 -and
                @(Get-ChildItem -LiteralPath (Join-Path $contractRoot 'snapshots') -Filter '*.json' -File).Count -eq $Publications) 'Positive publication count/latest state differs.'
            return [ordered]@{
                publications = $Publications; nativeObservation = $nativeObservation
                writerReady = $writerReady; readerReady = $readerReady; observerLock = $lockStamp
                observerSeen = $observerSeen; writerPublished = $published; readerAccepted = $accepted
                evidence = 'Actual immutable publisher/reader, external setup barriers, no production hook or UI.'
            }
        } finally {
            if ($held) { $held.Dispose() }
            if ($setupLock) { $setupLock.Dispose() }
            Write-JournalContractJson (Join-Path $contractRoot 'finish.json') (New-JournalContractStamp 'Observer' 'unlock-finish')
            foreach ($actor in $actors) {
                try {
                    $wait = Wait-CapManagedProcess -Run $actor -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10))
                    if ($wait.State -cne 'Exited') { $null = Stop-CapManagedProcess -Identity $actor.Identity; throw 'HARNESSFAIL: actor required guarded stop.' }
                    $stdout = $actor.StdoutTask.Wait(2000); $stderr = $actor.StderrTask.Wait(2000)
                    Assert-CapTest ($wait.ExitCode -eq 0 -and $stdout -and $stderr -and
                        [CapNative]::IsExited($actor.Identity.Process.Handle, $actor.Identity.Pid)) 'Actor normal exit/kernel/bothEOF not proven.'
                    $cleanup.Add([pscustomobject]@{ pid = $actor.Identity.Pid; creation = $actor.Identity.CreationFileTimeUtc
                        kernelExited = $true; stdoutEof = $stdout; stderrEof = $stderr; exitCode = $wait.ExitCode })
                } catch { $cleanupErrors.Add($_.Exception.ToString()) }
                finally {
                    try {
                        if ([CapNative]::IsExited($actor.Identity.Process.Handle, $actor.Identity.Pid)) {
                            $actor.Identity.Process.Dispose()
                        } else { $cleanupErrors.Add("Owned actor remains live: $($actor.Identity.Pid)") }
                    } catch { $cleanupErrors.Add($_.Exception.ToString()) }
                }
            }
            Write-JournalContractJson (Join-Path $contractRoot 'actor-cleanup.json') @{
                receipts = @($cleanup.ToArray()); expected = 2; failures = @($cleanupErrors.ToArray())
            }
            if ($cleanup.Count -ne 2 -or $cleanupErrors.Count -ne 0) {
                Assert-CapTest ($cleanup.Count -eq 2 -and $cleanupErrors.Count -eq 0) `
                    (Format-JournalActorCleanupFailure $contractRoot @($cleanupErrors.ToArray()))
            }
        }
    }

    function New-JournalTerminalFixture {
        param([string]$Name, [ValidateSet('COMPLETE','FAILED')][string]$Outcome = 'COMPLETE',
            [switch]$InvalidJobContract)
        $context = New-JournalContractContext $Name
        $data = [pscustomobject]@{ entries = @(); ownedProcesses = @(); outcome = $Outcome
            ownedProcessSurvivors = @(); pendingLaunchesRemaining = @(); cleanupFailures = @() }
        $null = Publish-CapJournalSnapshot $context.State Bootstrap $data
        $terminal = Publish-CapJournalSnapshot $context.State Terminal $data
        $manifest = [pscustomobject]@{ status = $Outcome; ownedProcesses = @(); ownedProcessSurvivors = @(); pendingLaunchesRemaining = @()
            cleanupFailures = @(); journal = [pscustomobject]@{ protocolVersion = 2L; binding = $context.Binding
                directory = $context.State.Directory; terminal = $terminal; published = @($context.State.Published.ToArray()) } }
        if ($InvalidJobContract) {
            $manifest | Add-Member -NotePropertyMembers @{
                leaseId = $context.Binding.leaseId; leaseReceiptSha256 = ('B' * 64)
                jobManifestSha256 = $context.Binding.jobSha256
                moduleSha256 = $context.Binding.moduleSha256
                workerSha256 = $context.Binding.workerSha256
                supervisorSha256 = $context.Binding.supervisorSha256
                executionMode = 'NO_DESKTOP_REAL_LAUNCH_REHEARSAL'
                guiLaunches = @(); images = @(); rehearsalLaunches = @(); failures = @()
            }
        }
        $reference = Write-CapImmutableJson -Root $context.Root -Path (Join-Path $context.Root 'manifest.json') -Value $manifest
        $line = Format-CapJournalFinalRecord $context.Binding $reference $terminal
        return [pscustomobject]@{ Context = $context; Line = $line; Record = (Read-CapJournalFinalRecord $line $context.Binding) }
    }

    function Invoke-JournalContractGroups {
        param([switch]$IncludeConcurrent)
        if ($IncludeConcurrent) {
            Invoke-CapTest 'actual immutable journal reader preserves held snapshots across concurrent numbered publications' {
                Invoke-JournalConcurrentContract -Name 'concurrent128' -Publications 128
            }
        }
        Invoke-CapTest 'numbered journal publisher refuses collisions without overwriting prior evidence' {
            $c = New-JournalContractContext 'collision'
            $reference = Publish-CapJournalSnapshot $c.State Bootstrap ([pscustomobject]@{ entries = @() })
            $path = Join-Path $c.State.Directory $reference.name
            $null = Assert-CapRejects { Write-CapImmutableJson -Root $c.Root -Path $path -Value @{ invalid = $true } } 'SequenceConflict'
            Assert-CapTest ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $reference.sha256) 'Collision changed prior bytes.'
            return @{ subcases = 1; priorBytesUnchanged = $true; retainedStagingFault = $true }
        }
        Invoke-CapTest 'numbered journal reader retries only transient Open failures within count and deadline' {
            $progress = Invoke-JournalConcurrentContract -Name 'retry-to2' -LockedFirst -Publications 2
            $c = New-JournalContractContext 'retry-exhaustion'
            $null = Publish-CapJournalSnapshot $c.State Bootstrap ([pscustomobject]@{ entries = @() })
            $lock = [IO.File]::Open((Join-Path $c.State.Directory '000001.json'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try { $null = Assert-CapRejects { Read-CapJournalSnapshot $c.State } 'JournalUnavailable' }
            finally { $lock.Dispose() }
            return @{ subcases = 2; realRetry = $progress; exhaustion = 'Observed actual held-file Open retry exhaustion, not a mock.' }
        }
        Invoke-CapTest 'numbered journal reader never regresses below its highest observed sequence' {
            $c = New-JournalContractContext 'floor'
            $null = Publish-CapJournalSnapshot $c.State Bootstrap ([pscustomobject]@{ entries = @() })
            $null = Publish-CapJournalSnapshot $c.State Progress ([pscustomobject]@{ entries = @() })
            $read = Read-CapJournalSnapshot $c.State
            Assert-CapTest ($read.Snapshot.Reference.sequence -eq 2) 'Floor2 was not actually observed.'
            [IO.File]::Move((Join-Path $c.State.Directory '000002.json'), (Join-Path $c.Root 'fault-removed-000002.json'))
            $null = Assert-CapRejects { Read-CapJournalSnapshot $c.State } 'JournalUnavailable'
            Assert-CapTest ($c.State.HighestObserved -eq 2 -and $c.State.LastApplied -eq 2) 'Reader returned older state.'
            return @{ subcases = 1; fault = 'Owned fixture publication removed for negative control, never a publisher action.' }
        }
        Invoke-CapTest 'numbered journal rejects corrupt encoding hashes schema and foreign identities' {
            $executed = 0
            foreach ($fault in @('encoding','parse','hash','schema','identity','lease','gap','alias','case','zero','expiry','acl')) {
                $c = New-JournalContractContext ('fault-' + $fault)
                $null = Publish-CapJournalSnapshot $c.State Bootstrap ([pscustomobject]@{ entries = @() })
                $path = Join-Path $c.State.Directory '000001.json'
                $expected = 'Journal'
                $originalAcl = $null
                try {
                    switch ($fault) {
                        'encoding' { [IO.File]::WriteAllBytes($path, [byte[]]@(255)); $expected = 'JournalEncoding' }
                        'parse' { [IO.File]::WriteAllText($path, '{"x":1,"x":2}'); $expected = 'JournalParse' }
                        'hash' {
                            $value = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                            $value.payloadLength++
                            [IO.File]::WriteAllText($path, (ConvertTo-Json $value -Compress)); $expected = 'JournalHash'
                        }
                        'schema' { [IO.File]::WriteAllText($path, '{}'); $expected = 'JournalSchema' }
                        'identity' { $c.State.Binding = $c.State.Binding.PSObject.Copy(); $c.State.Binding.runId = [guid]::NewGuid().ToString(); $expected = 'JournalIdentity' }
                        'lease' { $c.State.Binding = $c.State.Binding.PSObject.Copy(); $c.State.Binding.leaseId = [guid]::NewGuid().ToString(); $expected = 'JournalIdentity' }
                        'gap' {
                            [IO.File]::Move($path, (Join-Path $c.State.Directory '000002.json')); $expected = 'JournalSchema'
                        }
                        'alias' { [IO.File]::Move($path, (Join-Path $c.State.Directory '1.json')); $expected = 'JournalNamespace' }
                        'case' {
                            [IO.File]::Move($path, (Join-Path $c.Root 'fault-case.json'))
                            [IO.File]::Move((Join-Path $c.Root 'fault-case.json'), (Join-Path $c.State.Directory '000001.JSON'))
                            $expected = 'JournalNamespace'
                        }
                        'zero' { [IO.File]::Move($path, (Join-Path $c.State.Directory '000000.json')); $expected = 'SequenceConflict' }
                        'expiry' { $c.State.DeadlineUtc = [DateTime]::UtcNow.AddSeconds(-1); $expected = 'JournalUnavailable' }
                        'acl' {
                            $originalAcl = Get-Acl -LiteralPath $path
                            $denied = Get-Acl -LiteralPath $path
                            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
                            $denied.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,
                                [Security.AccessControl.FileSystemRights]::ReadData, [Security.AccessControl.AccessControlType]::Deny))
                            Set-Acl -LiteralPath $path -AclObject $denied
                            $expected = 'JournalAccessDenied'
                        }
                    }
                    $null = Assert-CapRejects { Read-CapJournalSnapshot $c.State } $expected
                    $executed++
                } finally { if ($null -ne $originalAcl) { Set-Acl -LiteralPath $path -AclObject $originalAcl } }
            }
            Assert-CapTest ($executed -eq 12) 'Immediate-fault inventory was empty or incomplete.'
            return @{ subcases = $executed; mode = 'Actual owned filesystem inputs/ACL, no reader endpoint mock.' }
        }
        Invoke-CapTest 'final manifest and release bind the exact quiescent terminal journal' {
            $executed = 0
            foreach ($outcome in @('COMPLETE','FAILED')) {
                $f = New-JournalTerminalFixture ('terminal-' + $outcome) $outcome
                $proof = Read-CapJournalFinalProof $f.Context.State $f.Context.Root $f.Record
                Assert-CapTest ($proof.Manifest.status -ceq $outcome) 'Failed manifest was accepted as COMPLETE.'
                $null = Assert-CapRejects { Read-CapJournalFinalRecord ($f.Line + "`n" + $f.Line) $f.Context.Binding } 'JournalFinalRecord'
                $null = Assert-CapRejects { Read-CapJournalFinalRecord ($f.Line + "`nAFTER") $f.Context.Binding } 'JournalFinalRecord'
                $null = Assert-CapRejects { Read-CapJournalFinalRecord 'ordinary log only' $f.Context.Binding } 'JournalFinalRecord'
                $null = Assert-CapRejects { Read-CapJournalFinalRecord 'CAP_JOURNAL_FINAL_V2 partial!' $f.Context.Binding } 'JournalFinalRecord'
                $foreign = $f.Context.Binding.PSObject.Copy()
                $foreign.leaseId = [guid]::NewGuid().ToString()
                $null = Assert-CapRejects { Read-CapJournalFinalRecord $f.Line $foreign } 'JournalFinalRecord'
                $wrongHash = $f.Record.PSObject.Copy()
                $wrongHash.manifest = $f.Record.manifest.PSObject.Copy()
                $wrongHash.manifest.sha256 = '0' * 64
                $null = Assert-CapRejects { Read-CapJournalFinalProof $f.Context.State $f.Context.Root $wrongHash } 'JournalHash'
                $null = Assert-CapRejects { Publish-CapJournalSnapshot $f.Context.State Progress ([pscustomobject]@{ entries = @() }) } 'JournalPublicationClosed'
                $executed += 8
            }
            $f = New-JournalTerminalFixture 'post-terminal'
            [IO.File]::Copy((Join-Path $f.Context.State.Directory '000002.json'), (Join-Path $f.Context.State.Directory '000003.json'))
            $null = Assert-CapRejects { Read-CapJournalFinalProof $f.Context.State $f.Context.Root $f.Record } 'PostTerminalPublication'
            $executed++
            $f = New-JournalTerminalFixture 'sealed-gap'
            [IO.File]::Move((Join-Path $f.Context.State.Directory '000001.json'), (Join-Path $f.Context.Root 'fault-removed-first.json'))
            $null = Assert-CapRejects { Read-CapJournalFinalProof $f.Context.State $f.Context.Root $f.Record } 'SequenceGap'
            $executed++
            $classification = & {
                $fixture = New-JournalTerminalFixture 'valid-cleanup-invalid-job' -InvalidJobContract
                $journalProof = Read-CapJournalFinalProof $fixture.Context.State $fixture.Context.Root $fixture.Record
                $boundWorkerManifest = $journalProof.Manifest
                $rehearsal = $true
                $ExecutionMode = 'NO_DESKTOP_REAL_LAUNCH_REHEARSAL'
                $ast = [Management.Automation.Language.Parser]::ParseInput(
                    [IO.File]::ReadAllText($supervisorPath), [ref]$null, [ref]$null)
                foreach ($functionName in @('Assert-CapWorkerManifest','Get-CapWorkerJobFailure')) {
                    $definition = $ast.Find({ param($node)
                        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Name -ceq $functionName
                    }, $true)
                    Assert-CapTest ($null -ne $definition) "Actual job assertion function missing: $functionName"
                    . ([scriptblock]::Create($definition.Extent.Text))
                }
                $statusGuards = @($ast.FindAll({ param($node)
                    $node -is [Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses[0].Item1.Extent.Text.Contains('$workerLaunchAttempted') -and
                    $node.Clauses[0].Item1.Extent.Text.Contains('$cleanupFailures.Count -eq 0') -and
                    $node.Extent.Text.Contains("'FAILED_ZERO_SURVIVORS'")
                }, $true))
                Assert-CapTest ($statusGuards.Count -eq 1) 'Actual release status expression missing or duplicated.'
                $actualStatus = [scriptblock]::Create($statusGuards[0].Extent.Text)
                $workerLaunchAttempted = $true
                $cleanupFailures = [Collections.Generic.List[string]]::new()
                $survivors = [Collections.Generic.List[object]]::new()
                $cleanupProven = $true
                $primaryFailure = Get-CapWorkerJobFailure
                Assert-CapTest ($null -ne $primaryFailure -and
                    $primaryFailure.Exception.Message.Contains('Offline real-launch manifest is incomplete') -and
                    $cleanupFailures.Count -eq 0) 'Invalid job assertion was lost or misclassified as cleanup failure.'
                $jobStatus = & $actualStatus
                Assert-CapTest ($jobStatus -ceq 'FAILED_ZERO_SURVIVORS') 'Valid cleanup plus failed job did not preserve primary failure status.'
                $invalid = $fixture.Record.PSObject.Copy()
                $invalid.manifest = $fixture.Record.manifest.PSObject.Copy()
                $invalid.manifest.sha256 = '0' * 64
                $bindingFailure = Assert-CapRejects {
                    Read-CapJournalFinalProof $fixture.Context.State $fixture.Context.Root $invalid
                } 'JournalHash'
                $cleanupFailures.Add($bindingFailure)
                $cleanupProven = $false
                $bindingStatus = & $actualStatus
                Assert-CapTest ($bindingStatus -ceq 'CLEANUP_UNPROVEN') 'Invalid cleanup binding became an ordinary failed job.'
                return [pscustomobject]@{
                    label = 'valid-cleanup-invalid-job versus invalid-cleanup-binding'
                    validCleanupInvalidJob = $jobStatus
                    invalidCleanupBinding = $bindingStatus
                    mode = 'Actual source assertion/status expressions and real bound-file negatives; no product/GUI or native worker mock.'
                }
            }
            $executed += 2
            Assert-CapTest ($executed -eq 20) 'Terminal positive/negative subcase inventory differs.'
            return @{ subcases = $executed; jobCleanupClassification = $classification
                mode = 'Exact file/data binding controls; real worker quiescence is tested by actual capture commands.' }
        }
        Invoke-CapTest 'journal proof inventory retains publications and refuses residual temporary artifacts' {
            $f = New-JournalTerminalFixture 'retention'
            $before = @(Get-ChildItem -LiteralPath $f.Context.State.Directory -File | ForEach-Object { $_.Name })
            $null = Read-CapJournalFinalProof $f.Context.State $f.Context.Root $f.Record
            Assert-CapTest (@(Get-ChildItem -LiteralPath $f.Context.State.Directory -File).Count -eq 2) 'Published evidence was deleted.'
            $tmp = Join-Path $f.Context.Root 'legacy-seed.json.tmp'
            [IO.File]::WriteAllText($tmp, 'retained negative diagnostic')
            $null = Assert-CapRejects { Assert-CapNoWorkerTransientArtifacts @($f.Context.Root) } 'ResidualJournalArtifact'
            Assert-CapTest ([IO.File]::Exists($tmp) -and $before.Count -eq 2) 'Residual diagnostic was deleted to pass.'
            return @{ subcases = 2; retainedPublications = $before; residualPreserved = $true }
        }
        Invoke-CapTest 'journal native bindings match the exact job-ownership declaration contract' {
            $expected = @(
                'GraphCodeUiaGateState|PostMessage|user32.dll|PostMessageA',
                'GraphCodeUiaGateState|EnumWindows|user32.dll|EnumWindows',
                'GraphCodeUiaGateState|GetWindowThreadProcessId|user32.dll|GetWindowThreadProcessId',
                'GraphCodeUiaGateState|GetClassName|user32.dll|GetClassNameW',
                'CapNative|NtQueryInformationProcess|ntdll.dll|NtQueryInformationProcess',
                'CapNative|NtQueryInformationProcess|ntdll.dll|NtQueryInformationProcess',
                'CapNative|CommandLineToArgvW|shell32.dll|CommandLineToArgvW',
                'CapNative|LocalFree|kernel32.dll|LocalFree',
                'CapNative|GetProcessId|kernel32.dll|GetProcessId',
                'CapNative|GetProcessTimes|kernel32.dll|GetProcessTimes',
                'CapNative|QueryFullProcessImageNameW|kernel32.dll|QueryFullProcessImageNameW',
                'CapNative|WaitForSingleObject|kernel32.dll|WaitForSingleObject',
                'CapNative|TerminateProcess|kernel32.dll|TerminateProcess',
                'CapNative|WaitNamedPipeW|kernel32.dll|WaitNamedPipeW',
                'CapNative|GetWindowThreadProcessId|user32.dll|GetWindowThreadProcessId',
                'CapNative|GetWindowRect|user32.dll|GetWindowRect',
                'CapNative|GetClientRect|user32.dll|GetClientRect',
                'CapNative|GetDpiForWindow|user32.dll|GetDpiForWindow',
                'CapNative|SetWindowPos|user32.dll|SetWindowPos',
                'CapNative|PrintWindow|user32.dll|PrintWindow',
                'CapProcessJob|CreateJobObjectW|kernel32.dll|CreateJobObjectW',
                'CapProcessJob|SetInformationJobObject|kernel32.dll|SetInformationJobObject',
                'CapProcessJob|QueryInformationJobObject|kernel32.dll|QueryInformationJobObject',
                'CapProcessJob|QueryInformationJobObject|kernel32.dll|QueryInformationJobObject',
                'CapProcessJob|IsProcessInJob|kernel32.dll|IsProcessInJob',
                'CapProcessJob|AssignProcessToJobObject|kernel32.dll|AssignProcessToJobObject',
                'CapProcessJob|TerminateJobObject|kernel32.dll|TerminateJobObject',
                'CapProcessJob|CloseHandle|kernel32.dll|CloseHandle',
                'CapProcessJob|GetStdHandle|kernel32.dll|GetStdHandle',
                'CapProcessJob|SetHandleInformation|kernel32.dll|SetHandleInformation'
            )
            $actual = @(Test-CapNativeBindings | ForEach-Object { "$($_.Type)|$($_.Method)|$($_.Library)|$($_.EntryPoint)" })
            Assert-CapTest ($actual.Count -eq 30 -and @(Compare-Object $expected $actual).Count -eq 0) 'Exact static30 export contract differs.'
            return @{ subcases = 30; evidence = 'API export resolution only, no native window or GUI action.' }
        }
        Invoke-CapTest 'legacy mutable seed journal proof is refused and exact numbered terminal proof is accepted' {
            $f = New-JournalTerminalFixture 'seed-reference'
            $legacy = [pscustomobject]@{ processJournalPath = (Join-Path $f.Context.Root 'process-journal.json') }
            $null = Assert-CapRejects { Read-CapNumberedSeedProof $f.Context.Root $legacy ('A' * 64) `
                $sourceHashesBefore[$modulePath] $sourceHashesBefore[$workerPath] ([DateTime]::UtcNow.AddMinutes(1)) } 'LegacyJournalProtocol'
            $reference = [pscustomobject]@{ protocolVersion = 2L; directory = $f.Context.State.Directory
                outputDirectory = $f.Context.Root; binding = $f.Context.Binding; record = $f.Record }
            $proof = Read-CapNumberedSeedProof $f.Context.Root $reference ('A' * 64) `
                $sourceHashesBefore[$modulePath] $sourceHashesBefore[$workerPath] ([DateTime]::UtcNow.AddMinutes(1))
            Assert-CapTest ($proof.Manifest.status -ceq 'COMPLETE') 'Exact new seed reference was not verified.'
            return @{ subcases = 2; actualLegacyRefused = $true; exactReferenceVerified = $true }
        }
    }
function Invoke-CapBoundedChild {
    param([string]$FilePath, [string[]]$Arguments, [string]$Directory, [string]$Role, [int]$Seconds = 45,
        [hashtable]$Environment = @{})
    $run = Start-CapManagedProcess -FilePath $FilePath -ArgumentList $Arguments `
        -WorkingDirectory $Directory -Role $Role -Environment $Environment
    try {
        $wait = Wait-CapManagedProcess -Run $run -DeadlineUtc ([DateTime]::UtcNow.AddSeconds($Seconds))
        if ($wait.State -ne 'Exited') { throw "Test child timed out: $Role" }
        Assert-CapTest ($run.StdoutTask.Wait(2000) -and $run.StderrTask.Wait(2000)) "Test child EOF missing: $Role"
        return [pscustomobject]@{
            exitCode = $wait.ExitCode; stdout = [string]$run.StdoutTask.Result; stderr = [string]$run.StderrTask.Result
            pid = $run.Identity.Pid; creationFileTimeUtc = $run.Identity.CreationFileTimeUtc
            executable = $run.Identity.ExpectedImagePath; kernelExited = [CapNative]::IsExited($run.Identity.Process.Handle, $run.Identity.Pid)
            heldKernelHandle = $run.Identity.Process.Handle.ToInt64()
            stdinRedirected = $run.StartInfo.RedirectStandardInput
        }
    } finally {
        if (-not [CapNative]::IsExited($run.Identity.Process.Handle, $run.Identity.Pid)) {
            $null = Stop-CapManagedProcess -Identity $run.Identity -TimeoutMilliseconds 5000
        }
        $run.Identity.Process.Dispose()
    }
}

function Read-CapCompileLogSnapshot {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Text = ''; Sha256 = $null; Bytes = $null; Length = $null; ObservedUtc = $null }
    }

    $fileStream = $null
    $snapshot = $null
    try {
        $fileStream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        )
        $snapshot = [IO.MemoryStream]::new()
        $fileStream.CopyTo($snapshot)
        $bytes = $snapshot.ToArray()
        $observedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    } finally {
        if ($null -ne $snapshot) { $snapshot.Dispose() }
        if ($null -ne $fileStream) { $fileStream.Dispose() }
    }

    $textStream = [IO.MemoryStream]::new($bytes)
    $reader = $null
    try {
        $reader = [IO.StreamReader]::new($textStream, [Text.Encoding]::UTF8, $true, 1024, $true)
        $text = $reader.ReadToEnd()
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $textStream.Dispose()
    }

    $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $hashAlgorithm.ComputeHash($bytes)
    } finally {
        $hashAlgorithm.Dispose()
    }

    return [pscustomobject]@{
        Text = $text
        Sha256 = ([BitConverter]::ToString($digest)).Replace('-', '')
        Bytes = $bytes
        Length = [long]$bytes.Length
        ObservedUtc = $observedUtc
    }
}

function Publish-CapCompileLogSnapshot {
    param([string]$RawPath, [string]$Path, $Snapshot)
    if (-not [IO.File]::Exists($RawPath) -or $null -eq $Snapshot.Bytes -or $null -eq $Snapshot.Length -or
        -not $Snapshot.ObservedUtc -or $Snapshot.Sha256 -cnotmatch '\A[A-F0-9]{64}\z') {
        throw 'CompileLogSnapshotUnproven: a positively present raw file and captured byte array are required.'
    }
    $bytes = [byte[]]$Snapshot.Bytes
    if ($bytes.Length -ne $Snapshot.Length -or
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $Snapshot.Sha256) {
        throw 'CompileLogSnapshotUnproven: captured bytes do not match their original snapshot digest.'
    }
    $stream = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -cne $Snapshot.Sha256) {
        throw 'CompileLogSnapshotUnproven: published snapshot bytes differ.'
    }
    return [pscustomobject]@{ rawPath = $RawPath; publishedPath = $Path; sha256 = $Snapshot.Sha256
        length = [long]$bytes.Length; observedUtc = $Snapshot.ObservedUtc; rawEof = 'UNPROVEN' }
}

function New-CapHarmlessTarget {
    $fixture = Join-Path $scratch 'fixture'
    $null = New-Item -ItemType Directory -Path $fixture
    # No GUI, backend, network or user data; descendants require the private app-child fixture gate.
    $source = @'
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
int wmain(int argc, wchar_t **argv) {
    char behavior[64] = {0};
    wchar_t output[32768] = {0}, path[32768] = {0};
    int i, c;
    if (GetEnvironmentVariableW(L"CAP_APP_CHILD_IMAGE", path, 32768) != 0) {
        if (argc > 1 && wcscmp(argv[1], L"--cap-app-parent") == 0) {
            STARTUPINFOW startup = {0};
            PROCESS_INFORMATION child = {0};
            FILETIME creation, exitTime, kernel, user;
            ULARGE_INTEGER stamp;
            wchar_t tail[2048] = {0}, command[32768] = {0}, receipt[32768] = {0}, pending[32768] = {0};
            char live[8] = {0};
            FILE *file = NULL;
            if (!FreeConsole()) return 87;
            while ((c = getchar()) != EOF) { (void)c; }
            if (GetEnvironmentVariableW(L"CAP_APP_CHILD_ARGUMENTS", tail, 2048) == 0 ||
                GetEnvironmentVariableW(L"CAP_APP_CHILD_RECEIPT", receipt, 32768) == 0) return 81;
            if (swprintf_s(command, 32768, L"\"%ls\" %ls", path, tail) < 0) return 82;
            startup.cb = sizeof(startup);
            startup.dwFlags = STARTF_USESTDHANDLES;
            startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
            startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
            startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
            if (!CreateProcessW(path, command, NULL, NULL, TRUE, CREATE_NO_WINDOW,
                NULL, NULL, &startup, &child)) return 83;
            if (!GetProcessTimes(child.hProcess, &creation, &exitTime, &kernel, &user)) return 84;
            stamp.LowPart = creation.dwLowDateTime;
            stamp.HighPart = creation.dwHighDateTime;
            if (swprintf_s(pending, 32768, L"%ls.pending", receipt) < 0 ||
                _wfopen_s(&file, pending, L"wb") != 0 || file == NULL) return 85;
            fprintf(file, "{\"pid\":%lu,\"creationFileTimeUtc\":%llu}", child.dwProcessId, stamp.QuadPart);
            if (fclose(file) != 0 || !MoveFileW(pending, receipt)) return 86;
            CloseHandle(child.hThread);
            CloseHandle(child.hProcess);
            puts("CAP_APP_PARENT_EXIT");
            fflush(stdout);
            if (GetEnvironmentVariableA("CAP_APP_PARENT_LIVE", live, 8) != 0 && strcmp(live, "1") == 0)
                Sleep(30000);
            return 0;
        }
        puts("CAP_APP_CHILD_READY");
        fputs("CAP_APP_CHILD_STDERR\n", stderr);
        fflush(stdout); fflush(stderr);
        Sleep(30000);
        return 0;
    }
    GetEnvironmentVariableA("CAP_REHEARSAL_BEHAVIOR", behavior, 64);
    puts("CAP_READY");
    printf("CAP_ARGC:%d\n", argc - 1);
    for (i = 1; i < argc; ++i) {
        size_t j;
        printf("CAP_ARG_%d:", i - 1);
        for (j = 0; argv[i][j] != 0; ++j) printf("%04X", (unsigned int)argv[i][j]);
        puts("");
    }
    fflush(stdout);
    while ((c = getchar()) != EOF) { (void)c; }
    puts("CAP_STDIN_EOF");
    fputs("CAP_STDERR_EOF\n", stderr);
    fflush(stdout); fflush(stderr);
    if (strcmp(behavior, "trace-readonly") == 0) {
        if (GetEnvironmentVariableW(L"CAP_REHEARSAL_OUTPUT", output, 32768) == 0) return 96;
        if (swprintf_s(path, 32768, L"%ls\\supervisor-calls.jsonl", output) < 0) return 97;
        if (!SetFileAttributesW(path, FILE_ATTRIBUTE_READONLY)) return 98;
        return 23;
    }
    if (strcmp(behavior, "primary-cleanup") == 0 || strcmp(behavior, "receipt-block") == 0) {
        if (GetEnvironmentVariableW(L"CAP_REHEARSAL_OUTPUT", output, 32768) == 0) return 93;
        if (swprintf_s(path, 32768, L"%ls\\%ls", output,
            strcmp(behavior, "receipt-block") == 0 ? L"lease-release.json" : L"supervisor-worker-stdout.log") < 0) return 94;
        if (!CreateDirectoryW(path, NULL)) return 95;
        return 23;
    }
    if (strcmp(behavior, "timeout") == 0) Sleep(30000);
    return strcmp(behavior, "nonzero") == 0 ? 23 : 0;
}
'@
    $sourcePath = Join-Path $fixture 'capture-target.c'
    [IO.File]::WriteAllText($sourcePath, $source, [Text.UTF8Encoding]::new($false))
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        throw 'Existing MSVC discovery is unavailable; this offline suite does not install a compiler.'
    }
    $discovery = Invoke-CapBoundedChild -FilePath $vswhere -Arguments @(
        '-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '-property', 'installationPath'
    ) -Directory $fixture -Role 'fixture-compiler-discovery'
    Assert-CapTest ($discovery.exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($discovery.stdout)) 'Existing MSVC was not found.'
    $installation = $discovery.stdout.Trim()
    $vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
    $version = [IO.File]::ReadAllText((Join-Path $installation 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt')).Trim()
    $compiler = Join-Path $installation "VC\Tools\MSVC\$version\bin\Hostx64\x64\cl.exe"
    $exe = Join-Path $fixture 'capture-target.exe'
    $object = Join-Path $fixture 'capture-target.obj'
    $compileStdout = Join-Path $fixture 'compile-stdout.log'
    $compileStderr = Join-Path $fixture 'compile-stderr.log'
    $compileStdoutRaw = Join-Path $fixture 'compile-stdout.raw.log'
    $compileStderrRaw = Join-Path $fixture 'compile-stderr.raw.log'
    $command = 'call "{0}" -vcvars_ver={1} >nul && "{2}" /nologo /W4 /WX /O2 /utf-8 /Fe:"{3}" /Fo:"{5}" "{4}" /link /SUBSYSTEM:CONSOLE' -f $vcvars, $version, $compiler, $exe, $sourcePath, $object
    # Redirect the whole compile group's stdout/stderr to owned files so the real
    # compiler and any toolchain telemetry helpers it spawns inherit file handles,
    # never the module's redirected pipe. Only the short-lived cmd.exe then holds
    # that pipe, so it reaches bounded EOF promptly on exit. This is a fixture setup
    # robustness fix; it does not touch any runtime/kernel/EOF/release guard.
    $redirectedCommand = '({0}) > "{1}" 2> "{2}"' -f $command, $compileStdoutRaw, $compileStderrRaw
    [IO.File]::WriteAllText((Join-Path $fixture 'compile.cmd'), "@echo off`r`n$redirectedCommand`r`nexit /b %errorlevel%`r`n", [Text.UTF8Encoding]::new($false))
    $compilerEnvironment = @{ PATH = (Split-Path -Parent $vswhere) + ';' + $env:PATH; VSCMD_SKIP_SENDTELEMETRY = '1' }
    foreach ($key in @('VSCMD_VER', '__VSCMD_PREINIT_PATH', 'VSINSTALLDIR', 'VCINSTALLDIR',
        'VCToolsInstallDir', 'VCToolsVersion', 'WindowsSdkDir', 'WindowsSDKVersion', 'INCLUDE', 'LIB', 'LIBPATH')) {
        $compilerEnvironment[$key] = ''
    }
    $build = Invoke-CapBoundedChild -FilePath $env:ComSpec -Arguments @('/d', '/c', '.\compile.cmd') `
        -Directory $fixture -Role 'harmless-fixture-compile' -Seconds 90 -Environment $compilerEnvironment
    # Preserve the actual compiler exit before reading the owned compile logs.
    $compilerExitCode = $build.exitCode
    $compileStdoutSnapshot = Read-CapCompileLogSnapshot -Path $compileStdoutRaw
    $compileStderrSnapshot = Read-CapCompileLogSnapshot -Path $compileStderrRaw
    $publishedStdout = Publish-CapCompileLogSnapshot $compileStdoutRaw $compileStdout $compileStdoutSnapshot
    $publishedStderr = Publish-CapCompileLogSnapshot $compileStderrRaw $compileStderr $compileStderrSnapshot
    $compileStdoutText = $compileStdoutSnapshot.Text
    $compileStderrText = $compileStderrSnapshot.Text
    Assert-CapTest ($compilerExitCode -eq 0 -and (Test-Path -LiteralPath $exe -PathType Leaf)) `
        "Harmless target compilation failed (not launch evidence): $compileStdoutText $compileStderrText"
    $provenance = [ordered]@{
        compiler = $compiler; compilerVersion = (Get-Item -LiteralPath $compiler).VersionInfo.FileVersion
        compilerSha256 = (Get-FileHash -LiteralPath $compiler -Algorithm SHA256).Hash
        compilerCommand = $command; compilerExitCode = $compilerExitCode
        compileStdoutLog = $compileStdout; compileStderrLog = $compileStderr
        compileStdoutSha256 = $compileStdoutSnapshot.Sha256
        compileStderrSha256 = $compileStderrSnapshot.Sha256
        source = $sourcePath; sourceSha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        executable = $exe; executableSha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
        object = $object; objectSha256 = (Get-FileHash -LiteralPath $object -Algorithm SHA256).Hash
        compileProcess = $build
        compileLogSnapshots = @($publishedStdout,$publishedStderr)
    }
    $provenance | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixture 'provenance.json') -Encoding utf8NoBOM
    return [pscustomobject]$provenance
}

function New-CapCimRaceTarget {
    # A harmless console child that optionally zeroes its OWN PEB command line
    # (self only), so Win32_Process.CommandLine reads empty while the kernel still
    # reports it live, and blocks on a release file the test owns (barrier). This
    # deterministically produces a live-incomplete owned child without any mock.
    $fixture = Join-Path $scratch 'cim-race-fixture'
    $null = New-Item -ItemType Directory -Path $fixture
    $source = @'
#include <windows.h>
#include <winternl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void clear_own_command_line(void) {
    PPEB peb = (PPEB)NtCurrentTeb()->ProcessEnvironmentBlock;
    if (peb == NULL || peb->ProcessParameters == NULL) return;
    peb->ProcessParameters->CommandLine.Length = 0;
    peb->ProcessParameters->CommandLine.MaximumLength = 0;
    peb->ProcessParameters->CommandLine.Buffer = NULL;
}

int wmain(void) {
    char behavior[64] = {0};
    wchar_t releaseFile[32768] = {0};
    int i;
    GetEnvironmentVariableA("CAP_CIM_BEHAVIOR", behavior, (DWORD)sizeof(behavior));
    if (strstr(behavior, "clearcmd") != NULL) clear_own_command_line();
    puts("CAP_READY");
    fflush(stdout);
    if (strstr(behavior, "fileblock") != NULL) {
        /* Barrier: stay live until the owning test creates the release file. */
        if (GetEnvironmentVariableW(L"CAP_CIM_RELEASE_FILE", releaseFile, 32768) == 0) return 91;
        for (i = 0; i < 1200; ++i) {
            if (GetFileAttributesW(releaseFile) != INVALID_FILE_ATTRIBUTES) break;
            Sleep(50);
        }
    }
    fputs("CAP_STDERR_EOF\n", stderr);
    fflush(stderr);
    return 0;
}
'@
    $sourcePath = Join-Path $fixture 'cim-race-target.c'
    [IO.File]::WriteAllText($sourcePath, $source, [Text.UTF8Encoding]::new($false))
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        throw 'Existing MSVC discovery is unavailable; this offline suite does not install a compiler.'
    }
    $discovery = Invoke-CapBoundedChild -FilePath $vswhere -Arguments @(
        '-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '-property', 'installationPath'
    ) -Directory $fixture -Role 'cim-race-compiler-discovery'
    Assert-CapTest ($discovery.exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($discovery.stdout)) 'Existing MSVC was not found.'
    $installation = $discovery.stdout.Trim()
    $vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
    $version = [IO.File]::ReadAllText((Join-Path $installation 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt')).Trim()
    $compiler = Join-Path $installation "VC\Tools\MSVC\$version\bin\Hostx64\x64\cl.exe"
    $exe = Join-Path $fixture 'cim-race-target.exe'
    $object = Join-Path $fixture 'cim-race-target.obj'
    $compileStdout = Join-Path $fixture 'compile-stdout.log'
    $compileStderr = Join-Path $fixture 'compile-stderr.log'
    $compileStdoutRaw = Join-Path $fixture 'compile-stdout.raw.log'
    $compileStderrRaw = Join-Path $fixture 'compile-stderr.raw.log'
    $command = 'call "{0}" -vcvars_ver={1} >nul && "{2}" /nologo /W3 /O2 /utf-8 /Fe:"{3}" /Fo:"{5}" "{4}" /link /SUBSYSTEM:CONSOLE' -f $vcvars, $version, $compiler, $exe, $sourcePath, $object
    # Same owned-file redirection as New-CapHarmlessTarget: the compiler and any
    # telemetry helpers inherit file handles, so only the short-lived cmd.exe holds
    # the module's redirected pipe and it reaches bounded EOF on exit.
    $redirectedCommand = '({0}) > "{1}" 2> "{2}"' -f $command, $compileStdoutRaw, $compileStderrRaw
    [IO.File]::WriteAllText((Join-Path $fixture 'compile.cmd'), "@echo off`r`n$redirectedCommand`r`nexit /b %errorlevel%`r`n", [Text.UTF8Encoding]::new($false))
    $compilerEnvironment = @{ PATH = (Split-Path -Parent $vswhere) + ';' + $env:PATH; VSCMD_SKIP_SENDTELEMETRY = '1' }
    foreach ($key in @('VSCMD_VER', '__VSCMD_PREINIT_PATH', 'VSINSTALLDIR', 'VCINSTALLDIR',
        'VCToolsInstallDir', 'VCToolsVersion', 'WindowsSdkDir', 'WindowsSDKVersion', 'INCLUDE', 'LIB', 'LIBPATH')) {
        $compilerEnvironment[$key] = ''
    }
    $build = Invoke-CapBoundedChild -FilePath $env:ComSpec -Arguments @('/d', '/c', '.\compile.cmd') `
        -Directory $fixture -Role 'cim-race-fixture-compile' -Seconds 90 -Environment $compilerEnvironment
    # Preserve the actual compiler exit before reading the owned compile logs.
    $compilerExitCode = $build.exitCode
    $compileStdoutSnapshot = Read-CapCompileLogSnapshot -Path $compileStdoutRaw
    $compileStderrSnapshot = Read-CapCompileLogSnapshot -Path $compileStderrRaw
    $publishedStdout = Publish-CapCompileLogSnapshot $compileStdoutRaw $compileStdout $compileStdoutSnapshot
    $publishedStderr = Publish-CapCompileLogSnapshot $compileStderrRaw $compileStderr $compileStderrSnapshot
    $compileStdoutText = $compileStdoutSnapshot.Text
    $compileStderrText = $compileStderrSnapshot.Text
    Assert-CapTest ($compilerExitCode -eq 0 -and (Test-Path -LiteralPath $exe -PathType Leaf)) `
        "CIM race target compilation failed (not launch evidence): $compileStdoutText $compileStderrText"
    $provenance = [pscustomobject]@{
        executable = $exe
        source = $sourcePath
        sourceSha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        executableSha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
        object = $object; objectSha256 = (Get-FileHash -LiteralPath $object -Algorithm SHA256).Hash
        compiler = $compiler; compilerSha256 = (Get-FileHash -LiteralPath $compiler -Algorithm SHA256).Hash
        compilerCommand = $command; compilerExitCode = $compilerExitCode; compileProcess = $build
        compileStdoutLog = $compileStdout; compileStderrLog = $compileStderr
        compileStdoutSha256 = $compileStdoutSnapshot.Sha256; compileStderrSha256 = $compileStderrSnapshot.Sha256
        compileLogSnapshots = @($publishedStdout,$publishedStderr)
    }
    $provenance | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $fixture 'provenance.json') -Encoding utf8NoBOM
    return $provenance
}

function Get-CapFixtureArtifactNames {
    return @(
        'fixture\capture-target.c','fixture\capture-target.exe','fixture\capture-target.obj',
        'fixture\provenance.json','fixture\compile.cmd','fixture\compile-stdout.log','fixture\compile-stderr.log',
        'cim-race-fixture\cim-race-target.c','cim-race-fixture\cim-race-target.exe','cim-race-fixture\cim-race-target.obj',
        'cim-race-fixture\provenance.json','cim-race-fixture\compile.cmd',
        'cim-race-fixture\compile-stdout.log','cim-race-fixture\compile-stderr.log'
    )
}

function Read-CapPrebuiltFixtures {
    param([string]$ManifestPath, [string]$ExpectedSha256)
    if (-not $ManifestPath -or $ExpectedSha256 -cnotmatch '\A[A-F0-9]{64}\z') {
        throw 'PrebuiltFixtureRequired: suite cannot compile or fall back inside the suite job.'
    }
    $directory = Split-Path -Parent ([IO.Path]::GetFullPath($ManifestPath))
    if ([IO.Path]::GetFileName($ManifestPath) -cne 'fixtures.json') { throw 'PrebuiltFixtureIdentity: unexpected manifest filename.' }
    $manifest = Read-CapBoundJson -Root $directory -Reference ([pscustomobject]@{ path = $ManifestPath; sha256 = $ExpectedSha256 })
    Assert-CapDataRecord $manifest @{ schemaVersion = [long]; scenario = [string]; sources = [pscustomobject]; files = [array] } 'Prebuilt fixtures'
    if ($manifest.schemaVersion -ne 1 -or $manifest.scenario -cne 'UI_CAPTURE_HARMLESS_AND_CIM_RACE_V1') {
        throw 'PrebuiltFixtureIdentity: unsupported fixture recipe.'
    }
    foreach ($path in @($modulePath,$supervisorPath,$workerPath,$PSCommandPath)) {
        $name = [IO.Path]::GetFileName($path)
        if ($manifest.sources.$name -cne $sourceHashesBefore[$path]) { throw 'PrebuiltFixtureSource: frozen control bytes differ.' }
    }
    $expected = @(Get-CapFixtureArtifactNames)
    if ($manifest.files.Count -ne $expected.Count) { throw 'PrebuiltFixtureInventory: incomplete or extra artifacts.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in $manifest.files) {
        Assert-CapDataRecord $file @{ name = [string]; sha256 = [string]; length = [long] } 'Prebuilt artifact'
        if ($file.name -cnotin $expected -or -not $seen.Add($file.name) -or
            $file.sha256 -cnotmatch '\A[A-F0-9]{64}\z' -or $file.length -lt 0) { throw 'PrebuiltFixtureInventory: foreign or duplicate artifact.' }
        $path = Assert-CapArtifactPath -Root $directory -Path (Join-Path $directory $file.name)
        $stream = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            if ($stream.Length -ne $file.length -or (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash -cne $file.sha256) {
                throw 'PrebuiltFixtureHash: artifact bytes differ.'
            }
        } finally { $stream.Dispose() }
    }
    $target = Get-Content -LiteralPath (Join-Path $directory 'fixture\provenance.json') -Raw | ConvertFrom-Json -DateKind String
    $race = Get-Content -LiteralPath (Join-Path $directory 'cim-race-fixture\provenance.json') -Raw | ConvertFrom-Json -DateKind String
    foreach ($pair in @(@($target,'fixture','capture-target'),@($race,'cim-race-fixture','cim-race-target'))) {
        $receipt = $pair[0]
        Assert-CapDataRecord $receipt @{ compilerExitCode = [long]; compiler = [string]
            compilerSha256 = [string]; compilerCommand = [string]; compileProcess = [pscustomobject] } 'Prebuilt compile provenance'
        Assert-CapDataRecord $receipt.compileProcess @{ pid = [long]; creationFileTimeUtc = [long]
            executable = [string]; heldKernelHandle = [long]; kernelExited = [bool]; exitCode = [long] } 'Held compile-command host'
        if ($receipt.compilerExitCode -ne 0 -or
            $receipt.compilerSha256 -cnotmatch '\A[A-F0-9]{64}\z' -or
            $receipt.compileProcess.pid -le 0 -or $receipt.compileProcess.creationFileTimeUtc -le 0 -or
            $receipt.compileProcess.heldKernelHandle -le 0 -or -not $receipt.compileProcess.kernelExited -or
            $receipt.compileProcess.exitCode -ne 0 -or
            $receipt.executable -ine (Join-Path $directory ($pair[1] + '\' + $pair[2] + '.exe')) -or
            $receipt.source -ine (Join-Path $directory ($pair[1] + '\' + $pair[2] + '.c')) -or
            $receipt.object -ine (Join-Path $directory ($pair[1] + '\' + $pair[2] + '.obj'))) {
            throw 'PrebuiltFixtureProvenance: compile outcome or exact fixture paths differ.'
        }
        foreach ($binding in @(@('executable','executableSha256'),@('source','sourceSha256'),@('object','objectSha256'),
            @('compileStdoutLog','compileStdoutSha256'),@('compileStderrLog','compileStderrSha256'))) {
            $path = Assert-CapArtifactPath -Root $directory -Path $receipt.($binding[0])
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $receipt.($binding[1])) {
                throw 'PrebuiltFixtureProvenance: recorded artifact digest differs.'
            }
        }
        if ($receipt.compileLogSnapshots -isnot [array] -or $receipt.compileLogSnapshots.Count -ne 2) {
            throw 'PrebuiltFixtureProvenance: two exact-byte compile-log snapshot records are required.'
        }
        foreach ($name in @('stdout','stderr')) {
            $published = Join-Path $directory ($pair[1] + '\compile-' + $name + '.log')
            $raw = Join-Path $directory ($pair[1] + '\compile-' + $name + '.raw.log')
            $snapshots = @($receipt.compileLogSnapshots | Where-Object publishedPath -IEQ $published)
            if ($snapshots.Count -ne 1) { throw 'PrebuiltFixtureProvenance: snapshot path binding differs.' }
            $snapshot = $snapshots[0]
            Assert-CapDataRecord $snapshot @{ rawPath = [string]; publishedPath = [string]; sha256 = [string]
                length = [long]; observedUtc = [string]; rawEof = [string] } 'Compile log snapshot'
            $null = Assert-CapArtifactPath -Root $directory -Path $snapshot.rawPath
            if ($snapshot.rawPath -ine $raw -or $snapshot.rawEof -cne 'UNPROVEN' -or
                -not [IO.File]::Exists($snapshot.rawPath) -or
                $snapshot.observedUtc -notmatch '(?i)(?:Z|[+-]\d{2}:\d{2})$' -or
                $snapshot.length -ne (Get-Item -LiteralPath $published).Length -or
                $snapshot.sha256 -cne (Get-FileHash -LiteralPath $published -Algorithm SHA256).Hash) {
                throw 'PrebuiltFixtureProvenance: snapshot byte/time identity differs or raw EOF was invented.'
            }
            $null = [DateTimeOffset]::Parse($snapshot.observedUtc,[Globalization.CultureInfo]::InvariantCulture)
        }
    }
    return [pscustomobject]@{ Target = $target; CimRace = $race; Manifest = $manifest; ManifestSha256 = $ExpectedSha256 }
}

function Write-CapPrebuiltFixtureManifest {
    $sources = [ordered]@{}
    foreach ($path in $sourceHashesBefore.Keys) { $sources[[IO.Path]::GetFileName($path)] = $sourceHashesBefore[$path] }
    $files = @(Get-CapFixtureArtifactNames | ForEach-Object {
        $path = Join-Path $scratch $_
        [pscustomobject]@{ name = $_; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash; length = [long](Get-Item -LiteralPath $path).Length }
    })
    $manifest = [ordered]@{ schemaVersion = 1; scenario = 'UI_CAPTURE_HARMLESS_AND_CIM_RACE_V1'; sources = $sources; files = $files }
    $path = Join-Path $scratch 'fixtures.json'
    Write-JournalContractJson $path $manifest
    return [pscustomobject]@{ path = $path; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash; files = $files }
}

function Invoke-CapAppChildCase {
    param(
        [string]$Name,
        [string]$Arguments,
        [string]$Refusal = '',
        [string]$ParentRole = 'graphcode-app-before-normal',
        [switch]$WrongImage,
        [switch]$WrongGeneration,
        [switch]$UnrelatedRoot,
        [switch]$AdvisoryParent,
        [switch]$LiveParent,
        [switch]$DiscoverBeforeCleanup,
        [switch]$DAdapter
    )
    $caseRoot = Join-Path $scratch ('app-children\' + $Name)
    $null = New-Item -ItemType Directory -Path (Join-Path $caseRoot 'runtime'),(Join-Path $caseRoot 'output'),(Join-Path $caseRoot 'journal')
    $childImage = Join-Path $caseRoot ('runtime\' + $(if ($WrongImage) { 'foreign.exe' } else { 'zmx.exe' }))
    Copy-Item -LiteralPath $target.executable -Destination $childImage
    $receiptPath = Join-Path $caseRoot 'child.json'
    . $workerPath -OwnedRoot $caseRoot -DefinitionsOnly
    $outputDirectory = Join-Path $caseRoot 'output'
    $job = [pscustomobject]@{ sceneAdapter = $(if ($DAdapter) { 'D_QUICK_CHAT_V1' } else { 'B_CANVAS_V1' })
        head = 'NO_DESKTOP_NATIVE_CHILD_FIXTURE'; base = 'NO_DESKTOP_NATIVE_CHILD_FIXTURE' }
    $auth = [pscustomobject]@{ leaseId = [guid]::NewGuid().ToString()
        supervisorSha256 = $sourceHashesBefore[$supervisorPath]; preflightReceiptSha256 = 'NOT_LIVE_PREFLIGHT' }
    $self = [Diagnostics.Process]::GetCurrentProcess()
    $run = $null
    $child = $null
    $ownedJob = [CapProcessJob]::Create()
    $detail = [ordered]@{ command = $Arguments; safetyJobEmpty = $false; finalStdoutEof = $false; finalStderrEof = $false }
    try {
        $selfIdentity = Get-CapProcessIdentity -Process $self -ExpectedImagePath $self.MainModule.FileName -Role 'app-child-test-owner'
        $binding = New-CapJournalBinding -RunId ([guid]::NewGuid().ToString()) -LeaseId ([guid]::NewGuid().ToString()) `
            -JobSha256 ('A' * 64) -ModuleSha256 $sourceHashesBefore[$modulePath] `
            -WorkerSha256 $sourceHashesBefore[$workerPath] -SupervisorSha256 $sourceHashesBefore[$supervisorPath] -Identity $selfIdentity
        $journalState = New-CapJournalState -Root $caseRoot -Directory (Join-Path $caseRoot 'journal') `
            -Binding $binding -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(2))
        $run = Start-CapManagedProcess -FilePath $target.executable -ArgumentList @('--cap-app-parent') `
            -WorkingDirectory $caseRoot -Role $ParentRole -HoldStdin -Environment @{
                CAP_APP_CHILD_IMAGE = $childImage; CAP_APP_CHILD_ARGUMENTS = $Arguments
                CAP_APP_CHILD_RECEIPT = $receiptPath; TEMP = $caseRoot; TMP = $caseRoot
                CAP_APP_PARENT_LIVE = $(if ($LiveParent) { '1' } else { '0' })
            }
        $runs.Add($run)
        [CapProcessJob]::Assign($ownedJob, $run.Identity.Process.Handle)
        $run.Identity.Process.StandardInput.Close()
        if ($LiveParent) {
            $spawn = Wait-JournalContractFile $receiptPath ([DateTime]::UtcNow.AddSeconds(5))
            Assert-CapTest (-not [CapNative]::IsExited($run.Identity.Process.Handle, $run.Identity.Pid)) `
                'Live-parent recovery fixture exited before cleanup.'
        } else {
            Assert-CapTest ($run.Identity.Process.WaitForExit(5000) -and $run.Identity.Process.ExitCode -eq 0) `
                'Real app-like parent did not spawn and exit zero after the assignment gate.'
            $spawn = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        }
        $child = [Diagnostics.Process]::GetProcessById([int]$spawn.pid)
        $childSnapshot = [CapNative]::Snapshot($child.Handle, $child.Id)
        Assert-CapTest (-not $childSnapshot.IsExited -and $childSnapshot.CreationFileTimeUtc -eq $spawn.creationFileTimeUtc -and
            [CapProcessJob]::Contains($ownedJob, $child.Handle)) 'Spawned child generation is not live inside the test-owned job.'
        Assert-CapTest (-not $run.StdoutTask.Wait(100) -and -not $run.StderrTask.Wait(100)) `
            'Fixture did not reproduce a real child retaining both app output pipes.'
        $detail.parentPid = $run.Identity.Pid
        $detail.parentCreationFileTimeUtc = $run.Identity.CreationFileTimeUtc
        $detail.childPid = $child.Id
        $detail.childCreationFileTimeUtc = $childSnapshot.CreationFileTimeUtc
        $detail.inheritedBothPipes = $true
        $detail.parentInitiallyLive = [bool]$LiveParent
        $app = New-CapAppRunRecord -Run $run -Phase before -SessionPrefix 'gc-cap-test-before-'
        Write-CapProcessJournal -Identity $run.Identity -Phase before
        if ($WrongGeneration) { $run.Identity.CreationFileTimeUtc++ }
        if ($AdvisoryParent) {
            $metadata = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($child.Id)" -ErrorAction Stop
            $advisory = [pscustomobject]@{
                ProcessId = $metadata.ProcessId; ParentProcessId = $selfIdentity.Pid; SessionId = $metadata.SessionId
                CreationDate = $metadata.CreationDate; ExecutablePath = $metadata.ExecutablePath; CommandLine = $metadata.CommandLine
            }
            $module = Get-Module UiCaptureDriver
            $other = $selfIdentity.PSObject.Copy()
            $other.Role = 'graphcode-app-before-normal'
            try {
                & $module {
                    param($Row)
                    if (Test-Path Function:Get-CimInstance) { throw 'Unexpected existing metadata test seam.' }
                    $script:CapAppChildAdvisoryRow = $Row
                    function script:Get-CimInstance {
                        param($ClassName, $Filter, $ErrorAction)
                        if ($ClassName -cne 'Win32_Process' -or $Filter -cnotin @(
                            "ProcessId = $($script:CapAppChildAdvisoryRow.ProcessId)",
                            "ParentProcessId = $($script:CapAppChildAdvisoryRow.ParentProcessId)"
                        )) { throw "Unexpected advisory-only metadata query: $ClassName $Filter" }
                        return $script:CapAppChildAdvisoryRow
                    }
                } $advisory
                $detail.refusal = Assert-CapRejects {
                    Get-CapOwnedDescendants -Roots @($other) -ZmxPath $childImage `
                        -CmdPath (Join-Path ([Environment]::SystemDirectory) 'cmd.exe') `
                        -ConhostPath (Join-Path ([Environment]::SystemDirectory) 'conhost.exe') `
                        -SessionName $app.SessionPrefix -CommandMarker $app.SessionPrefix -AllowGraphCodeRoot
                } 'does not match the saved parent generation/session'
                Assert-CapTest (-not [CapNative]::IsExited($child.Handle, $child.Id)) `
                    'Advisory metadata caused termination despite native parent mismatch.'
            } finally {
                & $module {
                    Remove-Item Function:Get-CimInstance -ErrorAction SilentlyContinue
                    Remove-Variable CapAppChildAdvisoryRow -Scope Script -ErrorAction SilentlyContinue
                }
            }
        } elseif ($UnrelatedRoot) {
            $other = $selfIdentity.PSObject.Copy()
            $other.Role = 'graphcode-app-before-normal'
            $found = @(Get-CapOwnedDescendants -Roots @($other) -ZmxPath (Join-Path $caseRoot 'runtime\zmx.exe') `
                -CmdPath (Join-Path ([Environment]::SystemDirectory) 'cmd.exe') `
                -ConhostPath (Join-Path ([Environment]::SystemDirectory) 'conhost.exe') `
                -SessionName $app.SessionPrefix -CommandMarker $app.SessionPrefix -AllowGraphCodeRoot)
            Assert-CapTest ($found.Count -eq 0 -and -not [CapNative]::IsExited($child.Handle, $child.Id)) `
                'A zmx child of a different held parent was adopted or terminated.'
        } elseif ($Refusal) {
            $message = Assert-CapRejects { Get-CapTreeForApp -AppRun $app } $Refusal
            Assert-CapTest (-not [CapNative]::IsExited($child.Handle, $child.Id) -and $descendantIdentities.Count -eq 0) `
                'Rejected child was mutated or registered as owned.'
            $detail.refusal = $message
        } else {
            if ($DiscoverBeforeCleanup) {
                $first = @(Get-CapTreeForApp -AppRun $app)
                $second = @(Get-CapTreeForApp -AppRun $app)
                Assert-CapTest ($first.Count -gt 0 -and $second.Count -eq $first.Count -and
                    [object]::ReferenceEquals($first[0], $second[0])) 'Repeated discovery discarded a held guarded generation.'
            }
            $null = Close-CapGraphCodeApp -AppRun $app -NormalExit
            Assert-CapTest ($cleanupFailures.Count -eq 0) ($cleanupFailures -join '; ')
            Assert-CapTest ($app.CleanupComplete -and [CapNative]::IsExited($child.Handle, $child.Id) -and
                $run.StdoutTask.IsCompletedSuccessfully -and $run.StderrTask.IsCompletedSuccessfully) `
                'Production app cleanup did not prove held child exit and both actual app stream EOFs.'
            $proof = @(Get-CapWorkerProcessReceipts)
            $clients = @($descendantIdentities | Where-Object Role -CEQ 'zmx-client')
            Assert-CapTest ($proof.Count -eq (1 + $descendantIdentities.Count) -and @($proof | Where-Object {
                -not $_.kernelExited -or -not $_.stdoutEof -or -not $_.stderrEof
            }).Count -eq 0 -and $clients.Count -eq 1 -and $clients[0].Pid -eq $child.Id -and
                @($descendantIdentities | Where-Object Role -CNotIn @('zmx-client','conpty-conhost')).Count -eq 0 -and
                $proof[1].streamOwnerPid -eq $run.Identity.Pid -and
                $proof[1].streamOwnerCreationFileTimeUtc -eq $run.Identity.CreationFileTimeUtc) `
                'Actual worker receipts do not bind the guarded client to its held app stream owner.'
            Assert-CapTest ($run.StdoutTask.Result.Contains('CAP_APP_CHILD_READY') -and
                $run.StderrTask.Result.Contains('CAP_APP_CHILD_STDERR')) 'Inherited app output was not actually drained.'
            $detail.receipts = $proof
        }
    } catch {
        $detail.primaryFailure = $_.Exception.ToString()
        throw
    } finally {
        try {
            [CapProcessJob]::Terminate($ownedJob)
            [CapProcessJob]::WaitForEmpty($ownedJob, 5000)
            $detail.safetyJobEmpty = [CapProcessJob]::Active($ownedJob) -eq 0
        } finally { [CapProcessJob]::Close($ownedJob) }
        if ($run) {
            $detail.finalStdoutEof = $run.StdoutTask.Wait(2000) -and $run.StdoutTask.IsCompletedSuccessfully
            $detail.finalStderrEof = $run.StderrTask.Wait(2000) -and $run.StderrTask.IsCompletedSuccessfully
        }
        foreach ($identity in $descendantIdentities) { $identity.Process.Dispose() }
        if ($child) { $child.Dispose() }
        if ($run) { $run.Identity.Process.Dispose() }
        $self.Dispose()
        Write-JournalContractJson (Join-Path $caseRoot 'ownership-evidence.json') $detail
        Assert-CapTest ($detail.safetyJobEmpty -and ($null -eq $run -or ($detail.finalStdoutEof -and $detail.finalStderrEof))) `
            'Test-owned safety job or inherited pipes remained unclosed.'
    }
    return $detail
}

function Invoke-CapAppChildContracts {
    Invoke-CapTest 'app seeded zmx attach child exits through guarded production cleanup with actual app EOF' {
        Invoke-CapAppChildCase 'seeded-attach' 'attach graphcode-11111111-1111-4111-8111-000000000001 --size 80x24'
    }
    Invoke-CapTest 'app zmx listing child exits through guarded production cleanup with actual app EOF' {
        Invoke-CapAppChildCase 'listing' 'ls'
    }
    Invoke-CapTest 'live app recovery stops only its guarded zmx tree and drains actual app EOF' {
        Invoke-CapAppChildCase 'live-parent' 'ls' -LiveParent -DiscoverBeforeCleanup
    }
    Invoke-CapTest 'app shell attach resize and kill use exact owned session arguments' {
        $session = 'graphcode-gc-cap-test-before--01234567-89ab-4cde-8fab-0123456789ab'
        return @(
            Invoke-CapAppChildCase 'shell-attach' "attach $session --size 80x24" -DiscoverBeforeCleanup
            Invoke-CapAppChildCase 'shell-resize' "resize $session 100x30"
            Invoke-CapAppChildCase 'shell-kill' "kill $session --force"
        )
    }
    Invoke-CapTest 'app zmx command gate refuses foreign sessions malformed options and daemon commands without mutation' {
        $bad = @(
            'attach graphcode-foreign --size 80x24',
            'attach graphcode-11111111-1111-4111-8111-000000000001-foreign --size 80x24',
            'ls graphcode-gc-cap-test-before--01234567-89ab-4cde-8fab-0123456789ab',
            'resize graphcode-11111111-1111-4111-8111-000000000001 invalid',
            'kill graphcode-11111111-1111-4111-8111-000000000001 graphcode-foreign --force',
            'run graphcode-gc-cap-test-before--01234567-89ab-4cde-8fab-0123456789ab',
            'attach graphcode-gc-cap-test-before--01234567-89ab-4cde-8fab-0123456789ab --size 0x24'
        )
        return @(for ($i = 0; $i -lt $bad.Count; $i++) {
            Invoke-CapAppChildCase "bad-command-$i" $bad[$i] -Refusal 'Unrecognized live zmx child'
        })
    }
    Invoke-CapTest 'app child gate refuses wrong image parent role and held generation without mutation' {
        return @(
            Invoke-CapAppChildCase 'wrong-image' 'ls' -WrongImage -Refusal 'Unknown live descendant'
            Invoke-CapAppChildCase 'wrong-role' 'ls' -ParentRole 'unrelated-parent' -Refusal 'Unrecognized live zmx child'
            Invoke-CapAppChildCase 'wrong-generation' 'ls' -WrongGeneration -Refusal 'Held parent generation changed'
        )
    }
    Invoke-CapTest 'app child gate does not adopt a zmx child of an unrelated held parent' {
        Invoke-CapAppChildCase 'unrelated-parent' 'ls' -UnrelatedRoot
    }
    Invoke-CapTest 'app child native ancestry refuses forged advisory parent metadata for a real owned fixture' {
        Invoke-CapAppChildCase 'advisory-parent' 'ls' -AdvisoryParent
    }
    Invoke-CapTest 'D app client cleanup accepts exact declared sessions and rejects prefix lookalikes' {
        return @(
            Invoke-CapAppChildCase 'd-primary' 'attach graphcode-33333333-3333-4333-8333-333333333333 --size 80x24' -DAdapter
            Invoke-CapAppChildCase 'd-history' 'resize graphcode-44444444-4444-4444-8444-444444444444 80x24' -DAdapter
            Invoke-CapAppChildCase 'd-foreign' 'attach graphcode-33333333-3333-4333-8333-333333333333-foreign --size 80x24' `
                -DAdapter -Refusal 'Unrecognized live zmx child'
        )
    }
}

function Invoke-CapCaptureCommand {
    param(
        [string]$Name,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments = @(),
        [string]$Behavior = 'normal',
        [string]$LeaseMutation = '',
        [string]$AdmissionMutation = '',
        [switch]$RealSeed,
        [string]$DSceneMutation = ''
    )
    $owned = Join-Path $scratch "cases\$Name"
    $null = New-Item -ItemType Directory -Path $owned
    $exe = Join-Path $owned 'harmless-target.exe'
    Copy-Item -LiteralPath $target.executable -Destination $exe
    $jobPath = Join-Path $owned 'job.json'
    $leasePath = Join-Path $owned 'lease.json'
    $output = Join-Path $owned 'output'
    $job = [ordered]@{
        executionMode = $mode; desktopAuthorized = $false; lane = 'B'
        head = 'OFFLINE_FIXTURE_NOT_PRODUCT'; base = 'OFFLINE_FIXTURE_NOT_PRODUCT'
        rehearsalTarget = [ordered]@{ path = $exe; sha256 = $target.executableSha256
            arguments = @($Arguments); behavior = $Behavior; timeoutMilliseconds = 1000 }
    }
    if ($RealSeed) {
        if (-not $RealSeedZmxPath -or $RealSeedZmxSha256 -cnotmatch '\A[A-F0-9]{64}\z' -or
            (Get-FileHash -LiteralPath $RealSeedZmxPath -Algorithm SHA256).Hash -cne $RealSeedZmxSha256) {
            throw 'Real seed tests require an explicitly supplied hash-verified pinned zmx.'
        }
        $null = New-Item -ItemType Directory -Path (Join-Path $owned 'runtime')
        $zmx = Join-Path $owned 'runtime\zmx.exe'
        Copy-Item -LiteralPath $RealSeedZmxPath -Destination $zmx
        $job.seedDependencies = [ordered]@{ zmxPath = $zmx; zmxSha256 = $RealSeedZmxSha256
            providerCommit = '785b3fd15dcafd1882b495c831a10f98c201b908' }
        $job.binaries = [ordered]@{ offlineZmx = [ordered]@{ sha256 = $RealSeedZmxSha256
            seedArgumentOrder = @('run','graphcode-11111111-1111-4111-8111-000000000001',
                '-d','cmd.exe','/Q','/K','echo Offline card fixture - no backend') } }
    }
    if ($AdmissionMutation) { $job = New-CapAdmissionJob -Owned $owned -Job $job -Mutation $AdmissionMutation }
    if ($DSceneMutation) { $job = New-CapDSceneJob -Owned $owned -Job $job -Mutation $DSceneMutation }
    $job | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jobPath -Encoding utf8NoBOM
    $jobHash = (Get-FileHash -LiteralPath $jobPath -Algorithm SHA256).Hash
    $now = [DateTime]::UtcNow
    $lease = [ordered]@{
        schemaVersion = 1; leaseId = [guid]::NewGuid().ToString(); lane = 'B'
        status = 'REHEARSAL_ONLY'; authorizedAction = 'no-desktop-real-launch-rehearsal'; desktopAuthorized = $false
        head = $job.head; jobManifestSha256 = $jobHash
        moduleSha256 = $sourceHashesBefore[$modulePath]; workerSha256 = $sourceHashesBefore[$workerPath]
        supervisorSha256 = $sourceHashesBefore[$supervisorPath]; preflightReceiptSha256 = $null
        grantedUtc = $now.AddSeconds(-1).ToString('o'); expiresUtc = $now.AddMinutes(5).ToString('o'); maxMinutes = 15
    }
    if ($AdmissionMutation) {
        $lease.lane = $job.lane
        $lease.base = $job.base
        $lease.reviewedHead = $job.admission.reviewedHead
        $lease.reviewAcceptanceSha256 = $job.admission.reviewAcceptance.sha256
        $lease.equivalenceSha256 = $job.admission.equivalence.sha256
        $lease.ciInventorySha256 = $job.admission.ci.sha256
        $lease.ciRuns = $job.admission.ci.runs
        foreach ($phase in @('before', 'after')) {
            $lease["${phase}BuildReceiptSha256"] = $job.binaries[$phase].buildReceipt.sha256
            $lease["${phase}BinarySha256"] = $job.binaries[$phase].sha256
        }
        if ($AdmissionMutation -eq 'lease-base') { $lease.base = '0' * 40 }
    }
    switch ($LeaseMutation) {
        'expired' { $lease.grantedUtc = $now.AddMinutes(-6).ToString('o'); $lease.expiresUtc = $now.AddSeconds(-1).ToString('o') }
        'future' { $lease.grantedUtc = $now.AddMinutes(1).ToString('o') }
        'over-15' { $lease.expiresUtc = $now.AddMinutes(16).ToString('o') }
        'missing-offset' { $lease.grantedUtc = $now.AddSeconds(-1).ToString('yyyy-MM-ddTHH:mm:ss') }
        'traversal-id' { $lease.leaseId = '..\foreign-output' }
        'hash' { $lease.moduleSha256 = '0' * 64 }
    }
    $lease | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $leasePath -Encoding utf8NoBOM
    if ($LeaseMutation -eq 'malformed') { [IO.File]::WriteAllText($leasePath, '{"leaseId":"..\foreign","outputDirectory":"C:\foreign"') }
    $leaseHash = (Get-FileHash -LiteralPath $leasePath -Algorithm SHA256).Hash
    $argumentsToSupervisor = @(
        '-NoProfile', '-File', $supervisorPath, '-OwnedRoot', $owned, '-OutputDirectory', $output,
        '-ExecutionMode', $mode, '-JobPath', $jobPath, '-JobSha256', $jobHash,
        '-LeaseReceiptPath', $leasePath, '-LeaseReceiptSha256', $leaseHash
    )
    $argumentsToSupervisor | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $owned 'command-arguments.json') -Encoding utf8NoBOM
    $child = Invoke-CapBoundedChild -FilePath (Join-Path $PSHOME 'pwsh.exe') -Arguments $argumentsToSupervisor `
        -Directory $owned -Role "rehearsal-supervisor-$Name"
    [IO.File]::WriteAllText((Join-Path $owned 'command-stdout.log'), $child.stdout)
    [IO.File]::WriteAllText((Join-Path $owned 'command-stderr.log'), $child.stderr)
    $receiptPath = Join-Path $output 'lease-release.json'
    $receipt = if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -DateKind String
    } else { $null }
    return [pscustomobject]@{
        name = $Name; child = $child; owned = $owned; output = $output; receipt = $receipt
        receiptPath = $receiptPath; commandArguments = $argumentsToSupervisor
        receiptSha256 = if ($receipt) { (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash } else { $null }
        leaseSha256 = $leaseHash
    }
}

function Write-CapTestArtifact {
    param([string]$Path, $Value)
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
    return [ordered]@{ path = $Path; sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
}

function Invoke-CapTestGit {
    param([string]$Repository, [string[]]$Arguments)
    $output = @(& git -C $Repository @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Offline fixture Git failed: $($output -join [Environment]::NewLine)" }
    return $output
}

function New-CapAdmissionJob {
    param([string]$Owned, $Job, [string]$Mutation)
    $repository = Join-Path $Owned 'source-repository'
    $null = New-Item -ItemType Directory -Path $repository
    $null = Invoke-CapTestGit $repository @('init', '--quiet')
    $null = Invoke-CapTestGit $repository @('config', 'user.name', 'Offline capture fixture')
    $null = Invoke-CapTestGit $repository @('config', 'user.email', 'fixture@example.invalid')
    $null = Invoke-CapTestGit $repository @('config', 'core.autocrlf', 'false')
    $null = New-Item -ItemType Directory -Path (Join-Path $repository 'graphcode-windows')
    [IO.File]::WriteAllText((Join-Path $repository 'graphcode-windows\product.txt'), 'before')
    $null = Invoke-CapTestGit $repository @('add', '.')
    $null = Invoke-CapTestGit $repository @('commit', '--quiet', '-m', 'Offline before')
    $base = [string](Invoke-CapTestGit $repository @('rev-parse', 'HEAD'))
    [IO.File]::WriteAllText((Join-Path $repository 'graphcode-windows\product.txt'), 'reviewed after')
    $null = Invoke-CapTestGit $repository @('commit', '--quiet', '-am', 'Offline reviewed product')
    $reviewed = [string](Invoke-CapTestGit $repository @('rev-parse', 'HEAD'))
    $null = New-Item -ItemType Directory -Path (Join-Path $repository 'Tools\windows') -Force
    [IO.File]::WriteAllText((Join-Path $repository 'Tools\windows\Invoke-UiCapture.ps1'), '# Offline tooling-only delta')
    if ($Mutation -in @('product-diff', 'omitted-product-diff')) {
        [IO.File]::WriteAllText((Join-Path $repository 'graphcode-windows\product.txt'), 'UNREVIEWED product')
    }
    $null = Invoke-CapTestGit $repository @('add', '.')
    $null = Invoke-CapTestGit $repository @('commit', '--quiet', '-m', 'Offline candidate')
    $head = [string](Invoke-CapTestGit $repository @('rev-parse', 'HEAD'))
    if ($Mutation -eq 'unrelated-base') {
        $tree = [string](Invoke-CapTestGit $repository @('rev-parse', "$base`^{tree}"))
        $base = [string](Invoke-CapTestGit $repository @('commit-tree', $tree, '-m', 'Offline unrelated base'))
    }
    $Job.head = $head
    $Job.base = $base
    if ($Mutation -eq 'lane-d') { $Job.lane = 'D' }
    $Job.sourceRepository = $repository
    $Job.binaries = [ordered]@{}
    $buildInput = Join-Path $Owned 'build-input.c'
    Copy-Item -LiteralPath $target.source -Destination $buildInput
    foreach ($phase in @('before', 'after')) {
        $commit = if ($phase -eq 'before') { $base } else { $head }
        $archive = Join-Path $Owned "$phase.zip"
        $sourceRoot = Join-Path $Owned "source-$phase"
        $null = Invoke-CapTestGit $repository @('archive', '--format=zip', "--output=$archive", $commit)
        Expand-Archive -LiteralPath $archive -DestinationPath $sourceRoot
        $logPath = Join-Path $Owned "$phase-build.log"
        [IO.File]::WriteAllText($logPath, 'OFFLINE_TEST_DATA: no product build was performed.')
        $binary = Join-Path $Owned "$phase.exe"
        Copy-Item -LiteralPath $target.executable -Destination $binary
        [IO.File]::AppendAllText($binary, "OFFLINE_DATA_ONLY_PHASE_$phase")
        $binaryHash = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
        $receipt = [ordered]@{
            schemaVersion = 1; evidenceMode = 'OFFLINE_TEST_DATA_NOT_PRODUCT_BUILD'
            sourceCommit = $commit; sourceTree = [string](Invoke-CapTestGit $repository @('rev-parse', "${commit}:graphcode-windows"))
            sourceRoot = Join-Path $sourceRoot 'graphcode-windows'; sourceSubdirectory = 'graphcode-windows'
            binaryBuiltAtSource = $commit
            archive = [ordered]@{ path = $archive; sha256 = (Get-FileHash $archive -Algorithm SHA256).Hash }
            log = [ordered]@{ path = $logPath; sha256 = (Get-FileHash $logPath -Algorithm SHA256).Hash }
            executablePath = $binary; executableSha256 = $binaryHash
            startedUtc = [DateTime]::UtcNow.AddSeconds(-5).ToString('o')
            finishedUtc = [DateTime]::UtcNow.AddSeconds(-1).ToString('o')
            exitCode = 0; command = 'OFFLINE_TEST_DATA: existing harmless fixture, not a product build'
            inputs = @([ordered]@{ path = $buildInput; sha256 = $target.sourceSha256 })
        }
        $receipt.rawReceipt = Write-CapTestArtifact (Join-Path $Owned "$phase-raw-build.json") ([ordered]@{
            sourceSha = $commit; builtAtSha = $commit; sourceTree = $receipt.sourceTree
            sourceExportSha256 = $receipt.archive.sha256; executableSha256 = $receipt.executableSha256
            exitCode = 0; startedUtc = $receipt.startedUtc; finishedUtc = $receipt.finishedUtc; command = $receipt.command
        })
        if ($phase -eq 'after' -and $Mutation -eq 'null-build') { $receipt.sourceCommit = $null }
        if ($phase -eq 'after' -and $Mutation -eq 'stale-build') { $receipt.binaryBuiltAtSource = $base }
        $Job.binaries[$phase] = [ordered]@{
            path = $binary; sha256 = $binaryHash; source = $commit; binaryBuiltAtSource = $commit
            buildReceipt = Write-CapTestArtifact (Join-Path $Owned "$phase-build.json") $receipt
        }
    }
    $ci = [ordered]@{
        schemaVersion = 1; evidenceMode = 'OFFLINE_TEST_DATA_NOT_LIVE_CI'
        repository = 'scgopi/GraphCode'; head = $head
        observedUtc = [DateTime]::UtcNow.ToString('o')
        runs = @([ordered]@{
            id = 123; run_attempt = 1; head_sha = $head; status = 'completed'; conclusion = 'success'
            total_count = 1; jobs = @([ordered]@{
                id = 456; run_id = 123; head_sha = $head; name = 'Offline synthetic context'
                status = 'completed'; conclusion = 'success'; configuredSkip = $false
            })
        })
    }
    if ($Mutation -eq 'red-ci') {
        $ci.runs[0].conclusion = 'failure'
        $ci.runs[0].jobs[0].conclusion = 'failure'
    }
    if ($Mutation -eq 'ci-head') { $ci.runs[0].jobs[0].head_sha = $base }
    if ($Mutation -eq 'empty-ci') { $ci.runs[0].jobs = @(); $ci.runs[0].total_count = 0 }
    if ($Mutation -eq 'duplicate-ci') {
        $ci.runs[0].jobs = @($ci.runs[0].jobs[0], $ci.runs[0].jobs[0])
        $ci.runs[0].total_count = 2
    }
    if ($Mutation -eq 'source-bytes') { [IO.File]::AppendAllText((Join-Path $Owned 'source-after\graphcode-windows\product.txt'), 'DIRTY') }
    if ($Mutation -eq 'binary-hash') { [IO.File]::AppendAllText($Job.binaries.after.path, 'MISMATCH') }
    $Job.admission = [ordered]@{
        schemaVersion = 1; reviewedHead = $reviewed
        reviewAcceptance = Write-CapTestArtifact (Join-Path $Owned 'review.json') ([ordered]@{
            schemaVersion = 1; verdict = 'ACCEPT'; reviewedHead = $reviewed; reviewedBase = $base
            evidenceMode = 'OFFLINE_TEST_DATA_NOT_REVIEW'
        })
        equivalence = Write-CapTestArtifact (Join-Path $Owned 'equivalence.json') ([ordered]@{
            schemaVersion = 1; reviewedHead = $reviewed; head = $head; reviewedBase = $base; base = $base
            headDeltaPaths = @(Invoke-CapTestGit $repository @('diff', '--name-only', '--no-renames', $reviewed, $head))
            baseDeltaPaths = @()
        })
        ci = Write-CapTestArtifact (Join-Path $Owned 'ci.json') $ci
    }
    $Job.admission.ci.runs = @([ordered]@{ id = 123; attempt = 1 })
    if ($Mutation -eq 'omitted-product-diff') {
        $proofPath = $Job.admission.equivalence.path
        $proof = Get-Content -LiteralPath $proofPath -Raw | ConvertFrom-Json -DateKind String
        $proof.headDeltaPaths = @($proof.headDeltaPaths | Where-Object { $_ -cne 'graphcode-windows/product.txt' })
        $Job.admission.equivalence = Write-CapTestArtifact $proofPath $proof
    }
    if ($Mutation -eq 'phase-swap') {
        Assert-CapTest ($Job.binaries.before.sha256 -cne $Job.binaries.after.sha256) 'Phase fixture binary hashes must differ.'
        $before = [IO.File]::ReadAllBytes($Job.binaries.before.path)
        $after = [IO.File]::ReadAllBytes($Job.binaries.after.path)
        [IO.File]::WriteAllBytes($Job.binaries.before.path, $after)
        [IO.File]::WriteAllBytes($Job.binaries.after.path, $before)
    }
    if ($Mutation -eq 'duplicate-json') {
        $path = $Job.admission.ci.path
        [IO.File]::WriteAllText($path, [IO.File]::ReadAllText($path).Insert(1, "`"head`":`"$head`","))
        $Job.admission.ci.sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    return $Job
}

function Assert-CapRehearsalSuccess {
    param($Run, [AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments)
    Assert-CapTest ($Run.child.exitCode -eq 0 -and -not $Run.child.stdinRedirected) "Capture command failed or changed default stdin inheritance: $($Run.child.stderr)"
    Assert-CapTest ($null -ne $Run.receipt -and $Run.receipt.status -ceq 'RELEASED_ZERO_SURVIVORS' -and
        $Run.receipt.workerStarted -and $Run.receipt.workerStdoutEof -and $Run.receipt.workerStderrEof -and
        $Run.receipt.captures -eq 0 -and $Run.receipt.kernelVerifiedSurvivors.Count -eq 0 -and
        $Run.receipt.cleanupFailures.Count -eq 0 -and $null -eq $Run.receipt.primaryFailure) 'Release is not a proven successful no-desktop cleanup.'
    $manifest = Get-Content -LiteralPath (Join-Path $Run.output 'manifest.json') -Raw | ConvertFrom-Json -DateKind String
    Assert-CapTest ($manifest.executionMode -ceq $mode -and $manifest.rehearsalLaunches.Count -eq 1 -and
        $manifest.images.Count -eq 0 -and $manifest.guiLaunches.Count -eq 0 -and
        $manifest.rehearsalLaunches[0].argumentCount -eq $Arguments.Count -and
        $manifest.rehearsalLaunches[0].heldKernelHandle -gt 0 -and $manifest.rehearsalLaunches[0].ready) 'Real target launch record missing.'
    $stdout = [IO.File]::ReadAllText((Join-Path $Run.output 'rehearsal-target-stdout.log'))
    Assert-CapTest ($stdout -match "(?m)^CAP_ARGC:$($Arguments.Count)\r?$") 'Target received a different argument count.'
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $hex = (@($Arguments[$i].ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) -join '')
        Assert-CapTest ($stdout -match "(?m)^CAP_ARG_${i}:$hex\r?$") "Target argument $i changed in real Process.Start."
    }
    $trace = @(Get-Content -LiteralPath (Join-Path $Run.output 'worker-calls.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    foreach ($name in @('Start-CapGraphCodeApp', 'Start-CapManagedProcess', 'Start-CapManagedProcessCore')) {
        Assert-CapTest (@($trace | Where-Object command -CEQ $name).Count -ge 1) "Actual launch callsite was not traced: $name"
    }
    Assert-CapTest (@($trace | Where-Object command -In @(
        'Find-CapTopLevelWindow', 'Find-CapAutomationElement', 'Invoke-CapAction',
        'Capture-CapWindow', 'Get-CapWindowMetrics', 'Set-CapWindowPosition'
    )).Count -eq 0) 'No-desktop rehearsal reached a GUI-only operation.'
    Assert-CapTest (@(Get-ChildItem -LiteralPath $Run.output -Filter '*.png' -File).Count -eq 0) 'Offline rehearsal created image files.'
    return [ordered]@{ commandExit = $Run.child.exitCode; release = $Run.receiptPath; releaseSha256 = $Run.receiptSha256
        targetArguments = @($Arguments); actualTargetLaunches = 1; images = 0; desktop = 'NotExecuted' }
}

function New-CapDSceneJob {
    param([string]$Owned, $Job, [string]$Mutation)
    $Job.lane = 'D'
    $Job.sceneAdapter = 'D_QUICK_CHAT_V1'
    $Job.authority = @{centralCaptureLeaseGrantedByThisArtifact=$false;dWorkerMayLaunchGui=$false}
    $Job.captureContract = @{
        phases=@('before','after');sceneCountPerPhase=10;expectedClientWH=@(1440,952);dpi=96;canvasZoomPercent=100
        placement='MEASURED_FIT_WORKAREA';estimatedSeconds=600;cleanupReserveSeconds=90
        requireLiveMissingChat=$false;requireLiveSavedAgentSplit=$false
    }
    $Job.scenes = @('d-quick-chats-canvas','d-chat-primary-shell','d-chat-history-roles','d-chat-show-graph-destination',
        'd-neighbor-sidebar','d-neighbor-overview','d-neighbor-project','d-normal-panel-expanded',
        'd-normal-panel-collapsed','d-normal-route-away-project') | ForEach-Object { @{name=$_;naturalWidthBeforeAfter=@(250,250)} }
    $original = Join-Path $Owned 'original'
    $projects = Join-Path $Owned 'fixtures\projects'
    foreach ($directory in @('inputs','fixtures','reports','runtime')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $Owned $directory)
    }
    $utc = [DateTime]::UtcNow
    $seconds = ($utc-[DateTime]::new(2001,1,1,0,0,0,[DateTimeKind]::Utc)).TotalSeconds
    $primary='33333333-3333-4333-8333-333333333333'
    $history='44444444-4444-4444-8444-444444444444'
    $normal='AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'
    $project = Join-Path $original 'D Offline Capture Fixture'
    $fixture = @{
        schemaVersion=1;sceneAdapter='D_QUICK_CHAT_V1';fixtureUtc=$utc.ToString('o');createdAt=$seconds
        graphs=@(@{id='d-capture-graph';project=@{name='D Offline Capture Fixture';path=$project}
            nodes=@(
                @{id=$normal;title='Loop workspace fixture';loopType='turnBased';state='running';backend='claudeCode'
                    createdAt=$seconds-3600;metricHistory=@(@{value=3},@{value=2});inputTokens=256;outputTokens=128},
                @{id='BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB';title='Secondary loop fixture';loopType='turnBased'
                    state='idle';backend='copilot';createdAt=$seconds-7200;metricHistory=@()}
            );edges=@()})
        chats=@(
            @{id=$primary;title='Quick Chat capture fixture';backend='claudeCode';createdAt=$seconds-2100;activity=$null},
            @{id=$history;title='Quick Chat history fixture';backend='copilot';createdAt=$seconds-10800;activity=$null})
        layouts=@(
            @{schemaVersion=2;project='graphcode://quick-chats';loop=$primary;selectedTab=0
                tabs=@(@{id=1;direction='horizontal';focused=0;panes=@(@{id=$primary;agent=$false})})},
            @{schemaVersion=2;project='graphcode://quick-chats';loop=$history;selectedTab=0
                tabs=@(@{id=2;direction='horizontal';focused=0;panes=@(@{id=$history;agent=$false})})},
            @{schemaVersion=2;project=$project;loop=$normal;selectedTab=0
                tabs=@(@{id=3;direction='horizontal';focused=0;panes=@(@{id=$normal;agent=$true})})})
    }
    switch ($Mutation) {
        'wrong-chat' {$fixture.chats[0].id='55555555-5555-4555-8555-555555555555'}
        'wrong-loop' {$fixture.graphs[0].nodes[0].id='foreign-loop'}
        'one-metric' {$fixture.graphs[0].nodes[0].metricHistory=@(@{value=3})}
        'wrong-date' {$fixture.createdAt='not-a-numeric-Swift-date'}
        'layout-project' {$fixture.layouts[0].project='foreign-project'}
        'layout-loop' {$fixture.layouts[0].loop='foreign-chat'}
        'embedded-path' {$fixture.graphs[0].nodes[0].worktreeBinding=@{path='C:\foreign\not-owned'}}
    }
    $sourcePath = Join-Path $Owned 'inputs\fixture-source.json'
    $sourceRef = Write-CapTestArtifact $sourcePath $fixture
    $originalEscaped=($original | ConvertTo-Json -Compress).Trim('"')
    $ownedEscaped=($projects | ConvertTo-Json -Compress).Trim('"')
    $mapped=[IO.File]::ReadAllText($sourcePath).Replace($originalEscaped,$ownedEscaped) | ConvertFrom-Json -DateKind String
    $mappedRef=Write-CapTestArtifact (Join-Path $Owned 'fixtures\fixture.json') $mapped
    $mappingRef=Write-CapTestArtifact (Join-Path $Owned 'reports\fixture-mapping.json') @{
        sourcePath=(Join-Path $original 'fixture.json');sourceSha256=$sourceRef.sha256;copiedSourcePath=$sourcePath
        rewrittenFixturePath=$mappedRef.path;rewrittenFixtureSha256=$mappedRef.sha256
        pathPrefixMap=@{from=$original;to=$projects};graphs=1;topLevelNodes=2;quickChats=2;layouts=3;pathsRewritten=$true
    }
    $peerPath=Join-Path $Owned 'inputs\offline-peer-source.ps1'
    [IO.File]::WriteAllText($peerPath,(Get-CapDPeerSource),[Text.UTF8Encoding]::new($false))
    $Job.fixture=@{sha256=$sourceRef.sha256;mappingSha256=$mappingRef.sha256;originalRoot=$original
        offlinePeerReference=@{sha256=(Get-FileHash -LiteralPath $peerPath -Algorithm SHA256).Hash}}
    $Job.binaries.offlineZmx=@{sha256=('B'*64);seedCommand=@('/Q','/K','echo D_OFFLINE_QUICKCHAT_FIXTURE')}
    switch ($Mutation) {
        'lane-mismatch' {$Job.lane='B'}
        'b-geometry' {$Job.captureContract.expectedClientWH=@(1440,900)}
        'b-scenes' {$Job.scenes=@(@{name='project-alpha'})}
        'live-missing' {$Job.captureContract.requireLiveMissingChat=$true}
        'live-roles' {$Job.captureContract.requireLiveSavedAgentSplit=$true}
        'runtime-awareness' {$Job.captureContract.requireRuntimeDpiAwareness=$true}
        'historical-shape' {$Job.head=@{sha=$Job.head};$Job.base=@{sha=$Job.base}}
        'stale-source' {[IO.File]::AppendAllText($sourcePath,"`n")}
        'stale-map' {[IO.File]::AppendAllText($mappingRef.path,"`n")}
        'stale-peer' {[IO.File]::AppendAllText($peerPath,"`n# changed")}
        'stale-fixture' {[IO.File]::AppendAllText($mappedRef.path,"`n")}
    }
    return $Job
}

function Invoke-CapPeerWireCase {
    param([string]$Peer, [ValidateSet('clean','early-close','invalid','cold')][string]$Case,
        [string]$Source, [string]$FixturePath, [string]$CaseRoot, [switch]$Baseline)
    $null = New-Item -ItemType Directory -Path $CaseRoot
    $temp = Join-Path $CaseRoot 'temp'
    $null = New-Item -ItemType Directory -Path $temp
    $peerPath = Join-Path $CaseRoot 'peer.ps1'
    [IO.File]::WriteAllText($peerPath,$Source,[Text.UTF8Encoding]::new($false))
    $fixtureCopy = Join-Path $CaseRoot 'fixture.json'
    [IO.File]::Copy($FixturePath,$fixtureCopy)
    $fixture = Get-Content -LiteralPath $fixtureCopy -Raw | ConvertFrom-Json -DateKind String
    $events = Join-Path $CaseRoot 'wire.jsonl'
    $record = {
        param($Kind,$Value)
        [IO.File]::AppendAllText($events,((@{kind=$Kind;utc=[DateTime]::UtcNow.ToString('o')
            ticks=[Diagnostics.Stopwatch]::GetTimestamp();value=$Value} | ConvertTo-Json -Depth 40 -Compress)+"`n"))
    }
    $pipeName = 'gc-peer-contract-' + [guid]::NewGuid().ToString('N')
    $connect = {
        $client = [IO.Pipes.NamedPipeClientStream]::new('.',$pipeName,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous)
        try { $client.ConnectAsync(5000).GetAwaiter().GetResult(); & $record 'connected' $pipeName; return $client }
        catch { $client.Dispose(); throw }
    }
    $write = {
        param($Client,[string]$Json,[byte[]]$Raw)
        if ($null -eq $Raw) {
            $body = [Text.Encoding]::UTF8.GetBytes($Json)
            $n = $body.Length
            $Raw = [byte[]]@((($n-shr 24)-band 255),(($n-shr 16)-band 255),(($n-shr 8)-band 255),($n-band 255))
            $Raw += $body
        }
        $cancel = [Threading.CancellationTokenSource]::new(5000)
        try { $Client.WriteAsync($Raw,0,$Raw.Length,$cancel.Token).GetAwaiter().GetResult() }
        finally { $cancel.Dispose() }
        & $record 'write' @{base64=[Convert]::ToBase64String($Raw);json=$Json}
    }
    $read = {
        param($Client)
        $cancel = [Threading.CancellationTokenSource]::new(5000)
        try {
            $parts = [Collections.Generic.List[byte]]::new()
            $length = 4
            foreach ($part in 0,1) {
                $bytes = [byte[]]::new($length)
                $offset = 0
                while ($offset -lt $length) {
                    $count = $Client.ReadAsync($bytes,$offset,$length-$offset,$cancel.Token).GetAwaiter().GetResult()
                    if ($count -eq 0) { throw 'Unexpected peer EOF.' }
                    $offset += $count
                }
                $parts.AddRange($bytes)
                if ($part -eq 0) {
                    $length = ([int]$bytes[0]-shl 24)-bor ([int]$bytes[1]-shl 16)-bor ([int]$bytes[2]-shl 8)-bor $bytes[3]
                    if ($length -le 0 -or $length -gt 2097152) { throw 'Invalid peer reply length.' }
                }
            }
            $json = [Text.UTF8Encoding]::new($false,$true).GetString($bytes)
            & $record 'read' @{base64=[Convert]::ToBase64String($parts.ToArray());json=$json}
            return ConvertFrom-Json $json -DateKind String
        } finally { $cancel.Dispose() }
    }
    $hello = '{"version":2,"kind":"hello","supportedVersions":[1,2]}'
    $valid = {
        param($Client)
        & $write $Client $hello $null
        $reply = & $read $Client
        if ($reply.kind -cne 'hello' -or $reply.selectedVersion -ne 2) { throw 'Missing v2 hello.' }
        & $write $Client '{"version":2,"kind":"request","requestID":"peer-contract","command":{"listRecentProjects":{}}}' $null
        $reply = & $read $Client
        $expectedNames = @($fixture.graphs | ForEach-Object {$_.project.name})
        if ($reply.kind -cne 'response' -or $reply.requestID -cne 'peer-contract' -or
            (@($reply.event.recentProjectsListed | ForEach-Object name) -join ',') -cne ($expectedNames -join ',')) {
            throw 'Missing positive correlated project list.'
        }
        foreach ($graph in $fixture.graphs) {
            $reply = & $read $Client
            if ($reply.kind -cne 'event' -or $reply.sequence -le 0 -or
                -not [Text.Json.Nodes.JsonNode]::DeepEquals(
                    [Text.Json.Nodes.JsonNode]::Parse(($reply.event.graphChanged | ConvertTo-Json -Depth 40 -Compress)),
                    [Text.Json.Nodes.JsonNode]::Parse(($graph | ConvertTo-Json -Depth 40 -Compress))) -or
                @($reply.event.graphChanged.nodes).Count -le 0) { throw 'Graph publish content changed.' }
        }
    }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path $PSHOME 'pwsh.exe'
    $info.WorkingDirectory = $CaseRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $quote = {param($Text) "'"+$Text.Replace("'","''")+"'"}
    $invocation = '[Console]::In.ReadLine() | Out-Null; & ' + (& $quote $peerPath) +
        ' -PipeName ' + (& $quote $pipeName) + ' -FixturePath ' + (& $quote $fixtureCopy)
    if ($Peer -ceq 'D') {
        $invocation += ' -CommandLog ' + (& $quote (Join-Path $CaseRoot 'commands.jsonl')) +
            ' -ModulePath ' + (& $quote $modulePath) + ' -ModuleSha256 ' + (& $quote ((Get-FileHash $modulePath -Algorithm SHA256).Hash))
    }
    foreach ($arg in @('-NoProfile','-NonInteractive','-Command',$invocation)) {$info.ArgumentList.Add($arg)}
    foreach ($name in @('TEMP','TMP','USERPROFILE','HOME','LOCALAPPDATA','APPDATA')) {$info.Environment[$name]=$temp}
    foreach ($name in @($info.Environment.Keys | Where-Object {$_ -like 'GRAPHCODE_*' -or $_ -in @('GH_TOKEN','GITHUB_TOKEN')})) {
        $null=$info.Environment.Remove($name)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $jobHandle = [CapProcessJob]::Create()
    $client = $null
    $stderr = $null
    $stdout = $null
    $receipt = [ordered]@{peer=$Peer;case=$Case;baseline=[bool]$Baseline;sourceSha256=(Get-FileHash $peerPath -Algorithm SHA256).Hash
        fixtureSha256=(Get-FileHash $fixtureCopy -Algorithm SHA256).Hash
        timerDefinition='monotonic immediately before first hello write through complete validated hello read; strict less than 1000ms'
        frequency=[Diagnostics.Stopwatch]::Frequency;spawnUtc=[DateTime]::UtcNow.ToString('o');spawnTicks=[Diagnostics.Stopwatch]::GetTimestamp()}
    try {
        if (-not $process.Start()) {throw 'Peer did not start.'}
        $native=[CapNative]::Snapshot($process.Handle,$process.Id)
        $receipt.pid=$native.ProcessId;$receipt.creationFileTimeUtc=$native.CreationFileTimeUtc
        $receipt.image=$native.ImagePath;$receipt.heldHandle=$process.Handle.ToInt64()
        $stderr=$process.StandardError.ReadToEndAsync()
        [CapProcessJob]::Assign($jobHandle,$process.Handle)
        $receipt.assignedBeforeGate=[CapProcessJob]::Contains($jobHandle,$process.Handle)
        $process.StandardInput.WriteLine('GO');$process.StandardInput.Close()
        if (-not $Baseline) {
            $readyTask=$process.StandardOutput.ReadLineAsync()
            if (-not $readyTask.Wait(10000)) {throw 'Peer ready marker deadline.'}
            $receipt.ready=$readyTask.Result
            [IO.File]::WriteAllText((Join-Path $CaseRoot 'stdout.log'),$receipt.ready+"`n")
            if ($receipt.ready -notmatch '^CAP_PEER_READY:(.+):([0-9]+)$') {throw 'Missing warm ready marker.'}
            $receipt.readyUtc=$Matches[1];$receipt.readyTicks=[long]$Matches[2]
            $receipt.spawnToWarmReadyMs=1000.0*($receipt.readyTicks-$receipt.spawnTicks)/$receipt.frequency
        }
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $client=& $connect
        $receipt.firstConnectTicks=[Diagnostics.Stopwatch]::GetTimestamp()
        if ($Case -ceq 'clean') {
            & $valid $client
            $client.Dispose();$client=$null
        } elseif ($Case -ceq 'early-close') {
            & $write $client $hello $null
            $client.Dispose();$client=$null
            & $record 'close-without-read' @{responseBytesRead=0}
        } elseif ($Case -ceq 'invalid') {
            & $write $client '{"command":{"listRecentProjects":{}}}' $null
            $client.Dispose();$client=$null
        } else {
            $receipt.firstWriteUtc=[DateTime]::UtcNow.ToString('o')
            $receipt.firstWriteTicks=[Diagnostics.Stopwatch]::GetTimestamp()
            & $write $client $hello $null
            $reply=& $read $client
            $receipt.firstReplyTicks=[Diagnostics.Stopwatch]::GetTimestamp()
            $receipt.firstReplyUtc=[DateTime]::UtcNow.ToString('o')
            if ($reply.kind -cne 'hello' -or $reply.selectedVersion -ne 2) {throw 'Invalid first hello reply.'}
            $receipt.firstHelloMs=1000.0*($receipt.firstReplyTicks-$receipt.firstWriteTicks)/$receipt.frequency
            if ($receipt.firstHelloMs -ge 1000) {throw "Cold first hello $($receipt.firstHelloMs)ms is not under 1000ms."}
            $client.Dispose();$client=$null
        }
        if ($Case -cne 'clean') {
            $client=& $connect
            & $valid $client
            $client.Dispose();$client=$null
        }
        if ($Case -ceq 'invalid' -and -not $Baseline) {
            foreach ($bad in @(
                @{json='{"version":2,"kind":"unknown"}';raw=$null},
                @{json='{';raw=$null},
                @{json='';raw=[byte[]]@(0,32,0,1)},
                @{json='';raw=[byte[]]@(255,255,255,255)},
                @{json='';raw=[byte[]]@(0,0)},
                @{json='';raw=[byte[]]@(0,0,0,5,123)}
            )) {
                $client=& $connect
                & $write $client $bad.json $bad.raw
                $client.Dispose();$client=$null
                $client=& $connect
                & $valid $client
                $client.Dispose();$client=$null
            }
        }
        if ($process.HasExited) {throw 'Peer exited after recovery.'}
        $receipt.recovered=$true
        return $receipt
    } catch {
        $receipt.error=$_.Exception.ToString()
        throw
    } finally {
        if ($client) {$client.Dispose()}
        if ($Baseline -and $Case -ceq 'clean') {$null=$process.WaitForExit(5000)}
        $receipt.exitedBeforeCleanup=$process.HasExited
        if ($process.HasExited) {$receipt.naturalExitCode=$process.ExitCode}
        $receipt.jobActiveBeforeTermination=[CapProcessJob]::Active($jobHandle)
        $receipt.forcedTermination=$receipt.jobActiveBeforeTermination -gt 0
        if ($receipt.forcedTermination) {[CapProcessJob]::Terminate($jobHandle)}
        [CapProcessJob]::WaitForEmpty($jobHandle,5000)
        $receipt.jobActiveAfterTermination=[CapProcessJob]::Active($jobHandle)
        $receipt.kernelExit=$process.WaitForExit(5000)
        $receipt.exitCode=$process.ExitCode
        if ($stdout) {
            $receipt.stdoutEof=$stdout.Wait(5000)
            if ($receipt.stdoutEof) {[IO.File]::AppendAllText((Join-Path $CaseRoot 'stdout.log'),$stdout.Result)}
        }
        if ($stderr) {
            $receipt.stderrEof=$stderr.Wait(5000)
            if ($receipt.stderrEof) {[IO.File]::WriteAllText((Join-Path $CaseRoot 'stderr.log'),$stderr.Result)}
        }
        [IO.File]::WriteAllText((Join-Path $CaseRoot 'receipt.json'),($receipt | ConvertTo-Json -Depth 20))
        [CapProcessJob]::Close($jobHandle)
        $process.Dispose()
        if (-not $Baseline -and $receipt.Contains('recovered')) {
            if (-not $receipt.stdoutEof -or -not $receipt.stderrEof -or -not $receipt.kernelExit -or
                $receipt.jobActiveAfterTermination -ne 0) {throw 'Peer cleanup proof is incomplete.'}
            if ($stderr.Result -match 'CAP_PEER_FATAL:') {throw 'Recovered peer logged an unexpected fatal failure.'}
            if ($Case -ceq 'invalid' -and
                [regex]::Matches($stderr.Result,'(?m)^CAP_PEER_PROTOCOL_REFUSAL:').Count -ne 7) {
                throw 'Every malformed connection must retain a loud protocol refusal.'
            }
        }
    }
}

function Invoke-CapDContracts {
    if ($DAdapterCase -ceq 'All') {
        Invoke-CapTest 'D real pipe clean session answers an empty project-list payload without fault injection' {
            $fixtureRoot=Join-Path $scratch 'peer-fixture-D-clean'
            $null=New-Item -ItemType Directory -Path $fixtureRoot
            $fixture=@{graphs=@(@{project=@{name='Alpha';path=(Join-Path $fixtureRoot 'Alpha')}
                nodes=@(@{id='Alpha-node'});edges=@()});chats=@()}
            $fixturePath=Join-Path $fixtureRoot 'fixture.json'
            $null=Write-CapTestArtifact $fixturePath $fixture
            Invoke-CapPeerWireCase -Peer D -Case clean -Source (Get-CapDPeerSource) -FixturePath $fixturePath `
                -CaseRoot (Join-Path $scratch 'peer-D-clean')
        }
        foreach ($peer in 'B','D') {
            foreach ($peerCase in 'early-close','invalid','cold') {
                Invoke-CapTest "$peer real pipe $peerCase preserves the same peer and full graph publications" {
                    $fixtureRoot=Join-Path $scratch "peer-fixture-$peer-$peerCase"
                    $null=New-Item -ItemType Directory -Path $fixtureRoot
                    $fixture=@{graphs=@('Alpha','Beta' | ForEach-Object {
                        @{project=@{name=$_;path=(Join-Path $fixtureRoot $_)};nodes=@(@{id="$_-node"});edges=@()}
                    });chats=@()}
                    if ($peer -ceq 'D') {$fixture.graphs=@($fixture.graphs[0])}
                    $fixturePath=Join-Path $fixtureRoot 'fixture.json'
                    $null=Write-CapTestArtifact $fixturePath $fixture
                    $source=if ($peer -ceq 'B') {Get-CapBPeerSource} else {Get-CapDPeerSource}
                    Invoke-CapPeerWireCase -Peer $peer -Case $peerCase -Source $source -FixturePath $fixturePath `
                        -CaseRoot (Join-Path $scratch "peer-$peer-$peerCase")
                }
            }
        }
        Invoke-CapTest 'B canonical peer binding accepts exact bytes and refuses hash-rebound altered source' {
            $owned=Join-Path $scratch 'b-canonical-binding'
            $original=Join-Path $owned 'original'
            $null=New-Item -ItemType Directory -Path (Join-Path $owned 'inputs'),(Join-Path $owned 'fixtures'),(Join-Path $owned 'reports')
            $source=@{graphs=@('Alpha','Beta' | ForEach-Object {
                @{project=@{name=$_;path=(Join-Path $original $_)};nodes=@(1..5 | ForEach-Object {@{id="node-$_"}})}
            })}
            $sourcePath=Join-Path $owned 'inputs\fixture-source.json'
            $fixturePath=Join-Path $owned 'fixtures\fixture.json'
            $sourceRef=Write-CapTestArtifact $sourcePath $source
            $mapped=[IO.File]::ReadAllText($sourcePath).Replace(
                (($original | ConvertTo-Json -Compress).Trim('"')),
                (((Join-Path $owned 'fixtures\projects') | ConvertTo-Json -Compress).Trim('"'))) | ConvertFrom-Json
            $fixtureRef=Write-CapTestArtifact $fixturePath $mapped
            $mappingRef=Write-CapTestArtifact (Join-Path $owned 'reports\fixture-mapping.json') @{
                sourcePath=(Join-Path $original 'fixture.json');sourceSha256=$sourceRef.sha256;copiedSourcePath=$sourcePath
                rewrittenFixturePath=$fixturePath;rewrittenFixtureSha256=$fixtureRef.sha256
                pathPrefixMap=@{from=$original;to=(Join-Path $owned 'fixtures\projects')};graphs=2;topLevelNodes=10;pathsRewritten=$true
            }
            $peerPath=Join-Path $owned 'inputs\offline-peer-source.ps1'
            [IO.File]::WriteAllText($peerPath,(Get-CapBPeerSource),[Text.UTF8Encoding]::new($false))
            $parameters=@{Root=$owned;FixturePath=$fixturePath;SourcePath=$sourcePath;MappingPath=$mappingRef.path
                ExpectedMappingSha256=$mappingRef.sha256;ExpectedSourceSha256=$sourceRef.sha256;OriginalRoot=$original
                ExpectedPeerSha256=(Get-FileHash $peerPath -Algorithm SHA256).Hash}
            $null=Assert-CapFixtureMapping @parameters
            [IO.File]::AppendAllText($peerPath,"`n# changed")
            $parameters.ExpectedPeerSha256=(Get-FileHash $peerPath -Algorithm SHA256).Hash
            $null=Assert-CapRejects {Assert-CapFixtureMapping @parameters} 'B peer bytes differ'
            return 'Canonical B accepted; altered bytes rejected even after the job peer hash was rebound.'
        }
    }
    if ($DAdapterCase -in @('All','SceneContract')) {
        Invoke-CapTest 'D declared scene inventory is admitted by the shared scene guard' {
            $job = @{
                lane = 'D'; sceneAdapter = 'D_QUICK_CHAT_V1'
                authority = @{ centralCaptureLeaseGrantedByThisArtifact = $false; dWorkerMayLaunchGui = $false }
                captureContract = @{
                    phases = @('before','after'); sceneCountPerPhase = 10; expectedClientWH = @(1440,952)
                    dpi = 96; canvasZoomPercent = 100; placement = 'MEASURED_FIT_WORKAREA'
                    estimatedSeconds = 600; cleanupReserveSeconds = 90
                    requireLiveMissingChat = $false; requireLiveSavedAgentSplit = $false
                }
                scenes = @('d-quick-chats-canvas','d-chat-primary-shell','d-chat-history-roles',
                    'd-chat-show-graph-destination','d-neighbor-sidebar','d-neighbor-overview',
                    'd-neighbor-project','d-normal-panel-expanded','d-normal-panel-collapsed',
                    'd-normal-route-away-project') | ForEach-Object { @{name=$_;naturalWidthBeforeAfter=@(250,250)} }
                fixture = @{sha256=('A'*64);mappingSha256=('B'*64);originalRoot='C:\declared'
                    offlinePeerReference=@{sha256=('C'*64)}}
                binaries = @{offlineZmx=@{sha256=('D'*64);seedCommand=@('/Q','/K','echo D_OFFLINE_QUICKCHAT_FIXTURE')}}
            } | ConvertTo-Json -Depth 20 | ConvertFrom-Json -DateKind String
            Assert-CapSceneContract -Job $job
            return 'Shared production scene predicate only; no launch, native call, fixture or image.'
        }
    }
    if ($DAdapterCase -in @('All','ActualAdmission')) {
        Invoke-CapTest 'D scene-marked fixture admission through actual capture command' {
            $run = Invoke-CapCaptureCommand -Name 'd-scenes-valid' -AdmissionMutation 'lane-d' -DSceneMutation 'valid'
            $detail = Assert-CapRehearsalSuccess -Run $run -Arguments @()
            foreach ($component in @('supervisor','worker')) {
                $trace = @(Get-Content -LiteralPath (Join-Path $run.output "$component-calls.jsonl") | ForEach-Object { $_ | ConvertFrom-Json })
                foreach ($command in @('Assert-CapSceneContract','Assert-CapFixtureMapping')) {
                    Assert-CapTest (@($trace | Where-Object command -CEQ $command).Count -eq 1) "D data not checked by $component/$command."
                }
            }
            return $detail
        }
    }
    if ($DAdapterCase -in @('All','FixtureDirectory')) {
        Invoke-CapTest 'D environment creates the exact owned project cwd before launch resolution' {
            $caseRoot=Join-Path $scratch 'd-owned-cwd'
            $null=New-Item -ItemType Directory -Path $caseRoot
            & {
                param($OwnedRoot,$WorkerSource)
                $root=$OwnedRoot
                $job=[pscustomobject]@{sceneAdapter='D_QUICK_CHAT_V1'}
                $rehearsal=$false
                $isD=$true
                $roots=[pscustomobject]@{Root=$root;Profile=(Join-Path $root 'profile');Local=(Join-Path $root 'local')
                    Temp=(Join-Path $root 'temp');Support=(Join-Path $root 'support');Zmx=(Join-Path $root 'zmx')}
                $errors=$null
                $ast=[Management.Automation.Language.Parser]::ParseFile($WorkerSource,[ref]$null,[ref]$errors)
                Assert-CapTest ($errors.Count -eq 0) 'Current worker did not parse.'
                $definitions=@($ast.FindAll({param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -cin @('Assert-CapOwnedPath','Get-CapBaseEnvironment')
                },$true))
                Assert-CapTest ($definitions.Count -eq 2) 'Actual environment/path functions missing or duplicated.'
                foreach ($definition in $definitions) {. ([scriptblock]::Create($definition.Extent.Text))}
                $expected=Join-Path $root 'fixtures\projects\D Offline Capture Fixture'
                Assert-CapTest (-not (Test-Path -LiteralPath $expected)) 'Owned D project must start absent.'
                $environment=Get-CapBaseEnvironment -Roots $roots -PipeName 'd-cwd-component' -SessionPrefix 'd-cwd-component'
                Assert-CapTest (Test-Path -LiteralPath $expected -PathType Container) 'D environment did not create the exact owned project working directory.'
                $launch=@($ast.FindAll({param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Start-CapGraphCodeApp'
                },$true))
                $cwd=@($launch[0].FindAll({param($node)
                    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text -ceq '$workingDirectory'
                },$true))
                Assert-CapTest ($launch.Count -eq 1 -and $cwd.Count -eq 1) 'Actual launch cwd assignment missing or duplicated.'
                . ([scriptblock]::Create($cwd[0].Extent.Text))
                Assert-CapTest ($workingDirectory -ceq $expected) 'Actual app launch cwd differs from the created D directory.'
                Assert-CapTest ($environment.GRAPHCODE_SUPPORT_DIR -ceq $roots.Support) 'D isolation environment changed.'
                return @{created=$expected;resolved=$workingDirectory;mode='ACTUAL_ENVIRONMENT_AND_CWD_EXPRESSION_NO_LAUNCH'}
            } $caseRoot $workerPath
        }
    }
    if ($DAdapterCase -cne 'All') { return }
    Invoke-CapTest 'D scene-marked real launch preserves empty Unicode and quoted arguments' {
        $arguments=[string[]]@('',('caf'+[char]0x00e9),'quote"inside','trailing\')
        $run=Invoke-CapCaptureCommand -Name 'd-scenes-argv' -Arguments $arguments -AdmissionMutation 'lane-d' -DSceneMutation 'valid'
        Assert-CapRehearsalSuccess -Run $run -Arguments $arguments
    }
    foreach ($mutation in @('lane-mismatch','b-geometry','b-scenes','live-missing','live-roles','runtime-awareness','historical-shape',
        'stale-source','stale-map','stale-peer','stale-fixture','wrong-chat','wrong-loop','one-metric','wrong-date',
        'layout-project','layout-loop','embedded-path')) {
        Invoke-CapTest "D scene-marked actual command refuses $mutation" {
            $run=Invoke-CapCaptureCommand -Name "d-scenes-$mutation" -AdmissionMutation 'lane-d' -DSceneMutation $mutation
            $expected=switch ($mutation) {
                'lane-mismatch' {'Unsupported scene adapter'}
                {$_ -in @('b-geometry','b-scenes')} {'D scene, geometry'}
                {$_ -in @('live-missing','live-roles')} {'required-live requests refuse'}
                'runtime-awareness' {'required-runtime-awareness job refuses'}
                'historical-shape' {"field 'head'"}
                {$_ -in @('stale-source','stale-map')} {'trusted hashes'}
                'stale-peer' {'D peer bytes differ'}
                'stale-fixture' {'exact source and rewritten'}
                'wrong-chat' {'D chat identity'}
                'wrong-loop' {'D normal-loop identity'}
                'one-metric' {'two numeric object samples'}
                'wrong-date' {'frozen Swift-reference date'}
                {$_ -in @('layout-project','layout-loop')} {'D layout binding'}
                'embedded-path' {'embedded path'}
            }
            Assert-CapTest ($run.child.exitCode -ne 0 -and $null -ne $run.receipt -and
                $run.receipt.status -ceq 'REFUSED_NO_WORKER' -and -not $run.receipt.workerStarted -and
                $run.receipt.primaryFailure.Contains($expected) -and $run.receipt.captures -eq 0 -and
                $run.receipt.cleanupFailures.Count -eq 0 -and $run.receipt.kernelVerifiedSurvivors.Count -eq 0) `
                "D $mutation did not refuse with official zero-worker release: $($run.child.stdout) $($run.child.stderr)"
            return @{release=$run.receiptPath;sha256=$run.receiptSha256;status=$run.receipt.status;reason=$run.receipt.primaryFailure}
        }
    }
    foreach ($mutation in @('malformed','expired','future','over-15','missing-offset','traversal-id','hash')) {
        Invoke-CapTest "D scene-marked actual command refuses $mutation lease" {
            $run=Invoke-CapCaptureCommand -Name "d-lease-$mutation" -AdmissionMutation 'lane-d' -DSceneMutation 'valid' -LeaseMutation $mutation
            Assert-CapTest ($run.child.exitCode -ne 0 -and $run.receipt.status -ceq 'REFUSED_NO_WORKER' -and
                -not $run.receipt.workerStarted -and $run.receipt.captures -eq 0 -and $run.receipt.cleanupFailures.Count -eq 0) 'D invalid lease did not refuse with official release.'
            return @{release=$run.receiptPath;status=$run.receipt.status;reason=$run.receipt.primaryFailure}
        }
    }
    foreach ($behavior in @('nonzero','timeout','primary-cleanup','receipt-block','trace-readonly')) {
        Invoke-CapTest "D scene-marked actual command handles target $behavior" {
            $run=Invoke-CapCaptureCommand -Name "d-target-$behavior" -AdmissionMutation 'lane-d' -DSceneMutation 'valid' -Behavior $behavior
            Assert-CapTest ($run.child.exitCode -ne 0) 'D failing target returned success.'
            if ($behavior -ceq 'receipt-block') {
                Assert-CapTest ($null -eq $run.receipt -and $run.child.stderr.Contains('LEASE_RELEASE_WRITE_FAILED')) 'Blocked D official receipt did not remain an explicit write failure.'
            } else {
                Assert-CapTest ($null -ne $run.receipt -and $run.receipt.workerStarted -and
                    $run.receipt.kernelVerifiedSurvivors.Count -eq 0 -and $run.receipt.captures -eq 0 -and
                    $null -ne $run.receipt.primaryFailure) 'D failure lost primary/release/zero-survivor evidence.'
                $expectedStatus=if ($behavior -in @('primary-cleanup','trace-readonly')) {'CLEANUP_UNPROVEN'} else {'FAILED_ZERO_SURVIVORS'}
                Assert-CapTest ($run.receipt.status -ceq $expectedStatus) "D target $behavior had wrong cleanup classification."
            }
            return @{output=$run.output;releaseSha256=$run.receiptSha256;exit=$run.child.exitCode}
        }
    }
    Invoke-CapTest 'D component layout geometry sessions and closed peer predicates' {
        $layout=Get-CapDLayoutPath -LayoutBase 'C:\owned\layouts\workspace.json' -ProjectKey 'abc' -LoopId 'unsafe/id'
        Assert-CapTest ($layout.ProjectPath -ceq 'C:\owned\layouts\workspace.eacf018fbf1678ba.json' -and
            $layout.LoopPath -match '\\loop-[a-f0-9]{16}\.json$') 'Production layout-path mirror did not use little-endian SHA256 suffix.'
        $geometry=Get-CapDGeometry -Metrics ([pscustomobject]@{Dpi=96;OuterBounds=@(30,30,1486,989);ClientBounds=@(0,0,1440,900)}) -WorkArea @(0,0,1920,1040)
        Assert-CapTest (($geometry.outerBounds -join ',') -ceq '0,0,1456,1011') 'D placement copied B Y=30 or wrong client height.'
        $null=Assert-CapRejects {Get-CapDGeometry -Metrics ([pscustomobject]@{Dpi=144;OuterBounds=@(0,0,1456,1011);ClientBounds=@(0,0,1440,952)}) -WorkArea @(0,0,1920,1080)} '96 DPI'
        $null=Assert-CapRejects {Get-CapDGeometry -Metrics ([pscustomobject]@{Dpi=96;OuterBounds=@(0,0,1456,1011);ClientBounds=@(0,0,1440,952)}) -WorkArea @(0,0,1400,1000)} 'do not fit'
        $sessions=@('graphcode-33333333-3333-4333-8333-333333333333','graphcode-44444444-4444-4444-8444-444444444444')
        Assert-CapTest (Test-CapDSessionCommand -CommandLine "`"C:\owned\zmx.exe`" attach $($sessions[0]) --size 80x24" -SessionNames $sessions) 'Exact D token refused.'
        Assert-CapTest (-not (Test-CapDSessionCommand -CommandLine "zmx.exe attach $($sessions[0])-foreign --size 80x24" -SessionNames $sessions)) 'D recovery admitted prefix.'
        Assert-CapTest (-not (Test-CapDSessionCommand -CommandLine 'zmx.exe ls' -SessionNames $sessions)) 'Bare listing is not an exact D token.'
        $fixture=Get-Content -LiteralPath (Join-Path $scratch 'cases\d-scenes-valid\fixtures\fixture.json') -Raw | ConvertFrom-Json -DateKind String
        $sequence=0
        $frame=@{version=2;kind='request';requestID=[guid]::NewGuid().ToString();command=@{graphCommand=@{
            projectPath=$fixture.graphs[0].project.path;command=@{resumeSession=@{_0='AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'}}}}} |
            ConvertTo-Json -Depth 10 | ConvertFrom-Json -DateKind String
        $reply=@(Get-CapDPeerFrames -Frame $frame -Fixture $fixture -Sequence ([ref]$sequence))
        Assert-CapTest ($reply.Count -eq 1 -and $reply[0].success -and $reply[0].requestID -ceq $frame.requestID) 'Exact metadata-only acknowledgement missing.'
        $frame.command.graphCommand.command.resumeSession._0='foreign-loop'
        $null=Assert-CapRejects {Get-CapDPeerFrames -Frame $frame -Fixture $fixture -Sequence ([ref]$sequence)} 'exact metadata-only'
        return 'DATA_COMPONENT_ONLY: path mirror, geometry, exact tokens and peer predicates; no pipe, provider or image.'
    }
    Invoke-CapTest 'D UIA action component predicates reject ambiguous disabled foreign and missing-pattern targets' {
        $holder=Start-CapManagedProcess -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 20') -WorkingDirectory $scratch -Role 'd-uia-component-holder'
        $tracePath=Join-Path $scratch 'd-uia-component-calls.jsonl'
        Set-CapTracePath -Path $tracePath
        try {
            foreach ($action in @('quick-chats-destination','open-quick-chat','workspace-show-graph','workspace-toggle-panel')) {
                $name=switch ($action) {'open-quick-chat' {'Quick Chat capture fixture'}; 'workspace-toggle-panel' {'Collapse loop panel'}; default {''}}
                $spec=Get-CapActionSpec -Action $action -Name $name
                $id=if ($spec.AutomationId) {$spec.AutomationId} else {$spec.AutomationIdPrefix+'123'}
                $candidate=[pscustomobject]@{Name=$spec.Name;AutomationId=$id;ProcessId=$holder.Identity.Pid;IsEnabled=$true
                    IsOffscreen=$false;ControlType=[Windows.Automation.ControlType]::Button;HasInvokePattern=$true
                    BoundingRectangle=[pscustomobject]@{Left=1;Top=1;Width=100;Height=30}}
                $candidates=@($candidate)
                $arguments=@{Action=$action;Name=$name;SubjectId='AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'
                    RootHandle=[IntPtr]1;ProcessIdentity=$holder.Identity;WindowProcessResolver={param($window) $holder.Identity.Pid}
                    ElementResolver={param($window,$identity,$spec) @($candidates)}
                    Invoker={param($spec,$element) [pscustomobject]@{componentOnly=$true;name=$element.Name}}}
                $dispatch=Invoke-CapAction @arguments
                Assert-CapTest $dispatch.componentOnly 'D explicit component dispatch missing.'
                $candidates=@($candidate,$candidate);$null=Assert-CapRejects {Invoke-CapAction @arguments} 'found=2'
                $candidates=@($candidate);$candidate.IsEnabled=$false;$null=Assert-CapRejects {Invoke-CapAction @arguments} 'disabled'
                $candidate.IsEnabled=$true;$candidate.HasInvokePattern=$false;$null=Assert-CapRejects {Invoke-CapAction @arguments} 'InvokePattern'
                $candidate.HasInvokePattern=$true;$candidate.IsOffscreen=$true;$null=Assert-CapRejects {Invoke-CapAction @arguments} 'found=0'
                $candidate.IsOffscreen=$false;$candidate.ProcessId++;$null=Assert-CapRejects {Invoke-CapAction @arguments} 'does not match owned PID'
                $candidate.ProcessId=$holder.Identity.Pid;$candidate.ControlType=[Windows.Automation.ControlType]::Text
                $null=Assert-CapRejects {Invoke-CapAction @arguments} 'control type'
            }
            $refusals=@(Get-Content -LiteralPath $tracePath | ForEach-Object {ConvertFrom-Json $_ -DateKind String} |
                Where-Object command -CEQ 'CapSelectorRefusal')
            Assert-CapTest ($refusals.Count -eq 12) 'D component selector refusals were not retained in the case-owned trace.'
        } finally {
            Set-CapTracePath -Path (Join-Path $scratch 'test-calls.jsonl')
            $null=Stop-CapManagedProcess -Identity $holder.Identity -TimeoutMilliseconds 5000
            Assert-CapTest ($holder.StdoutTask.Wait(2000) -and $holder.StderrTask.Wait(2000)) 'D component EOF missing.'
            $holder.Identity.Process.Dispose()
        }
        return @{mode='UIA_COMPONENT_ONLY: synthetic candidates/HWND/invoker, actual resolver; no native window or image.'
            selectorRefusalTrace=$tracePath;selectorRefusalCount=$refusals.Count}
    }
    Invoke-CapTest 'D typed observation components distinguish phases fallback roles and route-away' {
        function New-DObservationRow([string]$Id,[string]$Name) {
            return [pscustomobject]@{AutomationId=$Id;Name=$Name;ProcessId=123;IsOffscreen=$false
                BoundingRectangle=[pscustomobject]@{Left=1;Top=1;Width=220;Height=30}}
        }
        $healthy=@((New-DObservationRow 'graphcode-root' 'GraphCode'),(New-DObservationRow 'graph' 'Graph'))
        $shell=New-DObservationRow 'workspace-tab-123' 'Shell tab'
        $after=$healthy+@($shell,(New-DObservationRow 'workspace-quick-chat-bar-1' 'Quick Chat capture fixture'),
            (New-DObservationRow 'workspace-restart-session-2' 'Restart session'),(New-DObservationRow 'workspace-show-graph-3' 'Show in Graph'))
        $positive=Get-CapDObservation -Candidates $after -ExpectedProcessId 123 -State primary -Phase after
        Assert-CapTest ($positive.healthyRoot -and $positive.observations.Count -eq 4) 'After predicate lacks exact observations.'
        $null=Get-CapDObservation -Candidates ($healthy+@($shell)) -ExpectedProcessId 123 -State missing -Phase after
        $null=Assert-CapRejects {Get-CapDObservation -Candidates $after -ExpectedProcessId 123 -State missing -Phase after} 'still exposes chat controls'
        $shell.Name='Agent tab'
        $null=Get-CapDObservation -Candidates ($healthy+@($shell)) -ExpectedProcessId 123 -State primary -Phase before
        $null=Assert-CapRejects {Get-CapDObservation -Candidates ($healthy+@($shell)) -ExpectedProcessId 123 -State primary -Phase after} 'requires one bounded'
        $shell.Name='Shell tab'
        $null=Get-CapDObservation -Candidates ($healthy+@($shell,(New-DObservationRow 'workspace-tab-124' 'Agent tab'),
            (New-DObservationRow 'workspace-tab-125' 'Split tab'))) -ExpectedProcessId 123 -State roles-component -Phase after
        $null=Assert-CapRejects {Get-CapDObservation -Candidates @($shell) -ExpectedProcessId 123 -State missing -Phase after} 'healthy owned root'
        return 'UIA_COMPONENT_ONLY: actual phase predicates with synthetic healthy trees; not live scenes.'
    }
}

function Write-CapDContractReport {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($result in $results) {
        if (-not $names.Add($result.name)) { throw "Duplicate D case: $($result.name)" }
    }
    foreach ($path in $sourceHashesBefore.Keys) {
        Assert-CapTest ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $sourceHashesBefore[$path]) "D source changed: $path"
    }
    $passed = @($results | Where-Object passed -EQ $true).Count
    $failed = @($results | Where-Object passed -EQ $false).Count
    $report = [pscustomobject][ordered]@{suite='UiCaptureDriver';executed=$results.Count;passed=$passed;failed=$failed
        mode=$mode;gui='NotExecuted';images=0;backendTurns=0;cases=@($results);sourceHashesBeforeImport=$sourceHashesBefore}
    $report | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath (Join-Path $scratch 'report.json') -Encoding utf8NoBOM
    $report | Select-Object suite,executed,passed,failed | ConvertTo-Json -Compress
    $expected = if ($DAdapterCase -ceq 'All') {45} else {1}
    if ($results.Count -ne $expected -or $failed -ne 0 -or $passed -ne $expected) { exit 1 }
    exit 0
}

function Invoke-CapJobOwnershipContract {
    param([ValidateSet('normal','nonzero','timeout')][string]$Behavior)
    $context = New-JournalContractContext ('job-' + $Behavior)
    $directory = Join-Path $context.Root 'launch'
    $null = New-Item -ItemType Directory -Path $directory
    $run = Start-CapJobLauncher -Root $context.Root -OutputDirectory $directory `
        -FilePath $target.executable -ArgumentList @() -WorkingDirectory $directory `
        -Role 'job-contract-launcher' -Environment @{ CAP_REHEARSAL_BEHAVIOR = $Behavior }
    try {
        Assert-CapTest (-not [IO.File]::Exists($run.TargetReceiptPath)) 'Target executed before assignment/publication/gate release.'
        $gatedMembers = @([CapProcessJob]::Members($run.Job))
        Assert-CapTest ($gatedMembers.Count -eq 1 -and $gatedMembers[0] -eq $run.Identity.Pid -and
            [CapProcessJob]::Contains($run.Job, $run.Identity.Process.Handle)) 'Gated job does not contain exactly the held launcher.'
        $entry = [pscustomobject]@{ pid = [long]$run.Identity.Pid
            creationFileTimeUtc = [long]$run.Identity.CreationFileTimeUtc; jobId = $run.JobId }
        $null = Publish-CapJournalSnapshot $context.State Bootstrap ([pscustomobject]@{ entries = @($entry) })
        $targetReceipt = Release-CapJobLauncher -Run $run -JournalState $context.State
        Assert-CapTest ($targetReceipt.expectedImagePath -ieq $target.executable -and
            $targetReceipt.creationFileTimeUtc -gt 0) 'Normal target launch receipt is missing.'
        if ($Behavior -eq 'timeout') {
            $null = Assert-CapRejects {
                Wait-CapJobTarget -Run $run -DeadlineUtc ([DateTime]::UtcNow.AddMilliseconds(750))
            } 'Contained target deadline'
        } else {
            $exit = Wait-CapJobTarget -Run $run -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10))
            $expected = if ($Behavior -eq 'normal') { 0 } else { 23 }
            Assert-CapTest ($exit.exitCode -eq $expected -and $exit.kernelExited) 'Target exit was replaced by cleanup state.'
        }
        $proof = Close-CapJobLauncher -Run $run
        Assert-CapTest ($proof.jobActive0 -and $proof.activeProcesses -eq 0 -and
            $proof.files.Count -eq 2 -and $proof.launcherStdoutEof -and $proof.launcherStderrEof) `
            'Job Active=0, owned-file closure and actual launcher pipe EOF were not proved separately.'
        $stdout = [IO.File]::ReadAllText($proof.files[0].path)
        $stderr = [IO.File]::ReadAllText($proof.files[1].path)
        Assert-CapTest ($stdout.Contains('CAP_READY') -and $stdout.Contains('CAP_STDIN_EOF') -and
            $stderr.Contains('CAP_STDERR_EOF')) 'Closed owned files lost the target output contract.'
        return $proof
    } finally {
        if (-not $run.CleanupComplete) { $null = Close-CapJobLauncher -Run $run }
        foreach ($member in $run.Members) { $member.Process.Dispose() }
        foreach ($pin in @($run.OutputPins) + @($run.ClosedOutputPins)) { $pin.Dispose() }
        $run.Identity.Process.Dispose()
    }
}

function Invoke-CapReceiptReadControl {
    param($Run, [string]$Path, [DateTime]$DeadlineUtc, [int]$HoldMilliseconds = 0, $PublishValue = $null)
    $held = $null
    $reader = [powershell]::Create()
    $ready = [Threading.ManualResetEventSlim]::new($false)
    $pending = $null
    $tracePath = Join-Path (Split-Path -Parent $Path) 'reader-calls.jsonl'
    try {
        if ($HoldMilliseconds -gt 0) {
            $held = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        Assert-CapTest ([IO.File]::Exists($Path)) 'Receipt harness requires a positively present file.'
        $null = $reader.AddScript({
            param($ModulePath, $Run, $Path, $Deadline, $Ready, $TracePath)
            $ErrorActionPreference = 'Stop'
            Import-Module $ModulePath -Force -WarningAction SilentlyContinue
            Set-CapTracePath -Path $TracePath
            $Ready.Set()
            try {
                $record = & (Get-Module UiCaptureDriver) {
                    param($Run, $Path, $Deadline)
                    Read-CapJobTargetRecord -Run $Run -Path $Path -DeadlineUtc $Deadline
                } $Run $Path $Deadline
                [pscustomobject]@{ Succeeded = $true; Record = $record; Failure = $null }
            } catch {
                [pscustomobject]@{ Succeeded = $false; Record = $null; Failure = $_ }
            }
        }).AddArgument($modulePath).AddArgument($Run).AddArgument($Path).AddArgument($DeadlineUtc).AddArgument($ready).AddArgument($tracePath)
        $pending = $reader.BeginInvoke()
        if (-not $ready.Wait(5000)) { throw 'RECEIPT_HARNESS_MECHANICAL: reader did not reach its start barrier.' }
        $wait = if ($null -ne $PublishValue -and $HoldMilliseconds -eq 0) { 250 } else { $HoldMilliseconds }
        $completedBeforeRelease = $pending.AsyncWaitHandle.WaitOne([Math]::Max(0, $wait))
        if ($null -ne $held) { $held.Dispose(); $held = $null }
        if ($null -ne $PublishValue) {
            $temporary = "$Path.publish"
            [IO.File]::WriteAllText($temporary, (ConvertTo-Json $PublishValue -Compress), [Text.UTF8Encoding]::new($false))
            [IO.File]::Move($temporary, $Path, $true)
        }
        if (-not $pending.AsyncWaitHandle.WaitOne(5000)) {
            throw 'RECEIPT_HARNESS_MECHANICAL: production reader exceeded its bounded deadline.'
        }
        $values = @($reader.EndInvoke($pending))
        Assert-CapTest ($values.Count -eq 1) 'RECEIPT_HARNESS_MECHANICAL: reader returned no unique outcome.'
        return [pscustomobject]@{ Outcome = $values[0]; CompletedBeforeRelease = $completedBeforeRelease; TracePath = $tracePath }
    } finally {
        if ($null -ne $held) { $held.Dispose() }
        if ($null -ne $pending -and -not $pending.IsCompleted) { $reader.Stop() }
        $reader.Dispose()
        $ready.Dispose()
    }
}

function Get-CapReceiptControlCode {
    param($Failure)
    for ($exception = $Failure.Exception; $null -ne $exception; $exception = $exception.InnerException) {
        if ($exception.Data.Contains('CapCaptureCode')) { return [string]$exception.Data['CapCaptureCode'] }
    }
    return $null
}

function Invoke-CapReceiptIoCase {
    param([ValidateSet('exclusive-release','exclusive-deadline','partial-json','foreign-job','foreign-generation')][string]$Name)
    $directory = Join-Path $scratch ('receipt-io\' + $Name + '-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $directory
    $path = Join-Path $directory 'exit.json'
    $self = [Diagnostics.Process]::GetCurrentProcess()
    $run = [pscustomobject]@{
        JobId = [guid]::NewGuid().ToString('N'); SpecSha256 = ('A' * 64)
        TargetReceipt = [pscustomobject]@{ pid = 4242L; creationFileTimeUtc = 100000000L }
        ExitReceiptPath = $path
        Identity = [pscustomobject]@{ Process = $self; Pid = $self.Id }
    }
    $value = [pscustomobject]@{ jobId = $run.JobId; specSha256 = $run.SpecSha256
        pid = 4242L; creationFileTimeUtc = 100000000L; exitCode = 0L; kernelExited = $true }
    try {
        [IO.File]::WriteAllText($path, (ConvertTo-Json $value -Compress), [Text.UTF8Encoding]::new($false))
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        switch ($Name) {
            'exclusive-release' {
                $read = Invoke-CapReceiptReadControl $run $path $deadline -HoldMilliseconds 250
                if (-not $read.Outcome.Succeeded) { throw $read.Outcome.Failure }
                Assert-CapTest (-not $read.CompletedBeforeRelease -and $read.Outcome.Record.pid -eq 4242L) `
                    'Production reader did not wait for the exclusive holder before accepting the bound receipt.'
                $attempts = @(Get-Content -LiteralPath $read.TracePath | ForEach-Object { ConvertFrom-Json $_ } |
                    Where-Object { $_.command -ceq 'CapReceiptReadRetry' -and $_.parameters.Observation -ceq 'SharingViolation' })
                Assert-CapTest ($attempts.Count -gt 0) 'No actual production sharing-violation retry was observed.'
            }
            'exclusive-deadline' {
                $read = Invoke-CapReceiptReadControl $run $path ([DateTime]::UtcNow.AddMilliseconds(400)) -HoldMilliseconds 800
                Assert-CapTest (-not $read.Outcome.Succeeded -and
                    (Get-CapReceiptControlCode $read.Outcome.Failure) -ceq 'ReceiptDeadlineExceeded') `
                    'Exclusive receipt past the deadline did not preserve its typed refusal.'
            }
            'partial-json' {
                [IO.File]::WriteAllText($path, '{', [Text.UTF8Encoding]::new($false))
                $read = Invoke-CapReceiptReadControl $run $path $deadline -PublishValue $value
                if (-not $read.Outcome.Succeeded) { throw $read.Outcome.Failure }
                Assert-CapTest (-not $read.CompletedBeforeRelease -and $read.Outcome.Record.creationFileTimeUtc -eq 100000000L) `
                    'A partial JSON receipt was accepted before complete atomic publication.'
                $attempts = @(Get-Content -LiteralPath $read.TracePath | ForEach-Object { ConvertFrom-Json $_ } |
                    Where-Object { $_.command -ceq 'CapReceiptReadRetry' -and $_.parameters.Observation -ceq 'MalformedReceiptJson' })
                Assert-CapTest ($attempts.Count -gt 0) 'No actual partial-JSON retry was observed.'
            }
            'foreign-job' {
                $value.jobId = [guid]::NewGuid().ToString('N')
                [IO.File]::WriteAllText($path, (ConvertTo-Json $value -Compress))
                $read = Invoke-CapReceiptReadControl $run $path $deadline
                Assert-CapTest (-not $read.Outcome.Succeeded -and
                    (Get-CapReceiptControlCode $read.Outcome.Failure) -ceq 'ReceiptIdentityMismatch') 'Foreign job identity was not refused.'
            }
            'foreign-generation' {
                foreach ($field in @('pid','creationFileTimeUtc')) {
                    $foreign = $value.PSObject.Copy()
                    $foreign.$field++
                    [IO.File]::WriteAllText($path, (ConvertTo-Json $foreign -Compress))
                    $read = Invoke-CapReceiptReadControl $run $path $deadline
                    Assert-CapTest (-not $read.Outcome.Succeeded -and
                        (Get-CapReceiptControlCode $read.Outcome.Failure) -ceq 'ReceiptIdentityMismatch') 'Foreign target generation was not refused.'
                }
            }
        }
        return @{ name = $Name; productionReader = 'Read-CapJobTargetRecord'; nativeTargetLaunched = $false }
    } finally { $self.Dispose() }
}

if ($ReceiptContractOnly) {
    $receiptNames = @(if ($ReceiptExclusiveOnly) { @('exclusive-release') }
        else { @('exclusive-release','exclusive-deadline','partial-json','foreign-job','foreign-generation') })
    foreach ($receiptCaseName in $receiptNames) {
        Invoke-CapTest ("actual receipt file IO " + $receiptCaseName) { Invoke-CapReceiptIoCase $receiptCaseName }
    }
    $passed = @($results | Where-Object passed -EQ $true).Count
    $failed = @($results | Where-Object passed -EQ $false).Count
    $report = [ordered]@{ suite = 'UiCaptureReceiptContracts'; executed = $results.Count; passed = $passed; failed = $failed
        mode = 'FOCUSED_FILE_IO_NO_TARGET'; gui = 'NotExecuted'; images = 0; backendTurns = 0
        sourceHashesBeforeImport = $sourceHashesBefore; cases = @($results) }
    $report | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath (Join-Path $scratch 'report.json') -Encoding utf8NoBOM
    ([pscustomobject]$report) | Select-Object suite,executed,passed,failed | ConvertTo-Json -Compress
    if ($results.Count -ne $receiptNames.Count -or $failed -ne 0 -or $passed -ne $results.Count) { exit 1 }
    exit 0
}

function Invoke-CapPrebuiltFixtureContract {
    $savedScratch = $scratch
    $directory = Join-Path $scratch ('prebuilt-contract-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path (Join-Path $directory 'fixture'),(Join-Path $directory 'cim-race-fixture')
    try {
        $scratch = $directory
        foreach ($name in @(Get-CapFixtureArtifactNames)) {
            [IO.File]::WriteAllText((Join-Path $directory $name), 'SYNTHETIC_BINDING_BYTES_NOT_A_COMPILED_FIXTURE')
        }
        foreach ($pair in @(@('fixture','capture-target'),@('cim-race-fixture','cim-race-target'))) {
            $receipt = [ordered]@{ compilerExitCode = 0; compiler = 'C:\synthetic-cl.exe'
                compilerSha256 = ('C' * 64); compilerCommand = 'SYNTHETIC_BINDING_ONLY_NOT_A_COMPILE'
                compileProcess = [pscustomobject]@{ pid = 10L; creationFileTimeUtc = 100L
                    executable = 'C:\synthetic-cmd.exe'; heldKernelHandle = 123L; kernelExited = $true; exitCode = 0L } }
            foreach ($binding in @(@('executable','executableSha256','.exe'),@('source','sourceSha256','.c'),
                @('object','objectSha256','.obj'),@('compileStdoutLog','compileStdoutSha256','compile-stdout.log'),
                @('compileStderrLog','compileStderrSha256','compile-stderr.log'))) {
                $name = if ($binding[2].StartsWith('.')) { $pair[1] + $binding[2] } else { $binding[2] }
                $path = Join-Path $directory ($pair[0] + '\' + $name)
                $receipt[$binding[0]] = $path
                $receipt[$binding[1]] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            }
            $receipt.compileLogSnapshots = @('stdout','stderr') | ForEach-Object {
                $path = Join-Path $directory ($pair[0] + '\compile-' + $_ + '.log')
                $raw = Join-Path $directory ($pair[0] + '\compile-' + $_ + '.raw.log')
                [IO.File]::WriteAllText($raw,'SYNTHETIC_RAW_LOG_NOT_A_COMPILE')
                [pscustomobject]@{ rawPath = $raw
                    publishedPath = $path; sha256 = (Get-FileHash $path -Algorithm SHA256).Hash
                    length = [long](Get-Item $path).Length; observedUtc = [DateTimeOffset]::UtcNow.ToString('o'); rawEof = 'UNPROVEN' }
            }
            $receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory ($pair[0] + '\provenance.json')) -Encoding utf8NoBOM
        }
        $reference = Write-CapPrebuiltFixtureManifest
        $accepted = Read-CapPrebuiltFixtures $reference.path $reference.sha256
        Assert-CapTest ($accepted.Manifest.files.Count -eq 14 -and $accepted.Target.executable.EndsWith('capture-target.exe')) `
            'Actual prebuilt binder did not consume the complete fourteen-artifact manifest.'
        $null = Assert-CapRejects { Read-CapPrebuiltFixtures '' '' } 'PrebuiltFixtureRequired'
        $null = Assert-CapRejects { Read-CapPrebuiltFixtures $reference.path ('0' * 64) } 'hash mismatch'
        foreach ($fault in @('scenario','source')) {
            $foreign = $accepted.Manifest.PSObject.Copy()
            if ($fault -ceq 'scenario') { $foreign.scenario = 'FOREIGN_FIXTURE' }
            else {
                $foreign.sources = $foreign.sources.PSObject.Copy()
                $foreign.sources.'UiCaptureDriver.psm1' = '0' * 64
            }
            $foreignDirectory = Join-Path $directory $fault
            $null = New-Item -ItemType Directory -Path $foreignDirectory
            $foreignPath = Join-Path $foreignDirectory 'fixtures.json'
            Write-JournalContractJson $foreignPath $foreign
            $foreignHash = (Get-FileHash $foreignPath -Algorithm SHA256).Hash
            $expected = if ($fault -ceq 'scenario') { 'PrebuiltFixtureIdentity' } else { 'PrebuiltFixtureSource' }
            $null = Assert-CapRejects { Read-CapPrebuiltFixtures $foreignPath $foreignHash } $expected
        }
        $artifact = Join-Path $directory 'fixture\capture-target.obj'
        $original = [IO.File]::ReadAllBytes($artifact)
        [IO.File]::AppendAllText($artifact, 'TAMPER')
        $null = Assert-CapRejects { Read-CapPrebuiltFixtures $reference.path $reference.sha256 } 'PrebuiltFixtureHash'
        [IO.File]::WriteAllBytes($artifact, $original)
        $removed = Join-Path $directory 'fixture\saved-capture-target.obj'
        [IO.File]::Move($artifact, $removed)
        $missingRefused = $false
        try { $null = Read-CapPrebuiltFixtures $reference.path $reference.sha256 }
        catch [IO.FileNotFoundException] { $missingRefused = $true }
        Assert-CapTest $missingRefused 'Missing object bytes were accepted or silently rebuilt.'
        [IO.File]::Move($removed, $artifact)
        $raw = Join-Path $directory 'shared-writer.raw.log'
        $originalBytes = [byte[]]@(239,187,191,65,13,10,0,255)
        [IO.File]::WriteAllBytes($raw,$originalBytes)
        $writer = [IO.File]::Open($raw,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $snapshot = Read-CapCompileLogSnapshot $raw
            $writer.Position = 0; $writer.WriteByte(90); $writer.Flush($true)
            $published = Publish-CapCompileLogSnapshot $raw (Join-Path $directory 'immutable-snapshot.log') $snapshot
            $publishedBytes = [IO.File]::ReadAllBytes($published.publishedPath)
            Assert-CapTest ([Convert]::ToHexString($publishedBytes) -ceq [Convert]::ToHexString($originalBytes) -and
                $published.rawEof -ceq 'UNPROVEN' -and $published.length -eq 8) `
                'Snapshot publication reread/normalized the raw writer stream or invented EOF.'
            $missingSnapshot = Read-CapCompileLogSnapshot (Join-Path $directory 'absent.raw.log')
            $null = Assert-CapRejects {
                Publish-CapCompileLogSnapshot (Join-Path $directory 'absent.raw.log') (Join-Path $directory 'must-not-publish.log') $missingSnapshot
            } 'CompileLogSnapshotUnproven'
        } finally { $writer.Dispose() }
        return @{ subcases = 9; artifacts = 14; evidence = 'Actual binder, sharing raw writer and exact immutable byte snapshot; no compiler/target run.' }
    } finally { $scratch = $savedScratch }
}

function Get-CapJournalPostCopyObservations {
    param([Management.Automation.Language.Ast]$Ast)
    $readers = @($Ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Read-CapJournalObject'
    }, $true))
    Assert-CapTest ($readers.Count -eq 1) 'Journal reader AST is missing or duplicated.'
    $reader = $readers[0]
    $copies = @($reader.FindAll({ param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -ceq 'CopyTo'
    }, $true))
    Assert-CapTest ($copies.Count -eq 1) 'Journal CopyTo AST is missing or duplicated.'
    $copy = $copies[0]
    $checks = @($reader.FindAll({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Assert-CapJournalTime' -and $node.Extent.StartOffset -gt $copy.Extent.EndOffset
    }, $true) | Sort-Object { $_.Extent.StartOffset })
    Assert-CapTest ($checks.Count -gt 0) 'First post-copy time assertion is missing.'
    $firstCheck = $checks[0]
    return @($reader.FindAll({ param($node)
        if ($node -isnot [Management.Automation.Language.CommandAst] -or
            $node.GetCommandName() -cne 'Write-CapJournalObservation' -or
            $node.Extent.StartOffset -le $copy.Extent.EndOffset -or
            $node.Extent.EndOffset -ge $firstCheck.Extent.StartOffset) { return $false }
        for ($parent = $node.Parent; $null -ne $parent; $parent = $parent.Parent) {
            if ($parent -is [Management.Automation.Language.CatchClauseAst]) { return $false }
        }
        return $true
    }, $true))
}

function Invoke-CapJournalTimingContract {
    $readerAst = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$null)
    Assert-CapTest (@(Get-CapJournalPostCopyObservations $readerAst).Count -eq 0) `
        'A success-path observation write intervenes between CopyTo and its first deadline assertion.'
    $reader = @($readerAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Read-CapJournalObject'
    }, $true))[0]
    $copy = @($reader.FindAll({ param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -ceq 'CopyTo'
    }, $true))[0]
    $check = @($reader.FindAll({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Assert-CapJournalTime' -and $node.Extent.StartOffset -gt $copy.Extent.EndOffset
    }, $true) | Sort-Object { $_.Extent.StartOffset })[0]
    $position = $check.Extent.StartOffset - $reader.Extent.StartOffset
    $mutant = $reader.Extent.Text.Insert($position,
        "            Write-CapJournalObservation `$State `$Sequence `$attempt 'RenamedSuccessObservation' `$null `$Transaction`n")
    $mutantAst = [Management.Automation.Language.Parser]::ParseInput($mutant, [ref]$null, [ref]$null)
    Assert-CapTest (@(Get-CapJournalPostCopyObservations $mutantAst).Count -eq 1) `
        'Post-copy ordering contract failed to reject a renamed success-path observation.'
    $directory = Join-Path $scratch ('journal-timing-' + [guid]::NewGuid().ToString('N'))
    $snapshots = Join-Path $directory 'snapshots'
    $null = New-Item -ItemType Directory -Path $snapshots
    $binding = [pscustomobject]@{
        runId = [guid]::NewGuid().ToString(); leaseId = [guid]::NewGuid().ToString()
        jobSha256 = ('A' * 64); moduleSha256 = $sourceHashesBefore[$modulePath]
        workerSha256 = $sourceHashesBefore[$workerPath]; supervisorSha256 = $sourceHashesBefore[$supervisorPath]
        workerPid = 1L; workerCreationFileTimeUtc = 1L; workerImagePath = 'C:\synthetic-worker.exe'
        workerExecutableSha256 = ('B' * 64); workerParentPid = 2L; workerSessionId = 1L; workerRole = 'SYNTHETIC_TIMING_ONLY'
    }
    $observation = Join-Path $directory 'observations.jsonl'
    $state = New-CapJournalState -Root $scratch -Directory $snapshots -Binding $binding `
        -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(2)) -ObservationPath $observation
    $null = Publish-CapJournalSnapshot $state Bootstrap ([pscustomobject]@{ entries = @() })
    $module = Get-Module UiCaptureDriver
    $transaction = & $module { param($State) New-CapJournalTransaction $State } $state
    Assert-CapTest ($transaction.BudgetMilliseconds -eq 1000 -and
        $null -eq $transaction.OpenElapsedMilliseconds -and $null -eq $transaction.CopyElapsedMilliseconds) `
        'Timing instrumentation changed the 1000ms budget or invented unobserved phase durations.'
    $null = & $module { param($State,$Transaction) Read-CapJournalObject $State 1 $Transaction } $state $transaction
    Assert-CapTest ($null -ne $transaction.OpenElapsedMilliseconds -and $transaction.OpenElapsedMilliseconds -ge 0 -and
        $null -ne $transaction.CopyElapsedMilliseconds -and $transaction.CopyElapsedMilliseconds -ge 0) `
        'Actual Open/Copy phases were not measured.'
    $events = @(Get-Content -LiteralPath $observation | ForEach-Object { ConvertFrom-Json $_ -DateKind String })
    $verified = @($events | Where-Object decision -CEQ 'ReadVerified')
    Assert-CapTest ($verified.Count -eq 1 -and
        $verified[0].openElapsedMilliseconds -eq $transaction.OpenElapsedMilliseconds -and
        $verified[0].copyElapsedMilliseconds -eq $transaction.CopyElapsedMilliseconds -and
        $verified[0].totalElapsedMilliseconds -ge 0) `
        'Existing post-verification observation lacks the actual Open/Copy accumulator values.'
    Start-Sleep -Milliseconds 1050
    $failure = Assert-CapRejects {
        & $module { param($Transaction) Assert-CapJournalTime $Transaction 1 } $transaction
    } 'JournalUnavailable'
    Assert-CapTest ($failure -match 'openMs=[0-9]' -and $failure -match 'copyMs=[0-9]' -and
        $failure -match 'totalMs=[0-9]' -and $transaction.BudgetMilliseconds -eq 1000 -and $transaction.Retries -eq 0) `
        'Deadline message lost actual phases or changed the original timing/retry contract.'
    $missing = & $module { param($State) New-CapJournalTransaction $State } $state
    $null = Assert-CapRejects {
        & $module { param($State,$Transaction) Read-CapJournalObject $State 2 $Transaction } $state $missing
    } 'JournalUnavailable'
    Assert-CapTest ($missing.Retries -eq 7 -and $missing.Attempts[2L] -eq 8 -and
        $null -ne $missing.OpenElapsedMilliseconds -and $null -eq $missing.CopyElapsedMilliseconds) `
        'Open throw-path timing changed the seven-retry/eight-attempt limit or fabricated copy time.'
    return @{ subcases = 4; budgetMilliseconds = 1000; retryLimit = 7; openAttempts = 8
        mode = 'Actual file Open/Copy observations plus elapsed-clock refusal; no native target.' }
}

function New-CapFirstOpenContext {
    param([string]$Name)
    $directory = Join-Path $scratch $Name
    $null = New-Item -ItemType Directory -Path (Join-Path $directory 'snapshots')
    $binding = [pscustomobject]@{
        runId = [guid]::NewGuid().ToString(); leaseId = [guid]::NewGuid().ToString()
        jobSha256 = ('A' * 64); moduleSha256 = $sourceHashesBefore[$modulePath]
        workerSha256 = $sourceHashesBefore[$workerPath]; supervisorSha256 = $sourceHashesBefore[$supervisorPath]
        workerPid = 1L; workerCreationFileTimeUtc = 1L; workerImagePath = 'C:\synthetic-worker.exe'
        workerExecutableSha256 = ('B' * 64); workerParentPid = 2L; workerSessionId = 1L
        workerRole = 'SYNTHETIC_FIRST_OPEN_FILE_IO'
    }
    $state = New-CapJournalState -Root $scratch -Directory (Join-Path $directory 'snapshots') `
        -Binding $binding -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(2)) `
        -ObservationPath (Join-Path $directory 'observations.jsonl')
    $null = Publish-CapJournalSnapshot $state Bootstrap ([pscustomobject]@{ entries = @(); counter = 1L })
    return $state
}

function Wait-CapMeasuredDelay {
    param([Diagnostics.Stopwatch]$Clock, [double]$Milliseconds = 1500)
    $cap = [Diagnostics.Stopwatch]::StartNew()
    while ($Clock.Elapsed.TotalMilliseconds -lt $Milliseconds) {
        if ($cap.Elapsed.TotalMilliseconds -ge 5000) {
            $failure = [IO.IOException]::new('HARNESSFAIL: elapsed delay did not reach its unchanged threshold within 5000ms.')
            $failure.Data['CapTestHarnessFailure'] = 'ElapsedDelay'
            $failure.Data['CapTestDetail'] = @{ delayMilliseconds = $Clock.Elapsed.TotalMilliseconds
                capMilliseconds = $cap.Elapsed.TotalMilliseconds; requiredMilliseconds = $Milliseconds }
            throw $failure
        }
        Start-Sleep -Milliseconds ([int][Math]::Max(1, [Math]::Ceiling(
            [Math]::Min(100, $Milliseconds - $Clock.Elapsed.TotalMilliseconds))))
    }
    if ($cap.Elapsed.TotalMilliseconds -ge 5000) {
        $failure = [IO.IOException]::new('HARNESSFAIL: elapsed delay exceeded its 5000ms cap.')
        $failure.Data['CapTestHarnessFailure'] = 'ElapsedDelay'
        $failure.Data['CapTestDetail'] = @{ delayMilliseconds = $Clock.Elapsed.TotalMilliseconds
            capMilliseconds = $cap.Elapsed.TotalMilliseconds; requiredMilliseconds = $Milliseconds }
        throw $failure
    }
}

function Invoke-CapJournalObservationContract {
    if (-not ('CapObservationFlushStream' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Diagnostics;
using System.Threading;
public sealed class CapObservationFlushStream : FileStream {
    public static int DurableCalls;
    public static int BufferedCalls;
    public static double DelayMilliseconds;
    public static bool DelayDurable = true;
    public static bool FailFlush;
    public static int FlushDelayMilliseconds;
    public static int DisposeDelayMilliseconds;
    public static int ReaderOpenCalls;
    public static int InjectedSharingErrors;
    public static int ReaderErrorHresult = unchecked((int)0x80070020);
    public static FileStream OpenJournal(string path, FileMode mode, FileAccess access, FileShare share) {
        ReaderOpenCalls++;
        if (ReaderOpenCalls <= 2) {
            InjectedSharingErrors++;
            throw new IOException("Injected journal Open HRESULT.", ReaderErrorHresult);
        }
        return File.Open(path, mode, access, share);
    }
    public CapObservationFlushStream(string path, FileMode mode, FileAccess access, FileShare share)
        : base(path, mode, access, share) { }
    public override void Flush(bool flushToDisk) {
        if (flushToDisk) {
            DurableCalls++;
            if (DelayDurable) {
                var clock = Stopwatch.StartNew();
                while (clock.Elapsed.TotalMilliseconds < 1500) {
                    if (clock.Elapsed.TotalMilliseconds >= 5000)
                        throw new IOException("HARNESSFAIL: slow durability seam exceeded 5000ms.");
                    Thread.Sleep(Math.Max(1, (int)Math.Ceiling(Math.Min(100, 1500-clock.Elapsed.TotalMilliseconds))));
                }
                DelayMilliseconds = clock.Elapsed.TotalMilliseconds;
                if (DelayMilliseconds >= 5000)
                    throw new IOException("HARNESSFAIL: slow durability seam exceeded 5000ms.");
            }
        }
        base.Flush(flushToDisk);
    }
    public override void Flush() {
        BufferedCalls++;
        if (FailFlush) throw new IOException("Injected observation flush failure.");
        WaitMeasuredDelay(FlushDelayMilliseconds);
        base.Flush();
    }
    protected override void Dispose(bool disposing) {
        try { if (disposing) WaitMeasuredDelay(DisposeDelayMilliseconds); }
        finally { base.Dispose(disposing); }
    }
    private static void WaitMeasuredDelay(int milliseconds) {
        var clock = Stopwatch.StartNew();
        while (clock.Elapsed.TotalMilliseconds < milliseconds && clock.Elapsed.TotalMilliseconds < 5000)
            Thread.Sleep(Math.Max(1, (int)Math.Ceiling(Math.Min(10, milliseconds-clock.Elapsed.TotalMilliseconds))));
        if (clock.Elapsed.TotalMilliseconds >= 5000) {
            var failure = new IOException("HARNESSFAIL: observation measurement delay exceeded 5000ms.");
            failure.Data["CapTestHarnessFailure"] = "ElapsedDelay";
            throw failure;
        }
    }
}
'@
    }
    [CapObservationFlushStream]::DurableCalls = 0
    [CapObservationFlushStream]::BufferedCalls = 0
    [CapObservationFlushStream]::DelayMilliseconds = 0
    [CapObservationFlushStream]::DelayDurable = $true
    $state = New-CapFirstOpenContext 'observation-buffered-success'
    $module = Get-Module UiCaptureDriver
    $original = & $module { (Get-Item Function:Write-CapJournalObservation).ScriptBlock }
    $originalReader = & $module { (Get-Item Function:Read-CapJournalObject).ScriptBlock }
    $needle = '[IO.File]::Open($State.ObservationPath,'
    Assert-CapTest ([regex]::Matches($original.ToString(), [regex]::Escape($needle)).Count -eq 1) `
        'Observation seam requires exactly one actual file-open constructor.'
    $injected = [scriptblock]::Create($original.ToString().Replace($needle,
        '[CapObservationFlushStream]::new($State.ObservationPath,'))
    $readerNeedle = '[IO.File]::Open($path,'
    Assert-CapTest ([regex]::Matches($originalReader.ToString(), [regex]::Escape($readerNeedle)).Count -eq 1) `
        'Retry seam requires exactly one actual reader file-open constructor.'
    $injectedReader = [scriptblock]::Create($originalReader.ToString().Replace($readerNeedle,
        '[CapObservationFlushStream]::OpenJournal($path,'))
    try {
        & $module { param($Body) Set-Item Function:Write-CapJournalObservation -Value $Body } $injected
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $reading = $null
        $readFailure = $null
        try { $reading = Read-CapJournalSnapshot $state }
        catch { $readFailure = $_.Exception.ToString() }
        $clock.Stop()
        $detail = @{ elapsedMilliseconds = $clock.Elapsed.TotalMilliseconds
            injectedDurableDelayMilliseconds = [CapObservationFlushStream]::DelayMilliseconds
            durableCalls = [CapObservationFlushStream]::DurableCalls
            bufferedCalls = [CapObservationFlushStream]::BufferedCalls
            readFailure = $readFailure; seam = 'Actual writer with only File.Open constructor replaced; actual reader and file IO.' }
        Assert-CapTest ($null -eq $readFailure -and $null -ne $reading -and
            $reading.Snapshot.Reference.length -gt 0 -and $clock.Elapsed.TotalMilliseconds -lt 1000) `
            'Success observations consumed the I/O budget through the injected 1500ms disk-flush seam.' $detail
        $events = @(Get-Content -LiteralPath $state.ObservationPath | ForEach-Object { ConvertFrom-Json $_ })
        Assert-CapTest ($events.Count -eq 2 -and $events[0].decision -ceq 'ReadVerified' -and
            $events[1].decision -ceq 'AcceptedLiveSequenceOnly' -and
            [CapObservationFlushStream]::DurableCalls -eq 0 -and
            [CapObservationFlushStream]::BufferedCalls -eq 2) `
            'Buffered observations changed the existing count or invoked durable success flushing.' $detail
        Assert-CapTest ($null -eq $events[0].previousObservationWriteMs -and
            $null -eq $events[0].previousObservationOrdinal -and $events[0].observationOrdinal -eq 1 -and
            $events[1].observationOrdinal -eq 2 -and $events[1].previousObservationOrdinal -eq 1 -and
            $events[1].previousObservationWriteMs -gt 0 -and
            $events[0].observationTransactionId -cmatch '\A[0-9a-f]{32}\z' -and
            $events[1].observationTransactionId -ceq $events[0].observationTransactionId -and
            $events[1].runId -ceq $events[0].runId) `
            'Lagged observation timing lost its first-record nulls or causal transaction/ordinal binding.'
        $retryState = New-CapFirstOpenContext 'observation-buffered-retry'
        $retryPath = Join-Path $retryState.Directory '000001.json'
        [CapObservationFlushStream]::ReaderOpenCalls = 0
        [CapObservationFlushStream]::InjectedSharingErrors = 0
        $probeErrors = [Collections.Generic.List[string]]::new()
        foreach ($probe in 1..2) {
            try {
                $unexpected = [CapObservationFlushStream]::OpenJournal($retryPath,
                    [IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                $unexpected.Dispose()
                throw 'Configured sharing-error probe unexpectedly opened.'
            } catch {
                $native = & $module { param($Failure) Get-CapJournalNativeError $Failure } $_.Exception
                Assert-CapTest ($native -ceq '80070020') 'Sharing-error probe lost its injected typed HRESULT.'
                $probeErrors.Add($native)
            }
        }
        $probeStream = [CapObservationFlushStream]::OpenJournal($retryPath,
            [IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try { Assert-CapTest ($probeStream.Length -gt 0) 'Third configured Open did not read a nonempty real file.' }
        finally { $probeStream.Dispose() }
        [CapObservationFlushStream]::ReaderOpenCalls = 0
        [CapObservationFlushStream]::InjectedSharingErrors = 0
        [CapObservationFlushStream]::DurableCalls = 0
        [CapObservationFlushStream]::BufferedCalls = 0
        [CapObservationFlushStream]::DelayMilliseconds = 0
        & $module { param($Body) Set-Item Function:Read-CapJournalObject -Value $Body } $injectedReader
        $retryTransaction = & $module { param($State) New-CapJournalTransaction $State } $retryState
        $retryClock = [Diagnostics.Stopwatch]::StartNew()
        $retryRead = $null
        $retryFailure = $null
        try {
            $retryRead = & $module {
                param($State,$Transaction)
                Read-CapJournalObject $State 1 $Transaction
            } $retryState $retryTransaction
            & $module {
                param($State,$Transaction)
                Write-CapJournalObservation $State 1 3 'AcceptedLiveSequenceOnly' $null $Transaction
                Assert-CapJournalTime $Transaction 1
            } $retryState $retryTransaction
        } catch { $retryFailure = $_.Exception.ToString() }
        $retryClock.Stop()
        $retryDetail = @{ elapsedMilliseconds = $retryClock.Elapsed.TotalMilliseconds
            injectedSharingErrors = [CapObservationFlushStream]::InjectedSharingErrors
            actualReaderOpenCalls = [CapObservationFlushStream]::ReaderOpenCalls
            retries = $retryTransaction.Retries; attempts = $retryTransaction.Attempts[1L]
            durableCalls = [CapObservationFlushStream]::DurableCalls
            bufferedCalls = [CapObservationFlushStream]::BufferedCalls
            injectedDurableDelayMilliseconds = [CapObservationFlushStream]::DelayMilliseconds
            probeErrors = @($probeErrors.ToArray()); probeThirdRealFile = $true; failure = $retryFailure
            seam = 'Injected typed sharing HRESULTs, not kernel sharing evidence; unique reader Open constructor substitution.' }
        Assert-CapTest ($null -eq $retryFailure -and $null -ne $retryRead -and
            $retryRead.Reference.length -gt 0 -and $retryClock.Elapsed.TotalMilliseconds -lt 1000 -and
            [CapObservationFlushStream]::InjectedSharingErrors -eq 2 -and
            [CapObservationFlushStream]::ReaderOpenCalls -eq 3 -and
            $retryTransaction.Retries -eq 2 -and $retryTransaction.Attempts[1L] -eq 3) `
            'Transient retry observations consumed the unchanged read budget through slow durable flush.' $retryDetail
        Assert-CapTest ([CapObservationFlushStream]::BufferedCalls -eq 4 -and
            [CapObservationFlushStream]::DurableCalls -eq 0) `
            'Two transient failures and two successes must use exactly four buffered writes.' $retryDetail
        $detail.retry = $retryDetail
        & $module { param($Body) Set-Item Function:Read-CapJournalObject -Value $Body } $originalReader
        [CapObservationFlushStream]::DelayDurable = $false
        $transaction = & $module { param($State) New-CapJournalTransaction $State } $state
        & $module {
            param($State,$Transaction)
            Write-CapJournalObservation $State 1 1 'OtherNonFailureDecision' $null $Transaction
            Write-CapJournalObservation $State 1 1 'OpenFailed' '80070020' $Transaction
            Write-CapJournalObservation $State 1 1 'OpenFailed' '80070005' $Transaction -TerminalFailure
            Write-CapJournalObservation $State 1 1 'ReadVerified' $null $Transaction -TerminalFailure
            Write-CapJournalObservation $State 1 1 'OtherNonFailureDecision' $null $Transaction -TerminalFailure
        } $state $transaction
        Assert-CapTest ([CapObservationFlushStream]::BufferedCalls -eq 8 -and
            [CapObservationFlushStream]::DurableCalls -eq 1) `
            'Transient failures and successes must be buffered; only terminal failures may request durability.' $detail
        $durableBefore = [CapObservationFlushStream]::DurableCalls
        $bufferedBefore = [CapObservationFlushStream]::BufferedCalls
        $terminalState = New-CapFirstOpenContext 'observation-terminal-policy'
        $terminalState.ObservationPath = Join-Path (Split-Path -Parent $terminalState.Directory) 'terminal-observations.jsonl'
        $capTransaction = & $module { param($State) New-CapJournalTransaction $State } $terminalState
        $capTransaction.Retries = 7
        $null = Assert-CapRejects {
            & $module { param($State,$Transaction) Read-CapJournalObject $State 2 $Transaction } $terminalState $capTransaction
        } 'JournalUnavailable'
        Assert-CapTest ($capTransaction.Retries -eq 7 -and $capTransaction.Attempts[2L] -eq 1) `
            'Terminal global-cap fixture changed the existing retry/attempt state.'
        $manifestTransaction = & $module { param($State) New-CapJournalTransaction $State -ManifestBudget } $terminalState
        $manifestTransaction.Retries = 7
        $null = Assert-CapRejects {
            & $module {
                param($State,$Transaction)
                Open-CapJournalManifestStream $State (Join-Path $State.Directory 'missing-manifest.json') $Transaction 1
            } $terminalState $manifestTransaction
        } 'JournalUnavailable'
        [CapObservationFlushStream]::ReaderOpenCalls = 0
        [CapObservationFlushStream]::ReaderErrorHresult = [int]-2147024891
        & $module { param($Body) Set-Item Function:Read-CapJournalObject -Value $Body } $injectedReader
        $deniedTransaction = & $module { param($State) New-CapJournalTransaction $State } $terminalState
        try {
            $null = Assert-CapRejects {
                & $module { param($State,$Transaction) Read-CapJournalObject $State 1 $Transaction } $terminalState $deniedTransaction
            } 'JournalAccessDenied'
        } finally {
            [CapObservationFlushStream]::ReaderErrorHresult = [int]-2147024864
            & $module { param($Body) Set-Item Function:Read-CapJournalObject -Value $Body } $originalReader
        }
        $null = & $module {
            param($State,$Transaction)
            Write-CapJournalObservation $State 1 1 'CopyFailed' '80070020' $Transaction
            Write-CapJournalObservation $State 1 1 'DeadlineExhausted' '80070020' $Transaction
            Write-CapJournalObservation $State 1 1 'FinalManifestOpenFailed' '80070020' $Transaction
        } $terminalState $deniedTransaction
        Assert-CapTest ([CapObservationFlushStream]::DurableCalls -eq $durableBefore + 5 -and
            [CapObservationFlushStream]::BufferedCalls -eq $bufferedBefore + 1 -and
            $deniedTransaction.Retries -eq 0 -and $deniedTransaction.Attempts[1L] -eq 1) `
            'Terminal reader/cap/manifest/copy/deadline policy or transient manifest buffering differs.'
        $actorRoot = Join-Path $scratch 'actor-primary-message'
        $null = New-Item -ItemType Directory -Path $actorRoot
        Write-JournalContractJson (Join-Path $actorRoot 'Reader-failed.json') @{
            error = 'JournalUnavailable: retained known reader primary'
        }
        Write-JournalContractJson (Join-Path $actorRoot 'Writer-failed.json') @{
            error = 'Writer retained known primary'
        }
        $message = Format-JournalActorCleanupFailure $actorRoot @('Actor normal exit/kernel/bothEOF not proven.')
        $rendered = Assert-CapRejects { Assert-CapTest $false $message } 'Empty/incomplete actual actor cleanup'
        Assert-CapTest ($rendered.Contains('Actor normal exit/kernel/bothEOF not proven.') -and
            $rendered.Contains('JournalUnavailable: retained known reader primary') -and
            $rendered.Contains('Writer retained known primary')) `
            'Actual cleanup assertion message masked actor primary or weakened cleanup failure detail.'
        $missingRoot = Join-Path $scratch 'actor-primary-missing'
        $missingMessage = Format-JournalActorCleanupFailure $missingRoot @('EOF not proven')
        Assert-CapTest ($missingMessage.Contains('Reader-failed.json: MISSING') -and
            $missingMessage.Contains('Writer-failed.json: MISSING')) 'Missing actor primary must be explicit.'
        $boundedRoot = Join-Path $scratch 'actor-primary-bounded'
        $null = New-Item -ItemType Directory -Path (Join-Path $boundedRoot 'Reader-failed.json')
        [IO.File]::WriteAllText((Join-Path $boundedRoot 'Writer-failed.json'),('x' * 17000))
        $boundedMessage = Format-JournalActorCleanupFailure $boundedRoot @('EOF not proven')
        Assert-CapTest ($boundedMessage.Contains('Reader-failed.json: READ_ERROR') -and
            $boundedMessage.Contains('[TRUNCATED at 16384 bytes]') -and $boundedMessage.Length -lt 17000) `
            'Unreadable or oversized actor primary must be explicit and bounded.'
        $detail.actorFailureMessage = $rendered
        $measured = & $module { param($State) New-CapJournalTransaction $State } $state
        [CapObservationFlushStream]::FlushDelayMilliseconds = 60
        [CapObservationFlushStream]::DisposeDelayMilliseconds = 60
        & $module {
            param($State,$Transaction)
            Write-CapJournalObservation $State 1 1 'MeasuredCompletion' $null $Transaction
        } $state $measured
        $completed = $measured.LastCompletedObservationWriteMilliseconds
        Assert-CapTest ($completed -ge 120 -and $measured.LastCompletedObservationOrdinal -eq 1) `
            'Completed observation measurement excluded its actual Flush or Dispose delay.'
        [CapObservationFlushStream]::FailFlush = $true
        try {
            $null = Assert-CapRejects {
                & $module {
                    param($State,$Transaction)
                    Write-CapJournalObservation $State 1 1 'InjectedFailedWrite' $null $Transaction
                } $state $measured
            } 'JournalObservationFailure'
        } finally { [CapObservationFlushStream]::FailFlush = $false }
        Assert-CapTest ($measured.ObservationOrdinal -eq 2 -and
            $measured.LastCompletedObservationOrdinal -eq 1 -and
            $measured.LastCompletedObservationWriteMilliseconds -eq $completed) `
            'Failed observation advanced the last-completed timing pair.'
        & $module {
            param($State,$Transaction)
            Write-CapJournalObservation $State 1 1 'AfterFailedWrite' $null $Transaction
        } $state $measured
        $last = Get-Content -LiteralPath $state.ObservationPath | Select-Object -Last 1 | ConvertFrom-Json
        Assert-CapTest ($last.observationOrdinal -eq 3 -and $last.previousObservationOrdinal -eq 1 -and
            $last.previousObservationWriteMs -eq $completed -and
            $last.observationTransactionId -ceq $measured.ObservationTransactionId -and
            $last.observationTransactionId -cne $events[0].observationTransactionId -and
            $measured.LastCompletedObservationOrdinal -eq 3) `
            'The following record fabricated N-1 or crossed transaction timing identities.'
        $detail.completedObservationWriteMilliseconds = $completed
        $detail.failedOrdinalSkipped = 2
        return $detail
    } finally {
        try { & $module { param($Body) Set-Item Function:Read-CapJournalObject -Value $Body } $originalReader }
        finally { & $module { param($Body) Set-Item Function:Write-CapJournalObservation -Value $Body } $original }
        $restoredReader = & $module { (Get-Item Function:Read-CapJournalObject).ScriptBlock.ToString() }
        Assert-CapTest ($restoredReader -ceq $originalReader.ToString()) 'Actual journal reader was not restored after retry seam.'
        [CapObservationFlushStream]::FailFlush = $false
        [CapObservationFlushStream]::ReaderErrorHresult = [int]-2147024864
        [CapObservationFlushStream]::FlushDelayMilliseconds = 0
        [CapObservationFlushStream]::DisposeDelayMilliseconds = 0
        $restored = & $module { (Get-Item Function:Write-CapJournalObservation).ScriptBlock.ToString() }
        Assert-CapTest ($restored -ceq $original.ToString()) 'Actual observation writer was not restored after its test seam.'
    }
}

function Invoke-CapFirstOpenGroups {
    Invoke-CapTest 'journal first Open excludes actual 1500ms caller preparation and starts only once' {
        $state = New-CapFirstOpenContext 'first-open-delay'
        $held = [IO.File]::Open((Join-Path $state.Directory '000001.json'), [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $proof = & (Get-Module UiCaptureDriver) {
                param($State,$WaitDelay)
                $transaction = New-CapJournalTransaction $State
                $delay = [Diagnostics.Stopwatch]::StartNew()
                & $WaitDelay $delay
                $delay.Stop()
                Assert-CapJournalTime $transaction 1
                $names = Get-CapJournalNames $State
                $read = Read-CapJournalObject $State 1 $transaction
                [pscustomobject]@{ Transaction = $transaction; Read = $read
                    DelayMilliseconds = $delay.Elapsed.TotalMilliseconds; Names = $names.Count }
            } $state ${function:Wait-CapMeasuredDelay}
            Assert-CapTest ($proof.DelayMilliseconds -ge 1500 -and $proof.Names -eq 1 -and
                $proof.Read.Reference.length -gt 0 -and $proof.Read.Payload.data.counter -eq 1) `
                'Actual delayed caller preparation did not return the nonempty valid held-file publication.' `
                @{ delayMilliseconds = $proof.DelayMilliseconds; names = $proof.Names
                    length = $proof.Read.Reference.length; counter = $proof.Read.Payload.data.counter }
            $clock = $proof.Transaction.IoClock
            $deadline = $proof.Transaction.DeadlineUtc
            $null = & (Get-Module UiCaptureDriver) {
                param($State,$Transaction) Read-CapJournalObject $State 1 $Transaction
            } $state $proof.Transaction
            Assert-CapTest ([object]::ReferenceEquals($clock, $proof.Transaction.IoClock) -and
                $deadline -eq $proof.Transaction.DeadlineUtc -and $proof.Transaction.Attempts[1L] -eq 2 -and
                $proof.Transaction.Retries -eq 0 -and $proof.Transaction.PreOpenElapsedMilliseconds -ge 1500) `
                'A later object read restarted the transaction I/O budget or reset its counters.'
            $events = @(Get-Content -LiteralPath $state.ObservationPath | ForEach-Object { ConvertFrom-Json $_ })
            Assert-CapTest ($events.Count -eq 2 -and
                @($events | Where-Object { $_.PSObject.Properties.Name -contains 'preOpenMs' -or
                    $_.PSObject.Properties.Name -contains 'firstOpen' }).Count -eq 0) `
                'First-Open diagnostics added success-path observation fields or writes.'
            $retryState = New-CapFirstOpenContext 'first-open-shared-retries'
            $retryState.ObservationPath = $null
            $retryTransaction = & (Get-Module UiCaptureDriver) { param($State) New-CapJournalTransaction $State } $retryState
            $retryClock = $null
            $retryDeadline = $null
            foreach ($sequence in @(2L,3L)) {
                $null = Assert-CapRejects {
                    & (Get-Module UiCaptureDriver) {
                        param($State,$Transaction,$Sequence)
                        try { Read-CapJournalObject $State $Sequence $Transaction }
                        catch {
                            if ($_.Exception.Data['CapJournalFailure'] -cne 'JournalUnavailable') {
                                throw 'Retry refusal lost its typed journal classification.'
                            }
                            throw
                        }
                    } $retryState $retryTransaction $sequence
                } 'JournalUnavailable'
                if ($sequence -eq 2L) {
                    $retryClock = $retryTransaction.IoClock
                    $retryDeadline = $retryTransaction.DeadlineUtc
                }
            }
            Assert-CapTest ($null -ne $retryClock -and [object]::ReferenceEquals($retryClock, $retryTransaction.IoClock) -and
                $retryDeadline -eq $retryTransaction.DeadlineUtc -and $retryTransaction.Retries -eq 7 -and
                $retryTransaction.Attempts[2L] -eq 8 -and $retryTransaction.Attempts[3L] -eq 1) `
                'A new sequence reset the shared I/O budget, eight-attempt cap, or seven global retries.'
            return @{ delayMilliseconds = $proof.DelayMilliseconds; length = $proof.Read.Reference.length
                attempts = $proof.Transaction.Attempts[1L]; budgetMilliseconds = $proof.Transaction.BudgetMilliseconds }
        } finally { $held.Dispose() }
    }
    Invoke-CapTest 'journal absolute deadline refuses pre-Open without an attempt and clips the once-started budget' {
        $state = New-CapFirstOpenContext 'first-open-absolute'
        $state.DeadlineUtc = [DateTime]::UtcNow.AddMilliseconds(250)
        $transaction = & (Get-Module UiCaptureDriver) { param($State) New-CapJournalTransaction $State } $state
        $delay = [Diagnostics.Stopwatch]::StartNew()
        Wait-CapMeasuredDelay $delay
        $delay.Stop()
        $failure = Assert-CapRejects {
            & (Get-Module UiCaptureDriver) { param($State,$Transaction) Read-CapJournalObject $State 1 $Transaction } $state $transaction
        } 'JournalUnavailable'
        Assert-CapTest ($delay.Elapsed.TotalMilliseconds -ge 1500 -and
            $failure -match 'preOpenMs=([0-9]+\.[0-9]+)' -and
            [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) -ge 1500 -and
            $failure.Contains('firstOpen=NOT_ATTEMPTED') -and $transaction.Attempts.Count -eq 0 -and
            $null -eq $transaction.OpenElapsedMilliseconds -and $null -eq $transaction.CopyElapsedMilliseconds) `
            'Absolute refusal lost elapsed pre-open time, fabricated an Open, or allowed late success.' `
            @{ delayMilliseconds = $delay.Elapsed.TotalMilliseconds; refusal = $failure }
        $observations = @(Get-Content -LiteralPath $state.ObservationPath | ForEach-Object { ConvertFrom-Json $_ })
        Assert-CapTest ($observations.Count -eq 1 -and $observations[0].decision -ceq 'DeadlineExhausted' -and
            $observations[0].preOpenMs -ge 1500 -and $observations[0].firstOpen -ceq 'NOT_ATTEMPTED') `
            'Absolute pre-open refusal lacks its failure-only observation.'
        $state = New-CapFirstOpenContext 'first-open-clipped'
        $state.DeadlineUtc = [DateTime]::UtcNow.AddMilliseconds(750)
        $proof = & (Get-Module UiCaptureDriver) {
            param($State)
            $transaction = New-CapJournalTransaction $State
            Start-Sleep -Milliseconds 250
            $read = Read-CapJournalObject $State 1 $transaction
            [pscustomobject]@{ Transaction = $transaction; Read = $read }
        } $state
        Assert-CapTest ($proof.Read.Reference.length -gt 0 -and $proof.Transaction.BudgetMilliseconds -gt 0 -and
            $proof.Transaction.BudgetMilliseconds -lt 750 -and $proof.Transaction.DeadlineUtc -le $state.DeadlineUtc) `
            'First Open did not clip its I/O budget to the absolute deadline.'
        Start-Sleep -Milliseconds 800
        $null = Assert-CapRejects {
            & (Get-Module UiCaptureDriver) { param($State,$Transaction) Read-CapJournalObject $State 1 $Transaction } $state $proof.Transaction
        } 'JournalUnavailable'
        Assert-CapTest ($proof.Transaction.Attempts[1L] -eq 1) 'Absolute expiry allowed another Open or reset the attempt count.'
        $manifestState = New-CapFirstOpenContext 'manifest-creation-budget'
        $manifestTransaction = & (Get-Module UiCaptureDriver) {
            param($State) New-CapJournalTransaction $State -ManifestBudget
        } $manifestState
        Start-Sleep -Milliseconds 1500
        $manifestFailure = Assert-CapRejects {
            & (Get-Module UiCaptureDriver) {
                param($State,$Transaction)
                Open-CapJournalManifestStream $State (Join-Path $State.Directory '000001.json') $Transaction 1
            } $manifestState $manifestTransaction
        } 'JournalUnavailable'
        Assert-CapTest ($manifestTransaction.BudgetMilliseconds -eq 1000 -and
            [object]::ReferenceEquals($manifestTransaction.Clock, $manifestTransaction.IoClock) -and
            $null -eq $manifestTransaction.PreOpenElapsedMilliseconds -and
            $manifestFailure.Contains('firstOpen=NOT_ATTEMPTED')) `
            'Final manifest lost its creation-started 1000ms budget or attempted a late Open.'
        $manifestState.ObservationPath = $manifestState.Directory
        try {
            & (Get-Module UiCaptureDriver) { param($Transaction) Assert-CapJournalTime $Transaction 1 } $manifestTransaction
            throw 'Expired manifest unexpectedly passed with an unavailable observation sink.'
        } catch {
            Assert-CapTest ($_.Exception.Data['CapJournalFailure'] -ceq 'JournalUnavailable' -and
                $_.Exception.Data.Contains('CapJournalObservationFailure')) `
                'Failure observation masked the primary JournalUnavailable instead of retaining a secondary diagnostic.'
        }
        return @{ subcases = 4; delayMilliseconds = $delay.Elapsed.TotalMilliseconds
            preOpenRefusal = $failure; manifestRefusal = $manifestFailure
            clippedBudgetMilliseconds = $proof.Transaction.BudgetMilliseconds }
    }
}

function Invoke-CapPreflightReportContract {
    $ast = [Management.Automation.Language.Parser]::ParseFile($supervisorPath,[ref]$null,[ref]$null)
    $definitions = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-CapPreflightReport'
    },$true))
    Assert-CapTest ($definitions.Count -eq 1) 'Actual report-preflight function is missing or duplicated.'
    $definition = $definitions[0]
    . ([scriptblock]::Create($definition.Extent.Text))
    $requirements = @($definition.FindAll({ param($node)
        $node -is [Management.Automation.Language.ForEachStatementAst] -and
        $node.Variable.VariablePath.UserPath -ceq 'required'
    },$true))
    Assert-CapTest ($requirements.Count -eq 1) 'Actual required-case list is missing or duplicated.'
    $requiredNames = @($requirements[0].Condition.FindAll({ param($node)
        $node -is [Management.Automation.Language.StringConstantExpressionAst]
    },$true) | ForEach-Object Value)
    Assert-CapTest ($requiredNames.Count -gt 0 -and
        @($requiredNames | Sort-Object -Unique).Count -eq $requiredNames.Count) 'Synthetic case inventory is empty or duplicated.'
    $moduleHash = $sourceHashesBefore[$modulePath]
    $workerHash = $sourceHashesBefore[$workerPath]
    $supervisorHash = $sourceHashesBefore[$supervisorPath]
    $preflightHash = 'A' * 64
    $PreflightReceiptSha256 = $preflightHash
    $job = [pscustomobject]@{ binaries = [pscustomobject]@{ offlineZmx = [pscustomobject]@{
        sha256 = 'DFFF744FA8D7B0FB483416674C2FF4C2647EA46A3BDD82A95DC173A1FA07DC5B'
    } } }
    $preflight = [pscustomobject]@{
        suite = 'UiCaptureDriver'; executed = [long]$requiredNames.Count; passed = [long]$requiredNames.Count; failed = 0L
        mode = 'NO_DESKTOP_REAL_LAUNCH_REHEARSAL'; gui = 'NotExecuted'; images = 0L; backendTurns = 0L
        fixture = [pscustomobject]@{ compilerExitCode = 0L }
        controls = [pscustomobject]@{ moduleSha256 = $moduleHash; workerSha256 = $workerHash; supervisorSha256 = $supervisorHash }
        cases = @($requiredNames | ForEach-Object { [pscustomobject]@{
            name = $_; passed = $true; detail = [pscustomobject]@{
                zmxSha256 = $job.binaries.offlineZmx.sha256; providerCommit = '785b3fd15dcafd1882b495c831a10f98c201b908'
                evidenceMode = 'EXECUTED_CURRENT_REAL_ZMX'; phases = 2L
            }
        } })
    }
    Assert-CapPreflightReport
    $branches = [Collections.Generic.List[object]]::new()
    foreach ($behavior in @('normal','nonzero','timeout')) {
        $rows = @($preflight.cases | Where-Object name -CEQ "real zmx job lifecycle through actual command with target $behavior")
        Assert-CapTest ($rows.Count -eq 1) 'Synthetic real-case row does not uniquely select the actual behavior.'
        $rows[0].detail.phases = 1L
        $phaseRefusal = Assert-CapRejects { Assert-CapPreflightReport } 'Real seed preflight case does not bind the current pinned provider.'
        $rows[0].detail.phases = 2L
        $rows[0].detail.providerCommit = '0' * 40
        $providerRefusal = Assert-CapRejects { Assert-CapPreflightReport } 'Real seed preflight case does not bind the current pinned provider.'
        $rows[0].detail.providerCommit = '785b3fd15dcafd1882b495c831a10f98c201b908'
        $branches.Add([pscustomobject]@{ behavior = $behavior; phaseRefused = $phaseRefusal; providerRefused = $providerRefusal })
    }
    $traces = @(Get-Content -LiteralPath (Join-Path $scratch 'test-calls.jsonl') | ForEach-Object { ConvertFrom-Json $_ })
    $calls = @($traces | Where-Object command -CEQ 'Assert-CapPreflightReport')
    Assert-CapTest ($branches.Count -eq 3 -and $calls.Count -eq 7) 'Actual preflight acceptance and all three behavior checks did not execute.'
    return @{ mode = 'SYNTHETIC_REPORT_DATA_NOT_EXECUTED_PROVIDER_OR_LIVE_PREFLIGHT'
        validDataAccepted = $true; actualFunctionCalls = $calls.Count; behaviorBranches = @($branches.ToArray())
        syntheticCaseCount = $requiredNames.Count; requiredCaseNamesFromActualAst = $true
        functionSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($definition.Extent.Text))) }
}

function Invoke-CapSelectorRefusalContracts {
    function New-SelectorCandidate {
        param([string]$CandidateName = 'Alpha', [string]$Id = 'open-project-alpha',
            [int]$CandidateProcessId = 4242, [bool]$Offscreen = $false, [double]$Width = 200)
        return [pscustomobject]@{ Name = $CandidateName; AutomationId = $Id; ProcessId = $CandidateProcessId
            IsOffscreen = $Offscreen; BoundingRectangle = [pscustomobject]@{
                Left = 12.0; Top = 20.0; Width = $Width; Height = 24.0 }; ControlType = 'ControlType.Button' }
    }
    function Read-SelectorEvidence {
        param([string]$Path)
        $rows = @(Get-Content -LiteralPath $Path | ForEach-Object { ConvertFrom-Json $_ -DateKind String } |
            Where-Object command -CEQ 'CapSelectorRefusal')
        Assert-CapTest ($rows.Count -eq 1) 'Expected exactly one retained refusal diagnostic.'
        return ConvertFrom-Json $rows[0].parameters.diagnosticJson -DateKind String
    }
    Invoke-CapTest 'selector refusal zero retains typed stage and candidate evidence' {
        $candidate = [pscustomobject]@{
            Name = 'Beta'; AutomationId = 'open-project-beta'; ProcessId = 4242
            IsOffscreen = $false
            BoundingRectangle = [pscustomobject]@{ Left = 12.0; Top = 20.0; Width = 200.0; Height = 24.0 }
            ControlType = 'ControlType.Button'
        }
        $message = Assert-CapRejects {
            Resolve-CapAutomationCandidate -Candidates @($candidate) -ExpectedProcessId 4242 `
                -Name Alpha -AutomationIdPrefix 'open-project-'
        } "Expected exactly one visible UIA element Name='Alpha' id='' prefix='open-project-'; found=0."
        $records = @(Get-Content -LiteralPath (Join-Path $scratch 'test-calls.jsonl') |
            ForEach-Object { ConvertFrom-Json $_ -DateKind String } |
            Where-Object command -CEQ 'CapSelectorRefusal')
        Assert-CapTest ($records.Count -eq 1) `
            'Existing zero-match refusal occurred, but retained CapSelectorRefusal evidence is missing.'
        $evidence = ConvertFrom-Json $records[0].parameters.diagnosticJson -DateKind String
        Assert-CapTest ($evidence.schema -ceq 'CapSelectorRefusal/1' -and
            $evidence.refusal.message -ceq $message -and $evidence.expectedProcessId -eq 4242 -and
            $evidence.stageCounts.total -eq 1 -and $evidence.stageCounts.processOwned -eq 1 -and
            $evidence.stageCounts.nameMatch -eq 0 -and $evidence.stageCounts.prefixMatch -eq 0 -and
            $evidence.stageCounts.visible -eq 0 -and $evidence.stageCounts.bounds -eq 0) `
            'Retained refusal does not bind the original message and cumulative exact selector stages.'
        Assert-CapTest ($evidence.observedProcessIds.Count -eq 1 -and
            $evidence.observedProcessIds[0] -is [long] -and $evidence.observedProcessIds[0] -eq 4242 -and
            $evidence.candidates.Count -eq 1 -and $evidence.candidates[0].Name.value -ceq 'Beta' -and
            $evidence.candidates[0].AutomationId.value -ceq 'open-project-beta' -and
            $evidence.candidates[0].ProcessId.value -is [long] -and
            $evidence.candidates[0].IsOffscreen.value -is [bool] -and
            $evidence.candidates[0].BoundingRectangle.value.Width -eq 200 -and
            $evidence.candidates[0].ControlType.value -ceq 'ControlType.Button') `
            'Candidate evidence must contain actual typed scalar values, not CLR type names.'
        return @{ originalRefusal = $message; evidence = $evidence; mode = 'Synthetic candidates; actual resolver and retained trace sink; no desktop.' }
    }
    Invoke-CapTest 'selector refusal ambiguity preserves original outcome and held context' {
        $path = Join-Path $scratch 'selector-ambiguous.jsonl'
        Set-CapTracePath $path
        $context = @{ RootHandle = [IntPtr]77; RootProcessId = 4242; Scope = 'Descendants'; ParameterSet = 'Window'
            ProcessIdentity = [pscustomobject]@{ Pid = 4242; CreationFileTimeUtc = 123456789L
                ExpectedImagePath = 'C:\owned\fixture.exe'; Role = 'synthetic-held-generation' } }
        $message = Assert-CapRejects {
            Resolve-CapAutomationCandidate -Candidates @((New-SelectorCandidate), (New-SelectorCandidate)) `
                -ExpectedProcessId 4242 -Name Alpha -AutomationIdPrefix 'open-project-' -RefusalContext $context
        } "found=2."
        $data = Read-SelectorEvidence $path
        Assert-CapTest ($data.refusal.message -ceq $message -and $data.stageCounts.bounds -eq 2 -and
            $data.heldContext.rootHandle -eq 77 -and $data.heldContext.identity.Pid.value -eq 4242 -and
            $data.heldContext.identity.CreationFileTimeUtc.value -eq 123456789L -and
            $data.stageCountsComplete -and $data.observedProcessIdRawCount -eq 2 -and
            $data.observedProcessIdDistinctCount -eq 1) 'Ambiguity, held generation or actual PID multiplicity changed.'
        $legacy = @(Get-Content $path | ForEach-Object { ConvertFrom-Json $_ } |
            Where-Object command -CEQ 'Resolve-CapAutomationCandidate')
        Assert-CapTest (-not $legacy[0].parameters.PSObject.Properties['RefusalContext']) 'Diagnostic context leaked into legacy trace.'
        return $data
    }
    Invoke-CapTest 'selector refusal ownership records the full set without adopting foreign candidates' {
        $path = Join-Path $scratch 'selector-ownership.jsonl'
        Set-CapTracePath $path
        $message = Assert-CapRejects {
            Resolve-CapAutomationCandidate -Candidates @(
                (New-SelectorCandidate -CandidateProcessId 9999),
                (New-SelectorCandidate -Offscreen $true), (New-SelectorCandidate -CandidateName Beta)
            ) -ExpectedProcessId 4242 -Name Alpha -AutomationIdPrefix 'open-project-'
        } 'UIA subtree process 9999 does not match owned PID 4242.'
        $data = Read-SelectorEvidence $path
        Assert-CapTest ($data.refusal.message -ceq $message -and $data.stageCounts.total -eq 3 -and
            $data.stageCounts.processOwned -eq 2 -and $data.stageCounts.nameMatch -eq 1 -and
            $data.stageCounts.prefixMatch -eq 1 -and $data.stageCounts.visible -eq 0 -and
            ($data.observedProcessIds -join ',') -ceq '9999,4242' -and $data.observedProcessIdRawCount -eq 3 -and
            $data.heldContext.status -ceq 'NotObserved') 'Ownership refusal lost actual full-set stages/PIDs or invented held context.'
        return $data
    }
    Invoke-CapTest 'selector refusal stages preserve exact optional ID prefix and offscreen rules' {
        $candidates = @(
            (New-SelectorCandidate -CandidateName Beta), (New-SelectorCandidate -Id unrelated),
            (New-SelectorCandidate -Offscreen $true), (New-SelectorCandidate -Offscreen $true),
            (New-SelectorCandidate -Width 0), (New-SelectorCandidate -Width 0)
        )
        $details = @()
        foreach ($variant in @('prefix','offscreen','exact-id','inactive')) {
            $path = Join-Path $scratch ("selector-stages-$variant.jsonl")
            Set-CapTracePath $path
            $parameters = @{ Candidates = $candidates; ExpectedProcessId = 4242; Name = 'Alpha' }
            if ($variant -ne 'inactive') { $parameters.AutomationIdPrefix = 'open-project-' }
            if ($variant -in @('offscreen','inactive')) { $parameters.AllowOffscreen = $true }
            if ($variant -ceq 'exact-id') { $parameters.AutomationId = 'OPEN-PROJECT-alpha' }
            $null = Assert-CapRejects { Resolve-CapAutomationCandidate @parameters } 'Expected exactly one visible UIA element'
            $data = Read-SelectorEvidence $path
            Assert-CapTest ($data.stageCounts.total -eq 6 -and $data.stageCounts.processOwned -eq 6 -and
                $data.stageCounts.nameMatch -eq 5 -and $data.stageCountsComplete) 'Full-set process/name stage counts changed.'
            switch ($variant) {
                'prefix' { Assert-CapTest ($data.stageCounts.automationIdMatch -eq 5 -and
                    $data.stageCounts.prefixMatch -eq 4 -and $data.stageCounts.visible -eq 2 -and $data.stageCounts.bounds -eq 0) 'Prefix/visibility/bounds counts changed.' }
                'offscreen' { Assert-CapTest ($data.stageCounts.visible -eq 4 -and $data.stageCounts.bounds -eq 2) 'AllowOffscreen must count rule passage, not actual visibility.' }
                'exact-id' { Assert-CapTest ($data.stageCounts.automationIdMatch -eq 0 -and $data.stageCounts.prefixMatch -eq 0) 'Exact ID must remain case-sensitive before prefix.' }
                'inactive' { Assert-CapTest ($data.stageCounts.automationIdMatch -eq 5 -and
                    $data.stageCounts.prefixMatch -eq 5 -and $data.stageCounts.visible -eq 5 -and $data.stageCounts.bounds -eq 3) 'Inactive rules must propagate their predecessor count.' }
            }
            $details += $data
        }
        return @{ subcases = $details.Count; evidence = $details }
    }
    Invoke-CapTest 'selector refusal caps retain deterministic near matches typed PIDs and Unicode boundaries' {
        $path = Join-Path $scratch 'selector-caps.jsonl'
        Set-CapTracePath $path
        $unicode = ('x' * 511) + [char]0xd83d + [char]0xde80 + 'z'
        $candidates = @(
            foreach ($i in 0..97) {
                New-SelectorCandidate -CandidateProcessId (7000 + $i) -CandidateName $unicode -Id $unicode
            }
            New-SelectorCandidate -Offscreen $true
            New-SelectorCandidate -Offscreen $true
        )
        $null = Assert-CapRejects {
            Resolve-CapAutomationCandidate -Candidates $candidates -ExpectedProcessId 4242 -Name Alpha -AutomationIdPrefix 'open-project-'
        } 'UIA subtree process 7000'
        $data = Read-SelectorEvidence $path
        Assert-CapTest ($data.stageCounts.total -eq 100 -and $data.stageCounts.processOwned -eq 2 -and
            $data.stageCounts.prefixMatch -eq 2 -and $data.candidates.Count -eq 16 -and
            $data.candidatesOmitted -eq 84 -and
            ($data.candidates.sourceIndex -join ',') -ceq '98,99,0,1,2,3,4,5,6,7,8,9,10,11,12,13') 'Candidate cap/order must prefer deepest stages with stable source ties.'
        $nameField = $data.candidates[2].Name
        Assert-CapTest ($nameField.value.Length -eq 511 -and $nameField.originalLength -eq 514 -and
            $nameField.truncated -and -not [char]::IsHighSurrogate($nameField.value[-1]) -and
            $data.candidates[2].AutomationId.value.Length -eq 511) 'Scalar truncation split a Unicode surrogate pair.'
        $null = [Text.UTF8Encoding]::new($false, $true).GetBytes($nameField.value)
        Assert-CapTest ($data.observedProcessIdRawCount -eq 100 -and $data.observedProcessIdDistinctCount -eq 99 -and
            $data.observedProcessIdSampleCount -eq 64 -and $data.observedProcessIds.Count -eq 64 -and
            $data.observedProcessIdsTruncated -and -not $data.observedProcessIdsComplete -and
            $data.observedProcessIds[0] -eq 7000 -and $data.observedProcessIds[-1] -eq 7063 -and
            @($data.observedProcessIds | Where-Object { $_ -isnot [long] }).Count -eq 0) 'PID sample is not a bounded typed actual primitive sample with honest counts.'
        return $data
    }
    Invoke-CapTest 'selector refusal distinguishes missing null and property read errors' {
        $path = Join-Path $scratch 'selector-errors.jsonl'
        Set-CapTracePath $path
        $missing = New-SelectorCandidate -CandidateName Beta
        $missing.PSObject.Properties.Remove('ControlType')
        $nullValue = New-SelectorCandidate -CandidateName Beta
        $nullValue.ControlType = $null
        $errorValue = New-SelectorCandidate -CandidateName Beta
        $errorValue.PSObject.Properties.Remove('ControlType')
        $errorValue | Add-Member -MemberType ScriptProperty -Name ControlType -Value { throw 'controltype-observation-error' }
        $boundsError = New-SelectorCandidate -CandidateName Beta
        $boundsError.BoundingRectangle = [pscustomobject]@{ Left = 1; Top = 2; Height = 3 }
        $null = Assert-CapRejects {
            Resolve-CapAutomationCandidate -Candidates @($missing,$nullValue,$errorValue,$boundsError) -ExpectedProcessId 4242 -Name Alpha
        } 'found=0.'
        $data = Read-SelectorEvidence $path
        Assert-CapTest ($data.candidates[0].ControlType.status -ceq 'Missing' -and
            $data.candidates[1].ControlType.status -ceq 'Null' -and
            $data.candidates[2].ControlType.status -ceq 'ReadError' -and
            $data.candidates[2].ControlType.error.value.Contains('controltype-observation-error') -and
            $data.candidates[3].BoundingRectangle.status -ceq 'ReadError') 'Unavailable properties were fabricated or collapsed into empty scalar values.'
        $badName = New-SelectorCandidate
        $badName.PSObject.Properties.Remove('Name')
        $path2 = Join-Path $scratch 'selector-stage-error.jsonl'
        Set-CapTracePath $path2
        $null = Assert-CapRejects {
            Resolve-CapAutomationCandidate -Candidates @($badName) -ExpectedProcessId 4242 -Name Alpha
        } "property 'Name'"
        $incomplete = Read-SelectorEvidence $path2
        Assert-CapTest (-not $incomplete.stageCountsComplete -and $incomplete.stageReadErrors.nameMatch -eq 1 -and
            $incomplete.candidates[0].Name.status -ceq 'Missing') 'Stage read error was reported as complete negative matching.'
        return @{ evidence = $data; incomplete = $incomplete }
    }
    Invoke-CapTest 'selector success performs no new diagnostic write property read or serialization' {
        $path = Join-Path $scratch 'selector-success.jsonl'
        Set-CapTracePath $path
        $candidate = New-SelectorCandidate
        $candidate.PSObject.Properties.Remove('ControlType')
        $candidate | Add-Member -MemberType ScriptProperty -Name ControlType -Value { throw 'Success must not read diagnostic-only ControlType.' }
        $module = Get-Module UiCaptureDriver
        $serializationCount = & $module {
            param($Candidate)
            $script:SelectorSerializationCount = 0
            function script:ConvertTo-Json {
                [CmdletBinding()]
                param([Parameter(ValueFromPipeline)]$InputObject, [int]$Depth, [switch]$Compress)
                process {
                    $script:SelectorSerializationCount++
                    Microsoft.PowerShell.Utility\ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress:$Compress
                }
            }
            try {
                $selected = Resolve-CapAutomationCandidate -Candidates @($Candidate) -ExpectedProcessId 4242 -Name Alpha `
                    -AutomationIdPrefix 'open-project-' -RefusalContext @{ NotReadOnSuccess = $true }
                if (-not [object]::ReferenceEquals($selected, $Candidate)) { throw 'Success selection changed.' }
                return $script:SelectorSerializationCount
            } finally {
                Remove-Item Function:\ConvertTo-Json
                $restored = Get-Command ConvertTo-Json
                if ($restored.CommandType -ne [Management.Automation.CommandTypes]::Cmdlet -or
                    $restored.ModuleName -cne 'Microsoft.PowerShell.Utility') { throw 'Serialization spy command resolution was not restored.' }
                Remove-Variable SelectorSerializationCount -Scope Script
            }
        } $candidate
        $rows = @(Get-Content $path | ForEach-Object { ConvertFrom-Json $_ })
        Assert-CapTest ($serializationCount -eq 2 -and $rows.Count -eq 2 -and
            @($rows | Where-Object command -CEQ 'CapSelectorRefusal').Count -eq 0 -and
            -not $rows[0].parameters.PSObject.Properties['RefusalContext']) `
            'Successful selector added diagnostic serialization/writes beyond its two original legacy traces.'
        return @{ actualSerializations = $serializationCount; legacyTraceWrites = $rows.Count; diagnosticWrites = 0 }
    }
    Invoke-CapTest 'selector observer failure surfaces explicitly without replacing original ErrorRecord' {
        $path = Join-Path $scratch 'selector-observer-error.jsonl'
        Set-CapTracePath $path
        $before = @(Get-CapTraceFailures).Count
        $errorRecord = $null
        try {
            try {
                $null = Resolve-CapAutomationCandidate -Candidates @((New-SelectorCandidate -CandidateName Beta)) `
                    -ExpectedProcessId 4242 -Name Alpha -RefusalContext @{
                        RootProcessId = $null; RootHandle = 'deliberately-invalid-observer-context'
                        Scope = 'Descendants'; ParameterSet = 'Window' }
            } catch { $errorRecord = $_ }
            $failures = @(Get-CapTraceFailures)
            $invocation = if ($errorRecord) { $errorRecord.InvocationInfo } else { $null }
            $invocationCommand = if ($null -ne $invocation) { $invocation.MyCommand } else { $null }
            $commandNameProperty = if ($null -ne $invocationCommand) { $invocationCommand.PSObject.Properties['Name'] } else { $null }
            Write-JournalContractJson (Join-Path $scratch 'selector-observer-error-fields.json') @{
                errorObserved = ($null -ne $errorRecord)
                exceptionType = if ($errorRecord) { $errorRecord.Exception.GetType().FullName } else { $null }
                message = if ($errorRecord) { $errorRecord.Exception.Message } else { $null }
                fullyQualifiedErrorId = if ($errorRecord) { $errorRecord.FullyQualifiedErrorId } else { $null }
                category = if ($errorRecord) { [string]$errorRecord.CategoryInfo.Category } else { $null }
                invocationObserved = ($null -ne $invocation)
                invocationCommandObserved = ($null -ne $invocationCommand)
                invocationCommandType = if ($null -ne $invocationCommand) { $invocationCommand.GetType().FullName } else { $null }
                invocationCommandNameObserved = ($null -ne $commandNameProperty)
                invocationCommand = if ($null -ne $commandNameProperty) { $commandNameProperty.Value } else { $null }
                invocationPosition = if ($null -ne $invocation) { $invocation.PositionMessage } else { $null }
                scriptStackTrace = if ($errorRecord) { $errorRecord.ScriptStackTrace } else { $null }
                traceFailuresBefore = $before; traceFailuresAfter = $failures.Count; traceFailures = $failures
            }
            Assert-CapTest ($null -ne $errorRecord -and $errorRecord.Exception -is [Management.Automation.RuntimeException] -and
                $errorRecord.Exception.Message -ceq "Expected exactly one visible UIA element Name='Alpha' id='' prefix=''; found=0." -and
                $errorRecord.FullyQualifiedErrorId -ceq $errorRecord.Exception.Message -and
                $errorRecord.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::OperationStopped -and
                $errorRecord.InvocationInfo.ScriptName -ceq $modulePath -and
                $errorRecord.InvocationInfo.PositionMessage.Contains('throw "Expected exactly one visible UIA element') -and
                $errorRecord.ScriptStackTrace.StartsWith('at Resolve-CapAutomationCandidate,', [StringComparison]::Ordinal) -and
                $failures.Count -eq ($before + 1) -and $failures[-1].command -ceq 'CapSelectorRefusal') `
                'Observer error masked the original selector ErrorRecord or failed silently.'
            return @{ originalMessage = $errorRecord.Exception.Message; originalType = $errorRecord.Exception.GetType().FullName
                surfacedObserverFailure = $failures[-1]; note = 'Deliberate invalid diagnostic context only; selector unchanged.' }
        } finally {
            & (Get-Module UiCaptureDriver) { param($Count)
                while ($script:CapTraceFailures.Count -gt $Count) { $script:CapTraceFailures.RemoveAt($script:CapTraceFailures.Count - 1) }
            } $before
        }
    }
    function Invoke-SelectorWaitFixture {
        param([string]$CaseName, [switch]$EventuallySucceeds, [switch]$NoSink, [switch]$BrokenObserver,
            [switch]$StaleLastPoll)
        $path = Join-Path $scratch ("selector-wait-$CaseName.jsonl")
        Set-CapTracePath $path
        $meter = [pscustomobject]@{ polls = 0; diagnosticReads = 0; diagnosticSerializations = 0; currentReads = 0
            inBudgetReads = 0; deadline = [DateTime]::UtcNow.AddSeconds(2); lastCandidate = $null
            lastPoll = $null; failure = $null; selected = $null; snapshot = $null }
        $module = Get-Module UiCaptureDriver
        $failuresBefore = @(Get-CapTraceFailures).Count
        & $module {
            param($Meter, [bool]$NoSink)
            $script:SelectorWaitMeter = $Meter
            if ($NoSink) { $script:CapTracePath = $null }
            function script:ConvertTo-Json {
                [CmdletBinding()]
                param([Parameter(ValueFromPipeline)]$InputObject, [int]$Depth, [switch]$Compress)
                process {
                    if ($InputObject -is [Collections.IDictionary] -and $InputObject.Contains('schema') -and
                        $InputObject['schema'] -ceq 'CapSelectorRefusal/1') { $script:SelectorWaitMeter.diagnosticSerializations++ }
                    Microsoft.PowerShell.Utility\ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress:$Compress
                }
            }
        } $meter $NoSink.IsPresent
        try {
            $ast = [Management.Automation.Language.Parser]::ParseFile($workerPath,[ref]$null,[ref]$null)
            foreach ($functionName in @('Wait-CapVisibleElement','Assert-CapWorkerDeadline')) {
                $definitions = @($ast.FindAll({ param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
                },$true))
                Assert-CapTest ($definitions.Count -eq 1) 'Actual worker wait/deadline function is missing or duplicated.'
                . ([scriptblock]::Create($definitions[0].Extent.Text))
            }
            function Find-CapAutomationElement {
                param([IntPtr]$RootHandle, $ProcessIdentity, [string]$Name, [string]$AutomationId,
                    [string]$AutomationIdPrefix, [switch]$AllowOffscreen, [ref]$RefusalSnapshot)
                $meter.polls++
                $meter.lastPoll = [DateTime]::UtcNow
                $candidate = New-SelectorCandidate -CandidateName ("Beta-" + $meter.polls)
                if ($EventuallySucceeds -and $meter.polls -ge 2) { $candidate.Name = 'Alpha' }
                $candidate.PSObject.Properties.Remove('ControlType')
                $capturedMeter = $meter
                $getter = {
                    $capturedMeter.diagnosticReads++
                    if ([DateTime]::UtcNow -lt $capturedMeter.deadline) { $capturedMeter.inBudgetReads++ }
                    return 'ControlType.Button'
                }.GetNewClosure()
                $candidate | Add-Member -MemberType ScriptProperty -Name ControlType -Value $getter
                $meter.lastCandidate = $candidate
                $parameters = @{ Candidates = @($candidate); ExpectedProcessId = 4242; Name = $Name
                    AutomationId = $AutomationId; AutomationIdPrefix = $AutomationIdPrefix; AllowOffscreen = $AllowOffscreen
                    RefusalContext = @{ RootHandle = $RootHandle; RootProcessId = 4242; ProcessIdentity = $ProcessIdentity
                        Scope = 'Descendants'; ParameterSet = 'Window' } }
                if ($null -ne $RefusalSnapshot) { $parameters.RefusalSnapshot = $RefusalSnapshot }
                if ($BrokenObserver) {
                    $parameters.RefusalContext = @{ RootProcessId = $null; RootHandle = 'deliberately-invalid-observer-context'
                        Scope = 'Descendants'; ParameterSet = 'Window' }
                }
                try { return Resolve-CapAutomationCandidate @parameters }
                catch {
                    if ($null -ne $RefusalSnapshot) { $meter.snapshot = $RefusalSnapshot.Value }
                    if ($StaleLastPoll) {
                        $staleGetter = { $capturedMeter.currentReads++; throw 'last-poll-element-vanished' }.GetNewClosure()
                        $candidate | Add-Member -MemberType ScriptProperty -Name Current -Value $staleGetter
                    }
                    throw
                }
            }
            $leaseDeadlineUtc = $meter.deadline
            try {
                $meter.selected = Wait-CapVisibleElement -Window ([IntPtr]77) -ProcessIdentity ([pscustomobject]@{ Pid = 4242 }) `
                    -Name Alpha -AutomationIdPrefix 'open-project-'
            } catch { $meter.failure = $_ }
            $rows = @()
            if (Test-Path $path) { $rows = @(Get-Content $path | ForEach-Object { ConvertFrom-Json $_ -DateKind String }) }
            $caught = $meter.failure
            $fixtureFailures = @(Get-CapTraceFailures)
            Write-JournalContractJson (Join-Path $scratch ("selector-wait-$CaseName-fields.json")) ([ordered]@{
                polls = $meter.polls; diagnosticReads = $meter.diagnosticReads; currentReads = $meter.currentReads
                diagnosticSerializations = $meter.diagnosticSerializations; inBudgetReads = $meter.inBudgetReads
                deadlineUtc = $meter.deadline.ToString('o')
                lastQueryUtc = if ($null -ne $meter.lastPoll) { $meter.lastPoll.ToString('o') } else { $null }
                snapshotObserved = ($null -ne $meter.snapshot)
                emissionAttempted = if ($null -ne $meter.snapshot -and $meter.snapshot.Contains('EmissionAttempted')) {
                    $meter.snapshot.EmissionAttempted
                } else { $null }
                selectedObserved = ($null -ne $meter.selected); errorObserved = ($null -ne $caught)
                exceptionType = if ($null -ne $caught) { $caught.Exception.GetType().FullName } else { $null }
                message = if ($null -ne $caught) { $caught.Exception.Message } else { $null }
                fullyQualifiedErrorId = if ($null -ne $caught) { $caught.FullyQualifiedErrorId } else { $null }
                category = if ($null -ne $caught) { [string]$caught.CategoryInfo.Category } else { $null }
                scriptStackTrace = if ($null -ne $caught) { $caught.ScriptStackTrace } else { $null }
                traceRows = $rows.Count; traceFailuresBefore = $failuresBefore
                traceFailuresAfter = $fixtureFailures.Count
                traceFailures = @($fixtureFailures | Select-Object command,path,failure)
            })
            return [pscustomobject]@{ meter = $meter; tracePath = $path; rows = $rows
                traceFailures = $fixtureFailures; traceFailuresBefore = $failuresBefore }
        } finally {
            & $module {
                param($Count)
                Remove-Item Function:\ConvertTo-Json
                if ((Get-Command ConvertTo-Json).CommandType -ne [Management.Automation.CommandTypes]::Cmdlet) {
                    throw 'Wait serialization spy was not removed.'
                }
                Remove-Variable SelectorWaitMeter -Scope Script
                while ($script:CapTraceFailures.Count -gt $Count) { $script:CapTraceFailures.RemoveAt($script:CapTraceFailures.Count - 1) }
            } $failuresBefore
            Set-CapTracePath -Path (Join-Path $scratch 'test-calls.jsonl')
        }
    }
    Invoke-CapTest 'actual worker wait eventual success performs zero refusal observation work' {
        $run = Invoke-SelectorWaitFixture -CaseName success -EventuallySucceeds
        Assert-CapTest ($null -eq $run.meter.failure -and $run.meter.polls -eq 2 -and
            [object]::ReferenceEquals($run.meter.selected, $run.meter.lastCandidate)) 'Actual worker wait did not select its second synthetic query result.'
        Assert-CapTest ($run.meter.diagnosticReads -eq 0 -and $run.meter.diagnosticSerializations -eq 0 -and
            @($run.rows | Where-Object command -CEQ 'CapSelectorRefusal').Count -eq 0) `
            'Eventually successful actual worker wait performed refusal diagnostic reads, serialization or writes inside polling.'
        return @{ polls = $run.meter.polls; diagnosticReads = $run.meter.diagnosticReads
            diagnosticSerializations = $run.meter.diagnosticSerializations; diagnosticWrites = 0
            mode = 'Actual worker wait/deadline and resolver; synthetic query leaf only; real 100ms cadence.' }
    }
    Invoke-CapTest 'actual worker terminal refusal observes only last poll references after deadline' {
        $run = Invoke-SelectorWaitFixture -CaseName terminal
        Assert-CapTest ($run.meter.polls -ge 2 -and $null -ne $run.meter.failure -and
            $run.meter.failure.Exception.Message -ceq "UIA element 'Alpha' did not become available before the reserved deadline.") `
            'Actual worker did not preserve its original terminal timeout refusal.'
        $data = Read-SelectorEvidence $run.tracePath
        $observedAt = [DateTime]::Parse($data.propertyReadStartedUtc).ToUniversalTime()
        $polledAt = [DateTime]::Parse($data.terminalObservation.lastPollUtc).ToUniversalTime()
        Assert-CapTest ($run.meter.diagnosticReads -eq 1 -and $run.meter.diagnosticSerializations -eq 1 -and
            $run.meter.inBudgetReads -eq 0 -and $data.evidenceKind -ceq 'TERMINAL_LAST_POLL_SNAPSHOT' -and
            $data.candidates[0].Name.value -ceq ("Beta-" + $run.meter.polls) -and
            $observedAt -ge $run.meter.deadline -and $polledAt -le $run.meter.lastPoll -and
            [DateTime]::Parse($data.terminalObservation.waitDeadlineUtc).ToUniversalTime() -eq $run.meter.deadline -and
            $data.heldContext.rootHandle -eq 77 -and $data.heldContext.identity.Pid.value -eq 4242) `
            'Terminal observation queried again, observed a prior poll, or read properties inside the wait budget.'
        $stale = Invoke-SelectorWaitFixture -CaseName stale -StaleLastPoll
        $staleData = Read-SelectorEvidence $stale.tracePath
        Assert-CapTest ($stale.meter.polls -ge 2 -and $stale.meter.currentReads -eq 1 -and
            $staleData.candidates[0].currentStatus -ceq 'ReadError' -and
            $staleData.candidates[0].current.error.value.Contains('last-poll-element-vanished') -and
            $staleData.candidates[0].Name.status -ceq 'ReadError' -and
            -not $staleData.stageCountsComplete -and $staleData.observedProcessIds.Count -eq 0) `
            'Stale Current getter was collapsed into null/missing or caused a fresh query/invented PID.'
        return @{ polls = $run.meter.polls; evidence = $data; staleEvidence = $staleData
            staleCurrentReads = $stale.meter.currentReads; queriesAfterLastPoll = 0 }
    }
    Invoke-CapTest 'selector special rectangle values retain successful reads and the original raw predicate' {
        $path = Join-Path $scratch 'selector-special-bounds.jsonl'
        Set-CapTracePath $path
        $empty = New-SelectorCandidate
        $empty.BoundingRectangle = [pscustomobject]@{
            Left = [double]::PositiveInfinity; Top = [double]::PositiveInfinity
            Width = [double]::NegativeInfinity; Height = [double]::NegativeInfinity
        }
        $nan = New-SelectorCandidate
        $nan.BoundingRectangle.Width = [double]::NaN
        $infinity = New-SelectorCandidate
        $infinity.BoundingRectangle.Width = [double]::PositiveInfinity
        $candidates = @($empty,$nan,$nan,$infinity,$infinity)
        $expected = 0
        foreach ($candidate in $candidates) {
            $rect = $candidate.BoundingRectangle
            if ($null -eq $rect -or $rect.Width -le 0 -or $rect.Height -le 0) { continue }
            $expected++
        }
        $null = Assert-CapRejects {
            Resolve-CapAutomationCandidate -Candidates $candidates -ExpectedProcessId 4242 -Name Alpha
        } "found=$expected."
        $data = Read-SelectorEvidence $path
        $byIndex = @($data.candidates | Sort-Object sourceIndex)
        Assert-CapTest ($data.stageCounts.bounds -eq $expected -and $data.stageCountsComplete -and
            $data.stageReadErrors.bounds -eq 0 -and
            @($data.candidates | Where-Object { $_.BoundingRectangle.status -cne 'Value' -or
                -not $_.BoundingRectangle.propertyReadSucceeded }).Count -eq 0 -and
            $byIndex[0].BoundingRectangle.rectangleKind -ceq 'Empty' -and
            $byIndex[0].BoundingRectangle.value.Width.numberKind -ceq 'NegativeInfinity' -and
            $byIndex[0].BoundingRectangle.value.Left.numberKind -ceq 'PositiveInfinity' -and
            $byIndex[1].BoundingRectangle.value.Width.numberKind -ceq 'NaN' -and
            $byIndex[3].BoundingRectangle.value.Width.numberKind -ceq 'PositiveInfinity') `
            'Successful special-number reads were mislabeled ReadError or changed the original raw bounds predicate.'
        return @{ expectedByOriginalPredicate = $expected; evidence = $data
            fixture = 'SYNTHETIC canonical Rect.Empty numeric shape; not a genuine WPF instance or live UIA.' }
    }
    Invoke-CapTest 'actual worker no sink terminal refusal performs zero observation or serialization work' {
        $run = Invoke-SelectorWaitFixture -CaseName no-sink -NoSink
        Assert-CapTest ($run.meter.polls -ge 2 -and $null -ne $run.meter.failure -and
            $run.meter.diagnosticReads -eq 0 -and $run.meter.currentReads -eq 0 -and
            $run.meter.diagnosticSerializations -eq 0 -and $null -eq $run.meter.snapshot -and
            $run.rows.Count -eq 0 -and -not (Test-Path $run.tracePath)) `
            'Missing trace sink still retained/prepared diagnostic context, read properties, serialized or wrote.'
        return @{ polls = $run.meter.polls; diagnosticReads = 0; diagnosticSerializations = 0; writes = 0 }
    }
    Invoke-CapTest 'actual worker observer failure is attempted once per wait and preserves terminal refusal' {
        $run = Invoke-SelectorWaitFixture -CaseName observer-error -BrokenObserver
        Assert-CapTest ($run.meter.polls -ge 2 -and $null -ne $run.meter.failure -and
            $run.meter.failure.Exception.Message -ceq "UIA element 'Alpha' did not become available before the reserved deadline." -and
            $run.meter.failure.FullyQualifiedErrorId -ceq $run.meter.failure.Exception.Message -and
            $run.meter.failure.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::OperationStopped -and
            $run.meter.diagnosticReads -eq 1 -and $run.meter.inBudgetReads -eq 0 -and
            $run.traceFailures.Count -eq ($run.traceFailuresBefore + 1) -and
            $run.traceFailures[-1].command -ceq 'CapSelectorRefusal' -and $run.meter.snapshot.EmissionAttempted) `
            'Observer failure ran inside polling, repeated, or masked the original worker terminal refusal.'
        $before = @(Get-CapTraceFailures).Count
        Write-CapTerminalSelectorRefusal -Snapshot $run.meter.snapshot -Refusal $run.meter.failure `
            -PollUtc $run.meter.lastPoll -DeadlineUtc $run.meter.deadline
        Assert-CapTest ($run.meter.diagnosticReads -eq 1 -and @(Get-CapTraceFailures).Count -eq $before) `
            'Already attempted wait snapshot emitted or failed a second time.'
        return @{ polls = $run.meter.polls; originalMessage = $run.meter.failure.Exception.Message
            observerAttempts = 1; explicitFailure = $run.traceFailures[-1] }
    }
    Invoke-CapTest 'real Find forwards optional refusal references through owned hidden UIA roots' {
        if (-not ('CapOptionalRefWindowFixture' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class CapOptionalRefWindowFixture {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateWindowExW")]
    private static extern IntPtr CreateWindow(uint exStyle, string className, string title, uint style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyWindow(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);
    public static IntPtr Create() {
        var window = CreateWindow(0, "STATIC", "GraphCode optional reference fixture", 0x80000000u,
            0, 0, 120, 30, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (window == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        return window;
    }
    public static void Destroy(IntPtr window) {
        if (!DestroyWindow(window)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@
        }
        $module = Get-Module UiCaptureDriver
        $self = [Diagnostics.Process]::GetCurrentProcess()
        $window = [IntPtr]::Zero
        $branches = [Collections.Generic.List[object]]::new()
        $failuresBefore = @(Get-CapTraceFailures).Count
        $lifecycle = [ordered]@{
            mode = 'REAL_FIND_REAL_RESOLVER_HIDDEN_OWN_PROCESS_UIA_NO_INPUT_OR_CAPTURE'
            pid = $PID; startTimeUtc = $self.StartTime.ToUniversalTime().ToString('o')
            image = $self.MainModule.FileName; arguments = @([Environment]::GetCommandLineArgs())
            sourceHashes = $sourceHashesBefore; createdUtc = $null; readyUtc = $null
            hwnd = $null; creationFileTimeUtc = $null; rootProcessId = $null; candidateCount = $null
            destroyed = $false; destroyObservedUtc = $null; selfStillLiveBeforeDispose = $null
            selfWrapperDisposed = $false; spawnedFixtureProcesses = 0
            childExitAndRedirectedEof = 'Not applicable: HWND belongs to the current test process.'
            branches = $branches; errors = @()
        }
        try {
            $identity = Get-CapProcessIdentity -Process $self -ExpectedImagePath $self.MainModule.FileName `
                -Role 'optional-ref-hidden-uia-self'
            $lifecycle.creationFileTimeUtc = $identity.CreationFileTimeUtc
            $window = [CapOptionalRefWindowFixture]::Create()
            $lifecycle.hwnd = $window.ToInt64()
            $lifecycle.createdUtc = [DateTimeOffset]::UtcNow.ToString('o')
            Assert-CapTest (-not [CapOptionalRefWindowFixture]::IsWindowVisible($window)) 'Regression HWND must remain hidden.'
            $parent = [System.Windows.Automation.AutomationElement]::FromHandle($window)
            $lifecycle.rootProcessId = $parent.Current.ProcessId
            $candidates = $parent.FindAll([System.Windows.Automation.TreeScope]::Element,
                [System.Windows.Automation.Condition]::TrueCondition)
            $lifecycle.candidateCount = $candidates.Count
            Assert-CapTest ($parent.Current.ProcessId -eq $PID -and $candidates.Count -eq 1 -and
                $candidates[0].Current.ProcessId -eq $PID) 'Hidden UIA fixture must expose exactly its actual owned root.'
            $lifecycle.readyUtc = [DateTimeOffset]::UtcNow.ToString('o')
            foreach ($sink in @($true, $false)) {
                foreach ($parameterSet in @('Window', 'Element')) {
                    foreach ($bound in @($false, $true)) {
                        $path = Join-Path $scratch ("selector-real-find-$parameterSet-$sink-$bound.jsonl")
                        if ($sink) { Set-CapTracePath $path }
                        else { & $module { $script:CapTracePath = $null } }
                        $snapshot = $null
                        $parameters = @{
                            ProcessIdentity = $identity; Name = 'Intentionally absent selector'
                            Scope = [System.Windows.Automation.TreeScope]::Element
                        }
                        if ($parameterSet -ceq 'Window') { $parameters.RootHandle = $window }
                        else { $parameters.Parent = $parent }
                        if ($bound) { $parameters.RefusalSnapshot = [ref]$snapshot }
                        $caught = $null
                        try { $null = Find-CapAutomationElement @parameters }
                        catch { $caught = $_ }
                        $exceptionType = if ($caught) { $caught.Exception.GetType().FullName } else { $null }
                        $bindingFailure = $exceptionType -ceq 'System.Management.Automation.ParameterBindingArgumentTransformationException'
                        $rows = if (Test-Path -LiteralPath $path) {
                            @(Get-Content -LiteralPath $path | ForEach-Object { ConvertFrom-Json $_ -DateKind String })
                        } else { @() }
                        $entryCount = @($rows | Where-Object command -CEQ 'Resolve-CapAutomationCandidate').Count
                        $diagnosticCount = @($rows | Where-Object command -CEQ 'CapSelectorRefusal').Count
                        $branch = [ordered]@{
                            parameterSet = $parameterSet; referenceBound = $bound; traceSink = $sink
                            resolverEntries = $entryCount; diagnosticWrites = $diagnosticCount
                            snapshotObserved = ($null -ne $snapshot)
                            exceptionType = $exceptionType; bindingFailure = $bindingFailure
                            exception = if ($caught) { $caught.Exception.ToString() } else { $null }
                            fullyQualifiedErrorId = if ($caught) { $caught.FullyQualifiedErrorId } else { $null }
                            scriptStackTrace = if ($caught) { $caught.ScriptStackTrace } else { $null }
                        }
                        $branches.Add($branch)
                        Write-JournalContractJson (Join-Path $scratch ("selector-real-find-$parameterSet-$sink-$bound.json")) $branch
                        $expected = "Expected exactly one visible UIA element Name='Intentionally absent selector' id='' prefix=''; found=0."
                        Assert-CapTest ($null -ne $caught -and $caught.Exception.Message -ceq $expected -and
                            -not $bindingFailure -and
                            $caught.FullyQualifiedErrorId -ceq $expected -and
                            $caught.ScriptStackTrace.StartsWith('at Resolve-CapAutomationCandidate,', [StringComparison]::Ordinal)) `
                            'Real Find must reach the real resolver normal refusal, not optional-reference binding failure.' $branch
                        Assert-CapTest ($entryCount -eq [int]$sink -and
                            $diagnosticCount -eq [int]($sink -and -not $bound)) 'Real resolver entry or refusal emission count changed.' $branch
                        if ($sink -and $bound) {
                            Assert-CapTest ($null -ne $snapshot -and $snapshot.CandidatesObserved -and
                                $snapshot.Candidates.Count -eq 1 -and $snapshot.Candidates[0].Current.ProcessId -eq $PID -and
                                $snapshot.ExpectedProcessId -eq $PID -and $snapshot.Name -ceq $parameters.Name -and
                                -not $snapshot.EmissionAttempted -and
                                $snapshot.Context.RootProcessId -eq $PID -and
                                $snapshot.Context.ProcessIdentity.CreationFileTimeUtc -eq $identity.CreationFileTimeUtc -and
                                $snapshot.Context.ParameterSet -ceq $parameterSet -and
                                $snapshot.Context.Scope -eq [System.Windows.Automation.TreeScope]::Element) `
                                'Bound reference lost actual candidates, held generation, selector, or generated context.'
                            Assert-CapTest (($parameterSet -ceq 'Window' -and $snapshot.Context.RootHandle -eq $window) -or
                                ($parameterSet -ceq 'Element' -and $null -eq $snapshot.Context.RootHandle)) `
                                'Bound reference changed the generated root handle context.'
                        } elseif ($sink) {
                            $data = Read-SelectorEvidence $path
                            Assert-CapTest ($data.schema -ceq 'CapSelectorRefusal/1' -and
                                $data.refusal.message -ceq $expected -and $data.stageCounts.total -eq 1 -and
                                $data.stageCounts.processOwned -eq 1 -and $data.stageCounts.nameMatch -eq 0 -and
                                $data.candidates[0].ProcessId.value -is [long] -and
                                $data.candidates[0].ProcessId.value -eq $PID -and
                                $data.heldContext.rootProcessId -eq $PID -and
                                $data.heldContext.parameterSet -ceq $parameterSet -and
                                $data.heldContext.identity.CreationFileTimeUtc.value -eq $identity.CreationFileTimeUtc) `
                                'Unbound reference lost direct typed candidate/stage/held-context evidence.'
                        } else {
                            Assert-CapTest ($null -eq $snapshot -and -not (Test-Path -LiteralPath $path)) `
                                'No-sink real Find retained a snapshot or wrote trace output.'
                        }
                        Assert-CapTest (@(Get-CapTraceFailures).Count -eq $failuresBefore) 'Real Find added a trace observer failure.'
                    }
                }
            }
            Assert-CapTest ($branches.Count -eq 8) 'Real Find optional-reference matrix did not execute all eight branches.'
        } catch {
            $lifecycle.errors = @($_.Exception.ToString())
            throw
        } finally {
            try {
                if ($window -ne [IntPtr]::Zero) {
                    [CapOptionalRefWindowFixture]::Destroy($window)
                    $lifecycle.destroyed = -not [CapOptionalRefWindowFixture]::IsWindow($window)
                    $lifecycle.destroyObservedUtc = [DateTimeOffset]::UtcNow.ToString('o')
                    Assert-CapTest $lifecycle.destroyed 'Hidden regression HWND survived cleanup.'
                }
                $lifecycle.selfStillLiveBeforeDispose = -not [CapNative]::IsExited($self.Handle, $PID)
            } finally {
                $self.Dispose()
                $lifecycle.selfWrapperDisposed = $true
                Set-CapTracePath -Path (Join-Path $scratch 'test-calls.jsonl')
                Write-JournalContractJson (Join-Path $scratch 'selector-real-find-lifecycle.json') $lifecycle
            }
        }
        return $lifecycle
    }
    function Invoke-CapHiddenActionFixture {
        param([string]$CaseName, [switch]$Late)
        if (-not ('CapHiddenActionFixture' -as [type])) {
            Add-Type -AssemblyName UIAutomationProvider, WindowsBase
            $frameworkReferences = @(Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Filter '*.dll' -File |
                Where-Object Name -NotIn @('UIAutomationProvider.dll','UIAutomationTypes.dll','WindowsBase.dll') |
                Select-Object -ExpandProperty FullName)
            Add-Type -ReferencedAssemblies ($frameworkReferences + @(
                [System.Windows.Automation.Provider.IRawElementProviderSimple].Assembly.Location,
                [System.Windows.Automation.Provider.IRawElementProviderFragmentRoot].Assembly.Location,
                [System.Windows.Automation.AutomationElementIdentifiers].Assembly.Location,
                [System.Windows.Rect].Assembly.Location
            )) -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Provider;
[ComVisible(true)]
public sealed class CapHiddenActionFixture : IRawElementProviderFragmentRoot, IDisposable {
    private delegate IntPtr WindowProc(IntPtr h, uint m, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    private struct WindowClass {
        public uint style; public WindowProc procedure; public int classExtra, windowExtra;
        public IntPtr instance, icon, cursor, background;
        public string menu, name;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Message { public IntPtr h; public uint m; public UIntPtr w; public IntPtr l;
        public uint time; public int x, y; public uint extra; }
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern ushort RegisterClassW(ref WindowClass c);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr CreateWindowExW(uint e, string c, string n, uint s, int x, int y,
        int width, int height, IntPtr p, IntPtr menu, IntPtr instance, IntPtr argument);
    [DllImport("user32.dll")] private static extern IntPtr DefWindowProcW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] private static extern int GetMessageW(out Message m,IntPtr h,uint a,uint b);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref Message m);
    [DllImport("user32.dll")] private static extern IntPtr DispatchMessageW(ref Message m);
    [DllImport("user32.dll")] private static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern void PostQuitMessage(int code);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    private static extern bool UnregisterClassW(string c,IntPtr instance);
    private readonly ManualResetEvent ready = new ManualResetEvent(false);
    private readonly Thread thread;
    private readonly WindowProc procedure;
    private readonly string className = "CapHiddenAction" + Guid.NewGuid().ToString("N");
    private readonly Child child;
    private readonly bool late;
    private Timer timer;
    private Exception startupError;
    private int firstRead, available, invokes;
    public IntPtr Window { get; private set; }
    public int InitialNameReads { get { return firstRead; } }
    public int Invokes { get { return invokes; } }
    public DateTime? InitialReadUtc { get; private set; }
    public DateTime? AvailableUtc { get; private set; }
    public bool ThreadClosed { get; private set; }
    public CapHiddenActionFixture(bool late) {
        this.late=late; child=new Child(this); procedure=Procedure;
        thread=new Thread(Run); thread.IsBackground=true; thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
        if (!ready.WaitOne(5000)) throw new TimeoutException("Hidden HWND startup deadline.");
        if (startupError!=null) throw new InvalidOperationException("Hidden HWND startup failed.",startupError);
    }
    private void Run() {
        try {
            var c=new WindowClass { procedure=procedure, name=className };
            if (RegisterClassW(ref c)==0) throw new Win32Exception(Marshal.GetLastWin32Error());
            Window=CreateWindowExW(0,className,"Hidden action fixture",0x80000000u,0,0,120,30,
                IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
            if (Window==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            ready.Set();
            Message m; int status;
            while ((status=GetMessageW(out m,IntPtr.Zero,0,0))>0) {
                TranslateMessage(ref m); DispatchMessageW(ref m);
            }
            if (status<0) throw new Win32Exception(Marshal.GetLastWin32Error());
        } catch(Exception e) { startupError=e; ready.Set(); }
        finally { UnregisterClassW(className,IntPtr.Zero); }
    }
    private IntPtr Procedure(IntPtr h,uint m,IntPtr w,IntPtr l) {
        if (m==0x003d && l.ToInt64()==AutomationInteropProvider.RootObjectId)
            return AutomationInteropProvider.ReturnRawElementProvider(h,w,l,this);
        if (m==0x0010) { DestroyWindow(h); return IntPtr.Zero; }
        if (m==0x0002) { PostQuitMessage(0); return IntPtr.Zero; }
        return DefWindowProcW(h,m,w,l);
    }
    public void Dispose() {
        if (timer!=null) timer.Dispose();
        if (IsWindow(Window) && !PostMessageW(Window,0x0010,IntPtr.Zero,IntPtr.Zero))
            throw new InvalidOperationException("Hidden HWND close post failed.");
        ThreadClosed=thread.Join(5000);
        ready.Dispose();
        if (!ThreadClosed || IsWindow(Window)) throw new InvalidOperationException("Hidden HWND/thread survived cleanup.");
        if (startupError!=null) throw new InvalidOperationException("Hidden HWND thread failed.",startupError);
    }
    public ProviderOptions ProviderOptions { get { return ProviderOptions.ServerSideProvider; } }
    public IRawElementProviderSimple HostRawElementProvider { get { return AutomationInteropProvider.HostProviderFromHandle(Window); } }
    public object GetPatternProvider(int id) { return null; }
    public object GetPropertyValue(int id) {
        if (id==AutomationElementIdentifiers.NameProperty.Id) return "Hidden action root";
        if (id==AutomationElementIdentifiers.ProcessIdProperty.Id) return System.Diagnostics.Process.GetCurrentProcess().Id;
        if (id==AutomationElementIdentifiers.ControlTypeProperty.Id) return ControlType.Window.Id;
        return null;
    }
    public Rect BoundingRectangle { get { return new Rect(0,0,120,30); } }
    public IRawElementProviderFragmentRoot FragmentRoot { get { return this; } }
    public IRawElementProviderFragment Navigate(NavigateDirection d) {
        return d==NavigateDirection.FirstChild || d==NavigateDirection.LastChild ? child : null;
    }
    public int[] GetRuntimeId() { return null; }
    public IRawElementProviderSimple[] GetEmbeddedFragmentRoots() { return null; }
    public void SetFocus() { throw new InvalidOperationException("Fixture must not receive focus."); }
    public IRawElementProviderFragment ElementProviderFromPoint(double x,double y) { return child; }
    public IRawElementProviderFragment GetFocus() { return null; }
    [ComVisible(true)]
    private sealed class Child : IRawElementProviderFragment, IInvokeProvider {
        private readonly CapHiddenActionFixture owner;
        public Child(CapHiddenActionFixture owner) { this.owner=owner; }
        public ProviderOptions ProviderOptions { get { return ProviderOptions.ServerSideProvider; } }
        public IRawElementProviderSimple HostRawElementProvider { get { return null; } }
        public object GetPatternProvider(int id) { return id==InvokePatternIdentifiers.Pattern.Id ? this : null; }
        public object GetPropertyValue(int id) {
            if (id==AutomationElementIdentifiers.NameProperty.Id) {
                if (Interlocked.CompareExchange(ref owner.firstRead,1,0)==0) {
                    owner.InitialReadUtc=DateTime.UtcNow;
                    if (owner.late) owner.timer=new Timer(_ => {
                        owner.AvailableUtc=DateTime.UtcNow; Volatile.Write(ref owner.available,1);
                    },null,350,Timeout.Infinite);
                    return "Beta";
                }
                return Volatile.Read(ref owner.available)==1 ? "Alpha" : "Beta";
            }
            if (id==AutomationElementIdentifiers.AutomationIdProperty.Id) return "open-project-848";
            if (id==AutomationElementIdentifiers.ProcessIdProperty.Id) return System.Diagnostics.Process.GetCurrentProcess().Id;
            if (id==AutomationElementIdentifiers.IsOffscreenProperty.Id) return false;
            if (id==AutomationElementIdentifiers.IsEnabledProperty.Id) return true;
            if (id==AutomationElementIdentifiers.ControlTypeProperty.Id) return ControlType.Button.Id;
            if (id==AutomationElementIdentifiers.IsInvokePatternAvailableProperty.Id) return true;
            return null;
        }
        public Rect BoundingRectangle { get { return new Rect(10,10,100,20); } }
        public IRawElementProviderFragmentRoot FragmentRoot { get { return owner; } }
        public IRawElementProviderFragment Navigate(NavigateDirection d) { return d==NavigateDirection.Parent ? owner : null; }
        public int[] GetRuntimeId() { return new int[] { AutomationInteropProvider.AppendRuntimeId,848 }; }
        public IRawElementProviderSimple[] GetEmbeddedFragmentRoots() { return null; }
        public void SetFocus() { throw new InvalidOperationException("Fixture must not receive focus."); }
        public void Invoke() { Interlocked.Increment(ref owner.invokes); }
    }
}
'@
        }
        $path = Join-Path $scratch ("selector-action-$CaseName.jsonl")
        $snapshotPath = Join-Path $scratch ("selector-action-$CaseName-snapshot.json")
        Set-CapTracePath $path
        $self = [Diagnostics.Process]::GetCurrentProcess()
        $fixture = $null
        $detail = [ordered]@{
            mode = 'REAL_WORKER_ACTION_REAL_FIND_REAL_RESOLVER_HIDDEN_OWN_HWND_UIA_NO_INPUT_OR_CAPTURE'
            pid = $PID; image = $self.MainModule.FileName; startTimeUtc = $self.StartTime.ToUniversalTime().ToString('o')
            sourceHashes = $sourceHashesBefore; hwnd = $null; creationFileTimeUtc = $null
            createdUtc = $null; destroyed = $false; threadClosed = $false; fixtureProcesses = 0
            childExitAndEof = 'No fixture child: HWND/thread belong to current test process.'
            deadlineUtc = $null; beganUtc = $null; endedUtc = $null; elapsedMilliseconds = $null
            initialReadUtc = $null; availableUtc = $null; invokes = 0; resolverEntries = 0
            failure = $null; result = $null; terminalSnapshots = 0; snapshotPath = $snapshotPath
        }
        try {
            $identity = Get-CapProcessIdentity -Process $self -ExpectedImagePath $self.MainModule.FileName -Role 'hidden-action-self'
            $detail.creationFileTimeUtc = $identity.CreationFileTimeUtc
            $fixture = [CapHiddenActionFixture]::new($Late.IsPresent)
            $detail.hwnd = $fixture.Window.ToInt64()
            $detail.createdUtc = [DateTime]::UtcNow.ToString('o')
            Assert-CapTest (-not [CapHiddenActionFixture]::IsWindowVisible($fixture.Window)) 'Action fixture must stay hidden.'
            $ast = [Management.Automation.Language.Parser]::ParseFile($workerPath,[ref]$null,[ref]$null)
            foreach ($functionName in @('Invoke-CapSceneAction','Assert-CapWorkerDeadline')) {
                $definitions = @($ast.FindAll({ param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
                },$true))
                Assert-CapTest ($definitions.Count -eq 1) 'Actual worker action/deadline missing or duplicated.'
                . ([scriptblock]::Create($definitions[0].Extent.Text))
            }
            function Write-CapWorkerLog { param([string]$Message) Write-CapTrace 'HiddenActionWorkerLog' @{ message = $Message } }
            $leaseDeadlineUtc = [DateTime]::UtcNow.AddSeconds(15)
            $detail.deadlineUtc = $leaseDeadlineUtc.ToString('o')
            $detail.beganUtc = [DateTime]::UtcNow.ToString('o')
            $watch = [Diagnostics.Stopwatch]::StartNew()
            try {
                Invoke-CapSceneAction -AppRun ([pscustomobject]@{
                    Window = $fixture.Window; Run = @{ Identity = $identity }; Phase = 'hidden-action'
                }) -Action open-project -Name Alpha
                $detail.result = 'Scene action completed'
            } catch {
                $detail.failure = [ordered]@{
                    type = $_.Exception.GetType().FullName; message = $_.Exception.Message
                    raw = $_.Exception.ToString(); fullyQualifiedErrorId = $_.FullyQualifiedErrorId
                    stack = $_.ScriptStackTrace
                }
            }
            $detail.elapsedMilliseconds = $watch.Elapsed.TotalMilliseconds
            $detail.endedUtc = [DateTime]::UtcNow.ToString('o')
            $detail.initialReadUtc = $fixture.InitialReadUtc
            $detail.availableUtc = $fixture.AvailableUtc
            $detail.invokes = $fixture.Invokes
            $rows = @(Get-Content -LiteralPath $path | ForEach-Object { ConvertFrom-Json $_ -DateKind String })
            $detail.resolverEntries = @($rows | Where-Object command -CEQ 'Resolve-CapAutomationCandidate').Count
            $terminal = @($rows | Where-Object command -CEQ 'CapSelectorRefusal' | ForEach-Object {
                ConvertFrom-Json $_.parameters.diagnosticJson -Depth 20 -DateKind String
            } | Where-Object evidenceKind -CEQ 'TERMINAL_LAST_POLL_SNAPSHOT')
            $detail.terminalSnapshots = $terminal.Count
            if ($terminal.Count -eq 1) { Write-JournalContractJson $snapshotPath $terminal[0] }
            Assert-CapTest (@(Get-CapTraceFailures).Count -eq 0) 'Hidden action produced an observer failure.'
        } finally {
            try {
                if ($null -ne $fixture) {
                    $fixture.Dispose()
                    $detail.destroyed = -not [CapHiddenActionFixture]::IsWindow($fixture.Window)
                    $detail.threadClosed = $fixture.ThreadClosed
                }
            } finally {
                $self.Dispose()
                Set-CapTracePath -Path (Join-Path $scratch 'test-calls.jsonl')
                Write-JournalContractJson (Join-Path $scratch ("selector-action-$CaseName-fields.json")) $detail
            }
        }
        return $detail
    }
    Invoke-CapTest 'real worker action polls initial zero until a late hidden UIA element is available' {
        $detail = Invoke-CapHiddenActionFixture -CaseName late -Late
        Assert-CapTest ($null -eq $detail.failure -and $detail.invokes -eq 1 -and
            $detail.resolverEntries -ge 2 -and $null -ne $detail.initialReadUtc -and
            $null -ne $detail.availableUtc -and $detail.availableUtc -gt $detail.initialReadUtc -and
            $detail.terminalSnapshots -eq 0 -and $detail.destroyed -and $detail.threadClosed) `
            'Real action refused initial found=0 instead of waiting for its late native UIA target.' $detail
        return $detail
    }
    Invoke-CapTest 'real worker action terminal refusal persists typed last-poll native UIA candidates' {
        $detail = Invoke-CapHiddenActionFixture -CaseName terminal
        Assert-CapTest ($null -ne $detail.failure -and
            $detail.failure.message -ceq "UIA element 'Alpha' did not become available before the reserved deadline." -and
            $detail.resolverEntries -ge 2 -and $detail.invokes -eq 0 -and
            $detail.terminalSnapshots -eq 1 -and (Test-Path -LiteralPath $detail.snapshotPath) -and
            $detail.destroyed -and $detail.threadClosed) `
            'Real action refused immediately without retaining its terminal last-poll snapshot.' $detail
        $snapshot = Read-JournalContractJson $detail.snapshotPath
        Assert-CapTest ($snapshot.schema -ceq 'CapSelectorRefusal/1' -and $snapshot.candidatesObserved -and
            $snapshot.stageCounts.total -gt 0 -and $snapshot.candidates[0].Name.value -ceq 'Beta' -and
            $snapshot.candidates[0].AutomationId.value -ceq 'open-project-848' -and
            $snapshot.candidates[0].ProcessId.value -eq $PID -and
            $snapshot.heldContext.identity.CreationFileTimeUtc.value -eq $detail.creationFileTimeUtc -and
            $snapshot.terminalObservation.waitDeadlineUtc -ceq $detail.deadlineUtc) `
            'Terminal native candidates lost typed selector, ownership, generation or original deadline.'
        return $detail
    }
    Set-CapTracePath -Path (Join-Path $scratch 'test-calls.jsonl')
}

function Assert-CapIdentityUnavailable {
    param([scriptblock]$Action)
    try { $null = & $Action }
    catch {
        Assert-CapTest ($_.Exception -is [InvalidOperationException] -and
            $_.Exception.Data['CapCaptureCode'] -ceq 'ProcessIdentityUnavailable') `
            "Expected typed identity unavailability, got $($_.Exception.ToString())"
        return $_.Exception
    }
    throw 'Unavailable identity unexpectedly returned a result.'
}

function Invoke-CapIdentityContracts {
    foreach ($kind in @('not-started', 'disposed-self-wrapper')) {
        Invoke-CapTest "actual $kind identity refuses unavailable Handle and Id before Snapshot binding" {
            $process = if ($kind -ceq 'not-started') { [Diagnostics.Process]::new() }
                else { [Diagnostics.Process]::GetProcessById($PID) }
            if ($kind -ceq 'disposed-self-wrapper') { $process.Dispose() }
            try {
                $failure = Assert-CapIdentityUnavailable {
                    Get-CapProcessIdentity -Process $process -ExpectedImagePath ([Environment]::ProcessPath) -Role $kind
                }
                Assert-CapTest ($failure.Data['HandleState'] -ceq 'GetterException' -and
                    $failure.Data['IdState'] -ceq 'GetterException' -and
                    $null -eq $failure.Data['AcquiredPid'] -and $null -eq $failure.Data['ExpectedPid'] -and
                    $failure.Data['CallSite'] -ceq 'Get-CapProcessIdentity.InitialSnapshot' -and
                    $failure.InnerException -is [AggregateException] -and
                    $failure.InnerException.InnerExceptions.Count -eq 2) 'Getter failures or unknown PID evidence was lost.'
                return @{ code = $failure.Data['CapCaptureCode']; details = $failure.Data
                    originalExceptions = @($failure.InnerException.InnerExceptions | ForEach-Object { $_.ToString() })
                    historicalCause = 'UNOBSERVED; controlled object condition only' }
            } finally { $process.Dispose() }
        }
    }
    Invoke-CapTest 'synthetic accessor states reject null invalid values and independent getter failures without defaults' {
        $self = [Diagnostics.Process]::GetProcessById($PID)
        try {
            $handle = $self.get_Handle()
            $rows = @(
                @{ h = $null; i = $PID; hs = 'Null'; ids = 'Available' }
                @{ h = [IntPtr]::Zero; i = $PID; hs = 'Invalid'; ids = 'Available' }
                @{ h = [IntPtr]::new(-1); i = $PID; hs = 'Invalid'; ids = 'Available' }
                @{ h = 123; i = $PID; hs = 'Invalid'; ids = 'Available' }
                @{ h = $handle; i = $null; hs = 'Available'; ids = 'Null' }
                @{ h = $handle; i = 0; hs = 'Available'; ids = 'Invalid' }
                @{ h = $handle; i = [string]$PID; hs = 'Available'; ids = 'Invalid' }
                @{ h = $handle; i = $PID; hs = 'GetterException'; ids = 'Available' }
                @{ h = $handle; i = $PID; hs = 'Available'; ids = 'GetterException' }
            )
            $details = foreach ($row in $rows) {
                $probe = [Diagnostics.Process]::new()
                $probe | Add-Member -NotePropertyName CapAccessorProbe -NotePropertyValue @{
                    row = $row; handleReads = 0; idReads = 0
                }
                $probe | Add-Member -MemberType ScriptMethod -Name get_Handle -Force -Value {
                    $this.CapAccessorProbe.handleReads++
                    if ($this.CapAccessorProbe.row.hs -ceq 'GetterException') { throw [InvalidOperationException]::new('SYNTHETIC_HANDLE_GETTER') }
                    return $this.CapAccessorProbe.row.h
                }
                $probe | Add-Member -MemberType ScriptMethod -Name get_Id -Force -Value {
                    $this.CapAccessorProbe.idReads++
                    if ($this.CapAccessorProbe.row.ids -ceq 'GetterException') { throw [InvalidOperationException]::new('SYNTHETIC_ID_GETTER') }
                    return $this.CapAccessorProbe.row.i
                }
                try {
                    $failure = Assert-CapIdentityUnavailable {
                        Read-CapProcessAccess -Process $probe -Role 'synthetic-accessor' -CallSite 'SyntheticContract' -ExpectedPid $PID
                    }
                    Assert-CapTest ($failure.Data['HandleState'] -ceq $row.hs -and $failure.Data['IdState'] -ceq $row.ids -and
                        $probe.CapAccessorProbe.handleReads -eq 1 -and $probe.CapAccessorProbe.idReads -eq 1 -and
                        $failure.Data['ExpectedPid'] -eq $PID) 'Accessor states/counts/expected context changed.'
                    if ($row.ids -ceq 'Available') {
                        Assert-CapTest ($failure.Data['AcquiredPid'] -eq $PID) 'Actually read PID was lost when Handle was unavailable.'
                    } else {
                        Assert-CapTest ($null -eq $failure.Data['AcquiredPid']) 'Expected PID was misrepresented as acquired.'
                    }
                    if ($row.hs -ceq 'GetterException' -or $row.ids -ceq 'GetterException') {
                        Assert-CapTest ($null -ne $failure.InnerException) 'Original synthetic getter exception was discarded.'
                    }
                    @{ handleState = $row.hs; idState = $row.ids; handleReads = 1; idReads = 1 }
                } finally { $probe.Dispose() }
            }
            Assert-CapTest ($details.Count -eq 9) 'Synthetic accessor state inventory changed.'
            return @{ executed = $details.Count; rows = @($details); scope = 'Synthetic accessors; not a historical-cause reproduction' }
        } finally { $self.Dispose() }
    }
    Invoke-CapTest 'valid self identity preserves actual kernel CIM generation and explicit acquisition' {
        $self = [Diagnostics.Process]::GetProcessById($PID)
        try {
            $access = Read-CapProcessAccess -Process $self -Role 'valid-self' -CallSite 'ValidSelfContract' -ExpectedPid $PID
            $snapshot = [CapNative]::Snapshot($access.Handle, $access.Pid)
            $identity = Get-CapProcessIdentity -Process $self -ExpectedImagePath ([Environment]::ProcessPath) -Role 'valid-self'
            $verified = Assert-CapProcessIdentity $identity
            Assert-CapTest ($access.Pid -eq $PID -and $snapshot.ProcessId -eq $PID -and -not $snapshot.IsExited -and
                $snapshot.CreationFileTimeUtc -eq $identity.CreationFileTimeUtc -and
                $identity.InitialMetadataObserved -and $verified.State -ceq 'Live') 'Valid kernel/CIM ownership behavior changed.'
            return @{ pid = $identity.Pid; creationFileTimeUtc = $identity.CreationFileTimeUtc; state = $verified.State }
        } finally { $self.Dispose() }
    }
    Invoke-CapTest 'acquired PID mismatch and native handle PID mismatch still refuse without adoption' {
        $self = [Diagnostics.Process]::GetProcessById($PID)
        try {
            $failure = $null
            try { $null = Read-CapProcessAccess -Process $self -Role 'pid-mismatch' -CallSite 'MismatchContract' -ExpectedPid ($PID + 1) }
            catch [InvalidOperationException] { $failure = $_.Exception }
            Assert-CapTest ($null -ne $failure -and $failure.Data['CapCaptureCode'] -ceq 'ProcessIdentityMismatch' -and
                $failure.Data['AcquiredPid'] -eq $PID -and $failure.Data['ExpectedPid'] -eq ($PID + 1)) 'Expected PID replaced the acquired PID.'
            $null = Assert-CapRejects { [CapNative]::Snapshot($self.get_Handle(), ($PID + 1)) } 'Process handle/PID mismatch'
            $null = Assert-CapRejects { [CapNative]::Snapshot([IntPtr]::Zero, $PID) } 'handle'
            return @{ acquired = $PID; expected = $PID + 1; nativeMismatchRefused = $true; nativeZeroRefused = $true }
        } finally { $self.Dispose() }
    }
    Invoke-CapTest 'disposed tracked identity refuses assert stop and wait rather than claiming exit' {
        $self = [Diagnostics.Process]::GetProcessById($PID)
        $identity = Get-CapProcessIdentity -Process $self -ExpectedImagePath ([Environment]::ProcessPath) -Role 'disposed-tracked-self'
        $self.Dispose()
        $failures = @(
            Assert-CapIdentityUnavailable { Assert-CapProcessIdentity $identity }
            Assert-CapIdentityUnavailable { Stop-CapManagedProcess $identity }
            Assert-CapIdentityUnavailable { Wait-CapManagedProcess -Run ([pscustomobject]@{ Identity = $identity }) -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(1)) }
        )
        Assert-CapTest ($failures.Count -eq 3 -and @($failures | Where-Object {
            $_.Data['ExpectedPid'] -eq $PID -and $null -eq $_.Data['AcquiredPid']
        }).Count -eq 3) 'Disposed tracked identity was accepted, stopped, or treated as gone.'
        return @{ refused = 3; killAttempts = 0; exitInference = 'UNPROVEN' }
    }
    Invoke-CapTest 'unavailable launch rollback retains typed primary secondary pending evidence and unknown PID' {
        $module = Get-Module UiCaptureDriver
        $details = foreach ($knownPid in @($false, $true)) {
            $process = if ($knownPid) { [Diagnostics.Process]::GetProcessById($PID) } else { [Diagnostics.Process]::new() }
            $acquiredPid = if ($knownPid) { $process.get_Id() } else { $null }
            $process.Dispose()
            $primary = Assert-CapIdentityUnavailable {
                Get-CapProcessIdentity -Process $process -ExpectedImagePath ([Environment]::ProcessPath) -Role 'unavailable-launch-contract'
            }
            $record = [pscustomobject]@{
                Process = $process; AcquiredPid = $acquiredPid; Role = 'unavailable-launch-contract'
                ExpectedImagePath = [Environment]::ProcessPath; ExpectedParentPid = $PID; ExpectedSessionId = 0
                Snapshot = $null; StdoutTask = $null; StderrTask = $null; StartFailure = $null; RollbackFailure = $null
                StartFailureException = $null; RollbackFailureException = $null
            }
            $outcome = & $module {
                param($Record, $Primary)
                $previous = $script:CapLastRollbackReceipt
                $script:CapPendingLaunches.Add($Record)
                try {
                    $outer = $null
                    try { Complete-CapFailedLaunch -LaunchRecord $Record -StartFailure $Primary }
                    catch [InvalidOperationException] { $outer = $_.Exception }
                    $pending = @(Get-CapPendingLaunches | Where-Object Role -CEQ 'unavailable-launch-contract')
                    $resolve = $null
                    try { $null = Resolve-CapPendingLaunches }
                    catch { $resolve = $_.Exception }
                    [pscustomobject]@{ Outer = $outer; Pending = $pending; ResolveFailure = $resolve
                        Receipt = $script:CapLastRollbackReceipt; StillPending = $script:CapPendingLaunches.Contains($Record) }
                } finally {
                    $null = $script:CapPendingLaunches.Remove($Record)
                    $script:CapLastRollbackReceipt = $previous
                }
            } $record $primary
            Assert-CapTest ($outcome.Outer.Data['CapCaptureCode'] -ceq 'ProcessIdentityUnavailable' -and
                $outcome.Outer.InnerException -is [AggregateException] -and
                $outcome.Outer.InnerException.InnerExceptions.Count -eq 2 -and
                [object]::ReferenceEquals($outcome.Outer.InnerException.InnerExceptions[0], $primary) -and
                $outcome.Pending.Count -eq 1 -and $null -eq $outcome.Pending[0].KernelExited -and
                $outcome.Pending[0].KernelProbeFailure.Contains('ProcessIdentityUnavailable') -and
                $outcome.Pending[0].KernelProbeFailureDetails['CapCaptureCode'] -ceq 'ProcessIdentityUnavailable' -and
                $null -ne $outcome.ResolveFailure -and $outcome.StillPending -and
                $outcome.Receipt.RefusedUnsafeTermination -and $null -eq $outcome.Receipt.KernelExited) `
                'Unavailable cleanup lost a failure, removed pending evidence, or invented kernel exit.'
            $pidText = if ($knownPid) { [string]$acquiredPid } else { 'UNAVAILABLE' }
            Assert-CapTest ($outcome.Outer.Message.Contains("PID ${pidText}:") -and
                $outcome.Pending[0].Pid -eq $acquiredPid -and
                $outcome.ResolveFailure.Message.Contains("PID $pidText role=")) 'Failure formatting reread unavailable PID or invented zero.'
            @{ acquiredPid = $acquiredPid; outer = $outcome.Outer.ToString()
                pending = $outcome.Pending; kernelExit = 'UNPROVEN'; eof = 'UNPROVEN' }
        }
        Assert-CapTest ($details.Count -eq 2 -and @(Get-CapPendingLaunches).Count -eq 0) 'Synthetic-only pending test records were not removed.'
        return @{ cases = @($details); processStarts = 0; scope = 'Actual failed-launch handler and rollback with controlled wrappers; no target' }
    }
}

if ($IdentityContractOnly) {
    Invoke-CapIdentityContracts
    foreach ($path in $sourceHashesBefore.Keys) {
        Assert-CapTest ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $sourceHashesBefore[$path]) "Source changed during identity contracts: $path"
    }
    $passed = @($results | Where-Object passed -EQ $true).Count
    $failed = @($results | Where-Object passed -EQ $false).Count
    $report = [pscustomobject]@{ suite = 'UiCaptureIdentityContracts'; executed = $results.Count; passed = $passed; failed = $failed
        cases = @($results); sourceHashesBeforeImport = $sourceHashesBefore
        mode = 'SELF_PROCESS_AND_SYNTHETIC_ACCESSORS_NO_CHILD_FIXTURE_OR_KILL' }
    $report | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath (Join-Path $scratch 'report.json') -Encoding utf8NoBOM
    $report | Select-Object suite,executed,passed,failed | ConvertTo-Json -Compress
    if ($results.Count -ne 7 -or $passed -ne 7 -or $failed -ne 0) { exit 1 }
    exit 0
}

if ($SelectorRefusalContractOnly) {
    Invoke-CapSelectorRefusalContracts
    $passed = @($results | Where-Object passed -EQ $true).Count
    $failed = @($results | Where-Object passed -EQ $false).Count
    $report = [pscustomobject]@{ suite = 'UiCaptureSelectorRefusalContracts'; executed = $results.Count
        passed = $passed; failed = $failed; cases = @($results); sourceHashesBeforeImport = $sourceHashesBefore
        mode = 'SYNTHETIC_CANDIDATES_AND_REAL_FIND_HIDDEN_OWN_PROCESS_UIA_NO_DESKTOP_INPUT' }
    $report | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath (Join-Path $scratch 'report.json') -Encoding utf8NoBOM
    $report | Select-Object suite,executed,passed,failed | ConvertTo-Json -Compress
    if ($results.Count -ne 16 -or $passed -ne 16 -or $failed -ne 0) { exit 1 }
    exit 0
}

if ($PreflightReportContractOnly) {
    Invoke-CapTest 'actual rehearsal data satisfies the repaired report gate and refuses stale proof' { Invoke-CapPreflightReportContract }
    $passed = @($results | Where-Object passed -EQ $true).Count
    $failed = @($results | Where-Object passed -EQ $false).Count
    $report = [pscustomobject]@{ suite = 'UiCapturePreflightReportContract'; executed = $results.Count
        passed = $passed; failed = $failed; cases = @($results)
        mode = 'SYNTHETIC_REPORT_ACCEPTANCE_NO_COMPILER_TARGET_OR_PROVIDER' }
    $report | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath (Join-Path $scratch 'report.json') -Encoding utf8NoBOM
    $report | Select-Object suite,executed,passed,failed | ConvertTo-Json -Compress
    if ($results.Count -ne 1 -or $passed -ne 1 -or $failed -ne 0) { exit 1 }
    exit 0
}

if ($FixtureContractOnly -or $JournalTimingContractOnly -or $JournalFirstOpenContractOnly -or $JournalObservationContractOnly) {
    if ($FixtureContractOnly) {
        Invoke-CapTest 'prebuilt fixture binder accepts exact artifacts and refuses missing or tampered bytes' { Invoke-CapPrebuiltFixtureContract }
    }
    if ($JournalTimingContractOnly) {
        Invoke-CapTest 'journal phase timing records open copy total without changing budget or retry limits' { Invoke-CapJournalTimingContract }
    }
    if ($JournalFirstOpenContractOnly) { Invoke-CapFirstOpenGroups }
    if ($JournalObservationContractOnly) {
        Invoke-CapTest 'journal success observations bypass slow durable flush without changing the read budget or observation count' {
            Invoke-CapJournalObservationContract
        }
    }
    $passed = @($results | Where-Object passed -EQ $true).Count
    $failed = @($results | Where-Object passed -EQ $false).Count
    $report = [pscustomobject]@{ suite = 'UiCaptureSetupContracts'; executed = $results.Count; passed = $passed; failed = $failed
        cases = @($results); mode = if ($JournalObservationContractOnly) {
            'FILE_IO_IN_PROCESS_CSHARP_SEAM_NO_NATIVE_FIXTURE_COMPILER_OR_TARGET'
        } else { 'BINDER_AND_TIMING_FILE_IO_NO_COMPILER_OR_TARGET' } }
    $report | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath (Join-Path $scratch 'report.json') -Encoding utf8NoBOM
    $report | Select-Object suite,executed,passed,failed | ConvertTo-Json -Compress
    if ($results.Count -ne ([int]$FixtureContractOnly.IsPresent + [int]$JournalTimingContractOnly.IsPresent +
        2 * [int]$JournalFirstOpenContractOnly.IsPresent + [int]$JournalObservationContractOnly.IsPresent) -or $failed -ne 0) { exit 1 }
    exit 0
}

if ($DAdapterContractOnly -and $DAdapterCase -cin @('SceneContract','FixtureDirectory')) {
    Invoke-CapDContracts
    Write-CapDContractReport
}

if ($PrepareFixturesOnly) {
    if ($ReceiptContractOnly -or $FixtureContractOnly -or $JournalTimingContractOnly -or $JournalFirstOpenContractOnly -or $JournalObservationContractOnly -or $PrebuiltFixtureManifest) {
        throw 'Fixture preparation cannot also consume or run contract suites.'
    }
    $null = New-CapHarmlessTarget
    $null = New-CapCimRaceTarget
    $reference = Write-CapPrebuiltFixtureManifest
    $null = Read-CapPrebuiltFixtures $reference.path $reference.sha256
    $reference | ConvertTo-Json -Depth 8 -Compress
    exit 0
}

$target = $null
try {
    $prebuilt = Read-CapPrebuiltFixtures $PrebuiltFixtureManifest $PrebuiltFixtureManifestSha256
    $target = $prebuilt.Target
    if ($AppChildContractOnly) {
        Invoke-CapAppChildContracts
        $passed = @($results | Where-Object passed -EQ $true).Count
        $failed = @($results | Where-Object passed -EQ $false).Count
        $report = [pscustomobject]@{ suite = 'UiCaptureAppChildContracts'; executed = $results.Count; passed = $passed
            failed = $failed; cases = @($results); gui = 'NotExecuted'; images = 0 }
        $report | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath (Join-Path $scratch 'app-child-report.json') -Encoding utf8NoBOM
        $report | Select-Object suite,executed,passed,failed | ConvertTo-Json -Compress
        if ($results.Count -ne 9 -or $passed -ne 9 -or $failed -ne 0) { exit 1 }
        exit 0
    }
    if ($DAdapterContractOnly) {
        Invoke-CapDContracts
        Write-CapDContractReport
    }
    if ($JournalContractOnly) {
        Invoke-JournalContractGroups -IncludeConcurrent
        Invoke-CapTest 'real harmless managed-worker journal integration' {
            $run = Invoke-CapCaptureCommand -Name 'journal-integration'
            $null = Assert-CapRehearsalSuccess -Run $run -Arguments @()
            Assert-CapTest ($run.receipt.journalPublishedInventory.Count -ge 2 -and
                $null -ne $run.receipt.journalFinalBinding) 'Actual quiescent worker final binding is missing.'
            return @{ status = $run.receipt.status; binding = $run.receipt.journalFinalBinding
                inventory = $run.receipt.journalPublishedInventory; gui = 'NotExecuted' }
        }
    } else {
    $cimRaceTarget = $prebuilt.CimRace
    if (-not $LaunchContractOnly) {
        Invoke-CapAppChildContracts
        Invoke-CapDContracts
        Invoke-CapIdentityContracts
        Invoke-CapSelectorRefusalContracts
        Invoke-CapTest 'prebuilt fixture binder accepts exact artifacts and refuses missing or tampered bytes' { Invoke-CapPrebuiltFixtureContract }
        Invoke-CapTest 'journal phase timing records open copy total without changing budget or retry limits' { Invoke-CapJournalTimingContract }
        Invoke-CapFirstOpenGroups
        Invoke-CapTest 'journal success observations bypass slow durable flush without changing the read budget or observation count' {
            Invoke-CapJournalObservationContract
        }
        Invoke-CapTest 'actual exit receipt reader retries sharing and partial JSON with typed deadline and identity refusal' {
            $details = @(
                foreach ($receiptCaseName in @('exclusive-release','exclusive-deadline','partial-json','foreign-job','foreign-generation')) {
                    Invoke-CapReceiptIoCase $receiptCaseName
                }
            )
            Assert-CapTest ($details.Count -eq 5) 'Receipt contract group must execute all five actual-reader cases.'
            return @{ executed = $details.Count; cases = $details; mode = 'File IO only; no native target or lease mock' }
        }
        Invoke-CapTest 'zmx rendezvous lease guard accepts240 and refuses241 before launch' {
            $sid = 'S-1-5-21-1111111111-2222222222-3333333333-1234567890'
            $session = 'graphcode-11111111-1111-4111-8111-000000000001'
            $directory = 'C:\' + ('x' * 72)
            $accepted = Assert-CapZmxLeasePath -ZmxDir $directory -SessionName $session -Sid $sid
            Assert-CapTest ($sid.Length -eq 52 -and $accepted.LeasePathLength -eq 240 -and
                $accepted.SessionUtf8Bytes -eq 46 -and $accepted.SessionHexLength -eq 92) 'Provider lease-path boundary differs.'
            $refusal = $null
            try {
                $null = Assert-CapZmxLeasePath -ZmxDir ($directory + 'x') -SessionName $session -Sid $sid
                throw 'The 241-character lease path was not refused.'
            } catch [IO.PathTooLongException] { $refusal = $_.Exception }
            Assert-CapTest ($null -ne $refusal -and $refusal.Data['CapCaptureCode'] -ceq 'ZmxLeasePathTooLong' -and
                $refusal.Data['LeasePathLength'] -eq 241) 'Lease overflow did not preserve its typed refusal.'
            $unicode = Assert-CapZmxLeasePath -ZmxDir 'C:\gjp3\abcde' -SessionName ('a' + [char]0x00e9) -Sid $sid
            Assert-CapTest ($unicode.SessionUtf8Bytes -eq 3 -and $unicode.SessionHexLength -eq 6) 'Session hex must encode UTF8 bytes, not UTF16 characters.'
            $bSession = 'graphcode-gc-cap-actions-12345678-before--00000000-0000-0000-0000-000000000000'
            $bPath = Assert-CapZmxLeasePath -ZmxDir 'C:\b1\abcde' -SessionName $bSession -Sid $sid
            Assert-CapTest ($bSession.Length -eq 78 -and $bPath.LeasePathLength -eq 240) 'Live B root budget differs from its longest actual session shape.'
            $null = Assert-CapRejects {
                Assert-CapZmxLeasePath -ZmxDir 'C:\gjp3\abcde' -SessionName $bSession -Sid $sid
            } 'ZmxLeasePathTooLong'
            return 'Pure path arithmetic and typed guard, including inclusive240/negative241/UTF8; no target or provider execution.'
        }
        foreach ($jobBehavior in @('normal','nonzero','timeout')) {
            Invoke-CapTest "contained job launcher preserves target $jobBehavior and proves closure" {
                Invoke-CapJobOwnershipContract $jobBehavior
            }
        }
        Invoke-CapTest 'worker and contained launcher clear STD inheritance before target launch' {
            $source = [IO.File]::ReadAllText($workerPath)
            Assert-CapTest ($source.IndexOf('[CapProcessJob]::ClearStandardHandleInheritance()') -lt
                $source.IndexOf('    $identity = Assert-CapJobIdentity')) 'Worker guard does not precede admission Git spawns.'
            $moduleSource = [IO.File]::ReadAllText($modulePath)
            Assert-CapTest ($moduleSource.Contains('KILL_ON_JOB_CLOSE') -and
                -not $moduleSource.Contains('BREAKAWAY_OK')) 'Job containment policy changed.'
            return 'Source ordering only; duplicated/cached STD handles are not proved by this assertion.'
        }
        Invoke-CapTest 'umbrella safety-net kill refuses clean release for an unreceipted member' {
            $ast = [Management.Automation.Language.Parser]::ParseFile($supervisorPath, [ref]$null, [ref]$null)
            $consumer = @($ast.FindAll({ param($node)
                $node -is [Management.Automation.Language.ForEachStatementAst] -and
                $node.Variable.VariablePath.UserPath -ceq 'memberPid' -and
                $node.Extent.Text.Contains("'SAFETY_NET_KILLED'")
            }, $true))
            Assert-CapTest ($consumer.Count -eq 1) 'Actual umbrella safety-net consumer missing or duplicated.'
            $status = @($ast.FindAll({ param($node)
                $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text.Contains('$workerLaunchAttempted') -and
                $node.Clauses[0].Item1.Extent.Text.Contains('$cleanupFailures.Count -eq 0') -and
                $node.Extent.Text.Contains("'FAILED_ZERO_SURVIVORS'")
            }, $true))
            Assert-CapTest ($status.Count -eq 1) 'Actual release-status expression missing or duplicated.'
            $membersBeforeStop = @(10,20)
            $exemptWorkerPid = 10
            $recoveryReceipts = [Collections.Generic.List[object]]::new()
            $cleanupFailures = [Collections.Generic.List[string]]::new()
            & ([scriptblock]::Create($consumer[0].Extent.Text))
            Assert-CapTest ($recoveryReceipts.Count -eq 1 -and $recoveryReceipts[0].pid -eq 20 -and
                $recoveryReceipts[0].kind -ceq 'SAFETY_NET_KILLED' -and
                -not $recoveryReceipts[0].identityAttested -and -not $recoveryReceipts[0].cleanReleaseProven -and
                $cleanupFailures.Count -eq 1 -and $cleanupFailures[0].Contains('SAFETY_NET_KILLED')) `
                'Unreceipted member was silently safety-killed or the exact worker exemption widened.'
            $workerLaunchAttempted = $true
            $cleanupProven = $cleanupFailures.Count -eq 0
            $survivors = [Collections.Generic.List[object]]::new()
            $primaryFailure = $null
            $actualStatus = & ([scriptblock]::Create($status[0].Extent.Text))
            Assert-CapTest ($actualStatus -ceq 'CLEANUP_UNPROVEN') 'Safety-net cleanup became a clean release.'
            return 'Actual source consumer/status expressions with synthetic membership data only; no job/native execution or generation adoption.'
        }
        Invoke-CapTest 'N1 owned output descendant fixture accepts closure and refuses foreign or stale bytes' {
            $context = New-JournalContractContext 'n1-owned-files'
            $context.State.ObservationPath = Join-Path $context.Root 'journal-read-observations.jsonl'
            $directory = Join-Path $context.Root 'output'
            $null = New-Item -ItemType Directory -Path $directory
            $files = @('seed-stdout.log','seed-stderr.log') | ForEach-Object {
                $path = Join-Path $directory $_
                [IO.File]::WriteAllText($path, 'SYNTHETIC_RECEIPT_ACCEPT_PATH_NOT_REAL_SEED')
                [pscustomobject]@{ path = $path; length = [long](Get-Item $path).Length
                    sha256 = (Get-FileHash $path -Algorithm SHA256).Hash }
            }
            $proof = [pscustomobject]@{ kind = 'OWNED_FILES_JOB'; jobId = [guid]::NewGuid().ToString()
                state = 'CLOSED'; jobActive0 = $true; activeProcesses = 0L; files = $files
                launcherStdoutEof = $true; launcherStderrEof = $true
                launcherPid = 10L; launcherCreationFileTimeUtc = 100L; censusProven = $true }
            $null = Assert-CapJobOutputProof -Root $context.Root -Proof $proof
            $rootReceipt = [pscustomobject]@{ pid = 10L; creationFileTimeUtc = 100L
                expectedImagePath = (Join-Path $context.Root 'fixture.exe'); role = 'zmx-launcher'
                parentPid = 1L; sessionId = 1L; kernelExited = $true; stdoutEof = $true; stderrEof = $true
                streamOwnerPid = 10L; streamOwnerCreationFileTimeUtc = 100L; outputProof = $proof }
            $childReceipt = [pscustomobject]@{ pid = 20L; creationFileTimeUtc = 200L
                expectedImagePath = (Join-Path $context.Root 'daemon.exe'); role = 'zmx-daemon'
                parentPid = 10L; sessionId = 1L; kernelExited = $true; stdoutEof = $false; stderrEof = $false
                streamOwnerPid = 10L; streamOwnerCreationFileTimeUtc = 100L
                outputKind = 'OWNED_FILES_JOB'; jobId = $proof.jobId }
            $processes = @($rootReceipt,$childReceipt)
            $entries = @($processes | ForEach-Object { [pscustomobject]@{
                pid = $_.pid; creationFileTimeUtc = $_.creationFileTimeUtc; role = $_.role
                expectedImagePath = $_.expectedImagePath; expectedParentPid = $_.parentPid; expectedSessionId = $_.sessionId
            } })
            $data = [pscustomobject]@{ entries = $entries; ownedProcesses = $processes; outcome = 'COMPLETE'
                ownedProcessSurvivors = @(); pendingLaunchesRemaining = @(); cleanupFailures = @() }
            $null = Publish-CapJournalSnapshot $context.State Bootstrap $data
            $terminal = Publish-CapJournalSnapshot $context.State Terminal $data
            $manifest = [pscustomobject]@{ status = 'COMPLETE'; ownedProcesses = $processes
                ownedProcessSurvivors = @(); pendingLaunchesRemaining = @(); cleanupFailures = @()
                journal = [pscustomobject]@{ protocolVersion = 2L; binding = $context.Binding
                    directory = $context.State.Directory; terminal = $terminal
                    published = @($context.State.Published.ToArray()) } }
            $manifestRef = Write-CapImmutableJson -Root $context.Root -Path (Join-Path $directory 'manifest.json') -Value $manifest
            $record = Read-CapJournalFinalRecord (Format-CapJournalFinalRecord $context.Binding $manifestRef $terminal) $context.Binding
            $accepted = Read-CapJournalFinalProof -State $context.State -OutputDirectory $directory -Record $record
            Assert-CapTest ($accepted.HashChainVerified -and $accepted.Manifest.ownedProcesses.Count -eq 2 -and
                $accepted.Manifest.ownedProcesses[1].pid -ne $accepted.Manifest.ownedProcesses[1].streamOwnerPid -and
                -not $accepted.Manifest.ownedProcesses[1].stdoutEof) 'N1 did not exercise a real output-descendant accept path.'
            $wrong = $proof.PSObject.Copy()
            $wrong.files = @($files[0].PSObject.Copy(), $files[1])
            $wrong.files[0].path = Join-Path (Split-Path -Parent $context.Root) 'foreign.log'
            $null = Assert-CapRejects { Assert-CapJobOutputProof -Root $context.Root -Proof $wrong } 'escaped'
            [IO.File]::AppendAllText($files[0].path, 'STALE')
            $null = Assert-CapRejects { Assert-CapJobOutputProof -Root $context.Root -Proof $proof } 'bytes'
            $null = Assert-CapRejects {
                Read-CapJournalFinalProof -State $context.State -OutputDirectory $directory -Record $record
            } 'bytes'
            return 'Synthetic descendant output fixture, not root equality or real provider/daemon evidence.'
        }
        if ($RequireRealSeed) {
            foreach ($realBehavior in @('normal','nonzero','timeout')) {
                Invoke-CapTest "real zmx job lifecycle through actual command with target $realBehavior" {
                    $run = Invoke-CapCaptureCommand -Name ('real-seed-' + $realBehavior) -Behavior $realBehavior -RealSeed
                    Assert-CapTest ($null -ne $run.receipt -and $run.receipt.containmentJob.jobActive0 -and
                        $run.receipt.workerStdoutEof -and $run.receipt.workerStderrEof -and
                        $null -ne $run.receipt.journalFinalBinding) 'Real seed command lacks job/EOF/final binding.'
                    $manifest = Get-Content -LiteralPath (Join-Path $run.output 'manifest.json') -Raw | ConvertFrom-Json -DateKind String
                    Assert-CapTest ($manifest.zmxSeeds.Count -eq 2 -and @($manifest.zmxSeeds | Where-Object {
                        $_.exitCode -ne 0 -or -not $_.daemonReady -or $_.daemonCount -lt 1 -or $_.cmdCount -lt 1 -or
                        $_.cleanupStatus -cne 'CLEAN_ZERO_SURVIVORS_FILES_CLOSED' -or
                        $_.stdoutEof -or $_.stderrEof -or -not $_.outputProof.jobActive0
                    }).Count -eq 0) 'Real two-phase seed census/file closure was not proved.'
                    foreach ($seed in $manifest.zmxSeeds) { $null = Assert-CapJobOutputProof -Root $run.owned -Proof $seed.outputProof }
                    $expectedStatus = if ($realBehavior -eq 'normal') { 'RELEASED_ZERO_SURVIVORS' } else { 'FAILED_ZERO_SURVIVORS' }
                    Assert-CapTest ($run.receipt.status -ceq $expectedStatus -and
                        (($realBehavior -eq 'normal' -and $run.child.exitCode -eq 0) -or
                        ($realBehavior -ne 'normal' -and $run.child.exitCode -ne 0 -and
                            $run.receipt.workerPrimaryFailure.Count -gt 0))) 'Target primary failure was replaced by successful real seed cleanup.'
                    return @{ release = $run.receiptPath; releaseSha256 = $run.receiptSha256
                        zmxSha256 = $RealSeedZmxSha256; phases = 2; targetBehavior = $realBehavior
                        providerCommit = '785b3fd15dcafd1882b495c831a10f98c201b908'
                        evidenceMode = 'EXECUTED_CURRENT_REAL_ZMX' }
                }
            }
        }
        foreach ($mutation in @('accepted', 'lane-d', 'red-ci', 'binary-hash', 'product-diff',
            'ci-head', 'empty-ci', 'source-bytes', 'lease-base', 'duplicate-ci', 'duplicate-json', 'null-build', 'stale-build',
            'omitted-product-diff', 'phase-swap', 'unrelated-base')) {
            Invoke-CapTest "lease-bound admission $mutation through actual capture command" {
                $run = Invoke-CapCaptureCommand -Name "admission-$mutation" -AdmissionMutation $mutation
                if ($mutation -in @('accepted', 'lane-d')) {
                    $null = Assert-CapRehearsalSuccess -Run $run -Arguments @()
                    foreach ($component in @('supervisor', 'worker')) {
                        $trace = @(Get-Content (Join-Path $run.output "$component-calls.jsonl") |
                            ForEach-Object { $_ | ConvertFrom-Json })
                        Assert-CapTest (@($trace | Where-Object command -CEQ 'Assert-CapJobIdentity').Count -eq 1) `
                            "Lease-bound identity was not checked by the actual $component."
                    }
                } else {
                    $expected = switch ($mutation) {
                        'red-ci' { 'CI run is not exact-head completed success' }
                        'binary-hash' { 'binary hash mismatch' }
                        'product-diff' { 'Non-equivalent product/provider/build input diff' }
                        'ci-head' { 'CI context is not exact-head green' }
                        'empty-ci' { 'CI inventory must contain a positive complete context count' }
                        'source-bytes' { 'Fresh source bytes differ' }
                        'lease-base' { 'Lease-bound job identity differs' }
                        'duplicate-ci' { 'CI context is not exact-head green' }
                        'duplicate-json' { 'Duplicate JSON field' }
                        'null-build' { "field 'sourceCommit'" }
                        'stale-build' { 'Fresh build provenance must name the exact phase source' }
                        'omitted-product-diff' { 'Equivalence proof does not name the complete exact Git delta' }
                        'phase-swap' { 'before binary hash mismatch' }
                        'unrelated-base' { 'merge-base --is-ancestor' }
                    }
                    Assert-CapTest ($run.child.exitCode -ne 0 -and $null -ne $run.receipt -and
                        $run.receipt.status -ceq 'REFUSED_NO_WORKER' -and -not $run.receipt.workerStarted -and
                        $run.receipt.primaryFailure.Contains($expected) -and
                        $run.receipt.leaseReceiptSha256 -ceq $run.leaseSha256 -and
                        $run.receipt.cleanupState -ceq 'NO_WORKER_STARTED') `
                        "Admission $mutation was not refused by the actual supervisor with its official release: $($run.child.stderr)"
                }
                return [ordered]@{ release = $run.receiptPath; sha256 = $run.receiptSha256
                    status = $run.receipt.status; exit = $run.child.exitCode
                    data = 'Synthetic CI/build/review controls; real Git, binaries, command, lease, worker and release; no product evidence' }
            }
        }
    }
    if (-not $LaunchContractOnly) {
        Invoke-CapTest 'unsupported C D E scene adapters refuse independently of generic identity' {
            foreach ($lane in @('C', 'D', 'E')) {
                $null = Assert-CapRejects {
                    Assert-CapSceneContract -Job ([pscustomobject]@{ lane = $lane; sceneAdapter = 'B_FIVE_SCENES_V1' })
                } 'Unsupported scene adapter'
            }
            return 'Pure scene-contract refusal; no scene, UI, product or adapter ran.'
        }
    }
    Invoke-CapTest 'real capture command with nonempty arguments' {
        $arguments = [string[]]@('alpha', 'two words', 'quote"inside', 'trailing\')
        $run = Invoke-CapCaptureCommand -Name 'nonempty' -Arguments $arguments
        Assert-CapRehearsalSuccess -Run $run -Arguments $arguments
    }
    Invoke-CapTest 'real capture command with genuine zero arguments' {
        $run = Invoke-CapCaptureCommand -Name 'empty' -Arguments @()
        Assert-CapRehearsalSuccess -Run $run -Arguments @()
    }
    if (-not $LaunchContractOnly) {
        Invoke-CapTest 'real argument vector preserves an empty string and Unicode' {
            $arguments = [string[]]@('', ('caf' + [char]0x00e9), 'x\"y', 'two trailing\\')
            $run = Invoke-CapCaptureCommand -Name 'argument-vector' -Arguments $arguments
            Assert-CapRehearsalSuccess -Run $run -Arguments $arguments
        }
        $fixedNow = [DateTimeOffset]::Parse('2026-10-14T21:30:00Z',
            [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        $window = $null
        Invoke-CapTest 'UTC Z and numeric offsets preserve exact lease instants and 90-second reserve' {
            $script:window = Get-CapLeaseWindow -GrantedUtc '2026-10-14T21:25:01Z' `
                -ExpiresUtc '2026-10-14T21:40:01Z' -MaximumMinutes 15 -NowUtc $fixedNow
            foreach ($offset in @(
                @('2026-10-15T04:25:01+07:00', '2026-10-15T04:40:01+07:00'),
                @('2026-10-14T14:25:01-07:00', '2026-10-14T14:40:01-07:00')
            )) {
                $other = Get-CapLeaseWindow -GrantedUtc $offset[0] -ExpiresUtc $offset[1] -MaximumMinutes 15 -NowUtc $fixedNow
                Assert-CapTest ($other.GrantedUtc -eq $window.GrantedUtc -and $other.ExpiresUtc -eq $window.ExpiresUtc) 'Offset changed UTC lease instants.'
            }
            $deadline = Get-CapAuthorizedWorkerDeadline -WorkerDeadlineUtc '2026-10-15T04:38:31+07:00' `
                -LeaseWindow $window -NowUtc $fixedNow
            Assert-CapTest ($window.DurationMinutes -eq 15 -and $deadline.Kind -eq [DateTimeKind]::Utc -and
                $deadline -eq $window.ExpiresUtc.AddSeconds(-90)) 'Exact cleanup reserve changed.'
            return [ordered]@{ fixedNow = $fixedNow.ToString('o'); durationMinutes = 15; reserveSeconds = 90 }
        }
        foreach ($mutation in @('expired-boundary', 'future-boundary', 'over-duration', 'over-allocation',
            'missing-offset', 'clock-kind', 'deadline-mismatch', 'deadline-expired')) {
            Invoke-CapTest "fixed UTC guard refuses $mutation" {
                $parameters = @{
                    GrantedUtc = '2026-10-14T21:25:01Z'; ExpiresUtc = '2026-10-14T21:40:01Z'
                    MaximumMinutes = 15; NowUtc = $fixedNow
                }
                $expected = 'Coordinator lease is expired'
                switch ($mutation) {
                    'expired-boundary' { $parameters.NowUtc = $window.ExpiresUtc }
                    'future-boundary' { $parameters.NowUtc = $window.GrantedUtc.AddSeconds(-1) }
                    'over-duration' { $parameters.ExpiresUtc = '2026-10-14T21:40:02Z' }
                    'over-allocation' { $parameters.MaximumMinutes = 16 }
                    'missing-offset' { $parameters.GrantedUtc = '2026-10-14T21:25:01'; $expected = 'explicit UTC marker' }
                    'clock-kind' { $parameters.NowUtc = [DateTime]::SpecifyKind($fixedNow, [DateTimeKind]::Unspecified); $expected = 'explicitly UTC' }
                    'deadline-mismatch' { $expected = 'does not match' }
                    'deadline-expired' { $expected = 'already expired' }
                }
                Assert-CapRejects {
                    if ($mutation -like 'deadline-*') {
                        $value = if ($mutation -eq 'deadline-mismatch') { '2026-10-14T21:38:32Z' } else { '2026-10-14T21:38:31Z' }
                        $clock = if ($mutation -eq 'deadline-expired') { $window.WorkerDeadlineUtc } else { $fixedNow }
                        Get-CapAuthorizedWorkerDeadline -WorkerDeadlineUtc $value -LeaseWindow $window -NowUtc $clock
                    } else { Get-CapLeaseWindow @parameters }
                } $expected
            }
        }
        foreach ($mutation in @('malformed', 'expired', 'future', 'over-15', 'missing-offset', 'traversal-id', 'hash')) {
            Invoke-CapTest "same capture command refuses $mutation lease and writes release" {
                $run = Invoke-CapCaptureCommand -Name "lease-$mutation" -LeaseMutation $mutation
                Assert-CapTest ($run.child.exitCode -ne 0 -and $null -ne $run.receipt -and
                    $run.receipt.status -ceq 'REFUSED_NO_WORKER' -and -not $run.receipt.workerStarted -and
                    -not [string]::IsNullOrWhiteSpace($run.receipt.primaryFailure) -and
                    $run.receipt.leaseReceiptSha256 -ceq $run.leaseSha256 -and
                    $run.receipt.cleanupState -ceq 'NO_WORKER_STARTED') 'Invalid lease did not fail closed with an actual release file.'
                return [ordered]@{ exit = $run.child.exitCode; release = $run.receiptPath
                    sha256 = $run.receiptSha256; status = $run.receipt.status; primary = $run.receipt.primaryFailure }
            }
        }
        foreach ($behavior in @('nonzero', 'timeout', 'primary-cleanup', 'receipt-block', 'trace-readonly')) {
            Invoke-CapTest "same capture command handles target $behavior" {
                $run = Invoke-CapCaptureCommand -Name $behavior -Behavior $behavior
                Assert-CapTest ($run.child.exitCode -ne 0) 'Target failure became successful capture.'
                if ($behavior -eq 'receipt-block') {
                    Assert-CapTest ($null -eq $run.receipt -and $run.child.stderr.Contains('LEASE_RELEASE_WRITE_FAILED') -and
                        $run.child.stderr.Contains('Capture worker exited with code')) 'Receipt write failure or original worker failure was lost.'
                } else {
                    Assert-CapTest ($null -ne $run.receipt -and $null -ne $run.receipt.primaryFailure -and
                        ($behavior -eq 'trace-readonly' -or $run.receipt.workerPrimaryFailure.Count -gt 0) -and
                        $run.receipt.kernelVerifiedSurvivors.Count -eq 0 -and $run.receipt.workerStderrEof) 'Failure/release/EOF evidence missing.'
                    $expected = if ($behavior -in @('primary-cleanup', 'trace-readonly')) { 'CLEANUP_UNPROVEN' } else { 'FAILED_ZERO_SURVIVORS' }
                    Assert-CapTest ($run.receipt.status -ceq $expected) "Wrong failure release state: $($run.receipt.status)"
                    if ($behavior -in @('primary-cleanup', 'trace-readonly')) {
                        Assert-CapTest ($run.receipt.cleanupFailures.Count -gt 0) 'Primary failure replaced cleanup log-write failure.'
                    }
                    if ($behavior -eq 'trace-readonly') {
                        Assert-CapTest ($run.receipt.traceFailures.Count -gt 0) 'Trace I/O failure was not preserved in the actual release.'
                    }
                    if ($behavior -eq 'timeout') {
                        $reference = $run.receipt.journalFinalBinding.manifest
                        $manifestPath = Join-Path $run.output $reference.name
                        Assert-CapTest ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ceq $reference.sha256) `
                            'Timeout evidence is not the exact bound immutable FAILED manifest.'
                        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                        Assert-CapTest ($manifest.status -ceq 'FAILED') 'Timed-out target was not recorded as FAILED.'
                        Assert-CapTest ($manifest.rehearsalLaunches[0].cleanupResult -ceq 'TERMINATED_GUARDED_HANDLE') 'Timed-out target was not stopped by held kernel identity.'
                    }
                }
                return [ordered]@{ exit = $run.child.exitCode; output = $run.output; releaseSha256 = $run.receiptSha256 }
            }
        }

        Invoke-CapTest 'real pre-identity attestation failure rolls back its held process and EOF' {
            $receipt = Test-CapManagedProcessRollback -ProcessPath (Join-Path $PSHOME 'pwsh.exe') `
                -WorkingDirectory (Join-Path $scratch 'rollback')
            Assert-CapTest ($receipt.Result -ceq 'TERMINATED_GUARDED_HANDLE' -and $receipt.KernelExited -and
                $receipt.StdoutEof -and $receipt.StderrEof -and @(Get-CapPendingLaunches).Count -eq 0) 'Real guarded rollback was incomplete.'
            return $receipt
        }
        Invoke-CapTest 'guarded stop recognizes a genuinely exited held target generation' {
            $run = Start-CapManagedProcess -FilePath $target.executable -ArgumentList @() `
                -WorkingDirectory (Split-Path -Parent $target.executable) -Role 'held-exited-target-component' -CloseStdin `
                -Environment @{ CAP_REHEARSAL_BEHAVIOR = 'normal' }
            try {
                $wait = Wait-CapManagedProcess -Run $run -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5))
                Assert-CapTest ($wait.State -ceq 'Exited' -and $wait.ExitCode -eq 0) 'Harmless held target did not exit.'
                $terminated = [CapNative]::Terminate($run.Identity.Process.Handle, $run.Identity.Pid, 125, 1000)
                $stop = Stop-CapManagedProcess -Identity $run.Identity
                Assert-CapTest (-not $terminated -and $stop.Result -ceq 'SKIP_GENUINELY_EXITED_KERNEL' -and
                    $run.StdoutTask.Wait(2000) -and $run.StderrTask.Wait(2000)) 'Held exited generation was not distinguished from termination.'
                return [ordered]@{ pid = $run.Identity.Pid; creationFileTimeUtc = $run.Identity.CreationFileTimeUtc
                    result = $stop.Result; forcedTermination = $terminated
                    accessDeniedExitRace = 'Not forced; native code now waits on the retained kernel before refusing' }
            } finally {
                if (-not [CapNative]::IsExited($run.Identity.Process.Handle, $run.Identity.Pid)) {
                    $null = Stop-CapManagedProcess -Identity $run.Identity
                }
                $run.Identity.Process.Dispose()
            }
        }
        Invoke-CapTest 'attestation decision seam: fix matrix is correct over all rows and a faithful main mutant discriminates on the torn-row/just-exited and exited-without-EOF rows' {
            # TEST-ONLY faithful transcription of baseline main (D4579E92) decision logic:
            #  - Get-CapProcessIdentity read CIM first and THREW on an Incomplete row before
            #    consulting the retained kernel exit (so a torn row refused even once the child
            #    had genuinely exited); Absent retried while live and broke when exited; Complete
            #    used metadata.
            #  - Start-CapManagedProcessCore had NO both-stream EOF gate, so an exited generation
            #    recognized during attestation was accepted gone without EOF.
            # This is a decision-level transcription of the THREE selected counterexamples, NOT a
            # complete model of main (main also skips CIM when its initial snapshot is already
            # exited and still identity-validates a Complete row) and NOT main's code executing;
            # it is DISTINCT from the historical observed main RED (J3 baseline 49/48/1, CIM).
            function Resolve-MainAttestationDispositionMutant {
                param([string]$State, [bool]$KernelExited, [bool]$BothStreamsEofReached)
                if ($State -eq 'Incomplete') { return 'MainRefusesIncomplete' }
                if ($KernelExited) { return 'MainGoneNoEofGate' }
                if ($State -eq 'Complete') { return 'MainUseMetadata' }
                return 'MainRetryAbsent'
            }
            $rows = @(
                @{ s = 'Complete';   k = $false; e = $false; fix = 'UseMetadata' }
                @{ s = 'Complete';   k = $false; e = $true;  fix = 'UseMetadata' }
                @{ s = 'Incomplete'; k = $false; e = $false; fix = 'RefuseLiveIncomplete' }
                @{ s = 'Incomplete'; k = $false; e = $true;  fix = 'RefuseLiveIncomplete' }
                @{ s = 'Absent';     k = $false; e = $false; fix = 'RetryAbsent' }
                @{ s = 'Absent';     k = $false; e = $true;  fix = 'RetryAbsent' }
                @{ s = 'Complete';   k = $true;  e = $false; fix = 'RequireBothEofBeforeGone' }
                @{ s = 'Complete';   k = $true;  e = $true;  fix = 'GoneByKernelExit' }
                @{ s = 'Incomplete'; k = $true;  e = $false; fix = 'RequireBothEofBeforeGone' }
                @{ s = 'Incomplete'; k = $true;  e = $true;  fix = 'GoneByKernelExit' }
                @{ s = 'Absent';     k = $true;  e = $false; fix = 'RequireBothEofBeforeGone' }
                @{ s = 'Absent';     k = $true;  e = $true;  fix = 'GoneByKernelExit' }
            )
            foreach ($r in $rows) {
                $got = Resolve-CapAttestationDisposition -State $r.s -KernelExited $r.k -BothStreamsEofReached $r.e
                Assert-CapTest ($got -ceq $r.fix) "Fix disposition($($r.s),exit=$($r.k),eof=$($r.e))=$got; expected $($r.fix)."
            }
            $discriminators = @(
                @{ s = 'Incomplete'; k = $true; e = $true;  fixCorrect = 'GoneByKernelExit';         mainWrong = 'MainRefusesIncomplete' }
                @{ s = 'Complete';   k = $true; e = $false; fixCorrect = 'RequireBothEofBeforeGone'; mainWrong = 'MainGoneNoEofGate' }
                @{ s = 'Absent';     k = $true; e = $false; fixCorrect = 'RequireBothEofBeforeGone'; mainWrong = 'MainGoneNoEofGate' }
            )
            $discriminationCount = 0
            foreach ($d in $discriminators) {
                $fixGot = Resolve-CapAttestationDisposition -State $d.s -KernelExited $d.k -BothStreamsEofReached $d.e
                $mainGot = Resolve-MainAttestationDispositionMutant -State $d.s -KernelExited $d.k -BothStreamsEofReached $d.e
                Assert-CapTest ($fixGot -ceq $d.fixCorrect) "Fix must be correct on discriminator ($($d.s),$($d.k),$($d.e)): got $fixGot."
                Assert-CapTest ($mainGot -ceq $d.mainWrong) "Main mutant must reproduce the wrong disposition: got $mainGot."
                Assert-CapTest ($fixGot -cne $mainGot) 'Fix and main mutant must differ on this row.'
                $discriminationCount++
            }
            Assert-CapTest ($discriminationCount -eq 3) "Expected 3 discriminating rows; observed $discriminationCount."
            return [ordered]@{ fixRowsProven = $rows.Count; discriminatingRows = $discriminationCount
                note = 'Deterministic: real fix helper GREEN over 12 rows; test-only faithful main mutant RED on 3 rows (CIM torn-row refusal + missing EOF gate); distinct from the historical J3 49/48/1 CIM RED.' }
        }
        Invoke-CapTest 'live-incomplete child is refused with UNPROVEN rollback; test release records it genuinely gone' {
            $owned = Join-Path $scratch 'cim-incomplete'
            $null = New-Item -ItemType Directory -Path $owned
            $releaseFile = Join-Path $owned 'release.flag'
            # Outer try/finally covers launch + refusal + ALL assertions so the owned barrier is
            # always released and the owned pending resolved even if an early assertion fails.
            try {
                $refusal = $null
                try {
                    $null = Start-CapManagedProcess -FilePath $cimRaceTarget.executable -ArgumentList @() `
                        -WorkingDirectory (Split-Path -Parent $cimRaceTarget.executable) -Role 'cim-incomplete-live-refused' `
                        -Environment @{ CAP_CIM_BEHAVIOR = 'clearcmd-fileblock'; CAP_CIM_RELEASE_FILE = $releaseFile }
                    throw 'A live child with incomplete CIM was not refused.'
                } catch {
                    $refusal = $_.Exception.Message
                    if ($refusal -eq 'A live child with incomplete CIM was not refused.') { throw $refusal }
                    Assert-CapTest ($refusal -match 'incomplete current CIM metadata; refusing') "Refusal was not the live-incomplete guard: $refusal"
                }
                $pending = @((Get-CapPendingLaunches) | Where-Object { $_.Role -ceq 'cim-incomplete-live-refused' })
                Assert-CapTest ($pending.Count -eq 1 -and $null -ne $pending[0].RollbackFailure -and $pending[0].KernelExited -eq $false) `
                    'Live-incomplete child was not left as an UNPROVEN/retained pending launch (strict production contract).'
                $childPid = $pending[0].Pid
                $clsLive = Read-CapProcessMetadataState -Pid $childPid
                Assert-CapTest ($clsLive.State -ceq 'Incomplete') "Live refused child classified $($clsLive.State); expected Incomplete."
                # Test graceful assistance: release the test's OWN known child via a private
                # release file it owns (never a kill of a foreign/generic pid).
                [IO.File]::WriteAllText($releaseFile, 'release')
                $deadline = [DateTime]::UtcNow.AddSeconds(30)
                while ([DateTime]::UtcNow -lt $deadline) {
                    $p = @((Get-CapPendingLaunches) | Where-Object { $_.Pid -eq $childPid })
                    if (-not $p -or $p.KernelExited -eq $true) { break }
                    Start-Sleep -Milliseconds 50
                }
                $clsGone = Read-CapProcessMetadataState -Pid $childPid
                Assert-CapTest ($clsGone.State -ceq 'Absent') "Exited child classified $($clsGone.State); expected Absent."
                # Resolve-CapPendingLaunches processes all module-owned pending records; at this
                # point only this control's own child should remain pending.
                $resolved = @(Resolve-CapPendingLaunches)
                $me = $resolved | Where-Object { $_.Pid -eq $childPid }
                Assert-CapTest ($me -and $me.Result -ceq 'SKIP_GENUINELY_EXITED_KERNEL' -and $me.KernelExited -and
                    $me.StdoutEof -and $me.StderrEof -and
                    @((Get-CapPendingLaunches) | Where-Object { $_.Role -ceq 'cim-incomplete-live-refused' }).Count -eq 0) `
                    'Test-release cleanup did not record genuinely gone + both EOF + zero pending.'
                return [ordered]@{ refusal = $refusal
                    productionRollback = 'UNPROVEN_RETAINED (strict live-unknown contract preserved; no held-handle metadata bypass)'
                    incompleteClassificationObserved = $true
                    cleanup = 'TEST_GRACEFUL_RELEASE_OF_OWN_CHILD (not production live-unknown rollback success)'
                    resolvedResult = $me.Result }
            } finally {
                # Leak-prevention for THIS control's own child only (never a foreign kill):
                # release the owned barrier file, wait for the owned generation's kernel exit,
                # then resolve its own pending record. No bare catch that could mask a fault.
                if (-not (Test-Path -LiteralPath $releaseFile)) { [IO.File]::WriteAllText($releaseFile, 'release') }
                if (@((Get-CapPendingLaunches) | Where-Object { $_.Role -ceq 'cim-incomplete-live-refused' })) {
                    $deadline = [DateTime]::UtcNow.AddSeconds(20)
                    while ([DateTime]::UtcNow -lt $deadline -and
                        @((Get-CapPendingLaunches) | Where-Object { $_.Role -ceq 'cim-incomplete-live-refused' -and $_.KernelExited -ne $true })) {
                        Start-Sleep -Milliseconds 50
                    }
                    $null = Resolve-CapPendingLaunches
                }
            }
        }
        Invoke-CapTest 'current metadata and saved parent lifetime refuse unknown generations' {
            $identity = [pscustomobject]@{ Pid = 123; CreationFileTimeUtc = 100; ExpectedImagePath = 'C:\owned\target.exe'; ParentPid = 1; SessionId = 1 }
            $null = Assert-CapRejects { Assert-CapMetadataRecord -Identity $identity -Metadata $null } 'missing for live PID'
            $null = Assert-CapRejects {
                Assert-CapDescendantLifetime -ParentCreationFileTimeUtc 100 -ParentExitFileTimeUtc 200 -ChildCreationFileTimeUtc 201
            } 'outside parent lifetime'
            return 'Pure negative controls; no foreign process is opened or stopped.'
        }
        Invoke-CapTest 'shared live-admission fixture predicates accept an owned relocation and refuse stale or foreign mapping' {
            $owned = Join-Path $scratch 'relocated-fixture'
            $originalRoot = Join-Path $owned 'original'
            $null = New-Item -ItemType Directory -Path (Join-Path $owned 'inputs'), (Join-Path $owned 'fixtures'), (Join-Path $owned 'reports')
            $sourcePath = Join-Path $owned 'inputs\fixture-source.json'
            $fixturePath = Join-Path $owned 'fixtures\fixture.json'
            $mappingPath = Join-Path $owned 'reports\fixture-mapping.json'
            $source = [ordered]@{ graphs = @('Alpha', 'Beta') | ForEach-Object {
                [ordered]@{ project = [ordered]@{ name = $_; path = (Join-Path $originalRoot $_) }
                    nodes = @(1..5 | ForEach-Object { [ordered]@{ id = "node-$_" } }) }
            } }
            $source.graphs[0].nodes[0].worktreeBinding = @{ path = (Join-Path $originalRoot 'Alpha\card-tree') }
            $source.graphs[0].nodes[1].worktreeBinding = @{ path = (Join-Path $originalRoot 'Alpha\long-tree') }
            $source.graphs[1].nodes[0].worktreeBinding = @{ path = (Join-Path $originalRoot 'Beta\card-tree') }
            $source | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sourcePath -Encoding utf8NoBOM
            $originalEscaped = ($originalRoot | ConvertTo-Json -Compress).Trim('"')
            $ownedEscaped = ((Join-Path $owned 'fixtures\projects') | ConvertTo-Json -Compress).Trim('"')
            $mapped = [IO.File]::ReadAllText($sourcePath).Replace($originalEscaped, $ownedEscaped) | ConvertFrom-Json
            $mapped | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixturePath -Encoding utf8NoBOM
            $mapping = [ordered]@{
                sourcePath = (Join-Path $originalRoot 'fixture.json')
                sourceSha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
                copiedSourcePath = $sourcePath; rewrittenFixturePath = $fixturePath
                rewrittenFixtureSha256 = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
                pathPrefixMap = [ordered]@{ from = $originalRoot; to = (Join-Path $owned 'fixtures\projects') }
                graphs = 2; topLevelNodes = 10; pathsRewritten = $true
            }
            $mapping | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mappingPath -Encoding utf8NoBOM
            $parameters = @{ Root = $owned; FixturePath = $fixturePath; SourcePath = $sourcePath; MappingPath = $mappingPath
                ExpectedMappingSha256 = (Get-FileHash -LiteralPath $mappingPath -Algorithm SHA256).Hash
                ExpectedSourceSha256 = $mapping.sourceSha256; OriginalRoot = $originalRoot }
            $peerPath=Join-Path $owned 'inputs\offline-peer-source.ps1'
            [IO.File]::WriteAllText($peerPath,(Get-CapBPeerSource),[Text.UTF8Encoding]::new($false))
            $parameters.ExpectedPeerSha256=(Get-FileHash $peerPath -Algorithm SHA256).Hash
            $proof = Assert-CapFixtureMapping @parameters
            Assert-CapTest ($proof.FixtureSha256 -ceq $mapping.rewrittenFixtureSha256) 'Relocated fixture hash was not obtained from the bound mapping.'
            $staleParameters = $parameters.Clone()
            $staleParameters.ExpectedMappingSha256 = '0' * 64
            $null = Assert-CapRejects { Assert-CapFixtureMapping @staleParameters } 'trusted hashes'
            $null = Assert-CapRejects {
                Assert-CapArtifactPath -Root 'C:\gcs\cap' -Path 'C:\gcs\cap\never-created.json'
            } 'dedicated caller-owned root'
            $validFixture = [IO.File]::ReadAllText($fixturePath)
            [IO.File]::AppendAllText($fixturePath, "`n")
            $null = Assert-CapRejects { Assert-CapFixtureMapping @parameters } 'exact source and rewritten'
            [IO.File]::WriteAllText($fixturePath, $validFixture, [Text.UTF8Encoding]::new($false))
            $mapping.pathPrefixMap.to = $originalRoot
            $mapping | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mappingPath -Encoding utf8NoBOM
            $parameters.ExpectedMappingSha256 = (Get-FileHash -LiteralPath $mappingPath -Algorithm SHA256).Hash
            $null = Assert-CapRejects { Assert-CapFixtureMapping @parameters } 'exact source and rewritten'
            $mapping.pathPrefixMap.to = Join-Path $owned 'fixtures\projects'
            $validWorktreePath = $mapped.graphs[0].nodes[0].worktreeBinding.path
            $mapped.graphs[0].nodes[0].worktreeBinding.path = Join-Path $originalRoot 'Alpha\card-tree'
            $mapped | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixturePath -Encoding utf8NoBOM
            $mapping.rewrittenFixtureSha256 = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
            $mapping | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mappingPath -Encoding utf8NoBOM
            $parameters.ExpectedMappingSha256 = (Get-FileHash -LiteralPath $mappingPath -Algorithm SHA256).Hash
            $null = Assert-CapRejects { Assert-CapFixtureMapping @parameters } 'embedded path'
            $mapped.graphs[0].nodes[0].worktreeBinding.path = $validWorktreePath
            $mapped.graphs[0].project.path = Join-Path $originalRoot 'Alpha'
            $mapped | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixturePath -Encoding utf8NoBOM
            $mapping.rewrittenFixtureSha256 = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
            $mapping | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mappingPath -Encoding utf8NoBOM
            $parameters.ExpectedMappingSha256 = (Get-FileHash -LiteralPath $mappingPath -Algorithm SHA256).Hash
            $null = Assert-CapRejects { Assert-CapFixtureMapping @parameters } 'owned project path'
            return 'Actual shared root/source/mapping predicates only; no product binary, HWND, native compatibility, or live capture was executed.'
        }
        Invoke-CapTest 'actual immutable journal reader preserves held snapshots across concurrent numbered publications' {
            Invoke-JournalConcurrentContract -Name 'concurrent128' -Publications 128
        }
        Invoke-JournalContractGroups
        Invoke-CapTest 'actual rehearsal data satisfies the repaired report gate and refuses stale proof' {
            $source = [IO.File]::ReadAllText($supervisorPath)
            $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
            $function = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-CapPreflightReport'
            }, $true)
            . ([scriptblock]::Create($function.Extent.Text))
            $preflight = [ordered]@{
                suite = 'UiCaptureDriver'; executed = $results.Count; passed = $results.Count; failed = 0
                mode = $mode; gui = 'NotExecuted'; images = 0; backendTurns = 0; fixture = $target
                controls = [pscustomobject]@{ moduleSha256 = $sourceHashesBefore[$modulePath]
                    workerSha256 = $sourceHashesBefore[$workerPath]; supervisorSha256 = $sourceHashesBefore[$supervisorPath] }
                cases = @($results)
            } | ConvertTo-Json -Depth 25 | ConvertFrom-Json -DateKind String
            $moduleHash = $sourceHashesBefore[$modulePath]
            $workerHash = $sourceHashesBefore[$workerPath]
            $supervisorHash = $sourceHashesBefore[$supervisorPath]
            $preflightHash = 'A' * 64
            $PreflightReceiptSha256 = $preflightHash
            $job = [pscustomobject]@{ binaries = [pscustomobject]@{
                offlineZmx = [pscustomobject]@{ sha256 = $RealSeedZmxSha256 }
            } }
            if ($RequireRealSeed) { Assert-CapPreflightReport }
            else { $null = Assert-CapRejects { Assert-CapPreflightReport } 'real zmx job lifecycle' }
            $preflight.controls.workerSha256 = '0' * 64
            $null = Assert-CapRejects { Assert-CapPreflightReport } 'exact-source offline rehearsal'
            return 'Actual completed command-case data accepted; stale worker hash refused. Report-data validation only, no native preflight.'
        }
        Invoke-CapTest 'actual release data guard refuses unproved or omitted worker cleanup' {
            $ast = [Management.Automation.Language.Parser]::ParseInput(
                [IO.File]::ReadAllText($supervisorPath), [ref]$null, [ref]$null)
            $guard = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses[0].Item1.Extent.Text.Contains('$manifest.ownedProcessSurvivors') -and
                    $node.Extent.Text.Contains('Worker final kernel-cleanup evidence is absent or has survivors.')
            }, $true)
            Assert-CapTest ($null -ne $guard) 'Actual supervisor cleanup guard was not found.'
            foreach ($mutation in @('pending', 'cleanup-failure', 'survivor', 'missing-pending', 'missing-cleanup', 'missing-survivors', 'null-pending', 'scalar-cleanup')) {
                $workerRun = $true
                $manifest = [pscustomobject]@{ ownedProcessSurvivors = @(); pendingLaunchesRemaining = @(); cleanupFailures = @() }
                switch ($mutation) {
                    'pending' { $manifest.pendingLaunchesRemaining = @([pscustomobject]@{ pid = 123; role = 'unreturned-child'; state = 'UNPROVEN' }) }
                    'cleanup-failure' { $manifest.cleanupFailures = @('Guarded rollback refused unknown live metadata.') }
                    'survivor' { $manifest.ownedProcessSurvivors = @([pscustomobject]@{ pid = 123 }) }
                    'missing-pending' { $manifest.PSObject.Properties.Remove('pendingLaunchesRemaining') }
                    'missing-cleanup' { $manifest.PSObject.Properties.Remove('cleanupFailures') }
                    'missing-survivors' { $manifest.PSObject.Properties.Remove('ownedProcessSurvivors') }
                    'null-pending' { $manifest.pendingLaunchesRemaining = $null }
                    'scalar-cleanup' { $manifest.cleanupFailures = 0 }
                }
                $cleanupFailures = [Collections.Generic.List[string]]::new()
                & ([scriptblock]::Create($guard.Extent.Text))
                Assert-CapTest ($cleanupFailures.Count -eq 1) "Actual release guard falsely accepted $mutation cleanup data."
            }
            $manifest = [pscustomobject]@{ ownedProcessSurvivors = @(); pendingLaunchesRemaining = @(); cleanupFailures = @() }
            $cleanupFailures.Clear()
            & ([scriptblock]::Create($guard.Extent.Text))
            Assert-CapTest ($cleanupFailures.Count -eq 0) 'Actual guard refused complete empty cleanup arrays.'
            return 'Actual release predicate, eight negative data controls and one complete empty-array control; no unsafe child or process/lease/worker mock was executed.'
        }
        # Same frozen five-scene/two-phase mocks: component regression only, never launch/UI proof.
        # Test-CapCaptureOffline.ps1 SHA256 6C08A2029D9256405552BBA9B82B15A8A19359544433FD0E5928B4A7EA6C2592.
        try {
            $componentRoot = Join-Path $scratch 'component-only'
            . $workerPath -OwnedRoot $componentRoot -DefinitionsOnly
            $RunId = 'scene-components'
            $script:jobHash = 'D' * 64
            $script:moduleHash = $sourceHashesBefore[$modulePath]
            $script:workerHash = $sourceHashesBefore[$workerPath]
            $script:leaseHash = 'COMPONENT_ONLY_NOT_LEASED'
            $script:fixtureHash = 'A' * 64
            $script:fixtureSourceHash = 'B' * 64
            $script:fixtureMappingHash = 'C' * 64
            $script:leaseDeadlineUtc = [DateTime]::UtcNow.AddMinutes(3)
            $script:auth = [pscustomobject]@{ leaseId = [guid]::NewGuid().ToString(); supervisorSha256 = $sourceHashesBefore[$supervisorPath]; preflightReceiptSha256 = 'COMPONENT_ONLY' }
            $script:job = [pscustomobject]@{
                head = 'SYNTHETIC_AFTER'; base = 'SYNTHETIC_BEFORE'
                binaries = [pscustomobject]@{
                    before = [pscustomobject]@{ source = 'SYNTHETIC_BEFORE'; binaryBuiltAtSource = 'DISTINCT_BEFORE_BUILD'; sha256 = ('B' * 64) }
                    after = [pscustomobject]@{ source = 'SYNTHETIC_AFTER'; binaryBuiltAtSource = 'DISTINCT_AFTER_BUILD'; sha256 = ('C' * 64) }
                    offlineZmx = [pscustomobject]@{ seedArgumentOrder = @('run', 'graphcode-11111111-1111-4111-8111-000000000001', '-d', 'cmd.exe', '/Q', '/K', 'echo Offline card fixture - no backend') }
                }
                scenes = @(
                    [pscustomobject]@{ name = 'project-alpha'; zoomProbe = 'Name RefMain / AutomationId prefix canvas-card-'; naturalWidthBeforeAfter = @(250,250) },
                    [pscustomobject]@{ name = 'project-beta'; zoomProbe = 'Name RefComposite / AutomationId prefix canvas-card-'; naturalWidthBeforeAfter = @(250,250) },
                    [pscustomobject]@{ name = 'overview'; zoomProbe = 'Name RefMain / AutomationId prefix canvas-card-'; naturalWidthBeforeAfter = @(220,250) },
                    [pscustomobject]@{ name = 'workspace'; zoomProbe = $null },
                    [pscustomobject]@{ name = 'actions'; zoomProbe = 'Name UIA loop A / AutomationId prefix canvas-card-'; naturalWidthBeforeAfter = @(250,250) }
                )
            }
    $sceneTestRoot = Join-Path $root "preflight\$RunId\scene-functions"
    $script:runDirectory = $sceneTestRoot
    $script:outputDirectory = Join-Path $sceneTestRoot 'mock-output'
    $script:workerLog = Join-Path $sceneTestRoot 'mock-worker.log'
    $script:journalPath = Join-Path $sceneTestRoot 'mock-process-journal'
    $script:manifestPath = Join-Path $sceneTestRoot 'mock-manifest.json'
    New-Item -ItemType Directory -Path $script:outputDirectory -Force | Out-Null
    $null = New-Item -ItemType Directory -Path $script:journalPath
    $self = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $identity = Get-CapProcessIdentity -Process $self -ExpectedImagePath $self.MainModule.FileName -Role 'mock-scene-file-contract'
        $binding = New-CapJournalBinding -RunId ([guid]::NewGuid().ToString()) -LeaseId $script:auth.leaseId `
            -JobSha256 $script:jobHash -ModuleSha256 $script:moduleHash -WorkerSha256 $script:workerHash `
            -SupervisorSha256 $sourceHashesBefore[$supervisorPath] -Identity $identity
    } finally { $self.Dispose() }
    $script:journalState = New-CapJournalState -Root $root -Directory $script:journalPath `
        -Binding $binding -DeadlineUtc $script:leaseDeadlineUtc
    [IO.File]::WriteAllText($script:workerLog, '', [Text.UTF8Encoding]::new($false))
    $script:images = [Collections.Generic.List[object]]::new()
    $script:runs = [Collections.Generic.List[object]]::new()
    $script:seedRuns = [Collections.Generic.List[object]]::new()
    $script:applicationRuns = [Collections.Generic.List[object]]::new()
    $script:descendantIdentities = [Collections.Generic.List[object]]::new()
    $script:journalEntries = [Collections.Generic.List[object]]::new()
    $script:cleanupReceipts = [Collections.Generic.List[object]]::new()
    $script:cleanupFailures = [Collections.Generic.List[string]]::new()
    $script:zmxSeedReceipts = [Collections.Generic.List[object]]::new()
    $script:mockSceneRun = $true
    $sceneMock = [ordered]@{
        appRuns = [Collections.Generic.List[object]]::new()
        appEnvironments = [Collections.Generic.List[object]]::new()
        actionCalls = [Collections.Generic.List[object]]::new()
        actionObservations = [Collections.Generic.List[object]]::new()
        capturePaths = [Collections.Generic.List[string]]::new()
        cleanupCalls = [Collections.Generic.List[object]]::new()
        cleanupAttempts = [Collections.Generic.List[object]]::new()
        deadlineStages = [Collections.Generic.List[string]]::new()
        peerPipes = [Collections.Generic.List[string]]::new()
        seedStarts = [Collections.Generic.List[object]]::new()
        seedCloses = [Collections.Generic.List[string]]::new()
        zoomMeasurements = [Collections.Generic.List[object]]::new()
        zoomSelectors = [Collections.Generic.List[object]]::new()
    }
    function Assert-CapWorkerDeadline {
        param([string]$Stage)
        $script:sceneMock.deadlineStages.Add($Stage)
    }
    function Test-CapPipeUnserved {
        param([string]$PipeName)
        $script:sceneMock.peerPipes.Add("UNSERVED:$PipeName")
        return [pscustomobject]@{ PipeName = $PipeName; Unserved = $true; Win32Error = 2 }
    }
    function Start-CapOfflinePeer {
        param($Roots, [string]$PipeName, [string]$Phase)
        $null = Test-CapPipeUnserved -PipeName $PipeName
        $run = Start-CapManagedProcess -FilePath (Join-Path $PSHOME 'pwsh.exe') `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Milliseconds 250; exit 0') `
            -WorkingDirectory $Roots.Peer -Role "offline-fixture-peer-$Phase" `
            -Environment @{ TEMP = $Roots.Temp; TMP = $Roots.Temp; USERPROFILE = $Roots.Profile }
        $script:runs.Add($run)
        Write-CapProcessJournal -Identity $run.Identity -Phase $Phase
        $script:sceneMock.peerPipes.Add($PipeName)
        return $run
    }
    function Start-CapOfflineSeed {
        param($Roots, [string]$Phase)
        $arguments = @($script:job.binaries.offlineZmx.seedArgumentOrder)
        if ($arguments.Count -ne 7 -or $arguments[6] -cne 'echo Offline card fixture - no backend') {
            throw 'Scene runner did not retain the exact offline cmd-only seed contract.'
        }
        $workingDirectory = Join-Path $Roots.Peer 'mock-seed'
        New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null
        $run = Start-CapManagedProcess -FilePath (Join-Path $PSHOME 'pwsh.exe') `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Milliseconds 250; exit 0') `
            -WorkingDirectory $workingDirectory -Role "offline-scene-seed-mock-$Phase" `
            -Environment @{ TEMP = $Roots.Temp; TMP = $Roots.Temp; USERPROFILE = $Roots.Profile }
        $run | Add-Member -NotePropertyName Phase -NotePropertyValue $Phase
        $run | Add-Member -NotePropertyName SessionName -NotePropertyValue $arguments[1]
        $run | Add-Member -NotePropertyName Descendants -NotePropertyValue @()
        $run | Add-Member -NotePropertyName CleanupComplete -NotePropertyValue $false
        $receipt = [pscustomobject]@{
            phase = $Phase; mockOnly = $true; exitCode = $null
            daemonReady = $false; daemonCount = 0; cmdCount = 0
            descendants = @(); stdoutEof = $false; stderrEof = $false
            cleanupStatus = 'MOCK_PENDING'; cleanup = @()
        }
        $run | Add-Member -NotePropertyName SeedReceipt -NotePropertyValue $receipt
        $script:runs.Add($run)
        $script:seedRuns.Add($run)
        Write-CapProcessJournal -Identity $run.Identity -Phase $Phase
        $script:zmxSeedReceipts.Add($receipt)
        $script:sceneMock.seedStarts.Add([pscustomobject]@{
            Phase = $Phase; Root = $Roots.Root
            Zmx = $Roots.Zmx; Support = $Roots.Support; Arguments = $arguments
        })
        return $run
    }
    function Close-CapOfflineSeed {
        param($SeedRun)
        if ($SeedRun.CleanupComplete) { return }
        if (-not $SeedRun.Identity.Process.WaitForExit(3000)) {
            $null = Stop-CapManagedProcess -Identity $SeedRun.Identity -TimeoutMilliseconds 3000
        }
        if (-not $SeedRun.Identity.Process.WaitForExit(2000) -or
            $SeedRun.Identity.Process.ExitCode -ne 0) {
            throw 'Mock phase seed did not exit cleanly within its bounded no-GUI wait.'
        }
        Write-CapRunStreams -Run $SeedRun -Label "$($SeedRun.Phase)-mock-seed"
        $SeedRun.SeedReceipt.exitCode = $SeedRun.Identity.Process.ExitCode
        $SeedRun.SeedReceipt.stdoutEof = $SeedRun.StdoutTask.IsCompleted
        $SeedRun.SeedReceipt.stderrEof = $SeedRun.StderrTask.IsCompleted
        $SeedRun.SeedReceipt.cleanupStatus = 'CLEAN_ZERO_SURVIVORS_EOF'
        $SeedRun.CleanupComplete = $true
        $script:sceneMock.seedCloses.Add($SeedRun.SeedReceipt.phase)
    }
    function Start-CapGraphCodeApp {
        param($Roots, [string]$Phase, [string]$PipeName, [string]$SessionPrefix, [switch]$ActionsFixture)
        $environment = Get-CapBaseEnvironment -Roots $Roots -PipeName $PipeName `
            -SessionPrefix $SessionPrefix -ActionsFixture:$ActionsFixture
        if ($environment.ContainsKey('GRAPHCODE_UIA_SHOW_UPDATE') -or
            $environment.GRAPHCODE_UIA_UPDATE_AVAILABLE -ne '1' -or
            -not $environment.GRAPHCODE_GATE_CWD.StartsWith(($root + '\'), [StringComparison]::OrdinalIgnoreCase) -or
            $environment.ZMX_DIR -cne $Roots.Zmx) {
            throw "Unsafe or incorrect $Phase app environment in the worker scene flow."
        }
        if ($ActionsFixture -and
            ($environment.GRAPHCODE_UIA_FIXTURE_ROWS -ne '1' -or
             $environment.GRAPHCODE_UIA_CONNECTION_FAILURE -ne '1' -or
             $environment.GRAPHCODE_UIA_RESET_SIDEBAR -ne '1')) {
            throw "Actions scene did not receive the isolated builtin UIA fixture environment for $Phase."
        }
        $script:sceneMock.appEnvironments.Add([pscustomobject]@{
            Phase = $Phase; ActionsFixture = [bool]$ActionsFixture; Pipe = $PipeName
            Support = $Roots.Support; Local = $Roots.Local; Zmx = $Roots.Zmx
            ShowUpdate = $environment.ContainsKey('GRAPHCODE_UIA_SHOW_UPDATE')
            UpdateAvailable = $environment.GRAPHCODE_UIA_UPDATE_AVAILABLE
        })
        $run = Start-CapManagedProcess -FilePath (Join-Path $PSHOME 'pwsh.exe') `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Milliseconds 250; exit 0') `
            -WorkingDirectory (Join-Path $root 'fixtures\projects\Alpha') `
            -Role "offline-scene-mock-$Phase" -Environment $environment
        $run.Identity | Add-Member -NotePropertyName CapturePhase -NotePropertyValue $Phase
        $appRun = New-CapAppRunRecord -Run $run -Phase $Phase -SessionPrefix $SessionPrefix
        if ($appRun.CleanupComplete) { throw 'Production app-run record must start with cleanup incomplete.' }
        $script:runs.Add($run)
        Write-CapProcessJournal -Identity $run.Identity -Phase $Phase
        $script:applicationRuns.Add($appRun)
        $script:sceneMock.appRuns.Add($appRun)
        return $appRun
    }
    function Invoke-CapSceneAction {
        param($AppRun, [string]$Action, [string]$Name)
        if ($Action -in @('reply', 'reclaim', 'keep')) { throw "Mutating scene mock action is prohibited: $Action." }
        $script:sceneMock.actionCalls.Add([pscustomobject]@{
            Phase = $AppRun.Phase; Action = $Action; Name = $Name
        })
    }
    function Wait-CapVisibleElement {
        param($Window, $ProcessIdentity, [string]$Name, [string]$AutomationId, [string]$AutomationIdPrefix)
        $script:sceneMock.zoomSelectors.Add([pscustomobject]@{
            Phase = $ProcessIdentity.CapturePhase; Name = $Name; AutomationIdPrefix = $AutomationIdPrefix
        })
        return [pscustomobject]@{
            Name = $Name
            AutomationId = "$AutomationIdPrefix$Name"
            IsOffscreen = $false
            BoundingRectangle = [pscustomobject]@{ Left = 1.0; Top = 2.0; Width = 250.0; Height = 96.0 }
        }
    }
    function Measure-CapZoom {
        param($Element, [int]$NaturalWidth)
        $script:sceneMock.zoomMeasurements.Add([pscustomobject]@{
            Phase = $script:sceneMock.zoomSelectors[$script:sceneMock.zoomSelectors.Count - 1].Phase
            Name = $Element.Name; NaturalWidth = $NaturalWidth
        })
        return [pscustomobject]@{
            Name = $Element.Name; AutomationId = $Element.AutomationId
            NaturalWidth = $NaturalWidth; MeasuredWidth = [double]$NaturalWidth; ZoomPercent = 100.0
        }
    }
    function Get-CapWindowMetrics {
        param($Window, $ProcessIdentity)
        return [pscustomobject]@{
            OuterBounds = @(30, 30, 1486, 989)
            ClientBounds = @(0, 0, 1440, 900)
            Dpi = 96
        }
    }
    function Capture-CapWindow {
        param($Window, $ProcessIdentity, [string]$Path)
        $script:sceneMock.capturePaths.Add($Path)
        return [pscustomobject]@{
            IsMock = $true; Sha256 = ('A' * 64); Width = 1456; Height = 959
            SampledColors = 8; NonMagentaSamples = 30; Dpi = 96
        }
    }
    function Get-CapGraphActionObservations {
        param($RootHandle, $ProcessIdentity, [string[]]$RequiredNames)
        $script:sceneMock.actionObservations.Add([pscustomobject]@{
            Phase = $ProcessIdentity.CapturePhase; RequiredNames = @($RequiredNames)
        })
        return @($RequiredNames | ForEach-Object {
            [pscustomobject]@{ Name = $_; AutomationId = "action-$_"; ProcessId = $ProcessIdentity.Pid }
        })
    }
    function Close-CapGraphCodeApp {
        param($AppRun, [switch]$NormalExit)
        $script:sceneMock.cleanupAttempts.Add([pscustomobject]@{
            Phase = $AppRun.Phase; AlreadyComplete = [bool]$AppRun.CleanupComplete
        })
        if ($AppRun.CleanupComplete) { return }
        if (-not $AppRun.Run.Identity.Process.WaitForExit(3000)) {
            $null = Stop-CapManagedProcess -Identity $AppRun.Run.Identity -TimeoutMilliseconds 3000
        }
        if (-not $AppRun.Run.Identity.Process.WaitForExit(2000)) {
            throw 'Mocked app process did not exit within its bounded no-GUI test wait.'
        }
        if ($AppRun.Run.Identity.Process.ExitCode -ne 0 -or
            -not $AppRun.Run.StdoutTask.Wait(2000) -or -not $AppRun.Run.StderrTask.Wait(2000)) {
            throw 'Mocked app exit code or redirected stream EOF failed.'
        }
        $AppRun.CleanupComplete = $true
        $script:sceneMock.cleanupCalls.Add([pscustomobject]@{
            Phase = $AppRun.Phase; NormalExit = [bool]$NormalExit; CleanupComplete = $AppRun.CleanupComplete
        })
    }
    foreach ($phase in @('before', 'after')) {
        $null = Invoke-CapNormalScenes -Phase $phase
        $null = Invoke-CapActionsScene -Phase $phase
    }
    $readingState = New-CapJournalState -Root $root -Directory $script:journalPath `
        -Binding $binding -DeadlineUtc $script:leaseDeadlineUtc
    $mockManifest = (Read-CapJournalSnapshot $readingState).Snapshot.Payload.data.progressManifest
    $expectedScenePairs = @(
        'before:project-alpha', 'before:project-beta', 'before:overview', 'before:workspace', 'before:actions',
        'after:project-alpha', 'after:project-beta', 'after:overview', 'after:workspace', 'after:actions'
    )
    $actualScenePairs = @($script:images | ForEach-Object { "$($_.phase):$($_.scene)" })
    $scenePairDifference = Compare-Object ($expectedScenePairs | Sort-Object) ($actualScenePairs | Sort-Object)
    if ($script:images.Count -ne 10 -or $scenePairDifference -or
        @($script:images | Where-Object {
            $_.captureMode -ne 'MOCK_NO_IMAGE' -or $_.privacyStatus -ne 'NOT_CAPTURED_MOCK_ONLY'
        }).Count -ne 0 -or
        @($script:sceneMock.zoomSelectors).Count -ne 8 -or
        @($script:sceneMock.zoomMeasurements).Count -ne 8 -or
        @($script:sceneMock.appRuns | Where-Object { -not $_.CleanupComplete }).Count -ne 0 -or
        $script:sceneMock.cleanupAttempts.Count -ne 8 -or
        @($script:sceneMock.cleanupAttempts | Where-Object AlreadyComplete).Count -ne 4 -or
        @($script:sceneMock.cleanupAttempts | Where-Object { -not $_.AlreadyComplete }).Count -ne 4 -or
        $script:sceneMock.seedStarts.Count -ne 2 -or $script:sceneMock.seedCloses.Count -ne 2 -or
        @($script:zmxSeedReceipts | Where-Object {
            -not $_.mockOnly -or $_.cleanupStatus -ne 'CLEAN_ZERO_SURVIVORS_EOF' -or
            $_.exitCode -ne 0 -or -not $_.stdoutEof -or -not $_.stderrEof
        }).Count -ne 0 -or
        @($script:sceneMock.appEnvironments | Where-Object ShowUpdate -eq $true).Count -ne 0 -or
        @($script:sceneMock.appEnvironments | Where-Object UpdateAvailable -ne '1').Count -ne 0 -or
        @($script:sceneMock.actionCalls | Where-Object Action -in @('reply', 'reclaim', 'keep')).Count -ne 0 -or
        @($script:sceneMock.actionObservations | Where-Object {
            ($_.RequiredNames | Sort-Object) -join ',' -cne 'Keep,Reclaim,Reply'
        }).Count -ne 0 -or
        @(Get-ChildItem -LiteralPath $script:outputDirectory -Filter '*.png' -File).Count -ne 0 -or
        @($script:runs | Where-Object {
            -not [CapNative]::IsExited($_.Identity.Process.Handle, $_.Identity.Pid) -or
            -not $_.StdoutTask.IsCompleted -or -not $_.StderrTask.IsCompleted
        }).Count -ne 0 -or
        $mockManifest.executionMode -ne 'OFFLINE_MOCK_ONLY') {
        throw 'Actual B normal/actions scene functions failed their no-GUI mocked execution contract.'
    }
    $expectedSelectors = @(
        'before:RefMain:canvas-card-', 'before:RefComposite:canvas-card-',
        'before:RefMain:canvas-card-', 'before:UIA loop A:canvas-card-',
        'after:RefMain:canvas-card-', 'after:RefComposite:canvas-card-',
        'after:RefMain:canvas-card-', 'after:UIA loop A:canvas-card-'
    )
    $actualSelectors = @($script:sceneMock.zoomSelectors | ForEach-Object {
        "$($_.Phase):$($_.Name):$($_.AutomationIdPrefix)"
    })
    $expectedNaturalWidths = @(250, 250, 220, 250, 250, 250, 250, 250)
    $actualNaturalWidths = @($script:sceneMock.zoomMeasurements | ForEach-Object NaturalWidth)
    if (($expectedSelectors -join '|') -cne ($actualSelectors -join '|')) {
        throw 'Scene functions did not resolve the exact B zoom-probe names and AutomationId prefixes.'
    }
    if (($expectedNaturalWidths -join ',') -cne ($actualNaturalWidths -join ',') -or
        @($script:images | Where-Object { $_.zoom -and $_.zoom.ZoomPercent -ne 100.0 }).Count -ne 0) {
        throw 'Scene functions did not preserve the B phase-specific 100% natural-width zoom contract.'
    }
    if (@($script:sceneMock.appEnvironments | ForEach-Object Support | Sort-Object -Unique).Count -ne 4 -or
        @($script:sceneMock.appEnvironments | ForEach-Object Local | Sort-Object -Unique).Count -ne 4 -or
        @($script:sceneMock.appEnvironments | ForEach-Object Zmx | Sort-Object -Unique).Count -ne 4) {
        throw 'Scene functions reused a before/after or normal/actions private profile root.'
    }
    foreach ($image in $script:images) {
        $provenance = if ($image.phase -eq 'before') { $script:job.binaries.before } else { $script:job.binaries.after }
        if ($image.sourceHead -ne $provenance.source -or
            $image.binaryBuiltAtSource -ne $provenance.binaryBuiltAtSource -or
            $image.binarySha256 -ne $provenance.sha256) {
            throw "Image source/binary provenance was mislabeled for $($image.phase)/$($image.scene)."
        }
    }
    $sceneFunctionEvidence = [ordered]@{
        mode = $mockManifest.executionMode
        normalAndActionsPhases = @('before', 'after')
        scenePairs = @($actualScenePairs)
        mockImageRecords = $script:images.Count
        actualImageFiles = 0
        zoomSelectors = @($script:sceneMock.zoomSelectors)
        zoomNaturalWidths = @($script:sceneMock.zoomMeasurements)
        appEnvironments = @($script:sceneMock.appEnvironments)
        appCleanup = @($script:sceneMock.cleanupCalls)
        appCleanupAttempts = @($script:sceneMock.cleanupAttempts)
        sceneActions = @($script:sceneMock.actionCalls)
        actionObservationMocks = @($script:sceneMock.actionObservations)
        phasePrivateSeedMocks = @($script:sceneMock.seedStarts | ForEach-Object {
            [pscustomobject]@{
                phase = $_.Phase; mockOnly = $true; zmxRoot = $_.Zmx
                supportRoot = $_.Support; argumentList = $_.Arguments
            }
        })
    }


            $results.Add([ordered]@{name='preserved B five-scene/two-phase mocked component regression';passed=$true;detail=$sceneFunctionEvidence})
            Write-Host 'PASS preserved B five-scene/two-phase mocked component regression (zero actual images)'
        } catch {
            $results.Add([ordered]@{name='preserved B five-scene/two-phase mocked component regression';passed=$false;error=$_.Exception.ToString();stack=$_.ScriptStackTrace})
            Write-Host "FAIL scene component regression: $($_.Exception.Message)"
        } finally {
            foreach ($run in $script:runs) {
                if (-not [CapNative]::IsExited($run.Identity.Process.Handle, $run.Identity.Pid)) {
                    $null = Stop-CapManagedProcess -Identity $run.Identity -TimeoutMilliseconds 5000
                }
                Assert-CapTest ($run.StdoutTask.Wait(2000) -and $run.StderrTask.Wait(2000)) 'Component process EOF was incomplete.'
                $run.Identity.Process.Dispose()
            }
        }

    }
    }
} catch {
    $results.Add([ordered]@{ name = 'suite setup/execution'; passed = $false; error = $_.Exception.ToString() })
    Write-Host "FAIL suite setup/execution: $($_.Exception.Message)"
} finally {
    foreach ($path in $sourceHashesBefore.Keys) {
        Assert-CapTest ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $sourceHashesBefore[$path]) "Source changed during rehearsal: $path"
    }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($result in $results) {
        if (-not $names.Add($result.name)) { throw "Duplicate test case would inflate executed counts: $($result.name)" }
    }
    $passed = @($results | Where-Object passed -EQ $true).Count
    $failed = @($results | Where-Object passed -EQ $false).Count
    $suiteName = if ($JournalContractOnly) { 'UiCaptureJournalContracts' } else { 'UiCaptureDriver' }
    $report = [ordered]@{ suite = $suiteName; executed = $results.Count; passed = $passed; failed = $failed
        mode = $mode; gui = 'NotExecuted'; nativeCompatibilityPreflight = 'NotExecuted'; images = 0
        backendTurns = 0; fixture = $target; sourceHashesBeforeImport = $sourceHashesBefore
        prebuiltFixtureManifest = $PrebuiltFixtureManifest
        prebuiltFixtureManifestSha256 = $PrebuiltFixtureManifestSha256
        controls = [ordered]@{ moduleSha256 = $sourceHashesBefore[$modulePath]
            workerSha256 = $sourceHashesBefore[$workerPath]; supervisorSha256 = $sourceHashesBefore[$supervisorPath] }
        cases = @($results) }
    $report | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath (Join-Path $scratch 'report.json') -Encoding utf8NoBOM
}
[ordered]@{ suite = $suiteName; executed = $results.Count; passed = $passed; failed = $failed; artifacts = $scratch } |
    ConvertTo-Json -Compress
$expectedCount = if ($JournalContractOnly) { 10 } elseif ($LaunchContractOnly) { 2 } elseif ($RequireRealSeed) { 152 } else { 149 }
if ($results.Count -ne $expectedCount -or $failed -ne 0 -or $passed -ne $results.Count) { exit 1 }
exit 0
