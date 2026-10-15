param(
    [Parameter(Mandatory)][string]$OwnedRoot,
    [Parameter()][string]$AuthorizationPath,
    [Parameter()][string]$AuthorizationSha256,
    [Parameter()][switch]$DefinitionsOnly
)
$ErrorActionPreference = 'Stop'
# Promoted from Invoke-BCaptureWorker.ps1, FSL-1.1-MIT.
# SHA256 CDB5FFEDF2848F136DD44CFFF61CAF3048E733D67E16F0F9E28C27DEA5EB6D9E.
$root = [IO.Path]::GetFullPath($OwnedRoot).TrimEnd('\')
$modulePath = Join-Path $PSScriptRoot 'UiCaptureDriver.psm1'
$rehearsal = $false
$rehearsalLaunches = [Collections.Generic.List[object]]::new()
$peerScript = Join-Path $root 'inputs\offline-peer-source.ps1'
$fixturePath = Join-Path $root 'fixtures\fixture.json'
$journalPath = $null
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
    Write-CapJsonAtomic -Path $journalPath -Value ([ordered]@{
        schemaVersion = 1
        leaseId = $auth.leaseId
        jobSha256 = $jobHash
        workerSha256 = $workerHash
        moduleSha256 = $moduleHash
        updatedUtc = [DateTime]::UtcNow.ToString('o')
        entries = @($journalEntries)
    })
}

