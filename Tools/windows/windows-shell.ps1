[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $WinghosttyRoot,
  [Parameter(Mandatory)]
  [string] $ZmxRoot,
  [string] $Zig0152 = "zig",
  [string] $Zig0160 = "zig",
  [string] $DaemonRuntimeDirectory,
  [switch] $SkipBuild,
  [switch] $SkipTrayLive,
  [switch] $Stress,
  [switch] $UseStubDaemon,
  [ValidateRange(0, 1000)]
  [int] $StubResponseDelayMilliseconds = 0,
  [string] $Version
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$shellRoot = Join-Path $repoRoot "graphcode-windows"
$packageManifest = Get-Content (Join-Path $shellRoot "build.zig.zon") -Raw
if (-not $Version) {
  if ($packageManifest -notmatch '(?m)\.version\s*=\s*"([^"]+)"') {
    throw "GraphCode Windows shell package version is missing"
  }
  $Version = $Matches[1]
}
$pins = Get-Content (Join-Path $shellRoot "provider-pins.json") -Raw | ConvertFrom-Json
$app = Join-Path $shellRoot "zig-out\bin\graphcode-windows.exe"
$stubProcess = $null
$busyStubProcess = $null
$testSessionIds = @(
  [guid]::NewGuid().ToString(),
  [guid]::NewGuid().ToString()
)
$sessionPrefix = "gs-$([guid]::NewGuid().ToString('N'))"
$stubResult = Join-Path $shellRoot "stub-result-$PID.json"
$busyResult = Join-Path $shellRoot "busy-stub-result-$PID.json"
$busyError = Join-Path $shellRoot "busy-stub-error-$PID.txt"
$inputError = Join-Path $shellRoot "input-smoke-error-$PID.txt"
$oldPipe = [Environment]::GetEnvironmentVariable("GRAPHCODE_DAEMON_PIPE")
$oldRequireDaemon = [Environment]::GetEnvironmentVariable("GRAPHCODE_SHELL_REQUIRE_DAEMON")
$oldNonreadingAttach = [Environment]::GetEnvironmentVariable("GRAPHCODE_SHELL_NONREADING_ATTACH")
$oldLargePaste = [Environment]::GetEnvironmentVariable("GRAPHCODE_SHELL_LARGE_PASTE")
$oldWorkspaceActions = [Environment]::GetEnvironmentVariable("GRAPHCODE_SHELL_WORKSPACE_ACTIONS")
$oldWorkspaceLayout = [Environment]::GetEnvironmentVariable("GRAPHCODE_WORKSPACE_LAYOUT")
$oldStubNodeA = [Environment]::GetEnvironmentVariable("GRAPHCODE_STUB_NODE_A")
$oldStubNodeB = [Environment]::GetEnvironmentVariable("GRAPHCODE_STUB_NODE_B")
$oldSessionPrefix = [Environment]::GetEnvironmentVariable("GRAPHCODE_SHELL_SESSION_PREFIX")
$oldZmxDir = [Environment]::GetEnvironmentVariable("ZMX_DIR")
$smokeZmxDir = Join-Path ([IO.Path]::GetPathRoot([string] $repoRoot)) ("gcz-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$stubSessionHosts = @{}
$workspaceLayoutBase = Join-Path $shellRoot "graphcode-workspace-$PID.json"
$ownedSessionNames = [System.Collections.Generic.HashSet[string]]::new()
$ownedProcessIds = [System.Collections.Generic.HashSet[int]]::new()
$shellProcess = $null
$handoffStage = $null
$bareZmxStage = $null
$bareZmxProject = $null
$resourceRole = "graphcode-windows"
$metricSequence = 0

function Invoke-Native([string] $description, [scriptblock] $command) {
  Write-Host "==> $description"
  & $command
  if ($LASTEXITCODE -ne 0) {
    throw "$description failed with exit code $LASTEXITCODE"
  }
}

function Assert-Equal([string] $actual, [string] $expected, [string] $label) {
  if ($actual -ne $expected) {
    throw "$label expected $expected but found $actual"
  }
}

function New-SmokeZmxRoot([string] $Path) {
  if (Test-Path -LiteralPath $Path) { throw "Smoke zmx root already exists: $Path" }
  New-Item -ItemType Directory -Path $Path | Out-Null
  # Elevated runners default the owner to Administrators. zmx requires the token's
  # actual user SID; set it only on this fresh, test-owned directory.
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $acl = [Security.AccessControl.DirectorySecurity]::new()
  $acl.SetOwner($sid)
  $acl.SetAccessRuleProtection($true, $false)
  $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
      $sid, [Security.AccessControl.FileSystemRights]::FullControl,
      [Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit",
      [Security.AccessControl.PropagationFlags]::None,
      [Security.AccessControl.AccessControlType]::Allow))
  Set-Acl -LiteralPath $Path -AclObject $acl
  $owner = (Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier])
  if ($owner.Value -ne $sid.Value) { throw "Smoke zmx root owner does not match the current user" }
}

