param(
    [Parameter(Mandatory)][string]$OwnedRoot,
    [Parameter()][string]$AuthorizationPath,
    [Parameter()][string]$AuthorizationSha256,
    [switch]$AwaitSupervisorGate,
    [Parameter()][switch]$DefinitionsOnly
)
$ErrorActionPreference = 'Stop'
# Promoted from Invoke-BCaptureWorker.ps1, FSL-1.1-MIT.
# SHA256 CDB5FFEDF2848F136DD44CFFF61CAF3048E733D67E16F0F9E28C27DEA5EB6D9E.
$root = [IO.Path]::GetFullPath($OwnedRoot).TrimEnd('\')
$modulePath = Join-Path $PSScriptRoot 'UiCaptureDriver.psm1'
$rehearsal = $false
$rehearsalLaunches = [Collections.Generic.List[object]]::new()
$rehearsalActions = [Collections.Generic.List[object]]::new()
$peerScript = Join-Path $root 'inputs\offline-peer-source.ps1'
$fixturePath = Join-Path $root 'fixtures\fixture.json'
$journalPath = $null
$journalState = $null
$journalFinalLine = $null
$journalFinalCleanupCount = -1
$ownedProcessReceipts = @()
$leaseExpiresUtc = [DateTime]::MinValue
$outputDirectory = $null
$runDirectory = $null
$auth = $null
$job = $null
$lease = $null
$primaryFailure = $null
$cleanupFailures = [Collections.Generic.List[string]]::new()
$cleanupReceipts = [Collections.Generic.List[object]]::new()
$zmxSeedReceipts = [Collections.Generic.List[object]]::new()
$images = [Collections.Generic.List[object]]::new()
$runs = [Collections.Generic.List[object]]::new()
$seedRuns = [Collections.Generic.List[object]]::new()
$applicationRuns = [Collections.Generic.List[object]]::new()
$realRestarts = [Collections.Generic.List[object]]::new()
$descendantIdentities = [Collections.Generic.List[object]]::new()
$journalEntries = [Collections.Generic.List[object]]::new()
$manifestPath = $null
$logPath = $null
$workerLog = $null
$leaseDeadlineUtc = [DateTime]::MinValue
$fixtureHash = $null
$moduleHash = $null
$workerHash = $null
$jobHash = $null
$leaseHash = $null
$fixtureSourceHash = $null
$fixtureMappingHash = $null
$ownedProcessSurvivors = @()
$pendingLaunchesRemaining = @()
$mockSceneRun = $false
$outputBase = $null
$runBase = $null
$startedUtc = [DateTime]::UtcNow

function Write-CapWorkerLog {
    param([Parameter(Mandatory)][string]$Message)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    $line = '{0:o} {1}' -f [DateTime]::UtcNow, $Message
    Write-Output $line
    if ($workerLog) { [IO.File]::AppendAllText($workerLog, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false)) }
}

function Test-CapMatchedAdapter {
    return $job.PSObject.Properties['sceneAdapter'] -and
        $job.sceneAdapter -cin @('S_MATCHED_V12_V1','S_MATCHED_V12_DPI_V1')
}

function Test-CapMatchedDpiAdapter {
    return $job.PSObject.Properties['sceneAdapter'] -and
        $job.sceneAdapter -ceq 'S_MATCHED_V12_DPI_V1'
}

function Write-CapJsonAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    $temporary = "$Path.tmp"
    [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth 40), [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($Path)) {
        # ReplaceFile retains old reader snapshots; NullString supplies a true null backup path.
        [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value)
    } else {
        [IO.File]::Move($temporary, $Path)
    }
}

function Assert-CapWorkerDeadline {
    param([Parameter(Mandatory)][string]$Stage)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    if (@(Get-CapTraceFailures).Count -gt 0) { throw 'Capture tracing failed; worker must stop and clean up.' }
    if ([DateTime]::UtcNow -ge $leaseDeadlineUtc) { throw "Reserved worker deadline reached at stage '$Stage'." }
}

function Assert-CapOwnedPath {
    param([Parameter(Mandatory)][string]$Path)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    return Assert-CapArtifactPath -Root $root -Path $Path
}

function Write-CapProcessJournal {
    param(
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][string]$Phase,
        [AllowNull()][IntPtr]$Window = [IntPtr]::Zero
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    $entry = [pscustomobject]@{
        role = $Identity.Role
        phase = $Phase
        pid = [int]$Identity.Pid
        creationFileTimeUtc = [long]$Identity.CreationFileTimeUtc
        expectedImagePath = [string]$Identity.ExpectedImagePath
        expectedParentPid = [int]$Identity.ParentPid
        expectedSessionId = [int]$Identity.SessionId
        windowHandle = if ($Window -ne [IntPtr]::Zero) { [long]$Window.ToInt64() } else { 0 }
        registeredUtc = [DateTime]::UtcNow.ToString('o')
    }
    if ($Identity.PSObject.Properties['JobId']) {
        $entry | Add-Member -NotePropertyName jobId -NotePropertyValue $Identity.JobId
    }
    $index = -1
    for ($i = 0; $i -lt $journalEntries.Count; $i++) {
        if ($journalEntries[$i].pid -eq $entry.pid -and
            $journalEntries[$i].creationFileTimeUtc -eq $entry.creationFileTimeUtc -and
            $journalEntries[$i].phase -eq $Phase) {
            $index = $i
            break
        }
    }
    if ($index -ge 0) { $journalEntries[$index] = $entry } else { $journalEntries.Add($entry) }
    Write-CapWorkerJournalSnapshot -Kind 'Progress'
}

function Write-CapWorkerJournalSnapshot {
    param([ValidateSet('Bootstrap','Progress','Terminal')][string]$Kind,
        [string]$Outcome = 'CAPTURING')
    if ($null -eq $journalState) { throw 'Worker journal was not initialized before publication.' }
    $null = Publish-CapJournalSnapshot -State $journalState -Kind $Kind -Value ([pscustomobject]@{
        entries = @($journalEntries.ToArray())
        outcome = $Outcome
        ownedProcesses = @($ownedProcessReceipts)
        ownedProcessSurvivors = @($ownedProcessSurvivors)
        pendingLaunchesRemaining = @($pendingLaunchesRemaining)
        cleanupFailures = @($cleanupFailures.ToArray())
        progressManifest = [pscustomobject](New-CapManifest -Status $Outcome)
    })
}

function Get-CapWorkerProcessReceipts {
    $records = [Collections.Generic.List[object]]::new()
    $roots = @{}
    foreach ($run in $runs) {
        $identity = $run.Identity
        $kernelExited = [CapNative]::IsExited($identity.Process.Handle, $identity.Pid)
        $stdoutEof = $run.StdoutTask.IsCompleted -and -not $run.StdoutTask.IsFaulted -and -not $run.StdoutTask.IsCanceled
        $stderrEof = $run.StderrTask.IsCompleted -and -not $run.StderrTask.IsFaulted -and -not $run.StderrTask.IsCanceled
        $record = [pscustomobject]@{
            pid = [long]$identity.Pid; creationFileTimeUtc = [long]$identity.CreationFileTimeUtc
            expectedImagePath = $identity.ExpectedImagePath; role = $identity.Role
            parentPid = [long]$identity.ParentPid; sessionId = [long]$identity.SessionId
            kernelExited = $kernelExited; stdoutEof = $stdoutEof; stderrEof = $stderrEof
            streamOwnerPid = [long]$identity.Pid
            streamOwnerCreationFileTimeUtc = [long]$identity.CreationFileTimeUtc
        }
        if ($run.PSObject.Properties['JobId']) {
            if (-not $run.CleanupComplete -or $null -eq $run.OutputProof) { throw 'Contained root lacks job/file closure.' }
            $record | Add-Member -NotePropertyName outputProof -NotePropertyValue $run.OutputProof
        }
        if ($roots.ContainsKey($identity.Pid)) { throw 'Duplicate managed-root process generation.' }
        $roots[$identity.Pid] = $record
        $records.Add($record)
    }
    foreach ($identity in $descendantIdentities) {
        if ($identity.PSObject.Properties['JobId']) {
            $jobRoots = @($roots.Values | Where-Object {
                $_.PSObject.Properties['outputProof'] -and $_.outputProof.jobId -ceq $identity.JobId
            })
            if ($jobRoots.Count -ne 1) { throw 'Job member lacks its unique held launcher output owner.' }
            $owner = $jobRoots[0]
        } else {
            $parentPid = $identity.ParentPid
            $visited = [Collections.Generic.HashSet[int]]::new()
            while (-not $roots.ContainsKey($parentPid)) {
                if (-not $visited.Add([int]$parentPid)) { throw 'Descendant ownership cycle.' }
                $parents = @($descendantIdentities | Where-Object { $_.Pid -eq $parentPid })
                if ($parents.Count -ne 1) { throw 'Descendant has no unique owning managed stream root.' }
                $parentPid = $parents[0].ParentPid
            }
            $owner = $roots[$parentPid]
        }
        $record = [pscustomobject]@{
            pid = [long]$identity.Pid; creationFileTimeUtc = [long]$identity.CreationFileTimeUtc
            expectedImagePath = $identity.ExpectedImagePath; role = $identity.Role
            parentPid = [long]$identity.ParentPid; sessionId = [long]$identity.SessionId
            kernelExited = [CapNative]::IsExited($identity.Process.Handle, $identity.Pid)
            stdoutEof = $owner.stdoutEof; stderrEof = $owner.stderrEof
            streamOwnerPid = $owner.pid; streamOwnerCreationFileTimeUtc = $owner.creationFileTimeUtc
        }
        if ($identity.PSObject.Properties['JobId']) {
            $record.stdoutEof = $false; $record.stderrEof = $false
            $record | Add-Member -NotePropertyMembers @{ outputKind = 'OWNED_FILES_JOB'; jobId = $identity.JobId }
        }
        $records.Add($record)
    }
    return @($records.ToArray())
}

function Assert-CapAcceptedInputs {
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    Assert-CapSceneContract -Job $job
    if ($job.authority.centralCaptureLeaseGrantedByThisArtifact -ne $false -or
        $lease.status -ne 'GRANTED' -or $lease.lane -cne $job.lane -or
        $lease.authorizedAction -ne 'central-cap-capture' -or
        $lease.centralPreflightAccepted -ne $true) {
        throw 'A separate coordinator-granted central-cap lease and preflight acceptance are required.'
    }
    if ($lease.leaseId -ne $auth.leaseId -or $lease.head -ne $job.head -or $lease.jobManifestSha256 -ne $jobHash -or
        $lease.moduleSha256 -ne $moduleHash -or $lease.workerSha256 -ne $workerHash -or
        $lease.supervisorSha256 -ne $auth.supervisorSha256 -or
        $lease.preflightReceiptSha256 -ne $auth.preflightReceiptSha256) {
        throw 'Lease receipt hashes do not bind the exact reviewed B job and capture controls.'
    }
    $mappingProof = Assert-CapFixtureMapping -Root $root -FixturePath $fixturePath `
        -SourcePath (Join-Path $root 'inputs\fixture-source.json') -MappingPath (Join-Path $root 'reports\fixture-mapping.json') `
        -ExpectedMappingSha256 $auth.fixtureMappingSha256 `
        -ExpectedSourceSha256 $job.fixture.sha256 -OriginalRoot $job.fixture.originalRoot `
        -SceneAdapter $job.sceneAdapter -ExpectedPeerSha256 $job.fixture.offlinePeerReference.sha256
    $expectedHashes = @{
        fixture = $mappingProof.FixtureSha256
        fixtureSource = $job.fixture.sha256
        fixtureMapping = $auth.fixtureMappingSha256
        peer = $job.fixture.offlinePeerReference.sha256
        zmx = $job.binaries.offlineZmx.sha256
        before = $job.binaries.before.sha256
        after = $job.binaries.after.sha256
    }
    $paths = @{
        fixture = $fixturePath; fixtureSource = (Join-Path $root 'inputs\fixture-source.json')
        fixtureMapping = (Join-Path $root 'reports\fixture-mapping.json'); peer = $peerScript
        zmx = (Join-Path $root 'runtime\zmx.exe'); before = (Join-Path $root 'inputs\graphcode-before.exe')
        after = (Join-Path $root 'inputs\graphcode-after.exe')
    }
    if (Test-CapMatchedAdapter) {
        foreach ($item in @(@('daemon','graphcoded.exe'),@('backendFixture','copilot.exe'))) {
            $expectedHashes[$item[0]]=$job.binaries.($item[0]).sha256
            $paths[$item[0]]=Join-Path $root "runtime\$($item[1])"
        }
        $expectedHashes.backendSource=$job.binaries.backendFixture.sourceSha256
        $paths.backendSource=Join-Path $root 'inputs\offline-backend.c'
    }
    $actual = @{}
    foreach ($key in $expectedHashes.Keys) {
        $path = Assert-CapArtifactPath -Root $root -Path $paths[$key]
        $actual[$key] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($actual[$key] -ne $expectedHashes[$key]) { throw "Cap-owned $key input hash changed: $($actual[$key])." }
    }
    $script:fixtureSourceHash = $actual.fixtureSource
    $script:fixtureMappingHash = $actual.fixtureMapping
}

