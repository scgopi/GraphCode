param(
    [string]$ScratchRoot = (Join-Path ([IO.Path]::GetTempPath()) ('gc-capture-' + [guid]::NewGuid().ToString('N'))),
    [switch]$LaunchContractOnly,
    [switch]$JournalContractOnly,
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
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-CapTest {
    param([string]$Name, [scriptblock]$Action)
    try {
        $detail = & $Action
        $results.Add([ordered]@{ name = $Name; passed = $true; detail = $detail })
        Write-Host "PASS $Name"
    } catch {
        $results.Add([ordered]@{ name = $Name; passed = $false; error = $_.Exception.ToString(); stack = $_.ScriptStackTrace })
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
            Assert-CapTest ($cleanup.Count -eq 2 -and $cleanupErrors.Count -eq 0) `
                "Empty/incomplete actual actor cleanup: $($cleanupErrors -join '; ')"
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
        Invoke-CapTest 'journal native bindings match the exact sixteen-declaration contract' {
            $expected = @(
                'GraphCodeUiaGateState|PostMessage|user32.dll|PostMessageA',
                'GraphCodeUiaGateState|EnumWindows|user32.dll|EnumWindows',
                'GraphCodeUiaGateState|GetWindowThreadProcessId|user32.dll|GetWindowThreadProcessId',
                'GraphCodeUiaGateState|GetClassName|user32.dll|GetClassNameW',
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
                'CapNative|PrintWindow|user32.dll|PrintWindow'
            )
            $actual = @(Test-CapNativeBindings | ForEach-Object { "$($_.Type)|$($_.Method)|$($_.Library)|$($_.EntryPoint)" })
            Assert-CapTest ($actual.Count -eq 16 -and @(Compare-Object $expected $actual).Count -eq 0) 'Exact static16 export contract differs.'
            return @{ subcases = 16; evidence = 'API export resolution only, no native window or GUI action.' }
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
        return [pscustomobject]@{ Text = ''; Sha256 = $null }
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
    }
}

function New-CapHarmlessTarget {
    $fixture = Join-Path $scratch 'fixture'
    $null = New-Item -ItemType Directory -Path $fixture
    # This source is the entire target: no GUI, descendants, backend, network, or user data.
    $source = @'
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
int wmain(int argc, wchar_t **argv) {
    char behavior[64] = {0};
    wchar_t output[32768] = {0}, path[32768] = {0};
    int i, c;
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
    $compileStdout = Join-Path $fixture 'compile-stdout.log'
    $compileStderr = Join-Path $fixture 'compile-stderr.log'
    $command = 'call "{0}" -vcvars_ver={1} >nul && "{2}" /nologo /W4 /WX /O2 /utf-8 /Fe:"{3}" "{4}" /link /SUBSYSTEM:CONSOLE' -f $vcvars, $version, $compiler, $exe, $sourcePath
    # Redirect the whole compile group's stdout/stderr to owned files so the real
    # compiler and any toolchain telemetry helpers it spawns inherit file handles,
    # never the module's redirected pipe. Only the short-lived cmd.exe then holds
    # that pipe, so it reaches bounded EOF promptly on exit. This is a fixture setup
    # robustness fix; it does not touch any runtime/kernel/EOF/release guard.
    $redirectedCommand = '({0}) > "{1}" 2> "{2}"' -f $command, $compileStdout, $compileStderr
    [IO.File]::WriteAllText((Join-Path $fixture 'compile.cmd'), "@echo off`r`n$redirectedCommand`r`nexit /b %errorlevel%`r`n", [Text.UTF8Encoding]::new($false))
    $compilerEnvironment = @{ PATH = (Split-Path -Parent $vswhere) + ';' + $env:PATH }
    foreach ($key in @('VSCMD_VER', '__VSCMD_PREINIT_PATH', 'VSINSTALLDIR', 'VCINSTALLDIR',
        'VCToolsInstallDir', 'VCToolsVersion', 'WindowsSdkDir', 'WindowsSDKVersion', 'INCLUDE', 'LIB', 'LIBPATH')) {
        $compilerEnvironment[$key] = ''
    }
    $build = Invoke-CapBoundedChild -FilePath $env:ComSpec -Arguments @('/d', '/c', '.\compile.cmd') `
        -Directory $fixture -Role 'harmless-fixture-compile' -Seconds 90 -Environment $compilerEnvironment
    # Preserve the actual compiler exit before reading the owned compile logs.
    $compilerExitCode = $build.exitCode
    $compileStdoutSnapshot = Read-CapCompileLogSnapshot -Path $compileStdout
    $compileStderrSnapshot = Read-CapCompileLogSnapshot -Path $compileStderr
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
    $compileStdout = Join-Path $fixture 'compile-stdout.log'
    $compileStderr = Join-Path $fixture 'compile-stderr.log'
    $command = 'call "{0}" -vcvars_ver={1} >nul && "{2}" /nologo /W3 /O2 /utf-8 /Fe:"{3}" "{4}" /link /SUBSYSTEM:CONSOLE' -f $vcvars, $version, $compiler, $exe, $sourcePath
    # Same owned-file redirection as New-CapHarmlessTarget: the compiler and any
    # telemetry helpers inherit file handles, so only the short-lived cmd.exe holds
    # the module's redirected pipe and it reaches bounded EOF on exit.
    $redirectedCommand = '({0}) > "{1}" 2> "{2}"' -f $command, $compileStdout, $compileStderr
    [IO.File]::WriteAllText((Join-Path $fixture 'compile.cmd'), "@echo off`r`n$redirectedCommand`r`nexit /b %errorlevel%`r`n", [Text.UTF8Encoding]::new($false))
    $compilerEnvironment = @{ PATH = (Split-Path -Parent $vswhere) + ';' + $env:PATH }
    foreach ($key in @('VSCMD_VER', '__VSCMD_PREINIT_PATH', 'VSINSTALLDIR', 'VCINSTALLDIR',
        'VCToolsInstallDir', 'VCToolsVersion', 'WindowsSdkDir', 'WindowsSDKVersion', 'INCLUDE', 'LIB', 'LIBPATH')) {
        $compilerEnvironment[$key] = ''
    }
    $build = Invoke-CapBoundedChild -FilePath $env:ComSpec -Arguments @('/d', '/c', '.\compile.cmd') `
        -Directory $fixture -Role 'cim-race-fixture-compile' -Seconds 90 -Environment $compilerEnvironment
    # Preserve the actual compiler exit before reading the owned compile logs.
    $compilerExitCode = $build.exitCode
    $compileStdoutSnapshot = Read-CapCompileLogSnapshot -Path $compileStdout
    $compileStderrSnapshot = Read-CapCompileLogSnapshot -Path $compileStderr
    $compileStdoutText = $compileStdoutSnapshot.Text
    $compileStderrText = $compileStderrSnapshot.Text
    Assert-CapTest ($compilerExitCode -eq 0 -and (Test-Path -LiteralPath $exe -PathType Leaf)) `
        "CIM race target compilation failed (not launch evidence): $compileStdoutText $compileStderrText"
    return [pscustomobject]@{
        executable = $exe
        sourceSha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        executableSha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    }
}

function Invoke-CapCaptureCommand {
    param(
        [string]$Name,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments = @(),
        [string]$Behavior = 'normal',
        [string]$LeaseMutation = '',
        [string]$AdmissionMutation = ''
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
    if ($AdmissionMutation) { $job = New-CapAdmissionJob -Owned $owned -Job $job -Mutation $AdmissionMutation }
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

$target = $null
try {
    $target = New-CapHarmlessTarget
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
    $cimRaceTarget = New-CapCimRaceTarget
    if (-not $LaunchContractOnly) {
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
            Assert-CapPreflightReport
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
        controls = [ordered]@{ moduleSha256 = $sourceHashesBefore[$modulePath]
            workerSha256 = $sourceHashesBefore[$workerPath]; supervisorSha256 = $sourceHashesBefore[$supervisorPath] }
        cases = @($results) }
    $report | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath (Join-Path $scratch 'report.json') -Encoding utf8NoBOM
}
[ordered]@{ suite = $suiteName; executed = $results.Count; passed = $passed; failed = $failed; artifacts = $scratch } |
    ConvertTo-Json -Compress
$expectedCount = if ($JournalContractOnly) { 10 } elseif ($LaunchContractOnly) { 2 } else { 59 }
if ($results.Count -ne $expectedCount -or $failed -ne 0 -or $passed -ne $results.Count) { exit 1 }
exit 0