function Assert-CapAcceptedInputs {
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    Assert-CapSceneContract -Job $job
    if ($job.authority.centralCaptureLeaseGrantedByThisArtifact -ne $false -or
        $lease.status -ne 'GRANTED' -or $lease.lane -ne 'B' -or
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
        -ExpectedSourceSha256 $job.fixture.sha256 -OriginalRoot $job.fixture.originalRoot
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
    foreach ($name in @('support', 'local', 'profile', 'temp', 'tmp', 'zmx', 'peer')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $phaseRoot $name) -Force
    }
    $support = Join-Path $phaseRoot 'support'
    [IO.File]::WriteAllText((Join-Path $support 'onboarding-seen'), '1', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $support 'settings.json'),
        '{"defaultBackend":"copilotCLI","showsActivityStrip":true,"briefsSessionsAboutTheGraph":false}',
        [Text.UTF8Encoding]::new($false))
    $zmx = Join-Path $phaseRoot 'zmx'
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
    $run = Start-CapManagedProcess -FilePath $pwshPath -ArgumentList @(
        '-NoProfile', '-File', $peerScript, '-PipeName', $PipeName, '-FixturePath', $fixturePath
    ) -WorkingDirectory $Roots.Peer -Role "offline-fixture-peer-$Phase" -Environment @{
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
        [Parameter(Mandatory)][string]$Phase
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    $arguments = @($job.binaries.offlineZmx.seedArgumentOrder | ForEach-Object { [string]$_ })
    if ($arguments.Count -ne 7 -or $arguments[0] -cne 'run' -or
        $arguments[1] -cne 'graphcode-11111111-1111-4111-8111-000000000001' -or
        $arguments[2] -cne '-d' -or $arguments[3] -cne 'cmd.exe' -or
        $arguments[4] -cne '/Q' -or $arguments[5] -cne '/K' -or
        $arguments[6] -cne 'echo Offline card fixture - no backend') {
        throw 'The B job does not contain the exact seven-argument offline cmd-only zmx seed.'
    }
    $zmxRoot = Assert-CapOwnedPath $Roots.Zmx
    $zmxWorking = Assert-CapOwnedPath (Join-Path $Roots.Peer 'zmx-cwd')
    New-Item -ItemType Directory -Path $zmxWorking -Force | Out-Null
    $environment = @{
        ZMX_DIR = $zmxRoot
    }
    $zmxPath = Join-Path $root 'runtime\zmx.exe'
    $run = Start-CapManagedProcess -FilePath $zmxPath -ArgumentList $arguments `
        -WorkingDirectory $zmxWorking -Role 'zmx-seed' -Environment $environment
    $run | Add-Member -NotePropertyName Phase -NotePropertyValue $Phase
    $run | Add-Member -NotePropertyName SessionName -NotePropertyValue $arguments[1]
    $run | Add-Member -NotePropertyName Descendants -NotePropertyValue @()
    $run | Add-Member -NotePropertyName CleanupComplete -NotePropertyValue $false
    $runs.Add($run)
    $seedRuns.Add($run)
    Write-CapProcessJournal -Identity $run.Identity -Phase $Phase
    $receipt = [pscustomobject]@{
        phase = $Phase
        sessionName = $run.SessionName
        argumentList = @($arguments)
        exitCode = $null
        seedPid = $run.Identity.Pid
        seedCreationFileTimeUtc = $run.Identity.CreationFileTimeUtc
        expectedImagePath = $run.Identity.ExpectedImagePath
        zmxRoot = $zmxRoot
        supportRoot = $Roots.Support
        seedExitedUtc = $null
        daemonReady = $false
        daemonCount = 0
        cmdCount = 0
        descendants = @()
        stdoutEof = $false
        stderrEof = $false
        cleanupStatus = 'PENDING'
        cleanup = @()
    }
    $run | Add-Member -NotePropertyName SeedReceipt -NotePropertyValue $receipt
    $zmxSeedReceipts.Add($receipt)
    $seedReceiptPath = Join-Path $runDirectory "phases\$Phase\normal\zmx-seed.json"
    Write-CapJsonAtomic -Path $seedReceiptPath -Value $receipt

    $seedDeadline = [DateTime]::UtcNow.AddSeconds(20)
    if ($seedDeadline -gt $leaseDeadlineUtc) { $seedDeadline = $leaseDeadlineUtc }
    $seedWait = Wait-CapManagedProcess -Run $run -DeadlineUtc $seedDeadline -PollMilliseconds 50
    if ($seedWait.State -ne 'Exited') { throw "Pinned zmx seed did not exit before the bounded $Phase deadline." }
    $exitCode = [int]$seedWait.ExitCode
    $receipt.exitCode = $exitCode
    $receipt.seedExitedUtc = $seedWait.CompletedUtc.ToString('o')
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
        $tree = @(Get-CapOwnedDescendants -Roots @($run.Identity) -ZmxPath $zmxPath `
            -CmdPath $cmdPath -ConhostPath $conhostPath -SessionName $run.SessionName `
            -CommandMarker $arguments[6].Substring(5))
        $daemons = @($tree | Where-Object Role -eq 'zmx-daemon')
        $cmdPeers = @($tree | Where-Object Role -eq 'offline-cmd-peer')
        if ($daemons.Count -gt 0 -and $cmdPeers.Count -gt 0) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $readyDeadline)
    if ($daemons.Count -lt 1 -or $cmdPeers.Count -lt 1) {
        throw "Private $Phase zmx seed did not become ready with an owned daemon and cmd peer."
    }
    foreach ($identity in $tree) {
        if ($identity.Role -notin @('zmx-daemon', 'offline-cmd-peer', 'conpty-conhost')) {
            throw "Unrecognized live $Phase zmx descendant role '$($identity.Role)'; refusing."
        }
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
        [switch]$AllowOffscreen
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    while ([DateTime]::UtcNow -lt $leaseDeadlineUtc) {
        Assert-CapWorkerDeadline "UIA element $Name"
        try {
            return Find-CapAutomationElement -RootHandle $Window -ProcessIdentity $ProcessIdentity `
                -Name $Name -AutomationId $AutomationId -AutomationIdPrefix $AutomationIdPrefix `
                -AllowOffscreen:$AllowOffscreen
        } catch {
            if ($_.Exception.Message -notmatch 'found=0\.') { throw }
            Start-Sleep -Milliseconds 100
        }
    }
    throw "UIA element '$Name' did not become available before the reserved deadline."
}

function Invoke-CapSceneAction {
    param(
        [Parameter(Mandatory)]$AppRun,
        [Parameter(Mandatory)][string]$Action,
        [string]$Name
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    Assert-CapWorkerDeadline "before action $Action"
    $result = Invoke-CapAction -Action $Action -Name $Name -RootHandle $AppRun.Window `
        -ProcessIdentity $AppRun.Run.Identity
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
    return Measure-CapZoom -Element $element -NaturalWidth $NaturalWidth
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
    if ((Compare-Object $expectedOuter @($metrics.OuterBounds)) -or $metrics.Dpi -ne 96 -or
        $metrics.ClientBounds[2] -ne 1440 -or $metrics.ClientBounds[3] -ne 900) {
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
    Write-CapJsonAtomic -Path $manifestPath -Value (New-CapManifest -Status 'CAPTURING')
    Write-CapWorkerLog "IMAGE phase=$Phase scene=$SceneName sha256=$($capture.Sha256) size=$($capture.Width)x$($capture.Height) dpi=$($capture.Dpi) colors=$($capture.SampledColors)"
}

function New-CapManifest {
    param([Parameter(Mandatory)][string]$Status)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    return [ordered]@{
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
        privacyRequirement = 'Every image requires an individual privacy check before reviewer handoff.'
    }
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
            CAP_REHEARSAL_BEHAVIOR = $job.rehearsalTarget.behavior
            CAP_REHEARSAL_OUTPUT = $outputDirectory
        }
    } else {
        Get-CapBaseEnvironment -Roots $Roots -PipeName $PipeName -SessionPrefix $SessionPrefix `
            -ActionsFixture:$ActionsFixture
    }
    $arguments = if ($rehearsal) { [string[]]@($job.rehearsalTarget.arguments) } else { [string[]]@() }
    if ($rehearsal) { $role = 'rehearsal-target' }
    $workingDirectory = if ($rehearsal) { $Roots.Peer } else { Join-Path $root 'fixtures\projects\Alpha' }
    $run = Start-CapManagedProcess -FilePath $binaryPath -ArgumentList ([string[]]@($arguments)) `
        -WorkingDirectory $workingDirectory -Role $role -Environment $envMap -CloseStdin:$rehearsal
    $runs.Add($run)
    $appRun = New-CapAppRunRecord -Run $run -Phase $Phase -SessionPrefix $SessionPrefix
    $applicationRuns.Add($appRun)
    Write-CapProcessJournal -Identity $run.Identity -Phase $Phase
    if ($rehearsal) { return $appRun }
    $window = Find-CapTopLevelWindow -ProcessIdentity $run.Identity -TimeoutSeconds 30 -DeadlineUtc $leaseDeadlineUtc
    $appRun.Window = $window
    Write-CapProcessJournal -Identity $run.Identity -Phase $Phase -Window $window
    Set-CapWindowPosition -Window $window -ProcessIdentity $run.Identity
    Start-Sleep -Milliseconds 500
    $metrics = Get-CapWindowMetrics -Window $window -ProcessIdentity $run.Identity
    if ($metrics.Dpi -ne 96) { throw "Actual app DPI is $($metrics.Dpi), expected 96." }
    return $appRun
}

