[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $WinghosttyRoot,
  [Parameter(Mandatory)][string] $ZmxRoot,
  [string] $Zig0152 = "zig",
  [string] $Zig0160 = "zig",
  [switch] $SkipBuild,
  [switch] $SkipProviderBuild,
  [switch] $Stress
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$gateRoot = Join-Path $repoRoot "investigation\spikes\windows-terminal-gate"
$pins = Get-Content (Join-Path $gateRoot "provider-pins.json") -Raw | ConvertFrom-Json
$app = Join-Path $gateRoot "zig-out\bin\graphcode-terminal-gate.exe"
$wingLib = Join-Path $WinghosttyRoot "zig-out\lib\winghostty-win32-host.lib"
$zmx = Join-Path $ZmxRoot "zig-out\bin\zmx.exe"
$assembly = $env:GRAPHCODE_VALIDATION_ASSEMBLY
if (-not $assembly) { $assembly = & (Join-Path $PSScriptRoot "Build-CompiledValidationRunner.ps1") }
& (Join-Path $PSScriptRoot "Import-CompiledValidationAssembly.ps1") `
  -AssemblyPath $assembly -RequiredType "GraphCode.Validation.Ownership.OwnedChildSupervisor" | Out-Null
$workClock = [Diagnostics.Stopwatch]::StartNew()
$artifactRoot = Join-Path ([IO.Path]::GetTempPath()) ("terminal-owned-" + [guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path $artifactRoot -ErrorAction Stop
$ownedSessionNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$ownedSeeds = [Collections.Generic.List[object]]::new()
$launchSequence = 0
$primaryFailure = $null
$cleanupUnproven = $false
$stageCount = 0
$metricSequence = 0
$sessionPrefix = "gc-$([guid]::NewGuid().ToString('N'))"
$names = @("$sessionPrefix-a", "$sessionPrefix-b", "$sessionPrefix-shared")
$priorEnvironment = @{}
foreach ($name in @("GRAPHCODE_ZMX", "GRAPHCODE_GATE_CWD", "GRAPHCODE_TERMINAL_SESSION_PREFIX", "ZMX_DIR")) {
  $priorEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}
Write-Host "TERMINAL_GATE_ARTIFACT_ROOT=$artifactRoot"

function Get-TerminalRemaining([int] $maximumMilliseconds) {
  # Leave the owned command's original five-second teardown inside the work phase.
  $remaining = 1800000L - 5000L - $workClock.ElapsedMilliseconds
  if ($maximumMilliseconds -le 0 -or $remaining -le 0) {
    throw "Terminal work deadline reached; original cleanup reserve remains protected"
  }
  return [int][Math]::Min($maximumMilliseconds, $remaining)
}

function Resolve-TerminalApplication(
  [string] $name,
  [scriptblock] $discover = { param($commandName) Get-Command -Name $commandName -CommandType Application -ErrorAction Stop }
) {
  if ($name -cnotin @("git", "pwsh")) { throw "Terminal application resolver only admits git and pwsh" }
  $commands = @(& $discover $name)
  if ($commands.Count -eq 0) { throw "Terminal application is absent: $name" }
  $selected = $commands[0]
  $source = $selected.Source
  if ($selected.CommandType -ne [Management.Automation.CommandTypes]::Application -or
      $source -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($source) -or
      -not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw "First terminal application candidate is not an existing absolute application: $name"
  }
  return $source
}

function New-TerminalStartInfo([string] $file, [string[]] $arguments, [string] $directory) {
  $start = [Diagnostics.ProcessStartInfo]::new((Resolve-Path -LiteralPath $file).Path)
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $start.Environment["GRAPHCODE_VALIDATION_ASSEMBLY"] = $assembly
  $start.WorkingDirectory = $directory
  foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
  return $start
}

function Start-TerminalOwnedChild($start, [string] $role, [int] $milliseconds) {
  $script:launchSequence++
  $directory = Join-Path $artifactRoot ("{0:D4}-{1}" -f $launchSequence, $role)
  $null = New-Item -ItemType Directory -Path $directory
  return [GraphCode.Validation.Ownership.OwnedChildSupervisor]::Start(
    $start, [TimeSpan]::FromMilliseconds((Get-TerminalRemaining $milliseconds)), $directory)
}

function Invoke-TerminalOwnedCommand([string] $file, [string[]] $arguments,
    [string] $role, [int] $milliseconds = 5000, [string] $directory = $repoRoot) {
  $start = New-TerminalStartInfo $file $arguments $directory
  $child = Start-TerminalOwnedChild $start $role $milliseconds
  return $child.CompleteAsync().GetAwaiter().GetResult()
}

function Invoke-Native([string] $description, [scriptblock] $command) {
  Write-Host "==> $description"
  $global:LASTEXITCODE = 0
  & $command
  if ($LASTEXITCODE -ne 0) { throw "$description failed with exit code $LASTEXITCODE" }
  $script:stageCount++
}

function Assert-PinnedCleanWorktree([string] $root, [string] $sha, [string] $label) {
  $git = Resolve-TerminalApplication "git"
  $status = Invoke-TerminalOwnedCommand $git @("-C", $root, "status", "--porcelain", "--untracked-files=all") "pin-status"
  $head = Invoke-TerminalOwnedCommand $git @("-C", $root, "rev-parse", "HEAD") "pin-head"
  if ($status.ExitCode -ne 0 -or $head.ExitCode -ne 0 -or
      $status.StandardOutput.Trim().Length -ne 0 -or $head.StandardOutput.Trim() -cne $sha) {
    throw "$label provider pin/status differs; no unverified provider is admitted"
  }
}

function Assert-HistoryContains([string] $name, [string] $marker, [string] $label) {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    $remaining = [int][Math]::Min(5000, 10000 - $watch.ElapsedMilliseconds)
    if ($remaining -le 0) { break }
    $result = Invoke-TerminalOwnedCommand $zmx @("history", $name, "--vt") "history" $remaining
    if ($watch.ElapsedMilliseconds -ge 10000) { throw "$label exceeded its shared history deadline" }
    if ($result.ExitCode -eq 0 -and $result.StandardOutput.Contains($marker)) { return }
    Write-Host "TERMINAL_HISTORY_PENDING attempt=$attempt exit=$($result.ExitCode)"
    Start-Sleep -Milliseconds ([Math]::Min(250, [Math]::Max(0, 10000 - $watch.ElapsedMilliseconds)))
  }
  throw "$label did not contain the persistent VT marker '$marker'"
}

function Assert-ZmxSessionHealthy([string] $name, [string] $label) {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    $remaining = [int][Math]::Min(5000, 10000 - $watch.ElapsedMilliseconds)
    if ($remaining -le 0) { break }
    $result = Invoke-TerminalOwnedCommand $zmx @("get", $name) "health" $remaining
    if ($watch.ElapsedMilliseconds -ge 10000) { throw "$label exceeded its shared health deadline" }
    if ($result.ExitCode -eq 0) { return }
    Write-Host "TERMINAL_HEALTH_PENDING attempt=$attempt exit=$($result.ExitCode)"
    Start-Sleep -Milliseconds ([Math]::Min(250, [Math]::Max(0, 10000 - $watch.ElapsedMilliseconds)))
  }
  throw "$label did not become reachable"
}

function Send-TerminalText([string] $name, [string] $text) {
  $result = Invoke-TerminalOwnedCommand $zmx @("send", $name, $text) "send"
  if ($result.ExitCode -ne 0) { throw "Terminal send failed: $($result.StandardError)" }
}

function Invoke-GateProcess([string[]] $arguments, [string] $phase) {
  if ($ownedSeeds.Count -ne 3) { throw "Terminal spike requires exactly three original owned seed roots" }
  foreach ($seed in $ownedSeeds) {
    $observation = $seed.child.Observe()
    if ($observation.RootExited -or $observation.ActiveJobProcesses -eq 0) {
      throw "Original terminal seed root is not live; no replacement session is admitted"
    }
  }
  $start = New-TerminalStartInfo $app $arguments $repoRoot
  $child = Start-TerminalOwnedChild $start "spike" 30000
  $completionStarted = $false
  try {
    Write-OwnedResourceMetrics $phase $child
    $completionStarted = $true
    $result = $child.CompleteAsync().GetAwaiter().GetResult()
    if ($result.ExitCode -ne 0) {
      throw "Terminal spike failed: exit=$($result.ExitCode); stdout=$($result.StandardOutput); stderr=$($result.StandardError)"
    }
  } catch {
    $primary = $_.Exception
    if (-not $completionStarted) {
      try {
        $proof = $child.StopAsync($primary).GetAwaiter().GetResult()
        if (-not $proof.CanRelease -or -not $proof.ResourcesClosed) {
          $script:cleanupUnproven = $true
          throw "Pre-completion spike cleanup is unproved"
        }
      }
      catch { $primary.Data["TerminalMetricCleanupFailure"] = $_.Exception }
    }
    throw
  }
}

function Write-OwnedResourceMetrics([string] $phase, $spike) {
  if ($ownedSeeds.Count -ne 3) { throw "Terminal metrics require exactly three original owned seed roots" }
  $script:metricSequence++
  $metrics = @(foreach ($entry in @(@{ child=$spike; role="winghostty" }) +
      @($ownedSeeds | ForEach-Object { @{ child=$_.child; role="zmx" } })) {
    $resources = $entry.child.ReadResources()
    [ordered]@{ pid = $resources.ProcessId; creationFileTimeUtc = $resources.CreationFileTime
      role = $entry.role; handles = $resources.Handles; privateBytes = $resources.PrivateBytes }
  })
  Write-Host ("PRODUCT_RESOURCE_METRICS_JSON=" + ([ordered]@{
    snapshotId = "$sessionPrefix-$metricSequence"; phase = $phase; sessions = @($ownedSessionNames); processes = $metrics
    sampleScope = "ACTUAL_ACTIVE_SPIKE_INVOCATION_BEFORE_COMPLETION_NOT_POST_TYPED_WORKLOAD"
  } | ConvertTo-Json -Compress -Depth 4))
}

function Complete-TerminalSeeds([Exception] $primary) {
  $errors = [Collections.Generic.List[Exception]]::new()
  $tasks = [Collections.Generic.List[Threading.Tasks.Task]]::new()
  foreach ($seed in $ownedSeeds) {
    try { $tasks.Add($seed.child.StopAsync($primary)) }
    catch { $errors.Add($_.Exception) }
  }
  try {
    if (-not [Threading.Tasks.Task]::WaitAll($tasks.ToArray(), 9000)) {
      $script:cleanupUnproven = $true
      throw "Original terminal seed cleanup exceeded its shared 9000 ms reserve"
    }
  } catch { $errors.Add($_.Exception) }
  foreach ($task in $tasks) {
    if (-not $task.IsCompleted) { $script:cleanupUnproven = $true; continue }
    try {
      $proof = $task.GetAwaiter().GetResult()
      if (-not $proof.CanRelease -or -not $proof.ResourcesClosed) {
        $script:cleanupUnproven = $true
        throw "Terminal seed cleanup is unproved"
      }
    } catch { $errors.Add($_.Exception) }
  }
  if ($env:GRAPHCODE_TERMINAL_GATE_INJECT_CLEANUP_FAILURE -eq "1") {
    $errors.Add([InvalidOperationException]::new("injected cleanup failure"))
  }
  if ($errors.Count -gt 0) {
    $failure = [AggregateException]::new("terminal gate cleanup failed", $errors.ToArray())
    if ($primary) { $primary.Data["TerminalCleanupFailure"] = $failure }
    else { throw $failure }
  } else {
    Write-Host "TERMINAL_GATE_SEED_CLEANUP=verified roots=$($ownedSeeds.Count)"
  }
}

try {
  Assert-PinnedCleanWorktree $WinghosttyRoot $pins.winghostty.sha "Winghostty"
  Assert-PinnedCleanWorktree $ZmxRoot $pins.zmx.sha "zmx"
  $pwsh = Resolve-TerminalApplication "pwsh"
  $resourceContracts = Invoke-TerminalOwnedCommand $pwsh @(
    "-NoProfile", "-NonInteractive", "-File", (Join-Path $PSScriptRoot "Tests\TerminalGate.Tests.ps1"),
    "-ResourceCountersOnly") "resource-contracts" 60000
  if ($resourceContracts.ExitCode -ne 0 -or
      $resourceContracts.StandardOutput -notmatch 'Terminal held resource counters: PASS executed=11 source/managed-only') {
    throw "Canonical held-resource contracts failed or executed an incomplete count"
  }
  if (-not $SkipBuild) {
    if (-not $SkipProviderBuild) {
      $build = Invoke-TerminalOwnedCommand $pwsh @(
        "-NoProfile", "-NonInteractive", "-File", (Join-Path $PSScriptRoot "provider-build.ps1"),
        "-WinghosttyRoot", $WinghosttyRoot, "-ZmxRoot", $ZmxRoot,
        "-Zig0152", $Zig0152, "-Zig0160", $Zig0160,
        "-PinsPath", (Join-Path $gateRoot "provider-pins.json")) "provider-build" 1200000
      if ($build.ExitCode -ne 0) { throw "Provider build failed: $($build.StandardError)" }
    }
    $build = Invoke-TerminalOwnedCommand $Zig0152 @("build", "-Dwinghostty-dir=$WinghosttyRoot",
      "-Dwinghostty-lib=$wingLib", "-Doptimize=ReleaseSafe") "spike-build" 600000 $gateRoot
    if ($build.ExitCode -ne 0) { throw "Terminal gate build failed: $($build.StandardError)" }
    $tests = Invoke-TerminalOwnedCommand $Zig0152 @("test", "src\AttachCleanup.zig") "attach-contracts" 60000 $gateRoot
    if ($tests.ExitCode -ne 0 -or ($tests.StandardOutput + $tests.StandardError) -notmatch 'All [1-9][0-9]* tests passed\.') {
      throw "Terminal held attach contracts failed or executed zero tests"
    }
  }
  foreach ($path in @($app, $zmx)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Terminal executable missing: $path" }
  }
  $env:GRAPHCODE_ZMX = $zmx
  $env:GRAPHCODE_GATE_CWD = $repoRoot
  $env:GRAPHCODE_TERMINAL_SESSION_PREFIX = $sessionPrefix
  $env:ZMX_DIR = Join-Path $artifactRoot "zmx"
  $lease = Join-Path $env:ZMX_DIR ("ipc\" + ("s" * 52) + "\" +
    ("0" * (2 * [Text.Encoding]::UTF8.GetByteCount($names[2]))) + ".endpoint.lease")
  if ($lease.Length -gt 232) {
    throw "Terminal owned provider path exceeds the 232-character lease budget; use an admitted shorter TEMP root"
  }
  $null = New-Item -ItemType Directory -Path $env:ZMX_DIR
  foreach ($name in $names) {
    $start = New-TerminalStartInfo $zmx @("--daemon", $name,
      (Join-Path ([Environment]::SystemDirectory) "cmd.exe"), "/Q") $repoRoot
    $child = Start-TerminalOwnedChild $start "session-seed" (Get-TerminalRemaining 1800000)
    $ownedSeeds.Add([pscustomobject]@{ name = $name; child = $child })
    [void]$ownedSessionNames.Add($name)
    Assert-ZmxSessionHealthy $name "seed $name"
  }
  Invoke-Native "terminal gate first attach smoke" { Invoke-GateProcess @("--smoke") "terminal-gate:typed-input" }
  Invoke-Native "first-session health" {
    Assert-ZmxSessionHealthy $names[0] "session A"; Assert-ZmxSessionHealthy $names[1] "session B"
  }
  Invoke-Native "session shell pwd/cwd" { Send-TerminalText $names[0] "cd`r"; Send-TerminalText $names[1] "cd`r" }
  $expectedCwd = [IO.Path]::GetFullPath($repoRoot).TrimEnd("\")
  Assert-HistoryContains $names[0] $expectedCwd "session A cwd"
  Assert-HistoryContains $names[1] $expectedCwd "session B cwd"
  Assert-HistoryContains $names[0] "GraphCode typed output A" "typed A output"
  Assert-HistoryContains $names[1] "GraphCode typed output B" "typed B output"
  Invoke-Native "seed persistent shell output" {
    Send-TerminalText $names[0] "echo GraphCode persistent VT output A`r"
    Send-TerminalText $names[1] "echo GraphCode persistent VT output B`r"
  }
  Assert-HistoryContains $names[0] "GraphCode persistent VT output A" "first-session A history"
  Assert-HistoryContains $names[1] "GraphCode persistent VT output B" "first-session B history"
  Invoke-Native "terminal gate independent restart attach smoke" { Invoke-GateProcess @("--smoke") "terminal-gate:reconnect" }
  Invoke-Native "restart-session health" {
    Assert-ZmxSessionHealthy $names[0] "restart session A"; Assert-ZmxSessionHealthy $names[1] "restart session B"
  }
  Assert-HistoryContains $names[0] "GraphCode persistent VT output A" "restart A history"
  Assert-HistoryContains $names[1] "GraphCode persistent VT output B" "restart B history"
  Assert-HistoryContains $names[0] "GraphCode typed output A" "restart typed A history"
  Assert-HistoryContains $names[1] "GraphCode typed output B" "restart typed B history"
  Invoke-Native "terminal gate same-session attach smoke" { Invoke-GateProcess @("--smoke", "--same-session") "terminal-gate:typed-input" }
  Invoke-Native "same-session health" { Assert-ZmxSessionHealthy $names[2] "shared session" }
  Invoke-Native "seed shared persistent shell output" { Send-TerminalText $names[2] "echo GraphCode shared VT output`r" }
  Assert-HistoryContains $names[2] "GraphCode shared VT output" "same-session history"
  Invoke-Native "terminal gate same-session restart smoke" { Invoke-GateProcess @("--smoke", "--same-session") "terminal-gate:reconnect" }
  Assert-HistoryContains $names[2] "GraphCode shared VT output" "same-session restart history"
  if ($Stress) {
    Invoke-Native "terminal gate destroy/recreate stress" { Invoke-GateProcess @("--smoke", "--stress") "terminal-gate:stress" }
    Invoke-Native "post-stress session health" {
      Assert-ZmxSessionHealthy $names[0] "post-stress session A"; Assert-ZmxSessionHealthy $names[1] "post-stress session B"
    }
  }
} catch {
  $primaryFailure = $_.Exception
  throw
} finally {
  try { Complete-TerminalSeeds $primaryFailure }
  finally {
    foreach ($key in $priorEnvironment.Keys) {
      [Environment]::SetEnvironmentVariable($key, $priorEnvironment[$key], "Process")
    }
    if ($cleanupUnproven -or [GraphCode.Validation.Ownership.OwnedChildSupervisor]::RequiresLifetimeHold) {
      Write-Host "GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven"
      [Console]::Out.Flush()
      if ($cleanupUnproven) { [Threading.Thread]::Sleep([Threading.Timeout]::Infinite) }
      $null = [GraphCode.Validation.Ownership.OwnedChildSupervisor]::HoldRetainedResourcesAsync().GetAwaiter().GetResult()
    }
  }
}
if ($stageCount -ne $(if ($Stress) { 12 } else { 10 })) { throw "Terminal stage execution count differs" }
Write-Host "TERMINAL_GATE_STAGES_EXECUTED=$stageCount"
Write-Host "Windows terminal gate smoke/stress: PASS"
exit 0
