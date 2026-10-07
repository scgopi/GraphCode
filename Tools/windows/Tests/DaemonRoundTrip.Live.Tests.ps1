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

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    throw "could not start graphcoded.exe"
  }
  [void] $process.Handle
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  while ([DateTime]::UtcNow -lt $deadline) {
    $process.Refresh()
    if ($process.HasExited) {
      throw "graphcoded.exe exited during startup: $($stderr.Result)"
    }
    if (@(Get-OwnedDaemon $process.Id).Count -eq 1) {
      $script:daemonStdout = $stdout
      $script:daemonStderr = $stderr
      # A PID exists before the lifetime mutex and listener are initialized. This is
      # especially observable on restart, when the Zig test executable is already built.
      $readyPipe = [IO.Pipes.NamedPipeClientStream]::new(".", $daemonPipe.Substring(9),
        [IO.Pipes.PipeDirection]::InOut)
      try {
        $readyPipe.Connect(15000)
      } catch {
        if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }
        throw "Owned daemon did not publish its listener before the round-trip test: $($_.Exception.Message)"
      } finally {
        $readyPipe.Dispose()
      }
      return $process
    }
    Start-Sleep -Milliseconds 100
  }
  throw "graphcoded.exe did not appear as a child at its exact executable path"
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
  $script:runLog.Add("daemon-exit pid=$($process.Id) code=$($process.ExitCode)")
  $script:runLog.Add("daemon-stdout=$($script:daemonStdout.Result.Trim())")
  $script:runLog.Add("daemon-stderr=$($script:daemonStderr.Result.Trim())")
}

function Invoke-ZigTest([string] $label, [string] $filter) {
  $env:GRAPHCODE_DAEMON_ROUNDTRIP_PROJECT = $projectPath
  $env:GRAPHCODE_DAEMON_ROUNDTRIP_SPAWN_PROJECT = $spawnProjectPath
  $env:GRAPHCODE_LOCAL_TEST_SUPPORT = $supportDirectory
  $env:ZIG_LOCAL_CACHE_DIR = $zigLocalCache
  $env:ZIG_GLOBAL_CACHE_DIR = $zigGlobalCache
  $output = @()
  $exitCode = 0
  Push-Location $shellRoot
  try {
    $output = @(& $ZigExecutable test src\DaemonRoundTripTests.zig `
      -target x86_64-windows-msvc -lc -ladvapi32 "-I$WinghosttyInclude" `
      --cache-dir $zigLocalCache --global-cache-dir $zigGlobalCache `
      --test-filter $filter 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  $text = $output -join "`n"
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
New-Item -ItemType Directory -Force -Path @(
    $runRoot, $supportDirectory, $sessionDirectory, $projectPath, $spawnProjectPath,
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

try {
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
  $successful = $true
  $resultPath = Join-Path $evidenceDirectory "daemon-roundtrip-$nonce-summary.txt"
  [IO.File]::WriteAllLines($resultPath, $runLog, [Text.UTF8Encoding]::new($false))
  Write-Output "REAL_DAEMON_ROUNDTRIP: PASS"
  Write-Output "Accepted mutations: create node, update and rename node, create edge, edit edge, promote sketch"
  Write-Output "Restart readback: node identities/configuration and edge id/endpoints/fireCount/transform/spawn/cycle guard"
  Write-Output "Mutex: present in each live process and absent after each clean shutdown, using production-derived name"
  Write-Output "State: disposable support directory; default ~/.graphcode tree unchanged"
  Write-Output "Evidence: $resultPath"
} finally {
  if ($daemonProcess -and -not $daemonProcess.HasExited) {
    try { Stop-OwnedDaemon $daemonProcess } catch {
      Stop-Process -Id $daemonProcess.Id -Force -ErrorAction SilentlyContinue
    }
  }
  if ($daemonProcess) { $daemonProcess.Dispose() }
  if ($shutdownEvent) { $shutdownEvent.Dispose() }
  foreach ($name in @(
      "GRAPHCODE_DAEMON_ROUNDTRIP_PHASE",
      "GRAPHCODE_DAEMON_ROUNDTRIP_PROJECT",
      "GRAPHCODE_DAEMON_ROUNDTRIP_SPAWN_PROJECT",
      "GRAPHCODE_DAEMON_ROUNDTRIP_EDGE_ID",
      "GRAPHCODE_LOCAL_TEST_SUPPORT")) {
    Remove-Item -LiteralPath "env:$name" -ErrorAction SilentlyContinue
  }
  if ($successful) {
    Remove-Item -LiteralPath $runRoot -Recurse -Force
  } else {
    $failurePath = Join-Path $evidenceDirectory "daemon-roundtrip-$nonce-failure.txt"
    [IO.File]::WriteAllLines($failurePath, $runLog, [Text.UTF8Encoding]::new($false))
    Write-Output "Failure artifacts retained at $runRoot and $failurePath"
  }
}
