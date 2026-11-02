[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $DaemonExecutable,
  [Parameter(Mandatory)]
  [string] $ScratchRoot,
  [string] $ZigExecutable = $env:GRAPHCODE_ZIG0152,
  [string] $WinghosttyInclude = $(if ($env:GRAPHCODE_WINGHOSTTY_ROOT) {
      Join-Path $env:GRAPHCODE_WINGHOSTTY_ROOT "include"
    })
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\OwnedLiveProcess.ps1")
. (Join-Path $PSScriptRoot "ValidationFixtureDirectory.ps1")
Import-Module (Join-Path $PSScriptRoot "..\ShellProcessOwnership.psm1") -Force
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$shellRoot = Join-Path $repoRoot "graphcode-windows"
$DaemonExecutable = (Resolve-Path -LiteralPath $DaemonExecutable).Path
$ZigExecutable = (Resolve-Path -LiteralPath $ZigExecutable).Path
$WinghosttyInclude = (Resolve-Path -LiteralPath $WinghosttyInclude).Path
$ScratchRoot = [IO.Path]::GetFullPath($ScratchRoot)
if (-not (Test-Path -LiteralPath $DaemonExecutable -PathType Leaf)) {
  throw "real graphcoded.exe is missing: $DaemonExecutable"
}
if (-not (Test-Path -LiteralPath $ZigExecutable -PathType Leaf)) {
  throw "pinned Zig executable is missing: $ZigExecutable"
}
if (-not (Test-Path -LiteralPath $WinghosttyInclude -PathType Container)) {
  throw "pinned Winghostty headers are missing: $WinghosttyInclude"
}
if (-not (Test-Path -LiteralPath $ScratchRoot -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $ScratchRoot | Out-Null
}

$nonce = [guid]::NewGuid().ToString("N")
$runRoot = Join-Path $ScratchRoot "daemon-roundtrip-$nonce"
$supportDirectory = Join-Path $runRoot "support"
$sessionDirectory = Join-Path $supportDirectory "sessions"
$projectPath = Join-Path $runRoot "project"
$spawnProjectPath = Join-Path $runRoot "spawn-target"
$evidenceDirectory = Join-Path $ScratchRoot "daemon-roundtrip-evidence"
$tempDirectory = Join-Path $runRoot "temp"
$zigLocalCache = Join-Path $runRoot "zig-local-cache"
$zigGlobalCache = Join-Path $runRoot "zig-global-cache"
$daemonPipe = "\\.\pipe\graphcode-daemon-roundtrip-$PID-$nonce"
$shutdownEventName = "Local\GraphCode-daemon-roundtrip-shutdown-$PID-$nonce"
$projectNodeSketch = "A1111111-1111-4111-8111-111111111111"
$projectNodeDetails = "B2222222-2222-4222-8222-222222222222"
$sessionMarkerPath = Join-Path $sessionDirectory "$projectNodeSketch.id"
$sessionMarker = "daemon-roundtrip-session-preserved"
$canonicalProjectPath = $projectPath.Replace('\', '/')
$expectedDaemonPath = [IO.Path]::GetFullPath($DaemonExecutable)
$defaultSupportDirectory = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".graphcode"
$successful = $false
$shutdownEvent = $null
$daemonProcess = $null
$processScope = $null
$runLog = [Collections.Generic.List[string]]::new()

function Get-DefaultSupportSignature {
  if (-not (Test-Path -LiteralPath $defaultSupportDirectory -PathType Container)) {
    return "<missing>"
  }
  $records = [Collections.Generic.List[string]]::new()
  foreach ($entry in Get-ChildItem -LiteralPath $defaultSupportDirectory -Force -Recurse) {
    $relative = $entry.FullName.Substring($defaultSupportDirectory.Length).TrimStart('\')
    if ($entry.PSIsContainer) {
      $records.Add("D|$relative")
    } else {
      $hash = (Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash
      $records.Add("F|$relative|$($entry.Length)|$hash")
    }
  }
  return ($records | Sort-Object) -join "`n"
}

function Get-OwnedDaemon([int] $processId) {
  return @(
    Get-CimInstance Win32_Process -ErrorAction Stop |
      Where-Object {
        $_.Name -ieq "graphcoded.exe" -and
        [int]$_.ProcessId -eq $processId -and
        [int]$_.ParentProcessId -eq $PID -and
        $_.ExecutablePath -and
        [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $expectedDaemonPath
      }
  )
}

function Start-OwnedDaemon {
  [void] $script:shutdownEvent.Reset()
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $expectedDaemonPath
  $startInfo.WorkingDirectory = Split-Path -Parent $expectedDaemonPath
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($name in @(
      "GRAPHCODE_DAEMON_STARTUP_EVENT",
      "GRAPHCODE_DAEMON_HANDOFF_READY_EVENT",
      "GRAPHCODE_DAEMON_HANDOFF_TEST_STATE",
      "GRAPHCODE_DAEMON_SUPERVISOR_TEST_HOOK",
      "GRAPHCODE_DAEMON_SHUTDOWN_EVENT",
      "GRAPHCODE_SOCKET")) {
    [void] $startInfo.Environment.Remove($name)
  }
  $startInfo.Environment["GRAPHCODE_SUPPORT_DIR"] = $supportDirectory
  $startInfo.Environment["GRAPHCODE_SOCKET"] = $daemonPipe
  $startInfo.Environment["GRAPHCODE_DAEMON_PIPE"] = $daemonPipe
  $startInfo.Environment["GRAPHCODE_DAEMON_SHUTDOWN_EVENT"] = $shutdownEventName

  $process = $null
  $started = $false
  $handleHeld = $false
  try {
    $process = Start-ShellOwnedProcess $processScope $startInfo
    $started = $true
    [void] $process.Handle
    $handleHeld = $true
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
      $process.Refresh()
      if ($process.HasExited) {
        Complete-ShellOwnedProcess $processScope $process
        $stderr = Read-ShellOwnedOutput $processScope $process -StandardError
        throw "graphcoded.exe exited during startup: $stderr"
      }
      if (@(Get-OwnedDaemon $process.Id).Count -eq 1) {
        # A PID exists before the lifetime mutex and listener are initialized. This is
        # especially observable on restart, when the Zig test executable is already built.
        $readyPipe = [IO.Pipes.NamedPipeClientStream]::new(".", $daemonPipe.Substring(9),
          [IO.Pipes.PipeDirection]::InOut)
        try {
          $readyPipe.Connect(15000)
        } catch {
          throw [InvalidOperationException]::new(
            "Owned daemon did not publish its listener before the round-trip test.", $_.Exception)
        } finally {
          $readyPipe.Dispose()
        }
        return $process
      }
      Start-Sleep -Milliseconds 100
    }
    throw "graphcoded.exe did not appear as a child at its exact executable path"
  } catch {
    $startupError = $_
    $cleanupErrors = [Collections.Generic.List[Exception]]::new()
    try {
      if ($started) {
        if (-not $handleHeld) {
          throw "The started daemon's original process handle was not acquired; no termination attempted."
        }
        Stop-OwnedLiveProcess -Process $process -Name "round-trip daemon startup" `
          -TimeoutMilliseconds 5000
      }
    } catch {
      $cleanupErrors.Add($_.Exception)
    } finally {
      if ($process) {
        try { $process.Dispose() } catch { $cleanupErrors.Add($_.Exception) }
      }
    }
    if ($cleanupErrors.Count -gt 0) {
      $cleanupErrors.Insert(0, $startupError.Exception)
      throw (New-OwnedLiveProcessCleanupError `
        -Message "Round-trip daemon startup cleanup could not be verified; fixture root: $runRoot" `
        -Errors ([Exception[]]$cleanupErrors.ToArray()) -RetainedRoots @($runRoot))
    }
    throw $startupError
  }
}

function Stop-OwnedDaemon([Diagnostics.Process] $process) {
  if (-not $process) { return }
  $process.Refresh()
  if (-not $process.HasExited) {
    [void] $shutdownEvent.Set()
    if (-not $process.WaitForExit(15000)) {
      throw "graphcoded.exe did not exit after its named shutdown event"
    }
  }
  $process.Refresh()
  if (-not $process.HasExited) {
    throw "graphcoded.exe is still running after shutdown"
  }
  Complete-ShellOwnedProcess $processScope $process
  $script:runLog.Add("daemon-exit pid=$($process.Id) code=$($process.ExitCode)")
  $stdout = Read-ShellOwnedOutput $processScope $process
  $stderr = Read-ShellOwnedOutput $processScope $process -StandardError
  $script:runLog.Add("daemon-stdout=$($stdout.Trim())")
  $script:runLog.Add("daemon-stderr=$($stderr.Trim())")
}

function Invoke-ZigTest([string] $label, [string] $filter) {
  $env:GRAPHCODE_DAEMON_ROUNDTRIP_PROJECT = $projectPath
  $env:GRAPHCODE_DAEMON_ROUNDTRIP_SPAWN_PROJECT = $spawnProjectPath
  $env:GRAPHCODE_LOCAL_TEST_SUPPORT = $supportDirectory
  $env:ZIG_LOCAL_CACHE_DIR = $zigLocalCache
  $env:ZIG_GLOBAL_CACHE_DIR = $zigGlobalCache
  $testInfo = [Diagnostics.ProcessStartInfo]::new()
  $testInfo.FileName = $ZigExecutable
  $testInfo.WorkingDirectory = $shellRoot
  $testInfo.UseShellExecute = $false
  foreach ($argument in @(
      "test", "src\DaemonRoundTripTests.zig",
      "-target", "x86_64-windows-msvc", "-lc", "-ladvapi32", "-I$WinghosttyInclude",
      "--cache-dir", $zigLocalCache, "--global-cache-dir", $zigGlobalCache,
      "--test-filter", $filter)) {
    [void]$testInfo.ArgumentList.Add($argument)
  }
  $result = Invoke-OwnedLiveCommand -Scope $processScope -StartInfo $testInfo
  $exitCode = $result.ExitCode
  $global:LASTEXITCODE = $exitCode
  $text = @($result.Output, $result.Error) -join "`n"
  [Console]::WriteLine($text)
  $logPath = Join-Path $evidenceDirectory "daemon-roundtrip-$nonce-$label.log"
  [IO.File]::WriteAllText($logPath, "$text`n", [Text.UTF8Encoding]::new($false))
  $runLog.Add("$label-log=$logPath")
  if ($exitCode -ne 0) {
    throw "$label daemon round-trip test failed with exit code $exitCode; see $logPath"
  }
  $count = 0
  if ($text -match '(?m)All\s+(\d+)\s+tests?\s+passed') {
    $count = [int]$Matches[1]
  } elseif ($text -match '(?m)(\d+)/(\d+)\s+tests?\s+passed') {
    $count = [int]$Matches[1]
  }
  if ($count -lt 1) {
    throw "$label did not report a positive executed test count; see $logPath"
  }
  $runLog.Add("$label-tests=$count")
}

function Get-SavedProjectGraph {
  $projectsDirectory = Join-Path $supportDirectory "projects"
  if (-not (Test-Path -LiteralPath $projectsDirectory -PathType Container)) {
    return $null
  }
  foreach ($file in Get-ChildItem -LiteralPath $projectsDirectory -Filter "*.json" -File) {
    $graph = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
    if ($graph.project.path -ieq $canonicalProjectPath) {
      return [pscustomobject]@{ Path = $file.FullName; Graph = $graph }
    }
  }
  return $null
}

function Wait-SavedGraph([scriptblock] $predicate, [string] $description) {
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  while ([DateTime]::UtcNow -lt $deadline) {
    $saved = Get-SavedProjectGraph
    if ($saved -and (& $predicate $saved.Graph)) {
      return $saved
    }
    Start-Sleep -Milliseconds 100
  }
  throw "graph was not persisted under the disposable support directory: $description"
}

function Assert-SketchSessionMarker {
  if (-not (Test-Path -LiteralPath $sessionMarkerPath -PathType Leaf) -or
    [IO.File]::ReadAllText($sessionMarkerPath) -cne $sessionMarker) {
    throw "sketch session-ID mapping changed during promotion or daemon restart"
  }
}

function Assert-MutatedGraph([object] $graph, [int] $fireCount) {
  $sketch = @($graph.nodes | Where-Object id -eq $projectNodeSketch)
  $details = @($graph.nodes | Where-Object id -eq $projectNodeDetails)
  $edges = @($graph.edges)
  if ($sketch.Count -ne 1 -or $sketch[0].loopType -ne "turnBased" -or
    $sketch[0].title -ne "Persistent sketch") {
    return $false
  }
  if ($details.Count -ne 1 -or $details[0].title -ne "Renamed persisted details" -or
    $details[0].checkDescription -ne "Updated verification") {
    return $false
  }
  if ($edges.Count -ne 1 -or $edges[0].from -ne $projectNodeSketch -or
    $edges[0].to -ne $projectNodeDetails -or $edges[0].condition -ne "onSuccess" -or
    [int]$edges[0].fireCount -ne $fireCount -or
    $edges[0].kind -ne "spawn" -or
    $edges[0].payloadTransform.script._0 -ne "printf 'round trip'" -or
    $edges[0].spawnTargetProjectPath -ne $spawnProjectPath -or
    [int]$edges[0].cycleGuard.maxIterations -ne 7 -or
    [int]$edges[0].cycleGuard.stopAfterPassesWithoutImprovement -ne 3 -or
    $edges[0].cycleGuard.until -ne "test -f done") {
    return $false
  }
  return $true
}

$defaultSignatureBefore = Get-DefaultSupportSignature
if (Test-Path -LiteralPath $runRoot) {
  throw (New-OwnedLiveProcessCleanupError `
    -Message "Round-trip scratch already exists; ownership is unproven: $runRoot" `
    -Errors @([InvalidOperationException]::new("Existing scratch was not reused.")) `
    -RetainedRoots @($runRoot))
}
try {
  $null = New-ValidationFixtureDirectory -Path $runRoot
} catch {
  $creationError = $_.Exception
  if (Test-Path -LiteralPath $runRoot) {
    throw (New-OwnedLiveProcessCleanupError `
      -Message "Round-trip scratch appeared during admission; ownership is unproven: $runRoot" `
      -Errors @($creationError) -RetainedRoots @($runRoot))
  }
  throw
}
New-Item -ItemType Directory -Force -Path @(
    $supportDirectory, $sessionDirectory, $projectPath, $spawnProjectPath,
    $evidenceDirectory, $tempDirectory, $zigLocalCache, $zigGlobalCache
  ) | Out-Null
[IO.File]::WriteAllText($sessionMarkerPath, $sessionMarker, [Text.UTF8Encoding]::new($false))
$env:TEMP = $tempDirectory
$env:TMP = $tempDirectory
$env:GRAPHCODE_SUPPORT_DIR = $supportDirectory
$env:GRAPHCODE_DAEMON_PIPE = $daemonPipe
$env:GRAPHCODE_DAEMON_SHUTDOWN_EVENT = $shutdownEventName
$env:GRAPHCODE_DAEMON_ROUNDTRIP_PHASE = "create"
$env:GRAPHCODE_LOCAL_TEST_SUPPORT = $supportDirectory
$shutdownEvent = [Threading.EventWaitHandle]::new(
  $false,
  [Threading.EventResetMode]::ManualReset,
  $shutdownEventName
)

$roundtripError = $null
try {
  $processScope = New-ShellProcessScope
  $homePrefix = $defaultSupportDirectory.TrimEnd('\') + '\'
  if ($runRoot.StartsWith($homePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "disposable daemon state unexpectedly resolves under the default support directory"
  }
  if ([IO.Path]::GetFullPath($supportDirectory) -eq [IO.Path]::GetFullPath($defaultSupportDirectory)) {
    throw "refusing to use the user's default GraphCode support directory"
  }

  $daemonProcess = Start-OwnedDaemon
  $env:GRAPHCODE_DAEMON_ROUNDTRIP_PHASE = "create"
  Invoke-ZigTest "create" "real daemon mutations survive restart"
  $created = Wait-SavedGraph {
    param($graph)
    $graph.nodes.Count -eq 2 -and $graph.edges.Count -eq 1
  } "node and edge creation"
  $edgeId = [string]$created.Graph.edges[0].id
  if ([string]::IsNullOrWhiteSpace($edgeId)) {
    throw "daemon did not persist a stable edge identity"
  }
  $runLog.Add("edge-id=$edgeId")
  $runLog.Add("support-graph=$($created.Path)")
  if (-not $created.Path.StartsWith(
      [IO.Path]::GetFullPath($supportDirectory).TrimEnd('\') + '\',
      [StringComparison]::OrdinalIgnoreCase)) {
    throw "project graph was not stored below the disposable support directory"
  }
  Stop-OwnedDaemon $daemonProcess
  $daemonProcess.Dispose()
  $daemonProcess = $null
  $env:GRAPHCODE_DAEMON_ROUNDTRIP_PHASE = "mutex-absent"
  Invoke-ZigTest "mutex-after-first-stop" "real daemon lifetime mutex is absent after shutdown"

  $createdGraph = Get-SavedProjectGraph
  if (-not $createdGraph -or $createdGraph.Graph.edges.Count -ne 1 -or
    $createdGraph.Graph.edges[0].id -ne $edgeId) {
    throw "the created graph or edge identity was missing after the first daemon exit"
  }
  $createdGraph.Graph.edges[0].fireCount = 2
  $seededJson = ConvertTo-Json -InputObject $createdGraph.Graph -Depth 100 -Compress
  [IO.File]::WriteAllText($createdGraph.Path, $seededJson, [Text.UTF8Encoding]::new($false))
  $runLog.Add("edge-fire-count-fixture=2")

  $daemonProcess = Start-OwnedDaemon
  $env:GRAPHCODE_DAEMON_ROUNDTRIP_PHASE = "mutate"
  $env:GRAPHCODE_DAEMON_ROUNDTRIP_EDGE_ID = $edgeId
  Invoke-ZigTest "mutate" "real daemon mutations survive restart"
  $mutated = Wait-SavedGraph { param($graph) Assert-MutatedGraph $graph 2 } "accepted edits and promotion"
  Assert-SketchSessionMarker
  $runLog.Add("support-state=all mutations materialized")
  Stop-OwnedDaemon $daemonProcess
  $daemonProcess.Dispose()
  $daemonProcess = $null
  $env:GRAPHCODE_DAEMON_ROUNDTRIP_PHASE = "mutex-absent"
  Invoke-ZigTest "mutex-after-second-stop" "real daemon lifetime mutex is absent after shutdown"

  $daemonProcess = Start-OwnedDaemon
  $env:GRAPHCODE_DAEMON_ROUNDTRIP_PHASE = "verify"
  Invoke-ZigTest "reload" "real daemon mutations survive restart"
  $reloaded = Wait-SavedGraph { param($graph) Assert-MutatedGraph $graph 2 } "fresh daemon restart state"
  Assert-SketchSessionMarker
  if ($reloaded.Graph.edges[0].id -ne $edgeId) {
    throw "edge identity changed across daemon restart"
  }
  $runLog.Add("reloaded-edge-id=$($reloaded.Graph.edges[0].id)")
  $runLog.Add("sketch-session-marker=$sessionMarker")
  Stop-OwnedDaemon $daemonProcess
  $daemonProcess.Dispose()
  $daemonProcess = $null
  $env:GRAPHCODE_DAEMON_ROUNDTRIP_PHASE = "mutex-absent"
  Invoke-ZigTest "mutex-after-final-stop" "real daemon lifetime mutex is absent after shutdown"

  $defaultSignatureAfter = Get-DefaultSupportSignature
  if ($defaultSignatureAfter -cne $defaultSignatureBefore) {
    throw "the user's default ~/.graphcode tree changed during the isolated daemon test"
  }
  $runLog.Add("default-support=unchanged")
  $resultPath = Join-Path $evidenceDirectory "daemon-roundtrip-$nonce-summary.txt"
  [IO.File]::WriteAllLines($resultPath, $runLog, [Text.UTF8Encoding]::new($false))
  $successful = $true
} catch {
  $roundtripError = $_.Exception
  throw
} finally {
  $shutdownError = $null
  $cleanupError = $null
  $retentionError = $null
  if ($daemonProcess) {
    try { Stop-OwnedDaemon $daemonProcess } catch {
      $shutdownError = $_.Exception
      try {
        Stop-OwnedLiveProcess -Process $daemonProcess -Name "round-trip daemon"
      } catch {
        $cleanupError = $_.Exception
        $errors = @()
        if ($roundtripError) { $errors += $roundtripError }
        $errors += $shutdownError
        $errors += $cleanupError
        $retentionError = New-OwnedLiveProcessCleanupError `
          -Message "Round-trip daemon cleanup could not be verified; fixture root: $runRoot" `
          -Errors $errors -RetainedRoots @($runRoot)
      }
    }
    try { $daemonProcess.Dispose() } catch {
      $disposeError = $_.Exception
      $errors = @()
      if ($roundtripError) { $errors += $roundtripError }
      if ($shutdownError) { $errors += $shutdownError }
      if ($cleanupError) { $errors += $cleanupError }
      $errors += $disposeError
      $retentionError = New-OwnedLiveProcessCleanupError `
        -Message "Round-trip daemon handle cleanup could not be verified; fixture root: $runRoot" `
        -Errors $errors -RetainedRoots @($runRoot)
    }
  }
  if ($processScope) {
    try { Close-ShellProcessScope $processScope } catch {
      $jobError = $_.Exception
      $errors = @()
      if ($retentionError) {
        $errors += $retentionError
      } elseif ($roundtripError) {
        $errors += $roundtripError
      }
      if ($shutdownError -and -not $retentionError) { $errors += $shutdownError }
      $errors += $jobError
      $retentionError = New-OwnedLiveProcessCleanupError `
        -Message "Round-trip job cleanup could not be verified; fixture root: $runRoot" `
        -Errors $errors -RetainedRoots @($runRoot)
    }
  }
  $auxiliaryErrors = [Collections.Generic.List[Exception]]::new()
  if ($shutdownEvent) {
    try { $shutdownEvent.Dispose() } catch { $auxiliaryErrors.Add($_.Exception) }
  }
  foreach ($name in @(
      "GRAPHCODE_DAEMON_ROUNDTRIP_PHASE",
      "GRAPHCODE_DAEMON_ROUNDTRIP_PROJECT",
      "GRAPHCODE_DAEMON_ROUNDTRIP_SPAWN_PROJECT",
      "GRAPHCODE_DAEMON_ROUNDTRIP_EDGE_ID",
      "GRAPHCODE_LOCAL_TEST_SUPPORT")) {
    $environment = [Environment]::GetEnvironmentVariables(
      [EnvironmentVariableTarget]::Process)
    if ($environment.Contains($name)) {
      try { Remove-Item -LiteralPath "env:$name" -ErrorAction Stop } catch {
        $auxiliaryErrors.Add($_.Exception)
      }
    }
  }
  $artifactError = $null
  try {
    if ($successful -and -not $roundtripError -and -not $shutdownError -and -not $retentionError -and
        $auxiliaryErrors.Count -eq 0) {
      Remove-Item -LiteralPath $runRoot -Recurse -Force
    } else {
      $failurePath = Join-Path $evidenceDirectory "daemon-roundtrip-$nonce-failure.txt"
      [IO.File]::WriteAllLines($failurePath, $runLog, [Text.UTF8Encoding]::new($false))
      Write-Output "Failure artifacts written at $runRoot and $failurePath; enclosing isolation may remove them"
    }
  } catch {
    $artifactError = $_.Exception
  }
  if ($artifactError -or $auxiliaryErrors.Count -gt 0) {
    $errors = @()
    if ($retentionError) {
      $errors += $retentionError
    } elseif ($roundtripError) {
      $errors += $roundtripError
    }
    if ($shutdownError -and -not $retentionError) { $errors += $shutdownError }
    foreach ($error in $auxiliaryErrors) { $errors += $error }
    if ($artifactError) { $errors += $artifactError }
    $combined = [AggregateException]::new(
      "Round-trip failure reporting or fixture cleanup failed.", [Exception[]]$errors)
    if (Test-OwnedLiveProcessRetentionRequired $combined) {
      $combined.Data["GraphCodeValidationRootRetentionRequired"] = $true
      $combined.Data["GraphCodeValidationRetainedRoots"] = [string[]]@(
        Get-OwnedLiveProcessRetainedRoots -Errors $errors -RetainedRoots @($runRoot))
    }
    throw $combined
  }
  if ($retentionError) { throw $retentionError }
  if ($shutdownError) {
    $errors = @()
    if ($roundtripError) { $errors += $roundtripError }
    $errors += $shutdownError
    $combined = [AggregateException]::new(
      "Round-trip daemon required forced cleanup after shutdown failed.",
      [Exception[]]$errors)
    if (Test-OwnedLiveProcessRetentionRequired $combined) {
      $combined.Data["GraphCodeValidationRootRetentionRequired"] = $true
      $combined.Data["GraphCodeValidationRetainedRoots"] = [string[]]@(
        Get-OwnedLiveProcessRetainedRoots -Errors $errors -RetainedRoots @($runRoot))
    }
    throw $combined
  }
}
Write-Output "REAL_DAEMON_ROUNDTRIP: PASS"
Write-Output "Accepted mutations: create node, update and rename node, create edge, edit edge, promote sketch"
Write-Output "Restart readback: node identities/configuration and edge id/endpoints/fireCount/transform/spawn/cycle guard"
Write-Output "Mutex: present in each live process and absent after each clean shutdown, using production-derived name"
Write-Output "State: disposable support directory; default ~/.graphcode tree unchanged"
Write-Output "Evidence: $resultPath"