function Initialize-CapPhaseRoot {
    param([Parameter(Mandatory)][string]$PhaseRoot)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    $phaseRoot = Assert-CapOwnedPath $PhaseRoot
    foreach ($name in @('support', 'local', 'profile', 'temp', 'tmp', 'peer')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $phaseRoot $name) -Force
    }
    $support = Join-Path $phaseRoot 'support'
    [IO.File]::WriteAllText((Join-Path $support 'onboarding-seen'), '1', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $support 'settings.json'),
        '{"defaultBackend":"copilotCLI","showsActivityStrip":true,"briefsSessionsAboutTheGraph":false}',
        [Text.UTF8Encoding]::new($false))
    if (-not $rehearsal -and $job.PSObject.Properties['sceneAdapter'] -and $job.sceneAdapter -ceq 'D_QUICK_CHAT_V1') {
        $fixture=Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -DateKind String
        [IO.File]::WriteAllText((Join-Path $support 'quick-chats.json'),(ConvertTo-Json -InputObject @($fixture.chats) -Depth 20),[Text.UTF8Encoding]::new($false))
        $layoutBase=Join-Path $phaseRoot 'layouts\workspace.json'
        $null=New-Item -ItemType Directory -Path (Split-Path -Parent $layoutBase)
        foreach ($layout in $fixture.layouts) {
            $key=if ($layout.project -ceq 'graphcode://quick-chats') {Join-Path $phaseRoot 'profile'} else {$layout.project}
            $resolved=Get-CapDLayoutPath -LayoutBase $layoutBase -ProjectKey $key -LoopId $layout.loop
            [IO.File]::WriteAllText($resolved.LoopPath,($layout | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        }
    }
    $zmx = Assert-CapOwnedPath (Join-Path $root ([guid]::NewGuid().ToString('N').Substring(0, 5)))
    $null = New-Item -ItemType Directory -Path $zmx
    $null = Assert-CapOwnedPath $zmx
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($sid)
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $sid, [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $zmx -AclObject $acl
    if ((Get-Acl -LiteralPath $zmx).GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value) {
        throw "Private zmx state owner mismatch for $zmx."
    }
    return [pscustomobject]@{
        Root = $phaseRoot
        Support = $support
        Local = Join-Path $phaseRoot 'local'
        Profile = Join-Path $phaseRoot 'profile'
        Temp = Join-Path $phaseRoot 'temp'
        Zmx = $zmx
        Peer = Join-Path $phaseRoot 'peer'
    }
}

function Get-CapBaseEnvironment {
    param(
        [Parameter(Mandatory)]$Roots,
        [Parameter(Mandatory)][string]$PipeName,
        [Parameter(Mandatory)][string]$SessionPrefix,
        [switch]$ActionsFixture
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    if (Test-CapMatchedAdapter) {
        $project=Assert-CapOwnedPath (Join-Path $root 'fixtures\projects\Matched')
        $null=New-Item -ItemType Directory -Path $project -Force
        return @{
            APPDATA=(Join-Path $Roots.Profile 'AppData\Roaming');HOME=$Roots.Profile;USERPROFILE=$Roots.Profile
            LOCALAPPDATA=$Roots.Local;TEMP=$Roots.Temp;TMP=$Roots.Temp;GRAPHCODE_SUPPORT_DIR=$Roots.Support
            GRAPHCODE_DAEMON_PIPE="\\.\pipe\$PipeName";GRAPHCODE_ZMX=(Join-Path $root 'runtime\zmx.exe')
            ZMX_DIR=$Roots.Zmx;GRAPHCODE_SHELL_SESSION_PREFIX=$SessionPrefix;GRAPHCODE_UIA_GATE='1'
            GRAPHCODE_WORKSPACE_LAYOUT=(Join-Path $Roots.Root 'workspace.json')
            PATH=((Join-Path $root 'runtime')+';'+(Split-Path -Parent (Get-Command git -ErrorAction Stop).Source)+';'+$PSHOME+';'+[Environment]::SystemDirectory+';'+
                (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0'))
        }
    }
    if ($job.PSObject.Properties['sceneAdapter'] -and $job.sceneAdapter -ceq 'D_QUICK_CHAT_V1') {
        if ($ActionsFixture) { throw 'D does not support builtin UIA fixture actions.' }
        $project=Assert-CapOwnedPath (Join-Path $root 'fixtures\projects\D Offline Capture Fixture')
        $null=New-Item -ItemType Directory -Path $project -Force
        $null=Assert-CapOwnedPath $project
        if (-not (Test-Path -LiteralPath $project -PathType Container)) {throw 'D fixture project working directory was not created.'}
        return @{
            APPDATA=(Join-Path $Roots.Profile 'AppData\Roaming');HOME=$Roots.Profile;USERPROFILE=$Roots.Profile
            LOCALAPPDATA=$Roots.Local;TEMP=$Roots.Temp;TMP=$Roots.Temp;GRAPHCODE_SUPPORT_DIR=$Roots.Support
            GRAPHCODE_DAEMON_PIPE="\\.\pipe\$PipeName";GRAPHCODE_ZMX=(Join-Path $root 'runtime\zmx.exe')
            ZMX_DIR=$Roots.Zmx;GRAPHCODE_WORKSPACE_LAYOUT=(Join-Path $Roots.Root 'layouts\workspace.json')
        }
    }
    $projectAlpha = Assert-CapOwnedPath (Join-Path $root 'fixtures\projects\Alpha')
    $null = New-Item -ItemType Directory -Path $projectAlpha,(Join-Path $root 'fixtures\projects\Beta') -Force
    $envMap = @{
        APPDATA = Join-Path $Roots.Profile 'AppData\Roaming'
        HOME = $Roots.Profile
        LOCALAPPDATA = $Roots.Local
        TEMP = $Roots.Temp
        TMP = $Roots.Temp
        USERPROFILE = $Roots.Profile
        GRAPHCODE_DAEMON_PIPE = "\\.\pipe\$PipeName"
        GRAPHCODE_GATE_CWD = $projectAlpha
        GRAPHCODE_SUPPORT_DIR = $Roots.Support
        GRAPHCODE_SHELL_SESSION_PREFIX = $SessionPrefix
        GRAPHCODE_UIA_GATE = '1'
        GRAPHCODE_UIA_UPDATE_AVAILABLE = '1'
        GRAPHCODE_ZMX = Join-Path $root 'runtime\zmx.exe'
        ZMX_DIR = $Roots.Zmx
    }
    if ($ActionsFixture) {
        $envMap['GRAPHCODE_UIA_CONNECTION_FAILURE'] = '1'
        $envMap['GRAPHCODE_UIA_FIXTURE_ROWS'] = '1'
        $envMap['GRAPHCODE_UIA_INGRESS_ERROR'] = ''
        $envMap['GRAPHCODE_UIA_RESET_SIDEBAR'] = '1'
    }
    return $envMap
}

function Start-CapOfflinePeer {
    param(
        [Parameter(Mandatory)]$Roots,
        [Parameter(Mandatory)][string]$PipeName,
        [Parameter(Mandatory)][string]$Phase
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    $null = Test-CapPipeUnserved -PipeName $PipeName
    $pwshPath = Join-Path $PSHOME 'pwsh.exe'
    $arguments=@(
        '-NoProfile', '-File', $peerScript, '-PipeName', $PipeName, '-FixturePath', $fixturePath
    )
    if ($job.sceneAdapter -ceq 'D_QUICK_CHAT_V1') {$arguments+=@('-CommandLog',(Join-Path $Roots.Peer 'commands.jsonl'),'-ModulePath',$modulePath,'-ModuleSha256',$moduleHash)}
    $run = Start-CapManagedProcess -FilePath $pwshPath -ArgumentList $arguments -WorkingDirectory $Roots.Peer -Role "offline-fixture-peer-$Phase" -Environment @{
        APPDATA = Join-Path $Roots.Profile 'AppData\Roaming'
        HOME = $Roots.Profile
        LOCALAPPDATA = $Roots.Local
        TEMP = $Roots.Temp
        TMP = $Roots.Temp
        USERPROFILE = $Roots.Profile
    }
    $runs.Add($run)
    Write-CapProcessJournal -Identity $run.Identity -Phase $Phase
    $ready = $false
    for ($attempt = 0; $attempt -lt 30 -and [DateTime]::UtcNow -lt $leaseDeadlineUtc; $attempt++) {
        if ([CapNative]::ProbePipe($PipeName, 100) -eq 0) { $ready = $true; break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) { throw "Offline fixture peer failed to serve its unique pipe for $Phase." }
    return $run
}

function Start-CapOfflineSeed {
    param(
        [Parameter(Mandatory)]$Roots,
        [Parameter(Mandatory)][string]$Phase,
        [string]$SessionName
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    $isD=$job.sceneAdapter -ceq 'D_QUICK_CHAT_V1'
    $isS=Test-CapMatchedAdapter
    $arguments=if ($isS) {
        $fixture=Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -DateKind String
        $null=Assert-CapMatchedFixture -Fixture $fixture -ProjectRoot (Join-Path $root 'fixtures\projects')
        if ($SessionName -cnotin @($fixture.graphs[0].nodes | ForEach-Object {"graphcode-$($_.id)"})) {throw 'Unknown matched fixture session.'}
        @('run',$SessionName,'-d',(Join-Path ([Environment]::SystemDirectory) 'cmd.exe'),'/Q','/K','echo Offline card fixture - no backend')
    } elseif ($isD) {
        if ($SessionName -cnotin @('graphcode-33333333-3333-4333-8333-333333333333','graphcode-44444444-4444-4444-8444-444444444444')) {throw 'Unknown D seed session.'}
        @('run',$SessionName,'-d',(Join-Path ([Environment]::SystemDirectory) 'cmd.exe'))+@($job.binaries.offlineZmx.seedCommand)
    } else {@($job.binaries.offlineZmx.seedArgumentOrder | ForEach-Object {[string]$_})}
    if (-not $isD -and -not $isS -and ($arguments.Count -ne 7 -or $arguments[0] -cne 'run' -or
        $arguments[1] -cne 'graphcode-11111111-1111-4111-8111-000000000001' -or
        $arguments[2] -cne '-d' -or $arguments[3] -cne 'cmd.exe' -or
        $arguments[4] -cne '/Q' -or $arguments[5] -cne '/K' -or
        $arguments[6] -cne 'echo Offline card fixture - no backend')) {
        throw 'The B job does not contain the exact seven-argument offline cmd-only zmx seed.'
    }
    $seedReceiptRoot = if ($isS) { $Roots.Root } else { Join-Path $runDirectory "phases\$Phase\normal" }
    $seedReceiptPath = Assert-CapOwnedPath (Join-Path $seedReceiptRoot 'zmx-seed.json')
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $seedReceiptPath) -Force
    $zmxRoot = Assert-CapOwnedPath $Roots.Zmx
    $zmxWorking = Assert-CapOwnedPath (Join-Path $Roots.Peer 'zmx-cwd')
    New-Item -ItemType Directory -Path $zmxWorking -Force | Out-Null
    $environment = @{
        ZMX_DIR = $zmxRoot
    }
    $leasePathProof = Assert-CapZmxLeasePath -ZmxDir $zmxRoot -SessionName $arguments[1] `
        -Sid ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    $zmxPath = Join-Path $root 'runtime\zmx.exe'
    $run = Start-CapJobLauncher -Root $root -OutputDirectory $zmxWorking `
        -FilePath $zmxPath -ArgumentList $arguments -WorkingDirectory $zmxWorking `
        -Role 'zmx-launcher' -Environment $environment
    $run | Add-Member -NotePropertyName Phase -NotePropertyValue $Phase
    $run | Add-Member -NotePropertyName SessionName -NotePropertyValue $arguments[1]
    $run | Add-Member -NotePropertyName Descendants -NotePropertyValue @()
    $run | Add-Member -NotePropertyName SeedReceiptPath -NotePropertyValue $seedReceiptPath
    $run | Add-Member -NotePropertyName SeedCleanupComplete -NotePropertyValue $false
    $runs.Add($run)
    $seedRuns.Add($run)
    $launcherHandle = $run.Identity.Process.Handle
    $launcherSnapshot = [CapNative]::Snapshot($launcherHandle,$run.Identity.Pid)
    if ($launcherSnapshot.IsExited -or $launcherSnapshot.CreationFileTimeUtc -ne $run.Identity.CreationFileTimeUtc -or
        $launcherSnapshot.ImagePath -ine $run.Identity.ExpectedImagePath) {
        throw 'Seed launcher original image attestation differs.'
    }
    $run | Add-Member -NotePropertyName LauncherImageAttestation -NotePropertyValue ([pscustomobject]@{
        pid = $launcherSnapshot.ProcessId; creationFileTimeUtc = $launcherSnapshot.CreationFileTimeUtc
        imagePath = $launcherSnapshot.ImagePath; heldHandle = $launcherHandle.ToInt64()
    })
    Write-CapProcessJournal -Identity $run.Identity -Phase $Phase
    $target = Release-CapJobLauncher -Run $run -JournalState $journalState
    $receipt = [pscustomobject]@{
        phase = $Phase
        sessionName = $run.SessionName
        argumentList = @($arguments)
        exitCode = $null
        seedPid = $target.pid
        seedCreationFileTimeUtc = $target.creationFileTimeUtc
        expectedImagePath = $target.expectedImagePath
        launcherPid = $run.Identity.Pid
        launcherCreationFileTimeUtc = $run.Identity.CreationFileTimeUtc
        jobId = $run.JobId
        outputProof = $null
        zmxRoot = $zmxRoot
        leasePathProof = $leasePathProof
        supportRoot = $Roots.Support
        seedExitedUtc = $null
        daemonReady = $false
        daemonCount = 0
        cmdCount = 0
        descendants = @()
        stdoutEof = $false
        stderrEof = $false
        cleanupStatus = 'PENDING'
        receiptPublicationStatus = 'NOT_CREATED'
        launcherExitWait = $null
        cleanup = @()
    }
    $run | Add-Member -NotePropertyName SeedReceipt -NotePropertyValue $receipt
    $zmxSeedReceipts.Add($receipt)
    $receipt.receiptPublicationStatus = 'CREATED'
    try { Write-CapJsonAtomic -Path $seedReceiptPath -Value $receipt }
    catch {
        $receipt.receiptPublicationStatus = 'NOT_CREATED'
        throw
    }

    $seedDeadline = [DateTime]::UtcNow.AddSeconds(20)
    if ($seedDeadline -gt $leaseDeadlineUtc) { $seedDeadline = $leaseDeadlineUtc }
    $seedWait = Wait-CapJobTarget -Run $run -DeadlineUtc $seedDeadline
    $exitCode = [int]$seedWait.exitCode
    $receipt.exitCode = $exitCode
    $receipt.seedExitedUtc = [DateTime]::UtcNow.ToString('o')
    Write-CapJsonAtomic -Path $seedReceiptPath -Value $receipt
    $null = Write-CapWorkerLog "ZMX_SEED_EXIT phase=$Phase exit=$exitCode pid=$($run.Identity.Pid) args=$($arguments -join ' ')"
    if ($exitCode -ne 0) { throw "Pinned zmx seed exit code was $exitCode for $Phase; app launch is prohibited." }

    $cmdPath = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
    $conhostPath = Join-Path ([Environment]::SystemDirectory) 'conhost.exe'
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(10)
    if ($readyDeadline -gt $leaseDeadlineUtc) { $readyDeadline = $leaseDeadlineUtc }
    $tree = @()
    $daemons = @()
    $cmdPeers = @()
    do {
        Assert-CapWorkerDeadline "zmx seed readiness $Phase"
        $tree = @(Get-CapJobMembers -Run $run)
        foreach ($identity in $tree) {
            $metadata = Get-CapCurrentMetadata -Pid $identity.Pid
            if ($null -eq $metadata) { throw 'Ready job member lacks current metadata.' }
            if ($identity.ExpectedImagePath -ieq $zmxPath -and $metadata.CommandLine -like "*$($run.SessionName)*") {
                $identity.Role = 'zmx-daemon'
            } elseif ($identity.ExpectedImagePath -ieq $cmdPath -and
                $metadata.CommandLine -like "*$($arguments[6].Substring(5))*") {
                $identity.Role = 'offline-cmd-peer'
            } elseif ($identity.ExpectedImagePath -ieq $conhostPath) {
                $identity.Role = 'conpty-conhost'
            }
        }
        $daemons = @($tree | Where-Object Role -eq 'zmx-daemon')
        $cmdPeers = @($tree | Where-Object Role -eq 'offline-cmd-peer')
        if ($daemons.Count -gt 0 -and $cmdPeers.Count -gt 0) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $readyDeadline)
    if ($daemons.Count -lt 1 -or $cmdPeers.Count -lt 1) {
        throw "Private $Phase zmx seed did not become ready with an owned daemon and cmd peer."
    }
    foreach ($identity in $tree) {
        # Every member remains owned by the job even if it has no readiness role.
        Write-CapProcessJournal -Identity $identity -Phase $Phase
        if (-not @($descendantIdentities | Where-Object {
            $_.Pid -eq $identity.Pid -and $_.CreationFileTimeUtc -eq $identity.CreationFileTimeUtc
        }).Count) {
            $descendantIdentities.Add($identity)
        }
    }
    $run.Descendants = @($tree)
    $receipt.daemonReady = $true
    $receipt.daemonCount = $daemons.Count
    $receipt.cmdCount = $cmdPeers.Count
    $receipt.descendants = @($tree | ForEach-Object {
        [pscustomobject]@{
            role = $_.Role
            pid = $_.Pid
            creationFileTimeUtc = $_.CreationFileTimeUtc
            expectedImagePath = $_.ExpectedImagePath
            parentPid = $_.ParentPid
            sessionId = $_.SessionId
        }
    })
    Write-CapJsonAtomic -Path $seedReceiptPath -Value $receipt
    $null = Write-CapWorkerLog "ZMX_SEED_READY phase=$Phase daemon=$($daemons.Count) cmd=$($cmdPeers.Count) conhost=$(@($tree | Where-Object Role -eq 'conpty-conhost').Count)"
    return $run
}

function Wait-CapVisibleElement {
    param(
        [Parameter(Mandatory)][IntPtr]$Window,
        [Parameter(Mandatory)]$ProcessIdentity,
        [Parameter(Mandatory)][string]$Name,
        [string]$AutomationId,
        [string]$AutomationIdPrefix,
        [switch]$AllowOffscreen,
        [scriptblock]$FindElement
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    $actionDeadlineUtc = Get-CapActionDeadline -WorkerDeadlineUtc $leaseDeadlineUtc
    $resolver = if ($FindElement) {
        $FindElement
    } else {
        {
            param([ref]$Snapshot)
            Find-CapAutomationElement -RootHandle $Window -ProcessIdentity $ProcessIdentity `
                -Name $Name -AutomationId $AutomationId -AutomationIdPrefix $AutomationIdPrefix `
                -AllowOffscreen:$AllowOffscreen -RefusalSnapshot $Snapshot
        }
    }
    return Wait-CapAutomationElement -Window $Window -ProcessIdentity $ProcessIdentity `
        -Name $Name -AutomationId $AutomationId -AutomationIdPrefix $AutomationIdPrefix `
        -AllowOffscreen:$AllowOffscreen -DeadlineUtc $actionDeadlineUtc `
        -BeforePoll { Assert-CapWorkerDeadline "UIA element $Name" } -FindElement $resolver
}

function Invoke-CapSceneAction {
    param(
        [Parameter(Mandatory)]$AppRun,
        [Parameter(Mandatory)][string]$Action,
        [string]$Name,
        [string]$SubjectId
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    Assert-CapWorkerDeadline "before action $Action"
    $actionDeadlineUtc = Get-CapActionDeadline -WorkerDeadlineUtc $leaseDeadlineUtc
    $result = Invoke-CapAction -Action $Action -Name $Name -SubjectId $SubjectId -RootHandle $AppRun.Window `
        -ProcessIdentity $AppRun.Run.Identity -DeadlineUtc $actionDeadlineUtc `
        -BeforeElementPoll { Assert-CapWorkerDeadline "UIA element for action $Action" }
    if ($AppRun.PSObject.Properties['DActions']) {$AppRun.DActions.Add($result)}
    if ($AppRun.PSObject.Properties['SActions']) {$AppRun.SActions.Add($result)}
    Write-CapWorkerLog "ACTION phase=$($AppRun.Phase) action=$Action name=$Name result=$($result | ConvertTo-Json -Compress)"
    Start-Sleep -Milliseconds 250
    Assert-CapWorkerDeadline "after action $Action"
}

function Measure-CapSceneZoom {
    param(
        [Parameter(Mandatory)]$AppRun,
        [Parameter(Mandatory)]$Scene,
        [Parameter(Mandatory)][int]$NaturalWidth
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    if (-not $Scene.zoomProbe) { return $null }
    $probeMatch = [regex]::Match(
        [string]$Scene.zoomProbe,
        '^Name (?<Name>[^/]+?) / AutomationId prefix (?<AutomationIdPrefix>[A-Za-z0-9_-]+)$'
    )
    if (-not $probeMatch.Success) { throw "Unsupported zoom probe contract: $($Scene.zoomProbe)." }
    $name = $probeMatch.Groups['Name'].Value.Trim()
    $automationIdPrefix = $probeMatch.Groups['AutomationIdPrefix'].Value
    $element = Wait-CapVisibleElement -Window $AppRun.Window -ProcessIdentity $AppRun.Run.Identity `
        -Name $name -AutomationIdPrefix $automationIdPrefix
    $dpi=if ($AppRun.PSObject.Properties['Placement'] -and
        $AppRun.Placement.PSObject.Properties['ActualDpi']) {
        [uint32]$AppRun.Placement.ActualDpi
    } else {96}
    return Measure-CapZoom -Element $element -NaturalWidth $NaturalWidth -Dpi $dpi
}

function Save-CapSceneImage {
    param(
        [Parameter(Mandatory)]$AppRun,
        [Parameter(Mandatory)][string]$SceneName,
        [AllowNull()]$ZoomEvidence,
        [Parameter(Mandatory)][string]$Phase
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    Assert-CapWorkerDeadline "before image $Phase/$SceneName"
    $metrics = Get-CapWindowMetrics -Window $AppRun.Window -ProcessIdentity $AppRun.Run.Identity
    $expectedOuter = @(30, 30, 1486, 989)
    $isD=$job.PSObject.Properties['sceneAdapter'] -and $job.sceneAdapter -ceq 'D_QUICK_CHAT_V1'
    $isSDpi=Test-CapMatchedDpiAdapter
    if ($isD) {$expectedOuter=@($AppRun.Placement.outerBounds)}
    if ($isSDpi) {$expectedOuter=@($AppRun.Placement.OuterBounds)}
    $expectedDpi=if ($isSDpi) {$AppRun.Placement.ActualDpi} else {96}
    $expectedClient=if ($isSDpi) {
        "0,0,$($AppRun.Placement.PhysicalClientWH[0]),$($AppRun.Placement.PhysicalClientWH[1])"
    } else {
        $height=if ($isD) {952} else {900}
        "0,0,1440,$height"
    }
    if (($expectedOuter -join ',') -cne (@($metrics.OuterBounds) -join ',') -or
        $metrics.Dpi -ne $expectedDpi -or ($metrics.ClientBounds -join ',') -cne $expectedClient) {
        throw "Unexpected window geometry for ${Phase}/${SceneName}: $(ConvertTo-Json -InputObject $metrics -Compress)."
    }
    if ($ZoomEvidence -and [Math]::Abs([double]$ZoomEvidence.ZoomPercent - 100.0) -gt 1.0) {
        throw "Zoom evidence changed outside the 100% tolerance for $Phase/$SceneName."
    }
    $imagePath = Join-Path $outputDirectory "$Phase-$SceneName.png"
    if (Test-Path -LiteralPath $imagePath) { throw "Refusing to replace prior capture image: $imagePath" }
    $capture = Capture-CapWindow -Window $AppRun.Window -ProcessIdentity $AppRun.Run.Identity -Path $imagePath
    $isMockCapture = $capture.PSObject.Properties['IsMock'] -and [bool]$capture.IsMock
    $record = [pscustomobject]@{
        phase = $Phase
        scene = $SceneName
        path = $imagePath
        sha256 = $capture.Sha256
        captureMode = if ($isMockCapture) { 'MOCK_NO_IMAGE' } else { 'PRINTWINDOW' }
        width = $capture.Width
        height = $capture.Height
        sampledColors = $capture.SampledColors
        nonMagentaSamples = $capture.NonMagentaSamples
        outerBounds = @($metrics.OuterBounds)
        clientBounds = @($metrics.ClientBounds)
        dpi = $metrics.Dpi
        zoom = $ZoomEvidence
        sourceHead = if ($Phase -eq 'before') { $job.binaries.before.source } else { $job.binaries.after.source }
        binaryBuiltAtSource = if ($Phase -eq 'before') {
            $job.binaries.before.binaryBuiltAtSource
        } else {
            $job.binaries.after.binaryBuiltAtSource
        }
        binarySha256 = if ($Phase -eq 'before') { $job.binaries.before.sha256 } else { $job.binaries.after.sha256 }
        fixtureSha256 = $fixtureHash
        fixtureSourceSha256 = $fixtureSourceHash
        fixtureMappingSha256 = $fixtureMappingHash
        privacyStatus = if ($isMockCapture) { 'NOT_CAPTURED_MOCK_ONLY' } else { 'CAPTURED_PENDING_INDIVIDUAL_REVIEW' }
        privacyReview = $null
    }
    $images.Add($record)
    if ($isD) {
        $record | Add-Member -NotePropertyName sceneAdapter -NotePropertyValue 'D_QUICK_CHAT_V1'
        $record | Add-Member -NotePropertyName observedState -NotePropertyValue $AppRun.DObservation
        $record | Add-Member -NotePropertyName actions -NotePropertyValue @($AppRun.DActions)
        $record | Add-Member -NotePropertyName captureUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
        $record | Add-Member -NotePropertyName zoomApplicable -NotePropertyValue ($null -ne $ZoomEvidence)
        $record | Add-Member -NotePropertyName zoomReason -NotePropertyValue $(if ($ZoomEvidence) {'Measured source-width canvas probe'} else {'Workspace or fixed sidebar chrome'})
        $record | Add-Member -NotePropertyName dpiAwareness -NotePropertyValue 'NotVerified: unchanged native bindings do not query runtime awareness context'
        $record | Add-Member -NotePropertyName sceneLabel -NotePropertyValue $(if ($SceneName -ceq 'd-chat-history-roles') {'Observed production-restored history chat Shell state; actual baseline UIA role recorded'} else {$SceneName})
        $AppRun.DActions.Clear()
    }
    if (Test-CapMatchedAdapter) {
        $record | Add-Member -NotePropertyName sceneAdapter -NotePropertyValue $job.sceneAdapter
        $record | Add-Member -NotePropertyName observedState -NotePropertyValue $AppRun.SObservation
        $record | Add-Member -NotePropertyName actions -NotePropertyValue @($AppRun.SActions)
        $record | Add-Member -NotePropertyName captureUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
        if ($isSDpi) {
            $geometry=$AppRun.Placement
            $record | Add-Member -NotePropertyMembers @{
                evidenceClassification='C8R_RDP_DPI192_QUALIFIED'
                geometrySchemaVersion=3L
                geometryDerivation=$geometry.GeometryDerivation
                logicalClientWH=@($geometry.LogicalClientWH)
                physicalClientBounds=@($metrics.ClientBounds)
                physicalOuterBounds=@($metrics.OuterBounds)
                nonClientWH=@($geometry.NonClientWH)
                rawPixelWH=@([long]$capture.Width,[long]$capture.Height)
                actualWindowDpi=[long]$metrics.Dpi
                dpiBase=[long]$geometry.DpiBase
                dpiScaleNumerator=[long]$geometry.DpiScaleNumerator
                dpiScaleDenominator=[long]$geometry.DpiScaleDenominator
                windowStyle=[long]$metrics.Style
                windowStyleForAdjustment=[long]$geometry.WindowStyle
                windowExStyleForAdjustment=[long]$geometry.WindowExStyle
                windowExStyle=[long]$metrics.ExStyle
                hasMenu=[bool]$metrics.HasMenu
                physicalWorkAreaBounds=@($geometry.PhysicalWorkAreaBounds)
                placement=$geometry.Placement
                resampled=$false
            }
        }
        $AppRun.SActions.Clear()
    }
    Write-CapWorkerJournalSnapshot -Kind 'Progress'
    Write-CapWorkerLog "IMAGE phase=$Phase scene=$SceneName sha256=$($capture.Sha256) size=$($capture.Width)x$($capture.Height) dpi=$($capture.Dpi) colors=$($capture.SampledColors)"
}

function New-CapManifest {
    param([Parameter(Mandatory)][string]$Status)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    $result = [ordered]@{
        schemaVersion = 1
        status = $Status
        executionMode = if ($mockSceneRun) { 'OFFLINE_MOCK_ONLY' }
            elseif ($rehearsal) { 'NO_DESKTOP_REAL_LAUNCH_REHEARSAL' } else { 'LIVE_CAPTURE' }
        leaseId = $auth.leaseId
        leaseReceiptSha256 = $leaseHash
        jobManifestSha256 = $jobHash
        moduleSha256 = $moduleHash
        workerSha256 = $workerHash
        supervisorSha256 = $auth.supervisorSha256
        preflightReceiptSha256 = $auth.preflightReceiptSha256
        head = $job.head
        base = $job.base
        startedUtc = $startedUtc.ToString('o')
        finishedUtc = if ($Status -eq 'COMPLETE') { [DateTime]::UtcNow.ToString('o') } else { $null }
        leaseDeadlineUtc = $leaseDeadlineUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        guiLaunches = @($applicationRuns | Where-Object { -not $rehearsal } | ForEach-Object { $_.Run.Identity.Pid })
        rehearsalLaunches = @($rehearsalLaunches)
        rehearsalActions = @($rehearsalActions)
        guiOperations = if ($rehearsal) { 'NotExecuted: UIA, HWND, PrintWindow, native input and desktop capture' } else { 'See images' }
        fixtureSha256 = $fixtureHash
        fixtureSourceSha256 = $fixtureSourceHash
        fixtureMappingSha256 = $fixtureMappingHash
        zmxSeedExitCodes = @($zmxSeedReceipts | ForEach-Object exitCode)
        zmxSeeds = @($zmxSeedReceipts)
        images = @($images)
        cleanup = @($cleanupReceipts)
        cleanupFailures = @($cleanupFailures)
        pendingLaunchesRemaining = @($pendingLaunchesRemaining)
        failures = @($cleanupFailures)
        ownedProcessSurvivors = @($ownedProcessSurvivors)
        ownedProcesses = @($ownedProcessReceipts)
        privacyRequirement = 'Every image requires an individual privacy check before reviewer handoff.'
    }
    if ($job.PSObject.Properties['sceneAdapter'] -and $job.sceneAdapter -ceq 'D_QUICK_CHAT_V1') {
        $result.sceneAdapter=$job.sceneAdapter;$result.lane='D';$result.requiredSceneNames=@(Get-CapDSceneNames)
        $result.backendTurns=0;$result.backendAgentAttach=$false;$result.restartInvoked=$false
        $result.uncoveredLiveObligations=@(
            @{name='missing-bound-chat-workspace-tabs';status='NotExecuted';reason='Production events route away; component coverage only'},
            @{name='saved-Agent-Split-role-labels';status='NotExecuted';reason='Production listing prunes absent panes; only two chat seeds authorized'})
    }
    if (Test-CapMatchedAdapter) {
        $result.sceneAdapter=$job.sceneAdapter;$result.lane='S';$result.requiredSceneNames=@(Get-CapMatchedSceneNames)
        $result.g11Qualification='ASSESSABLE_SOURCE_CAPABILITY_NOT_RUNTIME_VALIDATED'
        $result.backendTurns=0;$result.realRestarts=@($realRestarts)
        if (Test-CapMatchedDpiAdapter) {
            $result.evidenceClassification='C8R_RDP_DPI192_QUALIFIED'
            $result.geometrySchemaVersion=3L
            $result.logicalClientWH=@($job.captureContract.logicalClientWH)
            $result.expectedWindowDpi=[long]$job.captureContract.expectedWindowDpi
            $result.rawCaptureResamplingAllowed=$false
        }
    }
    return $result
}

function New-CapAppRunRecord {
    param(
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$SessionPrefix
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    return [pscustomobject]@{
        Run = $Run
        Phase = $Phase
        Window = [IntPtr]::Zero
        SessionPrefix = $SessionPrefix
        CleanupComplete = $false
        Descendants = [Collections.Generic.List[object]]::new()
    }
}

function Start-CapGraphCodeApp {
    param(
        [Parameter(Mandatory)]$Roots,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$PipeName,
        [Parameter(Mandatory)][string]$SessionPrefix,
        [switch]$ActionsFixture
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    $binaryKey = if ($Phase -eq 'before') { 'graphcode-before.exe' } else { 'graphcode-after.exe' }
    $binaryPath = if ($rehearsal) { Assert-CapOwnedPath $job.rehearsalTarget.path }
        else { Join-Path $root "inputs\$binaryKey" }
    $role = "graphcode-app-$Phase-$(if ($ActionsFixture) { 'actions' } else { 'normal' })"
    $envMap = if ($rehearsal) {
        @{
            TEMP = $Roots.Temp; TMP = $Roots.Temp; USERPROFILE = $Roots.Profile
            HOME = $Roots.Profile; LOCALAPPDATA = $Roots.Local
            CAP_REHEARSAL_BEHAVIOR = if ($job.rehearsalTarget.behavior -ceq 'action-target-absent') {
                'timeout'
            } else { $job.rehearsalTarget.behavior }
            CAP_REHEARSAL_OUTPUT = $outputDirectory
        }
    } else {
        Get-CapBaseEnvironment -Roots $Roots -PipeName $PipeName -SessionPrefix $SessionPrefix `
            -ActionsFixture:$ActionsFixture
    }
    $arguments = if ($rehearsal) { [string[]]@($job.rehearsalTarget.arguments) } else { [string[]]@() }
    if ($rehearsal) { $role = 'rehearsal-target' }
    $isD=$job.PSObject.Properties['sceneAdapter'] -and $job.sceneAdapter -ceq 'D_QUICK_CHAT_V1'
    $isS=Test-CapMatchedAdapter
    $workingDirectory = if ($rehearsal) {$Roots.Peer} elseif ($isS) {Join-Path $root 'fixtures\projects\Matched'} elseif ($isD) {Join-Path $root 'fixtures\projects\D Offline Capture Fixture'} else {Join-Path $root 'fixtures\projects\Alpha'}
    if (-not $rehearsal) {
        $shellSession = 'graphcode-' + $SessionPrefix + '-' + [guid]::Empty.ToString('D')
        $null = Assert-CapZmxLeasePath -ZmxDir $Roots.Zmx -SessionName $shellSession `
            -Sid ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    }
    $ownedJob=$null
    if ($isS -and -not $rehearsal) {
        $ownedJob=Start-CapJobLauncher -Root $root -OutputDirectory $Roots.Peer -FilePath $binaryPath `
            -ArgumentList @() -WorkingDirectory $workingDirectory -Role "matched-app-launcher-$Phase" -Environment $envMap
        $runs.Add($ownedJob);Write-CapProcessJournal -Identity $ownedJob.Identity -Phase $Phase
        $process=$null
        try {
            $target=Release-CapJobLauncher -Run $ownedJob -JournalState $journalState
            $process=[Diagnostics.Process]::GetProcessById([int]$target.pid)
            $identity=Get-CapProcessIdentity -Process $process -ExpectedImagePath $binaryPath -Role $role `
                -ExpectedParentPid $ownedJob.Identity.Pid
            if ($identity.CreationFileTimeUtc -ne $target.creationFileTimeUtc -or
                -not [CapProcessJob]::Contains($ownedJob.Job,$process.Handle)) {throw 'Matched app target generation/job differs.'}
            $identity | Add-Member -NotePropertyName JobId -NotePropertyValue $ownedJob.JobId
            $ownedJob.Members.Add($identity)
            $descendantIdentities.Add($identity)
            $run=[pscustomobject]@{Identity=$identity;StartedUtc=$ownedJob.StartedUtc}
        } catch {
            $primary=$_
            $null=Close-CapMatchedJob -Run $ownedJob -Phase $Phase
            if ($process) {$process.Dispose()}
            throw $primary
        }
    } else {
        $run = Start-CapManagedProcess -FilePath $binaryPath -ArgumentList ([string[]]@($arguments)) `
            -WorkingDirectory $workingDirectory -Role $role -Environment $envMap -CloseStdin:$rehearsal
        $runs.Add($run)
    }
    $appRun = New-CapAppRunRecord -Run $run -Phase $Phase -SessionPrefix $SessionPrefix
    if ($ownedJob) {$appRun | Add-Member -NotePropertyName OwnedJob -NotePropertyValue $ownedJob}
    $applicationRuns.Add($appRun)
    Write-CapProcessJournal -Identity $run.Identity -Phase $Phase
    if ($rehearsal) { return $appRun }
    $window = Find-CapTopLevelWindow -ProcessIdentity $run.Identity -TimeoutSeconds 30 -DeadlineUtc $leaseDeadlineUtc
    $appRun.Window = $window
    Write-CapProcessJournal -Identity $run.Identity -Phase $Phase -Window $window
    if ($isD) {
        Add-Type -AssemblyName System.Windows.Forms
        $area=[Windows.Forms.Screen]::FromHandle($window).WorkingArea
        $placement=Get-CapDGeometry -Metrics (Get-CapWindowMetrics -Window $window -ProcessIdentity $run.Identity) -WorkArea @($area.Left,$area.Top,$area.Right,$area.Bottom)
        Set-CapWindowPosition -Window $window -ProcessIdentity $run.Identity -X $placement.x -Y $placement.y -Width $placement.width -Height $placement.height
        $appRun | Add-Member -NotePropertyName Placement -NotePropertyValue $placement
        $appRun | Add-Member -NotePropertyName Roots -NotePropertyValue $Roots
    } elseif (Test-CapMatchedDpiAdapter) {
        $area=Get-CapPrimaryPhysicalWorkArea
        $beforeMetrics=Get-CapWindowMetrics -Window $window -ProcessIdentity $run.Identity
        $contract=$job.captureContract
        $identity=$contract.windowIdentities.$Phase
        $null=Assert-CapDpiWindowIdentity -Metrics $beforeMetrics -Identity $identity -Initial
        $geometry=Get-CapDpiGeometry -LogicalClientWH @($contract.logicalClientWH) `
            -ExpectedDpi ([uint32]$contract.expectedWindowDpi) `
            -WindowStyle ([long]$identity.windowStyleForAdjustment) `
            -WindowExStyle ([long]$identity.windowExStyleForAdjustment) `
            -HasMenu ([bool]$identity.hasMenu) `
            -WorkArea @($area.Left,$area.Top,$area.Right,$area.Bottom) `
            -ExpectedAdjustedOuterWH @($identity.expectedAdjustedOuterWH)
        Set-CapWindowPosition -Window $window -ProcessIdentity $run.Identity `
            -X $geometry.OuterBounds[0] -Y $geometry.OuterBounds[1] `
            -Width $geometry.OuterWH[0] -Height $geometry.OuterWH[1]
        $appRun | Add-Member -NotePropertyName Placement -NotePropertyValue $geometry
        $appRun | Add-Member -NotePropertyName Roots -NotePropertyValue $Roots
    } else {Set-CapWindowPosition -Window $window -ProcessIdentity $run.Identity}
    Start-Sleep -Milliseconds 500
    $metrics = Get-CapWindowMetrics -Window $window -ProcessIdentity $run.Identity
    if (Test-CapMatchedDpiAdapter) {
        $geometry=$appRun.Placement
        $identity=$job.captureContract.windowIdentities.$Phase
        $null=Assert-CapDpiWindowIdentity -Metrics $metrics -Identity $identity `
            -ExpectedOuterBounds @($geometry.OuterBounds)
    } elseif ($metrics.Dpi -ne 96) {
        throw "Actual app DPI is $($metrics.Dpi), expected 96."
    }
    return $appRun
}

function Get-CapTreeForApp {
    param([Parameter(Mandatory)]$AppRun)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    if ($AppRun.PSObject.Properties['OwnedJob']) {
        if ($AppRun.OwnedJob.CleanupComplete) {return @($AppRun.Descendants)}
        $members=@(Get-CapJobMembers -Run $AppRun.OwnedJob)
        foreach ($member in $members) {
            if ($member.Pid -eq $AppRun.Run.Identity.Pid) {continue}
            if (-not @($AppRun.Descendants | Where-Object {$_.Pid -eq $member.Pid -and
                $_.CreationFileTimeUtc -eq $member.CreationFileTimeUtc}).Count) {
                $AppRun.Descendants.Add($member);$descendantIdentities.Add($member)
                Write-CapProcessJournal -Identity $member -Phase $AppRun.Phase
            }
        }
        return @($AppRun.Descendants | Where-Object {-not [CapNative]::IsExited($_.Process.Handle,$_.Pid)})
    }
    $dSessions=@{}
    if ($job.sceneAdapter -ceq 'D_QUICK_CHAT_V1') {$dSessions.ExactSessionNames=@('graphcode-33333333-3333-4333-8333-333333333333','graphcode-44444444-4444-4444-8444-444444444444')}
    try {
        $tree = @(Get-CapOwnedDescendants -Roots @($AppRun.Run.Identity) `
            -ZmxPath (Join-Path $root 'runtime\zmx.exe') `
            -CmdPath (Join-Path ([Environment]::SystemDirectory) 'cmd.exe') `
            -ConhostPath (Join-Path ([Environment]::SystemDirectory) 'conhost.exe') `
            -SessionName $AppRun.SessionPrefix -CommandMarker $AppRun.SessionPrefix `
            -AllowGraphCodeRoot -AllowUnmarkedCmd -OwnedDescendants $AppRun.Descendants @dSessions)
    } finally {
        foreach ($identity in $AppRun.Descendants) {
            if (-not @($descendantIdentities | Where-Object {
                $_.Pid -eq $identity.Pid -and $_.CreationFileTimeUtc -eq $identity.CreationFileTimeUtc
            }).Count) {
                $descendantIdentities.Add($identity)
                Write-CapProcessJournal -Identity $identity -Phase $AppRun.Phase
            }
        }
    }
    return $tree
}

function Write-CapRunStreams {
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)][string]$Label)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    if ($Run.PSObject.Properties['StreamsWritten'] -and $Run.StreamsWritten) { return }
    foreach ($streamName in @('Stdout', 'Stderr')) {
        $task = $Run."${streamName}Task"
        if (-not $task.Wait(2000)) { throw "$Label $streamName stream did not reach bounded EOF after guarded cleanup." }
        $streamPath = Join-Path $outputDirectory "$Label-$($streamName.ToLowerInvariant()).log"
        $content = [string]$task.Result
        if (Test-Path -LiteralPath $streamPath) {
            if ([IO.File]::ReadAllText($streamPath) -cne $content) {
                throw "Existing process stream log differs from the held stream content: $streamPath."
            }
        } else {
            [IO.File]::WriteAllText($streamPath, $content, [Text.UTF8Encoding]::new($false))
        }
        Write-CapWorkerLog "STREAM_EOF role=$($Run.Identity.Role) stream=$streamName bytes=$([Text.Encoding]::UTF8.GetByteCount($content))"
    }
    $Run | Add-Member -NotePropertyName StreamsWritten -NotePropertyValue $true -Force
}

function Close-CapGraphCodeApp {
    param(
        [Parameter(Mandatory)]$AppRun,
        [switch]$NormalExit
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    if ($AppRun.CleanupComplete) { return }
    $run = $AppRun.Run
    if ($AppRun.PSObject.Properties['OwnedJob']) {
        $exitFailure=$null
        try {
            if (-not [CapNative]::IsExited($run.Identity.Process.Handle,$run.Identity.Pid) -and $AppRun.Window -ne [IntPtr]::Zero) {
                $null=Invoke-CapAction -Action 'file-exit' -RootHandle $AppRun.Window -ProcessIdentity $run.Identity
                $wait=Wait-CapJobTarget -Run $AppRun.OwnedJob -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10))
                if ($NormalExit -and $wait.exitCode -ne 0) {throw 'Matched app did not exit normally after File Exit.'}
            }
            $null=Get-CapTreeForApp -AppRun $AppRun
        } catch {$exitFailure=$_}
        finally {
            $null=Close-CapMatchedJob -Run $AppRun.OwnedJob -Phase $AppRun.Phase
            $AppRun.CleanupComplete=$true
        }
        if ($exitFailure) {throw $exitFailure}
        return
    }
    if ($rehearsal) {
        $receipt = Stop-CapManagedProcess -Identity $run.Identity -TimeoutMilliseconds 5000
        $cleanupReceipts.Add($receipt)
        Write-CapRunStreams -Run $run -Label 'rehearsal-target'
        $AppRun.CleanupComplete = $true
        foreach ($launch in $rehearsalLaunches) {
            if ($launch.pid -eq $run.Identity.Pid) {
                $launch.kernelExited = [CapNative]::IsExited($run.Identity.Process.Handle, $run.Identity.Pid)
                $launch.stdoutEof = $run.StdoutTask.IsCompleted
                $launch.stderrEof = $run.StderrTask.IsCompleted
                $launch.cleanupResult = $receipt.Result
            }
        }
        return
    }
    if (-not [CapNative]::IsExited($run.Identity.Process.Handle, $run.Identity.Pid)) {
        if ($AppRun.Window -ne [IntPtr]::Zero) {
            try {
                $null = Invoke-CapAction -Action 'file-exit' -RootHandle $AppRun.Window `
                    -ProcessIdentity $run.Identity
                Write-CapWorkerLog "FILE_EXIT_POSTED role=$($run.Identity.Role) pid=$($run.Identity.Pid)"
            } catch {
                $cleanupFailures.Add("File Exit failed for PID $($run.Identity.Pid): $($_.Exception.Message)")
            }
        }
        $wait = Wait-CapManagedProcess -Run $run -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5))
        if ($wait.State -eq 'Exited') {
            $cleanupReceipts.Add([pscustomobject]@{
                phase = $AppRun.Phase; role = $run.Identity.Role; pid = $run.Identity.Pid
                result = 'FILE_EXIT'; exitCode = $wait.ExitCode; completedUtc = $wait.CompletedUtc.ToString('o')
            })
        } else {
            try {
                $tree = @(Get-CapTreeForApp -AppRun $AppRun)
                foreach ($identity in @($tree | Sort-Object CreationFileTimeUtc -Descending)) {
                    $receipt = Stop-CapManagedProcess -Identity $identity -TimeoutMilliseconds 5000
                    $cleanupReceipts.Add($receipt)
                }
                $receipt = Stop-CapManagedProcess -Identity $run.Identity -TimeoutMilliseconds 5000
                $cleanupReceipts.Add($receipt)
            } catch {
                $cleanupFailures.Add("Guarded app recovery failed for PID $($run.Identity.Pid): $($_.Exception.Message)")
            }
        }
    }
    try {
        $null = Get-CapTreeForApp -AppRun $AppRun
    } catch {
        $cleanupFailures.Add("Post-exit descendant discovery failed for PID $($run.Identity.Pid): $($_.Exception.Message)")
    }
    foreach ($identity in @($AppRun.Descendants | Sort-Object CreationFileTimeUtc -Descending)) {
        try {
            $receipt = Stop-CapManagedProcess -Identity $identity -TimeoutMilliseconds 5000
            $cleanupReceipts.Add($receipt)
        } catch {
            $cleanupFailures.Add("Guarded app descendant stop failed for PID $($identity.Pid): $($_.Exception.Message)")
        }
    }
    if (-not [CapNative]::IsExited($run.Identity.Process.Handle, $run.Identity.Pid)) {
        try {
            $receipt = Stop-CapManagedProcess -Identity $run.Identity -TimeoutMilliseconds 5000
            $cleanupReceipts.Add($receipt)
        } catch {
            $cleanupFailures.Add("Guarded app stop failed for PID $($run.Identity.Pid): $($_.Exception.Message)")
        }
    }
    if ($NormalExit -and -not [CapNative]::IsExited($run.Identity.Process.Handle, $run.Identity.Pid)) {
        $cleanupFailures.Add("App PID $($run.Identity.Pid) survived normal File Exit.")
    }
    try { Write-CapRunStreams -Run $run -Label "$($AppRun.Phase)-$($run.Identity.Role)" }
    catch { $cleanupFailures.Add($_.Exception.Message) }
    $AppRun.CleanupComplete = $true
}

function Write-CapSeedCleanupReceipt {
    param([Parameter(Mandatory)]$SeedRun)
    if ($SeedRun.SeedReceipt.receiptPublicationStatus -ceq 'NOT_CREATED') {
        $SeedRun.SeedReceipt.cleanupStatus = 'CLEANUP_UNPROVEN'
        $cleanupFailures.Add("Seed receipt not created: $($SeedRun.SeedReceiptPath)")
        return
    }
    try { Write-CapJsonAtomic -Path $SeedRun.SeedReceiptPath -Value $SeedRun.SeedReceipt }
    catch {
        $SeedRun.SeedReceipt.cleanupStatus = 'CLEANUP_UNPROVEN'
        throw
    }
}

function Wait-CapSeedLauncherExit {
    param([Parameter(Mandatory)]$SeedRun, [Parameter(Mandatory)]$Proof)
    $identity = $SeedRun.Identity
    $handle = $identity.Process.Handle
    if (-not $SeedRun.PSObject.Properties['LauncherImageAttestation']) {
        throw 'Seed launcher original image attestation is missing.'
    }
    $attestation = $SeedRun.LauncherImageAttestation
    if ($attestation.pid -ne $identity.Pid -or $attestation.creationFileTimeUtc -ne $identity.CreationFileTimeUtc -or
        $attestation.heldHandle -ne $handle.ToInt64() -or [string]::IsNullOrWhiteSpace($attestation.imagePath) -or
        $attestation.imagePath -ine $identity.ExpectedImagePath) {
        throw 'Seed launcher original image attestation differs from the held registration.'
    }
    $now = [Diagnostics.Stopwatch]::GetTimestamp()
    if ($Proof.terminationBudgetMilliseconds -ne 5000 -or $Proof.terminationStartedTimestamp -le 0 -or
        $Proof.terminationStartedTimestamp -gt $now) { throw 'Seed launcher termination-window evidence differs.' }
    $deadlineTimestamp = $Proof.terminationStartedTimestamp + 5L * [Diagnostics.Stopwatch]::Frequency
    $remaining = 0
    $configuredTimestamp = 0L
    $signalled = [CapNative]::WaitForExit($handle,$identity.Pid,$identity.CreationFileTimeUtc,$deadlineTimestamp,
        [ref]$remaining,[ref]$configuredTimestamp)
    $observed = [Diagnostics.Stopwatch]::GetTimestamp()
    return [pscustomobject]@{
        kind = 'POST_TERMINATION_HELD_HANDLE_EXIT_WAIT'
        pid = $identity.Pid; creationFileTimeUtc = $identity.CreationFileTimeUtc
        heldHandle = $handle.ToInt64(); signalled = $signalled
        waitBudgetRemainingMilliseconds = $remaining
        terminationStartedTimestamp = $Proof.terminationStartedTimestamp
        deadlineTimestamp = $deadlineTimestamp
        stopwatchFrequency = [Diagnostics.Stopwatch]::Frequency
        waitConfiguredTimestamp = $configuredTimestamp
        terminationToSignalledMilliseconds = if ($signalled) {
            ($observed-$Proof.terminationStartedTimestamp) * 1000.0 / [Diagnostics.Stopwatch]::Frequency
        } else { $null }
        observedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Close-CapOfflineSeed {
    param([Parameter(Mandatory)]$SeedRun)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    if ($SeedRun.PSObject.Properties['JobId']) {
        if ($SeedRun.SeedCleanupComplete) { return }
        $proof = Close-CapJobLauncher -Run $SeedRun
        $launcherExitWait = Wait-CapSeedLauncherExit -SeedRun $SeedRun -Proof $proof
        if ($SeedRun.PSObject.Properties['SeedReceipt']) { $SeedRun.SeedReceipt.launcherExitWait = $launcherExitWait }
        if (-not $launcherExitWait.signalled) { throw 'Job member remains kernel-live.' }
        foreach ($identity in $SeedRun.Members) {
            if (-not @($descendantIdentities | Where-Object {
                $_.Pid -eq $identity.Pid -and $_.CreationFileTimeUtc -eq $identity.CreationFileTimeUtc
            }).Count) { $descendantIdentities.Add($identity) }
            Write-CapProcessJournal -Identity $identity -Phase $SeedRun.Phase
        }
        $seedCleanup = @(@($SeedRun.Members) + @($SeedRun.Identity) | ForEach-Object {
            if (-not [CapNative]::IsExited($_.Process.Handle, $_.Pid)) { throw 'Job member remains kernel-live.' }
            [pscustomobject]@{ pid = $_.Pid; role = $_.Role; result = 'OWNED_JOB_ACTIVE_ZERO'; kernelExited = $true }
        })
        foreach ($result in $seedCleanup) { $cleanupReceipts.Add($result) }
        if ($SeedRun.PSObject.Properties['SeedReceipt']) {
            $SeedRun.SeedReceipt.cleanup = $seedCleanup
            $SeedRun.SeedReceipt.outputProof = $proof
            $SeedRun.SeedReceipt.cleanupStatus = 'CLEAN_ZERO_SURVIVORS_FILES_CLOSED'
            # Target files are not raw redirected-stream EOF.
            $SeedRun.SeedReceipt.stdoutEof = $false; $SeedRun.SeedReceipt.stderrEof = $false
            Write-CapSeedCleanupReceipt -SeedRun $SeedRun
        }
        Write-CapRunStreams -Run $SeedRun -Label "$($SeedRun.Phase)-zmx-launcher"
        $SeedRun.SeedCleanupComplete = $true
        return
    }
    if ($SeedRun.CleanupComplete) { return }
    $failureCountBefore = $cleanupFailures.Count
    $tree = @()
    try {
        $tree = @(Get-CapOwnedDescendants -Roots @($SeedRun.Identity) `
            -ZmxPath (Join-Path $root 'runtime\zmx.exe') `
            -CmdPath (Join-Path ([Environment]::SystemDirectory) 'cmd.exe') `
            -ConhostPath (Join-Path ([Environment]::SystemDirectory) 'conhost.exe') `
            -SessionName $SeedRun.SessionName -CommandMarker 'Offline card fixture - no backend')
    } catch {
        $cleanupFailures.Add("Private zmx tree discovery failed for $($SeedRun.Phase): $($_.Exception.Message)")
    }
    $identities = [Collections.Generic.List[object]]::new()
    foreach ($identity in @($SeedRun.Descendants) + @($tree)) {
        if (-not @($identities | Where-Object {
            $_.Pid -eq $identity.Pid -and $_.CreationFileTimeUtc -eq $identity.CreationFileTimeUtc
        }).Count) {
            $identities.Add($identity)
        }
        if (-not @($descendantIdentities | Where-Object {
            $_.Pid -eq $identity.Pid -and $_.CreationFileTimeUtc -eq $identity.CreationFileTimeUtc
        }).Count) {
            $descendantIdentities.Add($identity)
        }
        try { Write-CapProcessJournal -Identity $identity -Phase $SeedRun.Phase }
        catch { $cleanupFailures.Add("Private zmx process journal update failed for PID $($identity.Pid): $($_.Exception.Message)") }
    }
    $seedCleanup = [Collections.Generic.List[object]]::new()
    foreach ($identity in @($identities | Sort-Object CreationFileTimeUtc -Descending)) {
        try {
            $result = Stop-CapManagedProcess -Identity $identity -TimeoutMilliseconds 5000
            $seedCleanup.Add($result)
            $cleanupReceipts.Add($result)
        } catch {
            $cleanupFailures.Add("Private zmx descendant cleanup failed for PID $($identity.Pid): $($_.Exception.Message)")
        }
    }
    try {
        $result = Stop-CapManagedProcess -Identity $SeedRun.Identity -TimeoutMilliseconds 5000
        $seedCleanup.Add($result)
        $cleanupReceipts.Add($result)
    } catch {
        $cleanupFailures.Add("Private zmx seed cleanup failed for PID $($SeedRun.Identity.Pid): $($_.Exception.Message)")
    }
    foreach ($identity in @($identities) + @($SeedRun.Identity)) {
        try {
            if (-not [CapNative]::IsExited($identity.Process.Handle, $identity.Pid)) {
                throw "Owned zmx process remains kernel-live: role=$($identity.Role) pid=$($identity.Pid)."
            }
        } catch {
            $cleanupFailures.Add("Private zmx survivor check failed for PID $($identity.Pid): $($_.Exception.Message)")
        }
    }
    try {
        Write-CapRunStreams -Run $SeedRun -Label "$($SeedRun.Phase)-zmx-seed"
        $SeedRun.SeedReceipt.stdoutEof = $SeedRun.StdoutTask.IsCompleted
        $SeedRun.SeedReceipt.stderrEof = $SeedRun.StderrTask.IsCompleted
    } catch {
        $cleanupFailures.Add("Private zmx seed EOF failed for PID $($SeedRun.Identity.Pid): $($_.Exception.Message)")
    }
    $SeedRun.SeedReceipt.cleanup = @($seedCleanup)
    $SeedRun.SeedReceipt.cleanupStatus = if (
        $cleanupFailures.Count -eq $failureCountBefore -and
        $SeedRun.SeedReceipt.stdoutEof -and $SeedRun.SeedReceipt.stderrEof
    ) { 'CLEAN_ZERO_SURVIVORS_EOF' } else { 'CLEANUP_UNPROVEN' }
    try { Write-CapSeedCleanupReceipt -SeedRun $SeedRun }
    catch { $cleanupFailures.Add("Private zmx receipt update failed: $($_.Exception.Message)") }
    if ($cleanupFailures.Count -eq $failureCountBefore) { $SeedRun.CleanupComplete = $true }
}

function Close-CapPeer {
    param([Parameter(Mandatory)]$PeerRun, [Parameter(Mandatory)][string]$Label)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    if (-not [CapNative]::IsExited($PeerRun.Identity.Process.Handle, $PeerRun.Identity.Pid)) {
        try {
            $receipt = Stop-CapManagedProcess -Identity $PeerRun.Identity -TimeoutMilliseconds 5000
            $cleanupReceipts.Add($receipt)
        } catch {
            $cleanupFailures.Add("Offline peer cleanup failed for PID $($PeerRun.Identity.Pid): $($_.Exception.Message)")
        }
    }
    try { Write-CapRunStreams -Run $PeerRun -Label $Label }
    catch { $cleanupFailures.Add($_.Exception.Message) }
    try { $null = Test-CapPipeUnserved -PipeName $Label }
    catch { $cleanupFailures.Add("Offline peer pipe cleanup failed for '$Label': $($_.Exception.Message)") }
}

function Invoke-CapNormalScenes {
    param([Parameter(Mandatory)][string]$Phase)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    $phaseRoot = Join-Path $runDirectory "phases\$Phase\normal"
    $roots = Initialize-CapPhaseRoot -PhaseRoot $phaseRoot
    $pipeName = "gc-cap-$($auth.leaseId.Replace('-', '').Substring(0, 8))-$Phase"
    $sessionPrefix = "gc-cap-$($auth.leaseId.Replace('-', '').Substring(0, 8))-$Phase-"
    $peer = Start-CapOfflinePeer -Roots $roots -PipeName $pipeName -Phase "$Phase-normal"
    $seed = $null
    $app = $null
    try {
        $seed = Start-CapOfflineSeed -Roots $roots -Phase $Phase
        $app = Start-CapGraphCodeApp -Roots $roots -Phase $Phase -PipeName $pipeName -SessionPrefix $sessionPrefix
        $null = Invoke-CapSceneAction -AppRun $app -Action 'actual-size'
        $null = Invoke-CapSceneAction -AppRun $app -Action 'open-project' -Name 'Alpha'
        $null = Invoke-CapSceneAction -AppRun $app -Action 'actual-size'
        $alpha = $job.scenes | Where-Object name -CEQ 'project-alpha'
        $widthIndex = if ($Phase -eq 'before') { 0 } else { 1 }
        $zoom = Measure-CapSceneZoom -AppRun $app -Scene $alpha -NaturalWidth ([int]$alpha.naturalWidthBeforeAfter[$widthIndex])
        Save-CapSceneImage -AppRun $app -SceneName 'project-alpha' -ZoomEvidence $zoom -Phase $Phase

        $null = Invoke-CapSceneAction -AppRun $app -Action 'open-project' -Name 'Beta'
        $null = Invoke-CapSceneAction -AppRun $app -Action 'actual-size'
        $beta = $job.scenes | Where-Object name -CEQ 'project-beta'
        $zoom = Measure-CapSceneZoom -AppRun $app -Scene $beta -NaturalWidth ([int]$beta.naturalWidthBeforeAfter[$widthIndex])
        Save-CapSceneImage -AppRun $app -SceneName 'project-beta' -ZoomEvidence $zoom -Phase $Phase

        $null = Invoke-CapSceneAction -AppRun $app -Action 'overview-destination'
        $null = Invoke-CapSceneAction -AppRun $app -Action 'actual-size'
        $overview = $job.scenes | Where-Object name -CEQ 'overview'
        $zoom = Measure-CapSceneZoom -AppRun $app -Scene $overview -NaturalWidth ([int]$overview.naturalWidthBeforeAfter[$widthIndex])
        Save-CapSceneImage -AppRun $app -SceneName 'overview' -ZoomEvidence $zoom -Phase $Phase

        $null = Invoke-CapSceneAction -AppRun $app -Action 'open-project' -Name 'Alpha'
        $null = Invoke-CapSceneAction -AppRun $app -Action 'open-loop' -Name 'RefMain'
        $workspace = $job.scenes | Where-Object name -CEQ 'workspace'
        Save-CapSceneImage -AppRun $app -SceneName 'workspace' -ZoomEvidence $null -Phase $Phase
        Close-CapGraphCodeApp -AppRun $app -NormalExit
        if (-not [CapNative]::IsExited($app.Run.Identity.Process.Handle, $app.Run.Identity.Pid) -or
            $app.Run.Identity.Process.ExitCode -ne 0) {
            throw "App failed File > Exit for $Phase, exit=$($app.Run.Identity.Process.ExitCode)."
        }
    } finally {
        if ($app) { Close-CapGraphCodeApp -AppRun $app }
        if ($seed) { Close-CapOfflineSeed -SeedRun $seed }
        Close-CapPeer -PeerRun $peer -Label $pipeName
    }
    $expectedCleanup = if ($mockSceneRun) { 'CLEAN_ZERO_SURVIVORS_EOF' } else { 'CLEAN_ZERO_SURVIVORS_FILES_CLOSED' }
    if ($seed -and $seed.SeedReceipt.cleanupStatus -ne $expectedCleanup) {
        throw "Private zmx seed cleanup did not prove its output closure for $Phase."
    }
}

function Invoke-CapActionsScene {
    param([Parameter(Mandatory)][string]$Phase)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    $phaseRoot = Join-Path $runDirectory "phases\$Phase\actions"
    $roots = Initialize-CapPhaseRoot -PhaseRoot $phaseRoot
    $pipeName = "gc-cap-unserved-$($auth.leaseId.Replace('-', '').Substring(0, 8))-$Phase"
    $sessionPrefix = "gc-cap-actions-$($auth.leaseId.Replace('-', '').Substring(0, 8))-$Phase-"
    $null = Test-CapPipeUnserved -PipeName $pipeName
    $app = $null
    try {
        $app = Start-CapGraphCodeApp -Roots $roots -Phase $Phase -PipeName $pipeName `
            -SessionPrefix $sessionPrefix -ActionsFixture
        $null = Invoke-CapSceneAction -AppRun $app -Action 'actual-size'
        $null = Invoke-CapSceneAction -AppRun $app -Action 'open-project' -Name 'UIA project'
        $null = Invoke-CapSceneAction -AppRun $app -Action 'actual-size'
        $actionScene = $job.scenes | Where-Object name -CEQ 'actions'
        $widthIndex = if ($Phase -eq 'before') { 0 } else { 1 }
        $zoom = Measure-CapSceneZoom -AppRun $app -Scene $actionScene `
            -NaturalWidth ([int]$actionScene.naturalWidthBeforeAfter[$widthIndex])
        $observations = @(Get-CapGraphActionObservations -RootHandle $app.Window `
            -ProcessIdentity $app.Run.Identity -RequiredNames @('Reclaim', 'Keep', 'Reply'))
        if ($observations.Count -ne 3) { throw "Expected three direct read-only action observations; got $($observations.Count)." }
        $expected = @('Keep', 'Reclaim', 'Reply')
        $actual = @($observations | ForEach-Object Name | Sort-Object)
        if (Compare-Object $expected $actual) { throw 'Read-only action observation names differ from Reclaim/Keep/Reply.' }
        $null = Test-CapPipeUnserved -PipeName $pipeName
        Save-CapSceneImage -AppRun $app -SceneName 'actions' -ZoomEvidence $zoom -Phase $Phase
        $script:images[$script:images.Count - 1] | Add-Member -NotePropertyName actionObservations -NotePropertyValue $observations
        Write-CapWorkerJournalSnapshot -Kind 'Progress'
        Close-CapGraphCodeApp -AppRun $app -NormalExit
        if (-not [CapNative]::IsExited($app.Run.Identity.Process.Handle, $app.Run.Identity.Pid) -or
            $app.Run.Identity.Process.ExitCode -ne 0) {
            throw "Actions app failed File > Exit for $Phase, exit=$($app.Run.Identity.Process.ExitCode)."
        }
        $null = Test-CapPipeUnserved -PipeName $pipeName
    } finally {
        if ($app) { Close-CapGraphCodeApp -AppRun $app }
    }
}

function Read-CapDState {
    param($AppRun,[string]$State)
    Assert-CapWorkerDeadline "D state $State"
    $null=Assert-CapRootProcess -RootHandle $AppRun.Window -ProcessIdentity $AppRun.Run.Identity
    $element=[Windows.Automation.AutomationElement]::FromHandle($AppRun.Window)
    if ($null -eq $element) {throw 'D UIA root is unavailable.'}
    $rows=@($element)+@($element.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition))
    $observation=Get-CapDObservation -Candidates $rows -ExpectedProcessId $AppRun.Run.Identity.Pid -State $State -Phase $AppRun.Phase
    $observation.evidenceMode='OWNED_UIA_READ_NOT_VISUAL_PARITY'
    $AppRun.DObservation=$observation
    return $observation
}

function Save-CapDScene {
    param($AppRun,[string]$Scene,[string]$State,[string]$ProbeName,[string]$ProbePrefix='canvas-card-')
    $null=Read-CapDState -AppRun $AppRun -State $State
    $zoom=$null
    if ($ProbeName) {
        $null=Invoke-CapSceneAction -AppRun $AppRun -Action 'actual-size'
        $probe=Wait-CapVisibleElement -Window $AppRun.Window -ProcessIdentity $AppRun.Run.Identity -Name $ProbeName -AutomationIdPrefix $ProbePrefix
        $spec=@($job.scenes | Where-Object name -CEQ $Scene)
        $index=if ($AppRun.Phase -ceq 'before') {0} else {1}
        $width=if ($State -ceq 'chats') {220} else {[int]$spec[0].naturalWidthBeforeAfter[$index]}
        $zoom=Measure-CapZoom -Element $probe -NaturalWidth $width
    }
    Save-CapSceneImage -AppRun $AppRun -SceneName $Scene -ZoomEvidence $zoom -Phase $AppRun.Phase
}

function Invoke-CapDScenes {
    param([Parameter(Mandatory)][ValidateSet('before','after')][string]$Phase)
    Assert-CapWorkerDeadline "D phase $Phase"
    if (($leaseDeadlineUtc-[DateTime]::UtcNow).TotalSeconds -lt $(if ($Phase -ceq 'before') {$job.captureContract.estimatedSeconds} else {1})) {
        throw 'Insufficient admitted D scene budget before the cleanup reserve.'
    }
    $roots=Initialize-CapPhaseRoot -PhaseRoot (Join-Path $runDirectory "phases\$Phase\normal")
    $fixture=Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -DateKind String
    $pipe="gc-cap-d-$($auth.leaseId.Replace('-','').Substring(0,8))-$Phase"
    $peer=$null;$app=$null;$seeds=[Collections.Generic.List[object]]::new()
    try {
        $peer=Start-CapOfflinePeer -Roots $roots -PipeName $pipe -Phase "$Phase-normal"
        foreach ($i in 0..1) {
            $label=@('primary','history')[$i]
            $seedPhase="$Phase-$label"
            $null=New-Item -ItemType Directory -Path (Join-Path $runDirectory "phases\$seedPhase\normal")
            $seeds.Add((Start-CapOfflineSeed -Roots $roots -Phase $seedPhase -SessionName "graphcode-$($fixture.chats[$i].id)"))
        }
        $app=Start-CapGraphCodeApp -Roots $roots -Phase $Phase -PipeName $pipe -SessionPrefix 'D_EXACT_SESSIONS_ONLY'
        $app | Add-Member -NotePropertyName DObservation -NotePropertyValue $null
        $app | Add-Member -NotePropertyName DActions -NotePropertyValue ([Collections.Generic.List[object]]::new())
        $null=Invoke-CapSceneAction -AppRun $app -Action 'quick-chats-destination'
        Save-CapDScene -AppRun $app -Scene 'd-quick-chats-canvas' -State 'chats' -ProbeName 'Quick Chat capture fixture' -ProbePrefix 'quick-chat-card-'
        $null=Invoke-CapSceneAction -AppRun $app -Action 'open-quick-chat' -Name 'Quick Chat capture fixture'
        Save-CapDScene -AppRun $app -Scene 'd-chat-primary-shell' -State 'primary'
        $null=Invoke-CapSceneAction -AppRun $app -Action 'quick-chats-destination'
        $null=Invoke-CapSceneAction -AppRun $app -Action 'open-quick-chat' -Name 'Quick Chat history fixture'
        Save-CapDScene -AppRun $app -Scene 'd-chat-history-roles' -State 'history'
        $null=Invoke-CapSceneAction -AppRun $app -Action 'workspace-show-graph'
        Save-CapDScene -AppRun $app -Scene 'd-chat-show-graph-destination' -State 'project' -ProbeName 'Loop workspace fixture'
        Save-CapDScene -AppRun $app -Scene 'd-neighbor-sidebar' -State 'project'
        $null=Invoke-CapSceneAction -AppRun $app -Action 'overview-destination'
        Save-CapDScene -AppRun $app -Scene 'd-neighbor-overview' -State 'overview' -ProbeName 'Loop workspace fixture'
        $null=Invoke-CapSceneAction -AppRun $app -Action 'open-project' -Name 'D Offline Capture Fixture'
        Save-CapDScene -AppRun $app -Scene 'd-neighbor-project' -State 'project' -ProbeName 'Loop workspace fixture'
        $null=Invoke-CapSceneAction -AppRun $app -Action 'open-loop' -Name 'Loop workspace fixture'
        $toggle=$null
        try {$toggle=Find-CapAutomationElement -RootHandle $app.Window -ProcessIdentity $app.Run.Identity -Name 'Expand loop panel' -AutomationIdPrefix 'workspace-toggle-panel-'}
        catch {
            if ($_.Exception.Message -notmatch 'found=0\.') {throw}
            $null=Find-CapAutomationElement -RootHandle $app.Window -ProcessIdentity $app.Run.Identity -Name 'Collapse loop panel' -AutomationIdPrefix 'workspace-toggle-panel-'
        }
        if ($null -ne $toggle) {$null=Invoke-CapSceneAction -AppRun $app -Action 'workspace-toggle-panel' -Name 'Expand loop panel' -SubjectId 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'}
        Save-CapDScene -AppRun $app -Scene 'd-normal-panel-expanded' -State 'expanded'
        $null=Invoke-CapSceneAction -AppRun $app -Action 'workspace-toggle-panel' -Name 'Collapse loop panel' -SubjectId 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'
        Save-CapDScene -AppRun $app -Scene 'd-normal-panel-collapsed' -State 'collapsed'
        $null=Invoke-CapSceneAction -AppRun $app -Action 'workspace-show-graph'
        Save-CapDScene -AppRun $app -Scene 'd-normal-route-away-project' -State 'project' -ProbeName 'Loop workspace fixture'
        foreach ($layout in $fixture.layouts) {
            $key=if ($layout.project -ceq 'graphcode://quick-chats') {$roots.Profile} else {$layout.project}
            $path=Get-CapDLayoutPath -LayoutBase (Join-Path $roots.Root 'layouts\workspace.json') -ProjectKey $key -LoopId $layout.loop
            $saved=Get-Content -LiteralPath (Assert-CapOwnedPath $path.LoopPath) -Raw | ConvertFrom-Json -DateKind String
            if ($saved.project -cne $layout.project -or $saved.loop -cne $layout.loop -or $saved.selectedTab -ne 0 -or $saved.tabs.Count -ne 1) {
                throw 'Production-persisted D layout lost its exact project/loop/Shell binding.'
            }
        }
        Close-CapGraphCodeApp -AppRun $app -NormalExit
        if (-not [CapNative]::IsExited($app.Run.Identity.Process.Handle,$app.Run.Identity.Pid) -or $app.Run.Identity.Process.ExitCode -ne 0) {
            throw 'D app did not complete File > Exit with zero exit.'
        }
    } finally {
        if ($app) {Close-CapGraphCodeApp -AppRun $app}
        foreach ($seed in $seeds) {Close-CapOfflineSeed -SeedRun $seed}
        if ($peer) {Close-CapPeer -PeerRun $peer -Label $pipe}
    }
}

function Invoke-CapRealLaunchRehearsal {
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    Assert-CapWorkerDeadline 'starting offline real launch rehearsal'
    $roots = Initialize-CapPhaseRoot -PhaseRoot (Join-Path $runDirectory 'rehearsal-target')
    $app = Start-CapGraphCodeApp -Roots $roots -Phase 'before' -PipeName 'NOT_USED_NO_DESKTOP' `
        -SessionPrefix 'NOT_USED_NO_DESKTOP'
    $run = $app.Run
    $launch = [pscustomobject]@{
        role = $run.Identity.Role; pid = $run.Identity.Pid
        creationFileTimeUtc = $run.Identity.CreationFileTimeUtc
        expectedImagePath = $run.Identity.ExpectedImagePath
        heldKernelHandle = $run.Identity.Process.Handle.ToInt64()
        parentPid = $run.Identity.ParentPid; sessionId = $run.Identity.SessionId
        executableSha256 = (Get-FileHash -LiteralPath $run.Identity.ExpectedImagePath -Algorithm SHA256).Hash
        argumentCount = $job.rehearsalTarget.arguments.Count
        arguments = @($job.rehearsalTarget.arguments)
        stdinClosed = $run.StdinClosed; ready = $false; exitCode = $null
        stdoutEof = $false; stderrEof = $false; kernelExited = $false; cleanupResult = $null
    }
    $rehearsalLaunches.Add($launch)
    try {
        if ($job.rehearsalTarget.behavior -ceq 'action-target-absent') {
            $action = [pscustomobject]@{
                action = 'open-loop'
                targetAppeared = $false
                startedUtc = [DateTimeOffset]::UtcNow.ToString('o')
                actionDeadlineUtc = $null
                workerDeadlineUtc = $leaseDeadlineUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                failedUtc = $null
                workerReserveMilliseconds = $null
            }
            $rehearsalActions.Add($action)
            try {
                $action.actionDeadlineUtc = (
                    Get-CapActionDeadline -WorkerDeadlineUtc $leaseDeadlineUtc
                ).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                $null = Wait-CapVisibleElement -Window ([IntPtr]1) -ProcessIdentity $run.Identity `
                    -Name 'Never appearing rehearsal action target' -FindElement {
                        param([ref]$Snapshot)
                        $Snapshot.Value = @{ EmissionAttempted = $true }
                        throw "Expected exactly one visible UIA element Name='Never appearing rehearsal action target'; found=0."
                    }
                $action.targetAppeared = $true
                throw 'Never-appearing rehearsal action target unexpectedly resolved.'
            } finally {
                $failed = [DateTimeOffset]::UtcNow
                $action.failedUtc = $failed.ToString('o')
                $action.workerReserveMilliseconds = (
                    [DateTimeOffset]::new($leaseDeadlineUtc) - $failed
                ).TotalMilliseconds
            }
        }
        $timeout = [int]$job.rehearsalTarget.timeoutMilliseconds
        if ($timeout -lt 500 -or $timeout -gt 10000) { throw 'Rehearsal target timeout must be 500..10000 ms.' }
        $deadline = [DateTime]::UtcNow.AddMilliseconds($timeout)
        if ($deadline -gt $leaseDeadlineUtc) { $deadline = $leaseDeadlineUtc }
        $wait = Wait-CapManagedProcess -Run $run -DeadlineUtc $deadline -PollMilliseconds 50
        if ($wait.State -ne 'Exited') { throw [TimeoutException]::new('Harmless rehearsal target timed out.') }
        $launch.exitCode = $wait.ExitCode
        if (-not $run.StdoutTask.Wait(2000) -or -not $run.StderrTask.Wait(2000)) {
            throw 'Rehearsal target did not produce bounded stdout/stderr EOF.'
        }
        $stdout = [string]$run.StdoutTask.Result
        $launch.ready = $stdout -match '(?m)^CAP_READY\r?$' -and $stdout -match '(?m)^CAP_STDIN_EOF\r?$'
        if (-not $launch.ready) { throw 'Harmless target readiness/stdin EOF lines were not observed.' }
        if ($wait.ExitCode -ne 0) { throw "Harmless rehearsal target exited with code $($wait.ExitCode)." }
        Write-CapWorkerLog "REAL_LAUNCH_READY pid=$($launch.pid) arguments=$($launch.argumentCount) exit=$($launch.exitCode)"
    } finally { Close-CapGraphCodeApp -AppRun $app }
}

function Close-CapMatchedJob {
    param($Run,[string]$Phase)
    $proof=Close-CapJobLauncher -Run $Run
    foreach ($identity in $Run.Members) {
        if (-not @($descendantIdentities | Where-Object {$_.Pid -eq $identity.Pid -and
            $_.CreationFileTimeUtc -eq $identity.CreationFileTimeUtc}).Count) {
            $descendantIdentities.Add($identity)
            Write-CapProcessJournal -Identity $identity -Phase $Phase
        }
    }
    $cleanupReceipts.Add($proof)
    return $proof
}

function Read-CapMatchedRows {
    param($AppRun)
    $null=Assert-CapRootProcess -RootHandle $AppRun.Window -ProcessIdentity $AppRun.Run.Identity
    $graph=Find-CapAutomationElement -RootHandle $AppRun.Window -ProcessIdentity $AppRun.Run.Identity `
        -ExpectedProcessId $AppRun.Run.Identity.Pid -Name 'Graph' -AutomationId 'graph'
    return @(Get-CapDirectChildren -Parent $graph | Where-Object {
        $_.Current.AutomationId -cmatch '^(?:canvas-card|workspace-tab(?:-close)?)-'
    } | ForEach-Object {
        $current=$_.Current
        $parent=[Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($_)
        $selection=$_.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)
        [pscustomobject]@{AutomationId=[string]$current.AutomationId;Name=[string]$current.Name
            ProcessId=[long]$current.ProcessId;ParentAutomationId=[string]$parent.Current.AutomationId
            Selected=[bool]$selection.Current.IsSelected;IsEnabled=[bool]$current.IsEnabled
            IsOffscreen=[bool]$current.IsOffscreen;Bounds=@($current.BoundingRectangle.Left,
                $current.BoundingRectangle.Top,$current.BoundingRectangle.Right,$current.BoundingRectangle.Bottom)}
    })
}

function Read-CapMatchedPanes {
    param($AppRun,[int]$ExpectedCount,[int]$FocusedIndex=-1)
    $null=Assert-CapRootProcess -RootHandle $AppRun.Window -ProcessIdentity $AppRun.Run.Identity
    $rootElement=[Windows.Automation.AutomationElement]::FromHandle($AppRun.Window)
    $condition=[Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::IsTextPatternAvailableProperty,$true)
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    if ($deadline -gt $leaseDeadlineUtc.AddSeconds(-90)) {$deadline=$leaseDeadlineUtc.AddSeconds(-90)}
    do {
        $panes=@($rootElement.FindAll([Windows.Automation.TreeScope]::Descendants,$condition) |
            Where-Object {-not $_.Current.IsOffscreen -and $_.Current.BoundingRectangle.Width -gt 0 -and
                $_.Current.BoundingRectangle.Height -gt 0} | Sort-Object {$_.Current.BoundingRectangle.Left})
        if ($panes.Count -ge $ExpectedCount) {break}
        Assert-CapWorkerDeadline 'matched terminal provider publication';Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($panes.Count -ne $ExpectedCount) {throw "Matched panes expected $ExpectedCount bounded terminals; found=$($panes.Count)."}
    if ($FocusedIndex -ge 0) {
        if ($FocusedIndex -ge $panes.Count) {throw 'Matched pane focus index is outside the owned topology.'}
        $panes[$FocusedIndex].SetFocus()
        Start-Sleep -Milliseconds 100
    }
    return @($panes | ForEach-Object {
        $current=$_.Current
        $null=Assert-CapUiaProcessIds -ExpectedProcessId $AppRun.Run.Identity.Pid -ObservedProcessIds @($current.ProcessId)
        $parent=[Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($_)
        if ($null -eq $parent -or $parent.Current.ProcessId -ne $AppRun.Run.Identity.Pid) {throw 'Matched pane has a foreign or missing direct parent.'}
        [pscustomobject]@{processId=$current.ProcessId;automationId=$current.AutomationId
            parentAutomationId=$parent.Current.AutomationId;nativeWindowHandle=$current.NativeWindowHandle
            focused=$current.HasKeyboardFocus;bounds=@($current.BoundingRectangle.Left,$current.BoundingRectangle.Top,
                $current.BoundingRectangle.Right,$current.BoundingRectangle.Bottom)}
    })
}

function Get-CapMatchedAttach {
    param($AppRun,[string]$NodeId)
    $tree=@(Get-CapTreeForApp -AppRun $AppRun)
    $session="graphcode-$NodeId"
    $found=@(foreach ($candidate in $tree) {
        if ($candidate.ExpectedImagePath -ine (ConvertTo-CapImagePath (Join-Path $root 'runtime\zmx.exe'))) {continue}
        $verified=Assert-CapProcessIdentity -Identity $candidate
        if ($verified.State -ceq 'Exited') {continue}
        $arguments=@([CapNative]::CommandArguments($verified.Metadata.CommandLine))
        if ($arguments.Count -ge 3 -and $arguments[1] -ceq 'attach' -and $arguments[2] -ceq $session) {$candidate}
    })
    if ($found.Count -gt 1) {throw 'Restart evidence: ambiguous live attach owner'}
    if ($found.Count -eq 0) {return $null}
    $null=Assert-CapProcessIdentity -Identity $found[0]
    return $found[0]
}

function Get-CapMatchedRestartEvidence {
    param($AppRun,$Context)
    try {$rows=@(Read-CapRestartTranscript -Path $Context.transcript)}
    catch {
        if ($_.Exception.Data['CapCaptureCode'] -cne 'RestartTranscriptPending') {throw}
        $null=Write-CapWorkerLog 'RESTART_PENDING transcript publication is incomplete; retaining original deadline'
        return $null
    }
    $restartRows=@($rows | Where-Object {
        $_.direction -ceq 'shell' -and $_.frame.kind -ceq 'request' -and
        $_.frame.command.PSObject.Properties['graphCommand'] -and
        $_.frame.command.graphCommand.command.PSObject.Properties['restartNode']
    })
    if ($restartRows.Count -eq 0) {return $null}
    if ($restartRows.Count -ne 1) {throw 'Restart evidence: duplicate real restart requests'}
    $daemonSnapshot=[CapNative]::Snapshot($Context.daemonProcess.Handle,$Context.daemonProcess.Id)
    if ($daemonSnapshot.IsExited -or $daemonSnapshot.CreationFileTimeUtc -ne $Context.daemonTarget.creationFileTimeUtc -or
        -not [CapProcessJob]::Contains($Context.daemonRun.Job,$Context.daemonProcess.Handle)) {throw 'Restart evidence: held daemon generation changed'}
    $after=Get-CapMatchedAttach -AppRun $AppRun -NodeId $Context.nodeId
    if ($null -eq $after -or -not [CapNative]::IsExited($Context.oldAttach.Process.Handle,$Context.oldAttach.Pid)) {return $null}
    $members=@(Get-CapJobMembers -Run $Context.daemonRun)
    $backend=@($members | Where-Object ExpectedImagePath -IEQ (ConvertTo-CapImagePath (Join-Path $root 'runtime\copilot.exe')))
    $zmx=@($members | Where-Object ExpectedImagePath -IEQ (ConvertTo-CapImagePath (Join-Path $root 'runtime\zmx.exe')))
    if ($backend.Count -ne 1 -or $zmx.Count -lt 1) {return $null}
    if ($backend[0].CreationFileTimeUtc -le $Context.oldBackend.CreationFileTimeUtc -or
        -not [CapNative]::IsExited($Context.oldBackend.Process.Handle,$Context.oldBackend.Pid)) {return $null}
    $panes=@(Read-CapMatchedPanes -AppRun $AppRun -ExpectedCount 1)
    $evidence=[pscustomobject]@{
        projectPath=$Context.projectPath;nodeId=$Context.nodeId;connection=[long]$restartRows[0].connection
        counter=[long]$Context.counter;rows=$rows
        daemon=[pscustomobject]@{pid=[long]$daemonSnapshot.ProcessId;creationFileTimeUtc=[long]$daemonSnapshot.CreationFileTimeUtc
            held=$true;jobOwned=$true;imageSha256=(Get-FileHash (Join-Path $root 'runtime\graphcoded.exe') -Algorithm SHA256).Hash}
        beforeAttach=[pscustomobject]@{pid=[long]$Context.oldAttach.Pid;creationFileTimeUtc=[long]$Context.oldAttach.CreationFileTimeUtc
            session="graphcode-$($Context.nodeId)";retired=$true}
        afterAttach=[pscustomobject]@{pid=[long]$after.Pid;creationFileTimeUtc=[long]$after.CreationFileTimeUtc
            session="graphcode-$($Context.nodeId)";held=$true;jobOwned=[CapProcessJob]::Contains($AppRun.OwnedJob.Job,$after.Process.Handle)
            daemonSessionReady=$true;uiaPaneOwned=($panes.Count -eq 1);observedAfterOrdinal=[long]$rows[-1].ordinal
            panes=$panes;backendPid=[long]$backend[0].Pid;backendCreationFileTimeUtc=[long]$backend[0].CreationFileTimeUtc
            oldBackendPid=[long]$Context.oldBackend.Pid;oldBackendCreationFileTimeUtc=[long]$Context.oldBackend.CreationFileTimeUtc
            oldBackendExited=$true;appJobId=$AppRun.OwnedJob.JobId}
    }
    $resumeReplies=@($rows | Where-Object {$_.direction -ceq 'daemon' -and $_.frame.kind -ceq 'response'})
    if ($resumeReplies.Count -lt 1) {return $null}
    try {$null=Assert-CapRestartEvidence -Evidence $evidence -ExpectedDaemonSha256 $job.binaries.daemon.sha256}
    catch {
        if ($_.Exception.Message -ceq 'Restart evidence: complete correlated restart, counter advance, checked resume and subsequent attach required') {return $null}
        throw
    }
    return $evidence
}

function Invoke-CapMatchedRestartScene {
    param($AppRun,$Context)
    if ($Context.mode -cne 'REAL_DAEMON') {throw 'Matched Restart requires a real owned daemon, never offline peer authority.'}
    Assert-CapWorkerDeadline 'real Restart action'
    $null=Invoke-CapSceneAction -AppRun $AppRun -Action 'workspace-restart-session' -SubjectId $Context.nodeId
    $deadline=[DateTime]::UtcNow.AddSeconds(40)
    if ($deadline -gt $leaseDeadlineUtc.AddSeconds(-90)) {$deadline=$leaseDeadlineUtc.AddSeconds(-90)}
    do {
        Assert-CapWorkerDeadline 'real Restart confirmation and reattach'
        $evidence=Get-CapMatchedRestartEvidence -AppRun $AppRun -Context $Context
        if ($null -ne $evidence) {
            $proof=Assert-CapRestartEvidence -Evidence $evidence -ExpectedDaemonSha256 $job.binaries.daemon.sha256
            $Context | Add-Member -NotePropertyName evidence -NotePropertyValue $evidence
            return $proof
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Restart evidence: bounded daemon round-trip/resume/owned reattach was not confirmed'
}

function Initialize-CapMatchedWorktrees {
    param($Fixture)
    $project=Assert-CapOwnedPath $Fixture.graphs[0].project.path
    if (Test-Path -LiteralPath (Join-Path $project '.git')) {throw 'Matched project must be a fresh owned git fixture.'}
    $null=New-Item -ItemType Directory -Path $project -Force
    $env:GIT_CONFIG_NOSYSTEM='1';$env:GIT_CONFIG_GLOBAL=Join-Path $project 'empty-gitconfig'
    [IO.File]::WriteAllText($env:GIT_CONFIG_GLOBAL,'')
    [IO.File]::WriteAllText((Join-Path $project '.gitignore'),"fixture-payload.bin`nempty-gitconfig`n.graphcode/`n")
    foreach ($arguments in @(
        @('init','--quiet','-b','main',$project),
        @('-C',$project,'add','.gitignore'),
        @('-C',$project,'-c','user.name=Capture Fixture','-c','user.email=capture-fixture@invalid',
            'commit','--quiet','-s','-m','Seed offline capture worktree')
    )) {
        $output=@(& git @arguments 2>&1)
        if ($LASTEXITCODE -ne 0) {throw "Matched worktree fixture failed: $($output -join ' ')"}
    }
    foreach ($tree in $Fixture.worktrees) {
        $path=Assert-CapOwnedPath $tree.path
        $output=@(& git -C $project worktree add --quiet -b $tree.branch $path main 2>&1)
        if ($LASTEXITCODE -ne 0) {throw "Matched worktree add failed: $($output -join ' ')"}
        $file=[IO.File]::Open((Join-Path $path 'fixture-payload.bin'),[IO.FileMode]::CreateNew)
        try {$file.SetLength($tree.sizeBytes)} finally {$file.Dispose()}
    }
    $policyRoot=Join-Path $project '.graphcode'
    $null=New-Item -ItemType Directory -Path $policyRoot
    [IO.File]::WriteAllText((Join-Path $policyRoot 'worktree-policy.json'),
        '{"allowReclaim":true,"confirmEachReclaim":true,"onResolveLanded":"ask","noticeSizeGB":20,"noticeCount":10}')
}

function Initialize-CapMatchedRestartStore {
    param($Roots,$Fixture)
    $null=Assert-CapMatchedFixture -Fixture $Fixture -ProjectRoot (Join-Path $root 'fixtures\projects')
    $node=$Fixture.graphs[0].nodes | Where-Object id -CEQ '11111111-1111-4111-8111-000000000001'
    $project=Assert-CapOwnedPath $Fixture.graphs[0].project.path
    $wirePath=$project.Replace('\','/')
    $graph=$Fixture.graphs[0] | ConvertTo-Json -Depth 30 | ConvertFrom-Json -DateKind String
    $graph.project.path=$wirePath;$graph.nodes=@($node);$graph.edges=@()
    $projects=Join-Path $Roots.Support 'projects'
    $null=New-Item -ItemType Directory -Path $projects
    $key='v1-'+[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($wirePath))).ToLowerInvariant()
    $graphPath=Join-Path $projects "$key.json"
    $recentPath=Join-Path $Roots.Support 'recent-projects.json'
    Write-CapJsonAtomic -Path $graphPath -Value $graph
    Write-CapJsonAtomic -Path $recentPath -Value @($graph.project)
    Write-CapJsonAtomic -Path (Join-Path $Roots.Support 'open-projects.json') -Value @($wirePath)
    return [pscustomobject]@{node=$node;project=$project;wirePath=$wirePath;graphPath=$graphPath;recentPath=$recentPath}
}

function Invoke-CapMatchedRestartCapture {
    param([string]$Phase,$Fixture)
    $roots=Initialize-CapPhaseRoot -PhaseRoot (Join-Path $runDirectory "phases\$Phase\real-restart")
    $store=Initialize-CapMatchedRestartStore -Roots $roots -Fixture $Fixture
    $node=$store.node;$project=$store.project;$wirePath=$store.wirePath
    $nonce=[guid]::NewGuid().ToString('N')
    $daemonPipe="gc-s-daemon-$nonce";$shellPipe="gc-s-record-$nonce"
    $environment=Get-CapBaseEnvironment -Roots $roots -PipeName $daemonPipe -SessionPrefix "s-$Phase"
    $environment.GRAPHCODE_SOCKET="\\.\pipe\$daemonPipe"
    $daemon=$null;$proxy=$null;$app=$null;$daemonProcess=$null;$daemonIdentity=$null
    try {
        $daemon=Start-CapJobLauncher -Root $root -OutputDirectory $roots.Peer -FilePath (Join-Path $root 'runtime\graphcoded.exe') `
            -ArgumentList @() -WorkingDirectory $project -Role "matched-daemon-$Phase" -Environment $environment
        $runs.Add($daemon);Write-CapProcessJournal -Identity $daemon.Identity -Phase $Phase
        $target=Release-CapJobLauncher -Run $daemon -JournalState $journalState
        $daemonProcess=[Diagnostics.Process]::GetProcessById([int]$target.pid)
        $native=[CapNative]::Snapshot($daemonProcess.Handle,$daemonProcess.Id)
        if ($native.CreationFileTimeUtc -ne $target.creationFileTimeUtc -or
            -not [CapProcessJob]::Contains($daemon.Job,$daemonProcess.Handle)) {throw 'Matched real daemon target generation/job differs.'}
        $daemonIdentity=Get-CapProcessIdentity -Process $daemonProcess -ExpectedImagePath (Join-Path $root 'runtime\graphcoded.exe') `
            -Role "matched-daemon-target-$Phase" -ExpectedParentPid $daemon.Identity.Pid
        $daemonIdentity | Add-Member -NotePropertyName JobId -NotePropertyValue $daemon.JobId
        $daemon.Members.Add($daemonIdentity)
        $ready=$false
        for ($i=0;$i -lt 100;$i++) {
            if ([CapNative]::ProbePipe($daemonPipe,100) -eq 0) {$ready=$true;break}
            Assert-CapWorkerDeadline 'real daemon listener readiness';Start-Sleep -Milliseconds 100
        }
        if (-not $ready) {throw 'Matched real daemon never published its owned listener.'}
        Initialize-CapMatchedProxy
        $transcript=Join-Path $roots.Peer 'restart-frames.jsonl'
        $proxy=[CapMatchedProxy]::new($shellPipe,$daemonPipe,$transcript,120000)
        $app=Start-CapGraphCodeApp -Roots $roots -Phase $Phase -PipeName $shellPipe -SessionPrefix "s-$Phase"
        $app | Add-Member -NotePropertyMembers @{SActions=[Collections.Generic.List[object]]::new();SObservation=$null}
        $null=Invoke-CapSceneAction -AppRun $app -Action 'open-project' -Name 'Matched'
        $null=Invoke-CapSceneAction -AppRun $app -Action 'open-loop' -Name $node.title
        $old=$null;$oldBackend=@()
        for ($i=0;$i -lt 100;$i++) {
            $old=Get-CapMatchedAttach -AppRun $app -NodeId $node.id
            $members=@(Get-CapJobMembers -Run $daemon)
            $oldBackend=@($members | Where-Object ExpectedImagePath -IEQ (ConvertTo-CapImagePath (Join-Path $root 'runtime\copilot.exe')))
            if ($old -and $oldBackend.Count -eq 1) {break}
            Assert-CapWorkerDeadline 'initial daemon-owned attach';Start-Sleep -Milliseconds 100
        }
        if ($null -eq $old -or $oldBackend.Count -ne 1) {throw 'Matched real daemon did not provide the initial owned attach and offline backend.'}
        $context=[pscustomobject]@{mode='REAL_DAEMON';transcript=$transcript;nodeId=$node.id;projectPath=$wirePath
            counter=[long]$node.sessionRestarts;oldAttach=$old;oldBackend=$oldBackend[0];daemonRun=$daemon;daemonTarget=$target;daemonProcess=$daemonProcess}
        $proof=Invoke-CapMatchedRestartScene -AppRun $app -Context $context
        $app.SObservation=[pscustomobject]@{readSucceeded=$true;evidenceMode='OWNED_UIA_READ_NOT_VISUAL_PARITY'
            restart=$proof;panes=$context.evidence.afterAttach.panes}
        Save-CapSceneImage -AppRun $app -SceneName 's-restart-confirmed' -ZoomEvidence $null -Phase $Phase
        Close-CapGraphCodeApp -AppRun $app -NormalExit
        $proxy.Dispose();$proxy=$null
        $cleanup=Close-CapMatchedJob -Run $daemon -Phase $Phase
        $realRestarts.Add([pscustomobject]@{phase=$Phase;evidence=$context.evidence
            transcriptPath=$transcript;transcriptSha256=(Get-FileHash $transcript -Algorithm SHA256).Hash
            daemonCleanup=$cleanup;mode='REAL_GRAPHCoded_AND_ZMX_WITH_OFFLINE_BACKEND_FIXTURE'})
    } finally {
        if ($app) {Close-CapGraphCodeApp -AppRun $app}
        if ($proxy) {$proxy.Dispose()}
        if ($daemon -and -not $daemon.CleanupComplete) {$null=Close-CapMatchedJob -Run $daemon -Phase $Phase}
        if ($daemonProcess -and -not $daemonIdentity) {$daemonProcess.Dispose()}
    }
}

function Invoke-CapMatchedScenes {
    param([string]$Phase)
    $fixture=Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -DateKind String
    $null=Assert-CapMatchedFixture -Fixture $fixture -ProjectRoot (Join-Path $root 'fixtures\projects')
    foreach ($scene in @((Get-CapMatchedSceneNames)[0..16])) {
        Assert-CapWorkerDeadline "matched scene $scene"
        if ([DateTime]::UtcNow -ge $leaseDeadlineUtc.AddSeconds(-90)) {throw 'Matched scenes reached the required cleanup reserve.'}
        $roots=Initialize-CapPhaseRoot -PhaseRoot (Join-Path $runDirectory "phases\$Phase\$scene")
        $pipe="gc-s-$([guid]::NewGuid().ToString('N'))"
        $peer=Start-CapOfflinePeer -Roots $roots -PipeName $pipe -Phase "$Phase-$scene"
        $app=$null;$seed=$null
        try {
            $state=@($fixture.states | Where-Object scene -CEQ $scene)
            $workspace=$state.Count -eq 0
            $nodeIndex=switch ($scene) {
                's-tabs-goal-needs-you' {0}
                's-tabs-loop-running' {6}
                's-tabs-agent-unknown' {7}
                's-tabs-two-agent-selected' {1}
                default {5}
            }
            if ($workspace) {
                $node=$fixture.graphs[0].nodes[$nodeIndex]
                $seed=Start-CapOfflineSeed -Roots $roots -Phase "$Phase-$scene" -SessionName "graphcode-$($node.id)"
            }
            $app=Start-CapGraphCodeApp -Roots $roots -Phase $Phase -PipeName $pipe -SessionPrefix "s-$Phase"
            $app | Add-Member -NotePropertyMembers @{SActions=[Collections.Generic.List[object]]::new();SObservation=$null}
            $null=Invoke-CapSceneAction -AppRun $app -Action 'open-project' -Name 'Matched'
            if (-not $workspace) {
                $targetId=if ($state[0].selected) {$state[0].nodeId} else {$fixture.graphs[0].nodes[5].id}
                $target=@($fixture.graphs[0].nodes | Where-Object id -CEQ $targetId)[0]
                $null=Invoke-CapSceneAction -AppRun $app -Action 'open-loop' -Name $target.title
                $null=Invoke-CapSceneAction -AppRun $app -Action 'workspace-show-graph'
                $null=Invoke-CapSceneAction -AppRun $app -Action 'actual-size'
                $rows=@(Read-CapMatchedRows -AppRun $app)
                $cardId=Get-CapMatchedAutomationId ("project-card:"+$fixture.graphs[0].project.path+":"+$state[0].nodeId)
                $card=@($rows | Where-Object {$_.AutomationId -ceq $cardId -and
                    $_.Name -ceq ($fixture.graphs[0].nodes | Where-Object id -CEQ $state[0].nodeId).title})
                if ($card.Count -ne 1 -or $card[0].Selected -ne $state[0].selected) {throw 'Matched card selection was not observed on its actual owned UIA card.'}
                $probe=[pscustomobject]@{zoomProbe=("Name "+$target.title+" / AutomationId prefix canvas-card-")}
                $zoom=Measure-CapSceneZoom -AppRun $app -Scene $probe -NaturalWidth 250
                $app.SObservation=[pscustomobject]@{readSucceeded=$true;evidenceMode='OWNED_UIA_READ_NOT_VISUAL_PARITY'
                    fixtureState=$state[0];card=$card[0];wireState='HASH_BOUND_STATIC_PEER_NOT_LIVE_BACKEND'}
                if ($scene -cmatch '^s-goal-unwired-') {
                    $app.SObservation | Add-Member -NotePropertyName recoveryControls -NotePropertyValue `
                        'REFERENCE_ONLY: Wire it up / Mark as entry; Windows control equivalence requires C8 review'
                }
                Save-CapSceneImage -AppRun $app -SceneName $scene -ZoomEvidence $zoom -Phase $Phase
            } else {
                $null=Invoke-CapSceneAction -AppRun $app -Action 'open-loop' -Name $node.title
                $total=1;$selected=0;$title=switch ($nodeIndex) {0 {'Goal'};6 {'Loop'};7 {'Agent'};default {'Copilot CLI'}}
                $newTabs=if ($scene -cin @('s-tabs-many-first','s-tabs-overflow-last')) {11}
                    elseif ($scene -cin @('s-tabs-two-shell-selected','s-tabs-split-right-focused')) {2}
                    elseif ($scene -cin @('s-tabs-two-agent-selected','s-tabs-hover-close')) {1} else {0}
                for ($i=0;$i -lt $newTabs;$i++) {$null=Invoke-CapSceneAction -AppRun $app -Action 'workspace-new-tab';$total++;$selected=$total-1}
                if ($scene -cin @('s-tabs-two-shell-selected','s-tabs-split-right-focused')) {
                    $null=Invoke-CapSceneAction -AppRun $app -Action 'workspace-close-tab' -SubjectId '0'
                    $total=2;$selected=0;$title='Shell'
                    $null=Invoke-CapSceneAction -AppRun $app -Action 'workspace-select-tab' -SubjectId '1' -Name 'Shell'
                    $selected=1
                }
                if ($scene -cin @('s-tabs-two-agent-selected','s-tabs-hover-close','s-tabs-many-first')) {
                    if ($total -eq 12) {$null=Invoke-CapSceneAction -AppRun $app -Action 'workspace-select-tab' -SubjectId '2' -Name 'Shell'}
                    $null=Invoke-CapSceneAction -AppRun $app -Action 'workspace-select-tab' -SubjectId '0' -Name $title
                    $selected=0
                }
                if ($scene -ceq 's-tabs-split-right-focused') {$null=Invoke-CapSceneAction -AppRun $app -Action 'workspace-split-right'}
                $rows=@(Read-CapMatchedRows -AppRun $app)
                $visibleCount=[Math]::Min(10,$total)
                $first=if ($selected -ge $visibleCount) {$selected-$visibleCount+1} else {0}
                $visible=@($first..($first+$visibleCount-1))
                $tabs=Get-CapMatchedTabObservation -Rows $rows -ExpectedProcessId $app.Run.Identity.Pid `
                    -TotalTabs $total -SelectedTab $selected -AgentTitle $title -VisibleIndexes $visible
                if ($scene -ceq 's-tabs-hover-close') {
                    $tab=@($tabs.visible | Where-Object index -EQ 1)[0]
                    Set-CapMatchedTabHover -AppRun $app -Bounds $tab.bounds
                }
                $panes=@(Read-CapMatchedPanes -AppRun $app -ExpectedCount $(if ($scene -ceq 's-tabs-split-right-focused') {2} else {1}) `
                    -FocusedIndex $(if ($scene -ceq 's-tabs-split-right-focused') {1} else {0}))
                if (@($panes | Where-Object focused).Count -ne 1) {throw 'Matched selected pane did not acquire the reported UIA focus.'}
                $app.SObservation=[pscustomobject]@{readSucceeded=$true;evidenceMode='OWNED_UIA_READ_NOT_VISUAL_PARITY'
                    tabs=$tabs;panes=$panes;nodeId=$node.id;nodeState=$node.state
                    hover=if ($scene -ceq 's-tabs-hover-close') {'POSTED_WM_MOUSEMOVE_NOT_PHYSICAL_POINTER'} else {'NOT_REQUESTED'}}
                Save-CapSceneImage -AppRun $app -SceneName $scene -ZoomEvidence $null -Phase $Phase
            }
            Close-CapGraphCodeApp -AppRun $app -NormalExit
        } finally {
            if ($app) {Close-CapGraphCodeApp -AppRun $app}
            if ($seed) {Close-CapOfflineSeed -SeedRun $seed}
            Close-CapPeer -PeerRun $peer -Label $pipe
        }
    }
    Invoke-CapMatchedRestartCapture -Phase $Phase -Fixture $fixture
}

function Set-CapMatchedTabHover {
    param($AppRun,[double[]]$Bounds)
    $null=Assert-CapRootProcess -RootHandle $AppRun.Window -ProcessIdentity $AppRun.Run.Identity
    $metrics=Get-CapWindowMetrics -Window $AppRun.Window -ProcessIdentity $AppRun.Run.Identity
    $border=($metrics.OuterBounds[2]-$metrics.OuterBounds[0]-$metrics.ClientBounds[2])/2
    $topFrame=$metrics.OuterBounds[3]-$metrics.OuterBounds[1]-$metrics.ClientBounds[3]-$border
    $x=[int](($Bounds[0]+$Bounds[2])/2-$metrics.OuterBounds[0]-$border)
    $y=[int](($Bounds[1]+$Bounds[3])/2-$metrics.OuterBounds[1]-$topFrame)
    if ($x -lt 0 -or $y -lt 0 -or $x -ge $metrics.ClientBounds[2] -or $y -ge $metrics.ClientBounds[3]) {throw 'Matched hover escaped the owned client area.'}
    if (-not [GraphCodeUiaGateState]::PostHover($AppRun.Window,$x,$y)) {throw 'Posting owned tab hover failed.'}
    Start-Sleep -Milliseconds 150
}

function Invoke-CapRealSeedRehearsal {
    if (-not $job.PSObject.Properties['seedDependencies']) { return }
    $dependencies = $job.seedDependencies
    Assert-CapDataRecord $dependencies @{ zmxPath = [string]; zmxSha256 = [string]; providerCommit = [string] } 'Real seed dependencies'
    $zmx = Assert-CapOwnedPath $dependencies.zmxPath
    if ($zmx -ine (Join-Path $root 'runtime\zmx.exe') -or
        $dependencies.providerCommit -cne '785b3fd15dcafd1882b495c831a10f98c201b908' -or
        $dependencies.zmxSha256 -cne $job.binaries.offlineZmx.sha256 -or
        (Get-FileHash -LiteralPath $zmx -Algorithm SHA256).Hash -cne $dependencies.zmxSha256) {
        throw 'Real seed dependencies are not bound to the pinned owned provider.'
    }
    foreach ($phase in @('before','after')) {
        Assert-CapWorkerDeadline "real seed rehearsal $phase"
        $roots = Initialize-CapPhaseRoot -PhaseRoot (Join-Path $runDirectory "phases\$phase\normal")
        $seed = $null
        try { $seed = Start-CapOfflineSeed -Roots $roots -Phase $phase }
        finally { if ($seed) { Close-CapOfflineSeed -SeedRun $seed } }
    }
}

if ($DefinitionsOnly) { return }

try {
    if (-not $AuthorizationPath -or -not $AuthorizationSha256) {
        throw 'Live capture requires the supervisor-bound authorization path and hash.'
    }
    $authorizationFullPath = [IO.Path]::GetFullPath($AuthorizationPath)
    if (-not $authorizationFullPath.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Worker authorization path escaped its explicit owned root.'
    }
    if (-not (Test-Path -LiteralPath $AuthorizationPath -PathType Leaf)) {
        throw "Supervisor run authorization is missing: $AuthorizationPath"
    }
    $actualAuthorizationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $AuthorizationPath).Hash
    if ($actualAuthorizationHash -ne $AuthorizationSha256) {
        throw 'Supervisor run authorization hash mismatch.'
    }
    $auth = Get-Content -LiteralPath $AuthorizationPath -Raw | ConvertFrom-Json -DateKind String
    if ($auth.ownedRoot -ine $root -or $auth.executionMode -notin @('LIVE_CAPTURE', 'NO_DESKTOP_REAL_LAUNCH_REHEARSAL')) {
        throw 'Worker root or execution mode differs from supervisor authorization.'
    }
    $rehearsal = $auth.executionMode -ceq 'NO_DESKTOP_REAL_LAUNCH_REHEARSAL'
    # Hash the exact source bytes before importing or compiling the native declarations.
    $moduleHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $modulePath).Hash
    $workerHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $PSCommandPath).Hash
    if ($moduleHash -ne $auth.moduleSha256 -or $workerHash -ne $auth.workerSha256 -or
        $auth.supervisorPath -ine (Join-Path $PSScriptRoot 'Invoke-UiCapture.ps1')) {
        throw 'Worker/module loaded-source binding differs from supervisor authorization.'
    }
    Import-Module $modulePath -Force -WarningAction SilentlyContinue
    [CapProcessJob]::ClearStandardHandleInheritance()
    if (-not $AwaitSupervisorGate) { throw 'Worker requires the assigned supervisor job gate.' }
    $gate = [Console]::In.ReadLineAsync()
    if (-not $gate.Wait(30000) -or $gate.Result -cne $AuthorizationSha256) {
        throw 'Supervisor job gate was not released.'
    }
    $safeWorkerOutput = Assert-CapArtifactPath -Root $root -Path $auth.outputDirectory
    Set-CapTracePath -Path (Join-Path $safeWorkerOutput 'worker-calls.jsonl')
    Write-CapTrace -Command 'Invoke-UiCaptureWorker' -Parameters $PSBoundParameters
    $jobPath = Assert-CapOwnedPath $auth.jobPath
    $leasePath = [IO.Path]::GetFullPath($auth.leaseReceiptPath)
    $runDirectory = Assert-CapOwnedPath $auth.runDirectory
    $outputDirectory = Assert-CapOwnedPath $auth.outputDirectory
    $journalPath = Assert-CapOwnedPath $auth.processJournalPath
    $manifestPath = Assert-CapOwnedPath $auth.manifestPath
    $workerLog = Assert-CapOwnedPath $auth.workerLogPath
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $jobPath).Hash -ne $auth.jobSha256) {
        throw 'Green B job input changed after supervisor authorization.'
    }
    $jobHash = $auth.jobSha256
    $moduleHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $modulePath).Hash
    $workerHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $PSCommandPath).Hash
    $supervisorHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $auth.supervisorPath).Hash
    $preflightHash = if ($rehearsal) { $null }
        else { (Get-FileHash -Algorithm SHA256 -LiteralPath $auth.preflightReceiptPath).Hash }
    $leaseHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $leasePath).Hash
    if ($moduleHash -ne $auth.moduleSha256 -or $workerHash -ne $auth.workerSha256 -or
        $supervisorHash -ne $auth.supervisorSha256 -or $preflightHash -ne $auth.preflightReceiptSha256 -or
        $leaseHash -ne $auth.leaseReceiptSha256) {
        throw 'A reviewed capture control or authorization input changed after supervisor launch.'
    }
    if ($AuthorizationPath -ine $auth.authorizationPath) {
        throw 'Worker command-line authorization does not match the supervisor-bound record.'
    }
    $job = Read-CapBoundJson -Root $root -Reference ([pscustomobject]@{ path = $jobPath; sha256 = $jobHash })
    $lease = Read-CapBoundJson -Root $root -Reference ([pscustomobject]@{ path = $leasePath; sha256 = $leaseHash })
    if (-not $rehearsal -and $lease.fixtureMappingSha256 -ne $auth.fixtureMappingSha256) {
        throw 'Worker lease does not bind its exact owned-root fixture mapping.'
    }
    if ($lease.leaseId -ne $auth.leaseId -or $lease.jobManifestSha256 -ne $jobHash -or
        $lease.moduleSha256 -ne $moduleHash -or $lease.workerSha256 -ne $workerHash -or
        $lease.supervisorSha256 -ne $supervisorHash) {
        throw 'Worker lease no longer binds the authorized job and controls.'
    }
    $leaseWindow = Get-CapLeaseWindow -GrantedUtc $lease.grantedUtc -ExpiresUtc $lease.expiresUtc `
        -MaximumMinutes ([double]$lease.maxMinutes) -NowUtc ([DateTime]::UtcNow)
    $leaseExpiresUtc = $leaseWindow.ExpiresUtc
    $leaseDeadlineUtc = Get-CapAuthorizedWorkerDeadline -WorkerDeadlineUtc $auth.workerDeadlineUtc `
        -LeaseWindow $leaseWindow -NowUtc $leaseWindow.NowUtc
    $selfProcess = [Diagnostics.Process]::GetCurrentProcess()
    $selfIdentity = Get-CapProcessIdentity -Process $selfProcess -ExpectedImagePath $selfProcess.MainModule.FileName -Role 'b-capture-worker'
    $selfMetadata = Get-CapCurrentMetadata -Pid $PID
    if ($selfMetadata.ParentPid -ne [int]$auth.supervisorPid) {
        throw "Worker parent PID $($selfMetadata.ParentPid) is not its authorized supervisor PID $($auth.supervisorPid)."
    }
    $supervisorProcess = [Diagnostics.Process]::GetProcessById([int]$auth.supervisorPid)
    $supervisorIdentity = Get-CapProcessIdentity -Process $supervisorProcess `
        -ExpectedImagePath $auth.supervisorExecutable -Role 'b-capture-supervisor'
    if ($supervisorIdentity.CreationFileTimeUtc -ne [long]$auth.supervisorCreationFileTimeUtc) {
        throw 'Supervisor kernel generation differs from the run authorization.'
    }
    if ($journalPath -ine (Join-Path $runDirectory 'process-journal') -or
        $manifestPath -ine (Join-Path $outputDirectory 'manifest.json')) {
        throw 'Worker journal/final manifest paths differ from the numbered protocol authorization.'
    }
    $journalBinding = New-CapJournalBinding -RunId ([IO.Path]::GetFileName($runDirectory)) `
        -LeaseId $auth.leaseId -JobSha256 $jobHash -ModuleSha256 $moduleHash `
        -WorkerSha256 $workerHash -SupervisorSha256 $supervisorHash -Identity $selfIdentity
    $journalState = New-CapJournalState -Root $root -Directory $journalPath `
        -Binding $journalBinding -DeadlineUtc $leaseExpiresUtc
    Write-CapWorkerJournalSnapshot -Kind 'Bootstrap'
    if (-not $rehearsal -or $null -ne $job.PSObject.Properties['admission']) {
        $identity = Assert-CapJobIdentity -Root $root -Job $job -Lease $lease -JobSha256 $jobHash -OfflineTestData:$rehearsal
        if (($identity | ConvertTo-Json -Depth 15 -Compress) -cne ($auth.jobIdentity | ConvertTo-Json -Depth 15 -Compress)) {
            throw 'Worker recomputed job identity differs from supervisor authorization.'
        }
    }
    if ($rehearsal) {
        if ($lease.status -cne 'REHEARSAL_ONLY' -or $lease.desktopAuthorized -ne $false -or
            $lease.authorizedAction -cne 'no-desktop-real-launch-rehearsal' -or
            $job.executionMode -cne $auth.executionMode -or $job.desktopAuthorized -ne $false) {
            throw 'Rehearsal lease cannot authorize product or desktop use.'
        }
        $targetPath = Assert-CapOwnedPath $job.rehearsalTarget.path
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $targetPath).Hash -ne $job.rehearsalTarget.sha256) {
            throw 'Harmless target changed after supervisor authorization.'
        }
        if ($job.PSObject.Properties['sceneAdapter'] -and $job.sceneAdapter -ceq 'D_QUICK_CHAT_V1') {
            Assert-CapSceneContract -Job $job
            $proof=Assert-CapFixtureMapping -Root $root -FixturePath $fixturePath `
                -SourcePath (Join-Path $root 'inputs\fixture-source.json') -MappingPath (Join-Path $root 'reports\fixture-mapping.json') `
                -ExpectedMappingSha256 $auth.fixtureMappingSha256 -ExpectedSourceSha256 $job.fixture.sha256 `
                -OriginalRoot $job.fixture.originalRoot -SceneAdapter $job.sceneAdapter -ExpectedPeerSha256 $job.fixture.offlinePeerReference.sha256
            $fixtureHash=$proof.FixtureSha256
        }
    } else {
    Assert-CapAcceptedInputs
    $zmxHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root 'runtime\zmx.exe')).Hash
    $beforeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root 'inputs\graphcode-before.exe')).Hash
    $afterHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root 'inputs\graphcode-after.exe')).Hash
    if ($zmxHash -ne $job.binaries.offlineZmx.sha256 -or
        $beforeHash -ne $job.binaries.before.sha256 -or $afterHash -ne $job.binaries.after.sha256) {
        throw 'Copied B executable or pinned zmx binary no longer matches the accepted job.'
    }
    $fixtureHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixturePath).Hash
    }
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        throw "Supervisor did not pre-create the authorized output directory: $outputDirectory"
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $manifestPath) -Force | Out-Null
    [IO.File]::WriteAllText($workerLog, '', [Text.UTF8Encoding]::new($false))
    Write-CapWorkerLog "WORKER_STARTED lease=$($auth.leaseId) head=$($job.head) job=$jobHash deadline=$($leaseDeadlineUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture))"
    if ($rehearsal) {
        Invoke-CapRealSeedRehearsal
        Invoke-CapRealLaunchRehearsal
    } else {
    if (Test-CapMatchedAdapter) {
        foreach ($name in @('GH_TOKEN','GITHUB_TOKEN','COPILOT_GITHUB_TOKEN','COPILOT_API_KEY','ANTHROPIC_API_KEY',
            'OPENAI_API_KEY','AZURE_OPENAI_API_KEY','CODEX_API_KEY','SSH_AUTH_SOCK','SSH_AGENT_PID',
            'AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY','AWS_SESSION_TOKEN')) {
            [Environment]::SetEnvironmentVariable($name,$null,'Process')
        }
        $matchedFixture=Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -DateKind String
        Initialize-CapMatchedWorktrees -Fixture $matchedFixture
    }
    foreach ($phase in @('before', 'after')) {
        Assert-CapWorkerDeadline "starting phase $phase"
        if (Test-CapMatchedAdapter) {Invoke-CapMatchedScenes -Phase $phase}
        elseif ($job.sceneAdapter -ceq 'D_QUICK_CHAT_V1') {Invoke-CapDScenes -Phase $phase}
        else {Invoke-CapNormalScenes -Phase $phase;Invoke-CapActionsScene -Phase $phase}
    }
    $expectedImages=if (Test-CapMatchedAdapter) {36} elseif ($job.sceneAdapter -ceq 'D_QUICK_CHAT_V1') {20} else {10}
    $expectedSeeds=if (Test-CapMatchedAdapter) {22} elseif ($job.sceneAdapter -ceq 'D_QUICK_CHAT_V1') {4} else {2}
    if ($images.Count -ne $expectedImages) { throw "Expected $expectedImages images across before/after; captured $($images.Count)." }
    if ($zmxSeedReceipts.Count -ne $expectedSeeds -or @($zmxSeedReceipts | Where-Object {
        $_.exitCode -ne 0 -or -not $_.daemonReady -or $_.cmdCount -lt 1 -or
        $_.cleanupStatus -ne 'CLEAN_ZERO_SURVIVORS_FILES_CLOSED' -or
        $null -eq $_.outputProof -or -not $_.outputProof.jobActive0
    }).Count -ne 0) {
        throw 'Both phase-private cmd-only zmx seeds must exit zero, become ready, and cleanly drain EOF.'
    }
    }
} catch {
    $primaryFailure = $_
    Write-CapWorkerLog "WORKER_FAILURE=$($_.Exception.ToString())"
} finally {
    if (Get-Command Resolve-CapPendingLaunches -ErrorAction SilentlyContinue) {
        try {
            foreach ($receipt in @(Resolve-CapPendingLaunches)) { $cleanupReceipts.Add($receipt) }
            if (@(Get-CapPendingLaunches).Count -gt 0) { throw 'Pending real launches remain unresolved.' }
        } catch { $cleanupFailures.Add("Pending launch cleanup failed: $($_.Exception.Message)") }
        try { $pendingLaunchesRemaining = @(Get-CapPendingLaunches) }
        catch {
            $cleanupFailures.Add("Pending launch evidence failed: $($_.Exception.Message)")
            $pendingLaunchesRemaining = @([pscustomobject]@{ State = 'UNKNOWN'; Failure = $_.Exception.ToString() })
        }
    }
    foreach ($appRun in @($applicationRuns | Sort-Object { $_.Run.StartedUtc } -Descending)) {
        try { Close-CapGraphCodeApp -AppRun $appRun }
        catch { $cleanupFailures.Add("Final app cleanup failed for PID $($appRun.Run.Identity.Pid): $($_.Exception.Message)") }
    }
    foreach ($seedRun in @($seedRuns | Sort-Object StartedUtc -Descending)) {
        try { Close-CapOfflineSeed -SeedRun $seedRun }
        catch { $cleanupFailures.Add("Final zmx seed cleanup failed for PID $($seedRun.Identity.Pid): $($_.Exception.Message)") }
    }
    foreach ($run in @($runs | Where-Object { $_.Identity.Role -like 'offline-fixture-peer-*' })) {
        try {
            if (-not [CapNative]::IsExited($run.Identity.Process.Handle, $run.Identity.Pid)) {
                $receipt = Stop-CapManagedProcess -Identity $run.Identity -TimeoutMilliseconds 5000
                $cleanupReceipts.Add($receipt)
            }
            Write-CapRunStreams -Run $run -Label $run.Identity.Role
        } catch {
            $cleanupFailures.Add("Final peer cleanup failed for PID $($run.Identity.Pid): $($_.Exception.Message)")
        }
    }
    foreach ($run in $runs) {
        if (-not [CapNative]::IsExited($run.Identity.Process.Handle, $run.Identity.Pid)) {
            $cleanupFailures.Add("Owned process survived final cleanup: role=$($run.Identity.Role) pid=$($run.Identity.Pid).")
        }
    }
    foreach ($identity in $descendantIdentities) {
        if (-not [CapNative]::IsExited($identity.Process.Handle, $identity.Pid)) {
            $cleanupFailures.Add("Owned descendant survived final cleanup: role=$($identity.Role) pid=$($identity.Pid).")
        }
        if (Get-Command Get-CapTraceFailures -ErrorAction SilentlyContinue) {
            foreach ($failure in @(Get-CapTraceFailures)) { $cleanupFailures.Add("Call tracing failed: $($failure.failure)") }
        }
    }
    $ownedProcessSurvivors = @(
        @($runs | Where-Object { -not [CapNative]::IsExited($_.Identity.Process.Handle, $_.Identity.Pid) } |
            ForEach-Object { [pscustomobject]@{ role = $_.Identity.Role; pid = $_.Identity.Pid } }) +
        @($descendantIdentities | Where-Object { -not [CapNative]::IsExited($_.Process.Handle, $_.Pid) } |
            ForEach-Object { [pscustomobject]@{ role = $_.Role; pid = $_.Pid } }) +
        @($pendingLaunchesRemaining | Where-Object { $_.PSObject.Properties['KernelExited'] -and $_.KernelExited -eq $false } |
            ForEach-Object { [pscustomobject]@{ role = $_.Role; pid = $_.Pid
                creationFileTimeUtc = $_.CreationFileTimeUtc; expectedImagePath = $_.ExpectedPath; state = 'KERNEL_LIVE_UNRETURNED_LAUNCH' } })
    )
    try { $ownedProcessReceipts = @(Get-CapWorkerProcessReceipts) }
    catch { $cleanupFailures.Add("Owned process/stream inventory failed: $($_.Exception.Message)") }
    if ($journalState -and $auth) {
        try {
            $null = Assert-CapNoWorkerTransientArtifacts -Directories @($runDirectory, $outputDirectory)
            if (@(Get-CapTraceFailures).Count -ne 0) { throw 'Worker trace evidence failed.' }
        } catch { $cleanupFailures.Add("Final process journal update failed: $($_.Exception.Message)") }
    }
    foreach ($run in $runs) { $run.Identity.Process.Dispose() }
    foreach ($identity in $descendantIdentities) { $identity.Process.Dispose() }
    if ($manifestPath -and $job -and $auth -and $journalState) {
        $finalStatus = if (-not $primaryFailure -and $cleanupFailures.Count -eq 0 -and
            (($rehearsal -and $rehearsalLaunches.Count -eq 1 -and $images.Count -eq 0) -or
            (-not $rehearsal -and $images.Count -eq $(if (Test-CapMatchedAdapter) {36} else {10})))) {
            'COMPLETE'
        } else { 'FAILED' }
        try {
            Write-CapWorkerJournalSnapshot -Kind 'Terminal' -Outcome $finalStatus
            $manifest = New-CapManifest -Status $finalStatus
            if ($primaryFailure) { $manifest.failures += "Worker failure: $($primaryFailure.Exception.ToString())" }
            $manifest['journal'] = [pscustomobject]@{
                protocolVersion = 2L; binding = $journalState.Binding; directory = $journalPath
                terminal = $journalState.Terminal; published = @($journalState.Published.ToArray())
            }
            $manifestReference = Write-CapImmutableJson -Root $root -Path $manifestPath -Value $manifest
            $null = Assert-CapNoWorkerTransientArtifacts -Directories @($runDirectory, $outputDirectory)
            $journalFinalLine = Format-CapJournalFinalRecord -Binding $journalState.Binding `
                -Manifest $manifestReference -Terminal $journalState.Terminal
            $journalFinalCleanupCount = $cleanupFailures.Count
        } catch { $cleanupFailures.Add("Final manifest write failed: $($_.Exception.Message)") }
    }
}

if ($journalFinalLine) {
    if (-not $primaryFailure -and $cleanupFailures.Count -eq 0) {
        try { Write-CapWorkerLog "WORKER_COMPLETE images=$($images.Count) lease=$($auth.leaseId)" }
        catch { $cleanupFailures.Add("Completion logging failed: $($_.Exception.Message)") }
    }
    foreach ($run in $runs) {
        if ($run.PSObject.Properties['OutputPins']) {
            foreach ($pin in @($run.OutputPins) + @($run.ClosedOutputPins)) { $pin.Dispose() }
        }
    }
    if (@(Get-CapTraceFailures).Count -eq 0 -and $cleanupFailures.Count -eq $journalFinalCleanupCount) {
        [Console]::Out.WriteLine($journalFinalLine)
        [Console]::Out.Flush()
    } else { $cleanupFailures.Add('Final worker trace evidence failed; final record withheld.') }
}
if ($cleanupFailures.Count -gt 0) {
    throw "Capture worker cleanup was incomplete: $($cleanupFailures -join '; ')"
}
if ($primaryFailure) { throw $primaryFailure }