function Test-TestSessionProcess([object] $process) {
  if (-not $process.CommandLine) { return $false }
  foreach ($session in $testSessionIds) {
    if ($process.CommandLine -like "*$session*") { return $true }
  }
  if ($process.CommandLine -like "*$sessionPrefix*") { return $true }

  return $false
}

function Get-ZmxSessionRecords {
  $names = @($testSessionIds | ForEach-Object { [regex]::Escape("graphcode-$_") })
  $names += [regex]::Escape("graphcode-$sessionPrefix") + "-[A-Za-z0-9_-]+"
  $pattern = "(?<![A-Za-z0-9_-])(?:" + ($names -join "|") + ")(?![A-Za-z0-9_-])"
  foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'zmx.exe'" -ErrorAction Stop)) {
    if (-not $process.CommandLine) { continue }
    foreach ($match in [regex]::Matches($process.CommandLine, $pattern)) {
      [pscustomobject]@{ Name = $match.Value; Pid = [int] $process.ProcessId }
    }
  }
}

function Record-TestOwnedSessions {
  $records = @(Get-ZmxSessionRecords)
  foreach ($record in $records) {
    [void] $ownedSessionNames.Add($record.Name)
    [void] $ownedProcessIds.Add($record.Pid)
  }
  if ($records.Count -gt 0) {
    foreach ($processId in @(Get-ProcessTreeIds @($records.Pid))) {
      [void] $ownedProcessIds.Add($processId)
    }
  }
}

function Write-OwnedResourceMetrics([string] $phase, [int[]] $focusPids = @()) {
  $script:metricSequence++
  $metricPids = if ($focusPids.Count -gt 0) {
    @(Get-ProcessTreeIds $focusPids)
  } else { @($ownedProcessIds) }
  $metrics = @($metricPids | ForEach-Object {
      $p = Get-Process -Id $_ -ErrorAction SilentlyContinue
      if ($p) {
        [pscustomobject]@{
          pid = $_
          role = if ($p.ProcessName -match "zmx") { "zmx" } elseif ($_.Equals($script:shellProcess.Id)) { $resourceRole } else { $p.ProcessName }
          handles = [int64]$p.HandleCount
          privateBytes = [int64]$p.PrivateMemorySize64
        }

      }
    })
  Write-Host ("PRODUCT_RESOURCE_METRICS_JSON=" + (@{
      snapshotId = "$sessionPrefix-$resourceRole-$script:metricSequence"
      phase = $phase
      sessions = @($ownedSessionNames)
      processes = $metrics
    } | ConvertTo-Json -Compress -Depth 5))
}

function Invoke-ZmxProbe([string[]] $Arguments) {
  $start = [Diagnostics.ProcessStartInfo]::new($env:GRAPHCODE_ZMX)
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
  $process = [Diagnostics.Process]::Start($start)
  $output = $process.StandardOutput.ReadToEndAsync()
  $errors = $process.StandardError.ReadToEndAsync()
  try {
    if (-not $process.WaitForExit(5000)) {
      $process.Kill()
      throw "zmx probe timed out: $($Arguments -join ' ')"
    }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output.Result; Error = $errors.Result }
  } finally {
    $process.Dispose()
  }
}