function Get-CapTreeForApp {
    param([Parameter(Mandatory)]$AppRun)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    $tree = @(Get-CapOwnedDescendants -Roots @($AppRun.Run.Identity) `
        -ZmxPath (Join-Path $root 'runtime\zmx.exe') `
        -CmdPath (Join-Path ([Environment]::SystemDirectory) 'cmd.exe') `
        -ConhostPath (Join-Path ([Environment]::SystemDirectory) 'conhost.exe') `
        -SessionName $AppRun.SessionPrefix -CommandMarker $AppRun.SessionPrefix `
        -AllowGraphCodeRoot -AllowUnmarkedCmd)
    foreach ($identity in $tree) {
        Write-CapProcessJournal -Identity $identity -Phase $AppRun.Phase
        if (-not @($descendantIdentities | Where-Object {
            $_.Pid -eq $identity.Pid -and $_.CreationFileTimeUtc -eq $identity.CreationFileTimeUtc
        }).Count) {
            $descendantIdentities.Add($identity)
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
                $null = Get-CapTreeForApp -AppRun $AppRun
                foreach ($identity in @($descendantIdentities | Where-Object {
                    $_.Role -in @('offline-cmd-peer', 'conpty-conhost', 'zmx-daemon') -and
                    $_.Process.Id -ne $run.Identity.Pid
                } | Sort-Object CreationFileTimeUtc -Descending)) {
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
        $tree = @(Get-CapTreeForApp -AppRun $AppRun)
        foreach ($identity in @($tree | Sort-Object CreationFileTimeUtc -Descending)) {
            $receipt = Stop-CapManagedProcess -Identity $identity -TimeoutMilliseconds 5000
            $cleanupReceipts.Add($receipt)
        }
    } catch {
        $cleanupFailures.Add("Post-exit descendant discovery failed for PID $($run.Identity.Pid): $($_.Exception.Message)")
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

function Close-CapOfflineSeed {
    param([Parameter(Mandatory)]$SeedRun)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

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
    $seedReceiptPath = Join-Path $runDirectory "phases\$($SeedRun.Phase)\normal\zmx-seed.json"
    try { Write-CapJsonAtomic -Path $seedReceiptPath -Value $SeedRun.SeedReceipt }
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
    if ($seed -and $seed.SeedReceipt.cleanupStatus -ne 'CLEAN_ZERO_SURVIVORS_EOF') {
        throw "Private zmx seed cleanup did not prove zero survivors and EOF for $Phase."
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
        Write-CapJsonAtomic -Path $manifestPath -Value (New-CapManifest -Status 'CAPTURING')
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
        Invoke-CapRealLaunchRehearsal
    } else {
    foreach ($phase in @('before', 'after')) {
        Assert-CapWorkerDeadline "starting phase $phase"
        Invoke-CapNormalScenes -Phase $phase
        Invoke-CapActionsScene -Phase $phase
    }
    if ($images.Count -ne 10) { throw "Expected ten images across before/after; captured $($images.Count)." }
    if ($zmxSeedReceipts.Count -ne 2 -or @($zmxSeedReceipts | Where-Object {
        $_.exitCode -ne 0 -or -not $_.daemonReady -or $_.cmdCount -lt 1 -or
        $_.cleanupStatus -ne 'CLEAN_ZERO_SURVIVORS_EOF' -or
        -not $_.stdoutEof -or -not $_.stderrEof
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
    if ($journalPath -and $auth) {
        try {
            Write-CapJsonAtomic -Path $journalPath -Value ([ordered]@{
                schemaVersion = 1; leaseId = $auth.leaseId; jobSha256 = $jobHash
                workerSha256 = $workerHash; moduleSha256 = $moduleHash
                updatedUtc = [DateTime]::UtcNow.ToString('o'); entries = @($journalEntries)
                ownedProcessSurvivors = @($ownedProcessSurvivors)
                pendingLaunchesRemaining = @($pendingLaunchesRemaining)
                cleanupFailures = @($cleanupFailures)
            })
        } catch { $cleanupFailures.Add("Final process journal update failed: $($_.Exception.Message)") }
    }
    foreach ($run in $runs) { $run.Identity.Process.Dispose() }
    foreach ($identity in $descendantIdentities) { $identity.Process.Dispose() }
    if ($manifestPath -and $job -and $auth) {
        $finalStatus = if (-not $primaryFailure -and $cleanupFailures.Count -eq 0 -and
            (($rehearsal -and $rehearsalLaunches.Count -eq 1 -and $images.Count -eq 0) -or
            (-not $rehearsal -and $images.Count -eq 10))) {
            'COMPLETE'
        } else { 'FAILED' }
        try {
            $manifest = New-CapManifest -Status $finalStatus
            if ($primaryFailure) { $manifest.failures += "Worker failure: $($primaryFailure.Exception.ToString())" }
            if ($finalStatus -eq 'COMPLETE') {
                $finalManifest = Join-Path $outputDirectory 'manifest.json'
                if (Test-Path -LiteralPath $finalManifest) { throw "Refusing to replace prior final manifest: $finalManifest" }
                Write-CapJsonAtomic -Path $finalManifest -Value $manifest
            } else {
                Write-CapJsonAtomic -Path $manifestPath -Value $manifest
            }
        } catch { $cleanupFailures.Add("Final manifest write failed: $($_.Exception.Message)") }
    }
}

if ($cleanupFailures.Count -gt 0) {
    throw "Capture worker cleanup was incomplete: $($cleanupFailures -join '; ')"
}
if ($primaryFailure) { throw $primaryFailure }
Write-CapWorkerLog "WORKER_COMPLETE images=$($images.Count) lease=$($auth.leaseId)"