# A protocol-only stub cannot launch the agent. Host its two terminal fixtures through
# zmx's supported foreground daemon entry point, with a real liveness assertion.
function Start-StubLoopSessions {
  if (-not $UseStubDaemon) { return }
  foreach ($id in $testSessionIds) {
    $name = "graphcode-$id"
    $listing = Invoke-ZmxProbe @("ls")
    $livePattern = "(?m)^name=" + [regex]::Escape($name) + "\t(?![^\r\n]*\t(?:ended|exit_code|err)=)"
    if ($listing.ExitCode -eq 0 -and $listing.Output -match $livePattern) { continue }
    if ($stubSessionHosts.ContainsKey($name) -and -not $stubSessionHosts[$name].HasExited) {
      throw "Owned stub session host is running but its task is not live: $name"
    }
    $start = [Diagnostics.ProcessStartInfo]::new($env:GRAPHCODE_ZMX)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WorkingDirectory = [string] $repoRoot
    $start.RedirectStandardError = $true
    foreach ($argument in @("--daemon", $name)) { $start.ArgumentList.Add($argument) }
    $hostProcess = [Diagnostics.Process]::Start($start)
    $hostError = $hostProcess.StandardError.ReadToEndAsync()
    $stubSessionHosts[$name] = $hostProcess
    [void] $ownedProcessIds.Add($hostProcess.Id)
    [void] $ownedSessionNames.Add($name)
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
      if ($hostProcess.HasExited) {
        throw "zmx stub host exited ($($hostProcess.ExitCode)): $name; $($hostError.Result)"
      }
      $listing = Invoke-ZmxProbe @("ls")
      if ($listing.ExitCode -eq 0 -and $listing.Output -match $livePattern) { break }
      Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($listing.ExitCode -ne 0 -or $listing.Output -notmatch $livePattern) {
      throw "zmx stub session did not become live: $name; $($listing.Error)"
    }
    Write-Host "STUB_LOOP_SESSION_LIVE=$name"
  }
  Record-TestOwnedSessions
}

function Invoke-ShellProcess([string[]] $arguments, [string] $phase) {
  Start-StubLoopSessions
  $script:shellProcess = Start-Process -FilePath $app -ArgumentList $arguments -PassThru -WindowStyle Hidden
  [void] $ownedProcessIds.Add($script:shellProcess.Id)
  Start-Sleep -Milliseconds 250
  Record-TestOwnedSessions
  Write-OwnedResourceMetrics $phase
  $script:shellProcess.WaitForExit()
  if ($script:shellProcess.ExitCode -ne 0) {
    throw "GraphCode Windows shell exited with code $($script:shellProcess.ExitCode)"
  }
  $script:shellProcess.Dispose()
  $script:shellProcess = $null
}

function Get-StageZmxProcesses([string] $stageZmx) {
  @(Get-CimInstance Win32_Process -Filter "Name = 'zmx.exe'" -ErrorAction Stop |
      Where-Object {
        $_.ExecutablePath -and
        [IO.Path]::GetFullPath([string] $_.ExecutablePath) -ieq $stageZmx
      })
}

# The installed shell names zmx bare ("zmx.exe", GRAPHCODE_ZMX unset) and finds it beside
# itself through its working directory, which PATH need not name. Every other case here
# exports GRAPHCODE_ZMX as an absolute path, so a regression in resolving the bare name
# for a child started in another directory (beta18: "Unable to open selected loop",
# "Unable to create tab") reached no gate. Stage that layout - shell and zmx side by side,
# that directory off PATH, no GRAPHCODE_ZMX - and require the scripted workspace actions
# (New Tab, Split Right, among others) to pass through the same smoke contract, with
# attach children observed running the staged zmx.
function Invoke-BareNameZmxShell {
  $stage = Join-Path $shellRoot "bare-zmx-installed-$PID"
  # A real folder that is not the shell's directory: the loop's project. Terminals start
  # here, so the bare name cannot be found by the child's own working directory.
  $project = Join-Path $shellRoot "bare-zmx-project-$PID"
  $stageShell = Join-Path $stage "graphcode-windows.exe"
  $stageZmx = Join-Path $stage "zmx.exe"
  $script:bareZmxStage = $stage
  $script:bareZmxProject = $project
  foreach ($path in @($stage, $project)) {
    if (Test-Path -LiteralPath $path) { throw "Bare-name zmx fixture already exists: $path" }
  }
  New-Item -ItemType Directory -Path $stage, $project | Out-Null
  $process = $null
  $stub = $null
  $bareStubResult = Join-Path $shellRoot "bare-zmx-stub-result-$PID.json"
  try {
    Copy-Item -LiteralPath $app -Destination $stageShell
    Copy-Item -LiteralPath $env:GRAPHCODE_ZMX -Destination $stageZmx
    Start-StubLoopSessions
    $barePipe = "graphcode-shell-barezmx-$PID"
    $stub = Start-Process -FilePath "pwsh" -WindowStyle Hidden -PassThru -ArgumentList @(
      "-NoProfile", "-File", (Join-Path $repoRoot "Tools\windows\Stub-Daemon.ps1"),
      "-PipeName", $barePipe, "-ResultPath", $bareStubResult, "-StubProjectPath", $project)

    $start = [Diagnostics.ProcessStartInfo]::new($stageShell)
    $start.WorkingDirectory = $stage
    $start.UseShellExecute = $false
    $start.RedirectStandardError = $true
    [void] $start.ArgumentList.Add("--smoke")
    # The installed shell sets neither: it names zmx bare and its workspace directory
    # is its own working directory.
    [void] $start.Environment.Remove("GRAPHCODE_ZMX")
    [void] $start.Environment.Remove("GRAPHCODE_GATE_CWD")
    $start.Environment["GRAPHCODE_DAEMON_PIPE"] = "\\.\pipe\$barePipe"
    # No PATH entry may supply a zmx.exe: neither the stage nor any directory that
    # happens to hold one (a developer machine may have an installed copy on PATH).
    $pathEntries = [Collections.Generic.List[string]]::new()
    foreach ($entry in @($env:PATH -split ";")) {
      if (-not $entry) { continue }
      $holdsZmx = $false
      try { $holdsZmx = [IO.File]::Exists((Join-Path $entry "zmx.exe")) } catch { $holdsZmx = $false }
      if (-not $holdsZmx) { $pathEntries.Add($entry) }
    }
    $start.Environment["PATH"] = $pathEntries -join ";"
    if ($start.Environment.ContainsKey("GRAPHCODE_ZMX") -or
        $start.Environment.ContainsKey("GRAPHCODE_GATE_CWD")) {
      throw "Bare-name zmx shell still carries a provider path override"
    }
    if ($pathEntries | Where-Object { $_.TrimEnd("\") -ieq $stage.TrimEnd("\") }) {
      throw "Bare-name zmx shell has its own directory on PATH"
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    [void] $process.Start()
    [void] $ownedProcessIds.Add($process.Id)
    $stderr = $process.StandardError.ReadToEndAsync()
    $attachSessions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $shellSessions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $stageProcessIds = [Collections.Generic.HashSet[int]]::new()
    $shellSessionPattern = "^graphcode-" + [regex]::Escape($sessionPrefix) + "-"
    $sample = {
      foreach ($zmxProcess in @(Get-StageZmxProcesses $stageZmx)) {
        [void] $stageProcessIds.Add([int] $zmxProcess.ProcessId)
        [void] $ownedProcessIds.Add([int] $zmxProcess.ProcessId)
        if ($zmxProcess.CommandLine -match '(?<![\w-])(attach|--daemon)\s+"?(graphcode-[\w-]+)') {
          $verb = $Matches[1]
          $name = $Matches[2]
          if ($verb -eq "attach") { [void] $attachSessions.Add($name) }
          if ($name -match $shellSessionPattern) { [void] $shellSessions.Add($name) }
        }
      }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    while (-not $process.HasExited) {
      if ([DateTime]::UtcNow -ge $deadline) {
        Stop-Process -Id $process.Id -Force
        throw "Bare-name zmx smoke did not finish within 90 seconds"
      }
      & $sample
      Start-Sleep -Milliseconds 50
    }
    $process.WaitForExit()
    # A plain shell tab or split starts its session's daemon from the staged zmx, and that
    # daemon outlives the shell, so one last look settles what a sample could miss.
    & $sample
    Record-TestOwnedSessions
    Write-Host ("BARE_NAME_ZMX_EVIDENCE_JSON=" + (@{
          exitCode = $process.ExitCode
          stageProcessCount = $stageProcessIds.Count
          attachSessions = @($attachSessions | Sort-Object)
          shellSessions = @($shellSessions | Sort-Object)
        } | ConvertTo-Json -Compress))
    if ($process.ExitCode -ne 0) {
      throw "Bare-name zmx shell smoke exited with code $($process.ExitCode): $($stderr.Result)"
    }
    if ($stageProcessIds.Count -eq 0) {
      throw "Bare-name zmx shell never ran the staged zmx.exe; the layout was not exercised"
    }
    # The loops open from the staged copy, so both must attach through it.
    foreach ($id in $testSessionIds) {
      if (-not $attachSessions.Contains("graphcode-$id")) {
        throw "Bare-name zmx shell never attached loop graphcode-$id through the staged zmx.exe"
      }
    }
    # New Tab and Split Right start plain shell sessions in the loop's folder; the smoke's
    # scripted workspace actions only run once a loop is attached, and each must spawn one.
    if ($shellSessions.Count -lt 1) {
      throw "Bare-name zmx shell attached no New Tab or Split Right terminal through the staged zmx.exe"
    }
    $bareEvidence = Get-Content -LiteralPath $bareStubResult -Raw | ConvertFrom-Json
    if (@($bareEvidence.commands) -notcontains "openProject" -or [bool] $bareEvidence.error) {
      throw "Bare-name zmx stub did not serve the folder project: $($bareEvidence.error)"
    }
  } finally {
    if ($process) {
      if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
      $process.Dispose()
    }
    if ($stub -and -not $stub.HasExited) { Stop-Process -Id $stub.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $bareStubResult -Force -ErrorAction SilentlyContinue
    Remove-BareNameZmxStage
  }
  $global:LASTEXITCODE = 0
}

function Remove-BareNameZmxStage {
  $stage = $script:bareZmxStage
  if ($script:bareZmxProject) {
    Remove-Item -LiteralPath $script:bareZmxProject -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (-not $stage -or -not (Test-Path -LiteralPath $stage)) { return }
  $stageZmx = Join-Path $stage "zmx.exe"
  Record-TestOwnedSessions
  foreach ($zmxProcess in @(Get-StageZmxProcesses $stageZmx)) {
    Stop-Process -Id ([int] $zmxProcess.ProcessId) -Force -ErrorAction SilentlyContinue
  }
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $stage)) { return }
    Start-Sleep -Milliseconds 250
  }
}

function Get-ProcessTreeIds([int[]] $roots) {
  $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  $ids = [Collections.Generic.HashSet[int]]::new()
  foreach ($root in $roots) { [void] $ids.Add($root) }
  $changed = $true
  while ($changed) {
    $changed = $false
    foreach ($process in $all) {
      if (-not $ids.Contains([int]$process.ProcessId) -and
          $ids.Contains([int]$process.ParentProcessId)) {
        [void] $ids.Add([int]$process.ProcessId)
        $changed = $true
      }
    }
  }
  return @($ids)
}

function Assert-PinnedCleanWorktree(
  [string] $root,
  [string] $expectedSha,
  [string] $label
) {
  if (-not (Test-Path -LiteralPath (Join-Path $root ".git"))) {
    throw "$label provider root is not a Git worktree: $root"
  }
  $status = @(git -C $root status --porcelain --untracked-files=all)
  if ($LASTEXITCODE -ne 0) {
    throw "$label provider status failed"
  }
  if ($status.Count -ne 0) {
    throw "$label provider worktree is dirty"
  }
  Assert-Equal (git -C $root rev-parse HEAD) $expectedSha "$label pin"
}

function Assert-NoOrphanShellProcesses {
  $processes = @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.CommandLine -and (Test-TestSessionProcess $_)
      }
  )
  if ($processes.Count -ne 0) {
    throw "Windows shell cleanup left orphan processes: $($processes.ProcessId -join ', ')"
  }
}

Assert-PinnedCleanWorktree $WinghosttyRoot $pins.winghostty.sha "Winghostty"
Assert-PinnedCleanWorktree $ZmxRoot $pins.zmx.sha "zmx"

try {
  if (-not $SkipBuild) {
    Invoke-Native "Pinned provider artifacts" {
      & (Join-Path $PSScriptRoot "provider-build.ps1") `
        -WinghosttyRoot $WinghosttyRoot `
        -ZmxRoot $ZmxRoot `
        -Zig0152 $Zig0152 `
        -Zig0160 $Zig0160
    }
    Invoke-Native "GraphCode Windows shell" {
      Push-Location $shellRoot
      try {
        & $Zig0152 build `
          "-Dwinghostty-dir=$WinghosttyRoot" `
          "-Dwinghostty-lib=$(Join-Path $WinghosttyRoot 'zig-out\lib\winghostty-win32-host.lib')" `
          "-Dversion=$Version" `
          -Doptimize=ReleaseSafe
      } finally { Pop-Location }
    }
  }

  if (-not (Test-Path -LiteralPath $app)) {
    throw "GraphCode Windows shell executable is missing: $app"
  }
  $reportedVersion = (& $app --version 2>$null | Select-Object -First 1).Trim()
  if ($reportedVersion -ne $Version) {
    throw "GraphCode Windows shell version mismatch: expected $Version, executable reports $reportedVersion"
  }
  $env:GRAPHCODE_ZMX = Join-Path $ZmxRoot "zig-out\bin\zmx.exe"
  $env:GRAPHCODE_GATE_CWD = $repoRoot
  $env:GRAPHCODE_SHELL_WORKSPACE_ACTIONS = "1"
  New-SmokeZmxRoot $smokeZmxDir
  $env:ZMX_DIR = $smokeZmxDir
  $env:GRAPHCODE_WORKSPACE_LAYOUT = $workspaceLayoutBase
  $env:GRAPHCODE_SHELL_SESSION_PREFIX = $sessionPrefix
  if ($UseStubDaemon) {
    $env:GRAPHCODE_STUB_NODE_A = $testSessionIds[0]
    $env:GRAPHCODE_STUB_NODE_B = $testSessionIds[1]
    Remove-Item -LiteralPath $stubResult -Force -ErrorAction SilentlyContinue
    $pipeName = "graphcode-shell-stub-$PID"
    $stubScript = Join-Path $repoRoot "Tools\windows\Stub-Daemon.ps1"
    $stubProcess = Start-Process -FilePath "pwsh" -WindowStyle Hidden -PassThru -ArgumentList @(
      "-NoProfile",
      "-File",
      $stubScript,
      "-PipeName",
      $pipeName,
      "-ResultPath",
      $stubResult,
      "-ResponseDelayMilliseconds",
      $StubResponseDelayMilliseconds
    )
    $env:GRAPHCODE_DAEMON_PIPE = "\\.\pipe\$pipeName"
    $env:GRAPHCODE_SHELL_REQUIRE_DAEMON = "1"
  }
  $arguments = @("--smoke")
  if ($Stress) { $arguments += "--stress" }
  Invoke-Native "GraphCode Windows shell smoke/stress" {
    Invoke-ShellProcess $arguments "windows-shell:topology"
  }
  Record-TestOwnedSessions
  Write-OwnedResourceMetrics "windows-shell:topology"
  if ($UseStubDaemon -and -not $SkipTrayLive) {
    Invoke-Native "GraphCode Windows tray live executable interaction" {
      & (Join-Path $repoRoot "Tools\windows\Tests\TrayLive.Tests.ps1") `
        -Executable $app `
        -PipeName $pipeName `
        -ExternalDaemonPid $stubProcess.Id
    }
  } elseif ($UseStubDaemon) {
    Write-Host "Skipping physical tray interaction because this runner has no interactive Explorer desktop."
  }
  if ($UseStubDaemon) {
    Invoke-Native "GraphCode Windows shell restart smoke" {
      Invoke-ShellProcess $arguments "windows-shell:restart"
    }
    Record-TestOwnedSessions
  }
  if ($UseStubDaemon) {
    if (-not (Test-Path -LiteralPath $stubResult)) {
      throw "Stub daemon did not write protocol evidence"
    }
    $evidence = Get-Content -LiteralPath $stubResult -Raw | ConvertFrom-Json
    Write-Host ("STUB_DAEMON_EVIDENCE_JSON=" + ($evidence | ConvertTo-Json -Compress -Depth 6))
    foreach ($property in @(
        "protocolConnected",
        "correlatedRequests",
        "reconnectObserved",
        "graphSent"
      )) {
      if (-not [bool] $evidence.$property) {
        throw "Stub daemon evidence failed: $property"
      }
    }
    # The shell is a sidebar client: a hello that names projectPaths would stop the
    # daemon delivering every other open project's live updates (beta17 ProjectLiveUpdates).
    if ([bool] $evidence.subscriptionSeen) {
      throw "Stub daemon evidence failed: a shell hello narrowed delivery to specific projects"
    }
    if ($evidence.error) {
      throw "Stub daemon reported an error: $($evidence.error)"
    }
    foreach ($command in @("listRecentProjects", "openProject", "graphCommand")) {
      if (@($evidence.commands) -notcontains $command) {
      throw "Stub daemon did not observe command: $command"
      }
    }
    Invoke-Native "GraphCode Windows shell bare-name zmx installed-layout smoke" {
      Invoke-BareNameZmxShell
    }
    Remove-Item -LiteralPath $busyResult,$busyError -Force -ErrorAction SilentlyContinue
    $busyPipeName = "graphcode-shell-busy-$PID"
    $busyStubProcess = Start-Process -FilePath "pwsh" -WindowStyle Hidden -PassThru -ArgumentList @(
      "-NoProfile",
      "-File",
      $stubScript,
      "-PipeName",
      $busyPipeName,
      "-ResultPath",
      $busyResult,
      "-NonReading"
    )
    $env:GRAPHCODE_DAEMON_PIPE = "\\.\pipe\$busyPipeName"
    $env:GRAPHCODE_SHELL_EXPECT_TRANSPORT_ERROR = "1"
    $busyApp = Start-Process -FilePath $app -ArgumentList @("--smoke") -PassThru `
      -RedirectStandardError $busyError
    [void] $busyApp.Handle
    if (-not $busyApp.WaitForExit(8000)) {
      Stop-Process -Id $busyApp.Id -Force
      throw "Busy daemon smoke blocked the UI beyond the bounded timeout"
    }
    $busyApp.WaitForExit()
    $busyApp.Refresh()
    Record-TestOwnedSessions
    $busyEvidence = Get-Content -LiteralPath $busyResult -Raw | ConvertFrom-Json
    if (-not [bool] $busyEvidence.busyObserved) {
      throw "Busy daemon smoke did not accept a non-reading connection"
    }
    $busyErrorText = Get-Content -LiteralPath $busyError -Raw
    if ($busyErrorText -notmatch "(?i)Smoke daemon status: .*daemon") {
      throw "Busy daemon smoke did not post a daemon transport error"
    }
    $env:GRAPHCODE_DAEMON_PIPE = "\\.\pipe\$pipeName"
    Remove-Item Env:GRAPHCODE_SHELL_EXPECT_TRANSPORT_ERROR -ErrorAction SilentlyContinue
    Remove-Item Env:GRAPHCODE_SHELL_NONREADING_ATTACH,Env:GRAPHCODE_SHELL_LARGE_PASTE `
      -ErrorAction SilentlyContinue
    $env:GRAPHCODE_SHELL_NONREADING_ATTACH = "1"
    $env:GRAPHCODE_SHELL_LARGE_PASTE = "1"
    Remove-Item -LiteralPath $inputError -Force -ErrorAction SilentlyContinue
    Start-StubLoopSessions
    $inputDeadline = [DateTime]::UtcNow.AddSeconds(8)
    $inputApp = Start-Process -FilePath $app -ArgumentList @("--smoke") -PassThru `
      -RedirectStandardError $inputError
    [void] $inputApp.Handle
    [void] $ownedProcessIds.Add($inputApp.Id)
    $shellProcess = $inputApp
    $attachReady = $false
    while ([DateTime]::UtcNow -lt $inputDeadline -and -not $inputApp.HasExited) {
      if (-not $attachReady) {
        $attachReady = @(
          Get-ProcessTreeIds @($inputApp.Id) | ForEach-Object {
            Get-Process -Id $_ -ErrorAction SilentlyContinue
          } | Where-Object ProcessName -eq "pwsh"
        ).Count -gt 0
      }
      if ($attachReady) {
        Record-TestOwnedSessions
        Write-OwnedResourceMetrics "windows-shell:large-paste" @($inputApp.Id)
      }
      Start-Sleep -Milliseconds 50
    }
    if (-not $attachReady) {
      throw "Large paste fixture did not start its owned pwsh attach within eight seconds"
    }
    $remainingMilliseconds = [Math]::Max(
      0, [int]($inputDeadline - [DateTime]::UtcNow).TotalMilliseconds)
    if ([DateTime]::UtcNow -ge $inputDeadline -or -not $inputApp.WaitForExit($remainingMilliseconds)) {
      if (-not $inputApp.HasExited) { Stop-Process -Id $inputApp.Id -Force }
      throw "Large paste/non-reading attach smoke blocked the UI beyond the bounded timeout"
    }
    $inputApp.WaitForExit()
    $inputApp.Refresh()
    $inputExitCode = $inputApp.ExitCode
    $inputApp.Dispose()
    $shellProcess = $null
    Record-TestOwnedSessions
    if ($null -eq $inputExitCode) {
      throw "Large paste/non-reading attach smoke completed without an observable exit code"
    }
    if ($inputExitCode -ne 0) {
      $inputErrorText = if (Test-Path -LiteralPath $inputError) {
       Get-Content -LiteralPath $inputError -Raw
      } else {
       "<no stderr captured>"
      }
      throw "Large paste/non-reading attach smoke failed with exit code $inputExitCode`: $inputErrorText"
    }
    Remove-Item -LiteralPath $inputError -Force -ErrorAction SilentlyContinue
  }
  if ($DaemonRuntimeDirectory) {
    $runtime = Resolve-Path -LiteralPath $DaemonRuntimeDirectory -ErrorAction Stop
    foreach ($name in @("graphcoded.exe", "graphcode.exe")) {
      if (-not (Test-Path -LiteralPath (Join-Path $runtime $name) -PathType Leaf)) {
        throw "Daemon handoff runtime is missing $name"
      }
    }
    $handoffStage = Join-Path $shellRoot "daemon-handoff-live-$PID"
    New-Item -ItemType Directory -Force -Path $handoffStage | Out-Null
    Copy-Item -LiteralPath $app -Destination (Join-Path $handoffStage "graphcode-windows.exe") -Force
    Get-ChildItem -LiteralPath $runtime -File |
      Where-Object { $_.Name -in @("graphcoded.exe", "graphcode.exe") -or $_.Extension -ieq ".dll" } |
      Copy-Item -Destination $handoffStage -Force
    Invoke-Native "Concurrent shell daemon handoff" {
      & (Join-Path $repoRoot "Tools\windows\Tests\DaemonHandoff.Live.Tests.ps1") `
        -Executable (Join-Path $handoffStage "graphcode-windows.exe")
    }
  }
  Record-TestOwnedSessions
  Write-Host "Windows shell smoke/stress: PASS"
}
finally {
  if ($stubProcess -and -not $stubProcess.HasExited) {
    Stop-Process -Id $stubProcess.Id -Force
  }
  if ($busyStubProcess -and -not $busyStubProcess.HasExited) {
    Stop-Process -Id $busyStubProcess.Id -Force
  }
  if ($env:GRAPHCODE_ZMX -and (Test-Path -LiteralPath $env:GRAPHCODE_ZMX)) {
    $treeProcessIds = Get-ProcessTreeIds @($ownedProcessIds)
    foreach ($processId in $treeProcessIds) {
      [void] $ownedProcessIds.Add($processId)
    }
    foreach ($session in @($ownedSessionNames)) {
      & $env:GRAPHCODE_ZMX kill --force $session *> $null
    }
    foreach ($processId in @($ownedProcessIds)) {
      if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
      }
    }
    $orphanTestDaemons = @(
      Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
          $_.Name -match "(?i)^zmx(?:\.exe)?$" -and
          (Test-TestSessionProcess $_)
        }
    )
    foreach ($process in $orphanTestDaemons) {
      Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
  }
  Remove-Item Env:GRAPHCODE_ZMX -ErrorAction SilentlyContinue
  Remove-Item Env:GRAPHCODE_GATE_CWD -ErrorAction SilentlyContinue
  if ($null -eq $oldZmxDir) {
    Remove-Item Env:ZMX_DIR -ErrorAction SilentlyContinue
  } else {
    $env:ZMX_DIR = $oldZmxDir
  }
  foreach ($hostProcess in $stubSessionHosts.Values) { $hostProcess.Dispose() }
  if (Test-Path -LiteralPath $smokeZmxDir) {
    Remove-Item -LiteralPath $smokeZmxDir -Recurse -Force
  }
  if ($null -eq $oldSessionPrefix) {
    Remove-Item Env:GRAPHCODE_SHELL_SESSION_PREFIX -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_SHELL_SESSION_PREFIX = $oldSessionPrefix
  }
  if ($null -eq $oldStubNodeA) {
    Remove-Item Env:GRAPHCODE_STUB_NODE_A -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_STUB_NODE_A = $oldStubNodeA
  }
  if ($null -eq $oldStubNodeB) {
    Remove-Item Env:GRAPHCODE_STUB_NODE_B -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_STUB_NODE_B = $oldStubNodeB
  }
  if ($null -eq $oldPipe) {
    Remove-Item Env:GRAPHCODE_DAEMON_PIPE -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_DAEMON_PIPE = $oldPipe
  }
  if ($null -eq $oldRequireDaemon) {
    Remove-Item Env:GRAPHCODE_SHELL_REQUIRE_DAEMON -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_SHELL_REQUIRE_DAEMON = $oldRequireDaemon
  }
  if ($null -eq $oldNonreadingAttach) {
    Remove-Item Env:GRAPHCODE_SHELL_NONREADING_ATTACH -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_SHELL_NONREADING_ATTACH = $oldNonreadingAttach
  }
  if ($null -eq $oldLargePaste) {
    Remove-Item Env:GRAPHCODE_SHELL_LARGE_PASTE -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_SHELL_LARGE_PASTE = $oldLargePaste
  }
  if ($null -eq $oldWorkspaceActions) {
    Remove-Item Env:GRAPHCODE_SHELL_WORKSPACE_ACTIONS -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_SHELL_WORKSPACE_ACTIONS = $oldWorkspaceActions
  }
  if ($null -eq $oldWorkspaceLayout) {
    Remove-Item Env:GRAPHCODE_WORKSPACE_LAYOUT -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_WORKSPACE_LAYOUT = $oldWorkspaceLayout
  }
  $layoutStem = [IO.Path]::GetFileNameWithoutExtension($workspaceLayoutBase)
  Get-ChildItem -LiteralPath $shellRoot -Filter "$layoutStem*.json" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $stubResult -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $busyResult,$busyError,$inputError -Force -ErrorAction SilentlyContinue
  if ($handoffStage) {
    Remove-Item -LiteralPath $handoffStage -Recurse -Force -ErrorAction SilentlyContinue
  }
  Remove-BareNameZmxStage
  Assert-NoOrphanShellProcesses
}

exit 0
