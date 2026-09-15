[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $WinghosttyRoot,
  [Parameter(Mandatory)]
  [string] $ZmxRoot,
  [string] $Zig0152 = "zig",
  [string] $Zig0160 = "zig",
  [switch] $SkipBuild,
  [switch] $Stress
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$gateRoot = Join-Path $repoRoot "investigation\spikes\windows-terminal-gate"
$pins = Get-Content (Join-Path $gateRoot "provider-pins.json") -Raw | ConvertFrom-Json
$app = Join-Path $gateRoot "zig-out\bin\graphcode-terminal-gate.exe"
$wingLib = Join-Path $WinghosttyRoot "zig-out\lib\winghostty-win32-host.lib"
$zmx = Join-Path $ZmxRoot "zig-out\bin\zmx.exe"
$ownedSessionNames = [System.Collections.Generic.HashSet[string]]::new()
$ownedProcessIds = [System.Collections.Generic.HashSet[int]]::new()
$gateOutputFiles = [System.Collections.Generic.List[string]]::new()
$gateProcess = $null
$resourceRole = "winghostty"
$metricSequence = 0
$sessionPrefix = "gc-$([guid]::NewGuid().ToString('N'))"
$names = @(
  "$sessionPrefix-a",
  "$sessionPrefix-b",
  "$sessionPrefix-shared"
)

function Invoke-Native([string] $description, [scriptblock] $command) {
  Write-Host "==> $description"
  & $command
  if ($LASTEXITCODE -ne 0) {
    throw "$description failed with exit code $LASTEXITCODE"
  }
}

function Invoke-NativeWithRetry(
  [string] $description,
  [scriptblock] $command,
  [int] $Attempts = 3
) {
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    Write-Host "==> $description (attempt $attempt/$Attempts)"
    & $command
    if ($LASTEXITCODE -eq 0) {
      return
    }
    if ($attempt -lt $Attempts) {
      Start-Sleep -Seconds (5 * $attempt)
    }
  }
  throw "$description failed after $Attempts attempts with exit code $LASTEXITCODE"
}

function Assert-Equal([string] $actual, [string] $expected, [string] $label) {
  if ($actual -ne $expected) {
    throw "$label expected $expected but found $actual"
  }
}

function Assert-HistoryContains([string] $name, [string] $marker, [string] $label) {
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    $history = (& $zmx history $name --vt 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0 -and
      $history -match [regex]::Escape($marker)) {
      return
    }
    Start-Sleep -Milliseconds 250
  }
  throw "$label did not contain the persistent VT marker '$marker'"
}

function Assert-ZmxSessionHealthy([string] $name, [string] $label) {
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    & $zmx get $name *> $null
    if ($LASTEXITCODE -eq 0) {
      return
    }
    Start-Sleep -Milliseconds 250
  }
  throw "$label did not become reachable"
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
    throw "$label provider worktree is dirty; use a clean pinned worktree or immutable artifact"
  }
  Assert-Equal (git -C $root rev-parse HEAD) $expectedSha "$label pin"
}

function Record-TestOwnedSessions {
  foreach ($name in $names) {
    [void] $ownedSessionNames.Add($name)
    foreach ($processId in @(Get-ZmxSessionProcessIds $name)) {
      [void] $ownedProcessIds.Add($processId)
    }
  }
}

function Write-OwnedResourceMetrics([string] $phase) {
  $script:metricSequence++
  $metrics = @($ownedProcessIds | ForEach-Object {
      $p = Get-Process -Id $_ -ErrorAction SilentlyContinue
      if ($p) {
        [pscustomobject]@{
          pid = $_
          role = if ($p.ProcessName -match "zmx") { "zmx" } elseif ($_.Equals($script:gateProcess.Id)) { $resourceRole } else { $p.ProcessName }
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

function Invoke-GateProcess([string[]] $arguments, [string] $phase) {
  $outputPrefix = Join-Path ([IO.Path]::GetTempPath()) `
    "graphcode-terminal-gate-$([guid]::NewGuid().ToString('N'))"
  $stdoutPath = "$outputPrefix.stdout.log"
  $stderrPath = "$outputPrefix.stderr.log"
  [void] $gateOutputFiles.Add($stdoutPath)
  [void] $gateOutputFiles.Add($stderrPath)
  $script:gateProcess = Start-Process -FilePath $app `
    -ArgumentList $arguments `
    -NoNewWindow `
    -PassThru `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath
  [void] $ownedProcessIds.Add($script:gateProcess.Id)
  Start-Sleep -Milliseconds 250
  Record-TestOwnedSessions
  Write-OwnedResourceMetrics $phase
  $script:gateProcess.WaitForExit()
  $exitCode = $script:gateProcess.ExitCode
  $script:gateProcess.Dispose()
  $script:gateProcess = $null
  if ($exitCode -ne 0) {
    $stdout = Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
    $stderr = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
    throw "terminal gate exited with code ${exitCode}: stdout=$stdout, stderr=$stderr"
  }
}

function Get-ZmxSessionProcessIds([string] $name) {
  $ids = [System.Collections.Generic.List[int]]::new()
  $escaped = [regex]::Escape($name)
  foreach ($process in @(
      Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
          $_.Name -match "(?i)^zmx(?:\.exe)?$" -and
          $_.CommandLine -and
          $_.CommandLine -match $escaped
        }
    )) {
    $ids.Add([int] $process.ProcessId)
  }
  return @($ids | Select-Object -Unique)
}

function Assert-ZmxSessionAbsent([string] $name) {
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $processIds = @(Get-ZmxSessionProcessIds $name)
    if ($processIds.Count -eq 0) {
      return
    }

    Start-Sleep -Milliseconds 250
  }
  $details = @($processIds | ForEach-Object { "pid=$_" }) -join "; "
  throw "cleanup left zmx session '$name' running: $details"
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

Assert-PinnedCleanWorktree $WinghosttyRoot $pins.winghostty.sha "Winghostty"
Assert-PinnedCleanWorktree $ZmxRoot $pins.zmx.sha "zmx"

try {
  if (-not $SkipBuild) {
    Invoke-Native "Winghostty host artifact" {
      Push-Location $WinghosttyRoot
      try { & $Zig0152 build -Demit-win32-host=true } finally { Pop-Location }
    }
    Invoke-NativeWithRetry "zmx Windows provider artifact" {
      Push-Location $ZmxRoot
      try { & $Zig0160 build -Dtarget=x86_64-windows-gnu } finally { Pop-Location }
    }
    Invoke-Native "GraphCode terminal gate" {
      Push-Location $gateRoot
      try {
        & $Zig0152 build `
          "-Dwinghostty-dir=$WinghosttyRoot" `
          "-Dwinghostty-lib=$wingLib" `
          -Doptimize=ReleaseSafe
      } finally { Pop-Location }
    }
  }

  if (-not (Test-Path $app)) { throw "terminal gate executable is missing: $app" }
  if (-not (Test-Path $zmx)) { throw "zmx executable is missing: $zmx" }

  $env:GRAPHCODE_ZMX = $zmx
  $env:GRAPHCODE_GATE_CWD = $repoRoot
  $env:GRAPHCODE_TERMINAL_SESSION_PREFIX = $sessionPrefix
  Write-Host "terminal gate session prefix: $sessionPrefix"
  try {
    Invoke-Native "terminal gate first attach smoke" {
      Invoke-GateProcess @("--smoke") "terminal-gate:typed-input"
    }
    Record-TestOwnedSessions
    Write-OwnedResourceMetrics "terminal-gate:typed-input"
    Invoke-Native "first-session health" {
      Assert-ZmxSessionHealthy $names[0] "session A"
      Assert-ZmxSessionHealthy $names[1] "session B"
    }
    Invoke-Native "session shell pwd/cwd" {
      & $zmx send $names[0] "cd`r"
      & $zmx send $names[1] "cd`r"
    }
    $expectedCwd = ([System.IO.Path]::GetFullPath($repoRoot)).TrimEnd("\")
    Assert-HistoryContains $names[0] `
      $expectedCwd "session A cwd"
    Assert-HistoryContains $names[1] `
      $expectedCwd "session B cwd"
    Assert-HistoryContains $names[0] `
      "GraphCode typed output A" "typed A output"
    Assert-HistoryContains $names[1] `
      "GraphCode typed output B" "typed B output"
    Invoke-Native "seed persistent shell output" {
      & $zmx send $names[0] "echo GraphCode persistent VT output A`r"
      & $zmx send $names[1] "echo GraphCode persistent VT output B`r"
    }
    Assert-HistoryContains $names[0] `
      "GraphCode persistent VT output A" "first-session A history"
    Assert-HistoryContains $names[1] `
      "GraphCode persistent VT output B" "first-session B history"
    Invoke-Native "terminal gate independent restart attach smoke" {
      Invoke-GateProcess @("--smoke") "terminal-gate:reconnect"
    }
    Record-TestOwnedSessions
    Invoke-Native "restart-session health" {
      Assert-ZmxSessionHealthy $names[0] "restart session A"
      Assert-ZmxSessionHealthy $names[1] "restart session B"
    }
    Assert-HistoryContains $names[0] `
      "GraphCode persistent VT output A" "restart A history"
    Assert-HistoryContains $names[1] `
      "GraphCode persistent VT output B" "restart B history"
    Assert-HistoryContains $names[0] `
      "GraphCode typed output A" "restart typed A history"
    Assert-HistoryContains $names[1] `
      "GraphCode typed output B" "restart typed B history"
    Invoke-Native "terminal gate same-session attach smoke" {
      Invoke-GateProcess @("--smoke", "--same-session") "terminal-gate:typed-input"
    }
    Record-TestOwnedSessions
    Invoke-Native "same-session health" {
      Assert-ZmxSessionHealthy $names[2] "shared session"
    }
    Invoke-Native "seed shared persistent shell output" {
      & $zmx send $names[2] "echo GraphCode shared VT output`r"
    }
    Assert-HistoryContains $names[2] `
      "GraphCode shared VT output" "same-session history"
    Invoke-Native "terminal gate same-session restart smoke" {
      Invoke-GateProcess @("--smoke", "--same-session") "terminal-gate:reconnect"
    }
    Record-TestOwnedSessions
    Assert-HistoryContains $names[2] `
      "GraphCode shared VT output" "same-session restart history"
    if ($Stress) {
      Invoke-Native "terminal gate destroy/recreate stress" {
        Invoke-GateProcess @("--smoke", "--stress") "terminal-gate:stress"
      }
      Record-TestOwnedSessions
      Invoke-Native "post-stress session health" {
        Assert-ZmxSessionHealthy $names[0] "post-stress session A"
        Assert-ZmxSessionHealthy $names[1] "post-stress session B"
      }
    }
    Write-Host "Windows terminal gate smoke/stress: PASS"
  }
  finally {
    $cleanupFailures = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $names) {
      foreach ($processId in @(Get-ZmxSessionProcessIds $name)) {
        [void] $ownedSessionNames.Add($name)
        [void] $ownedProcessIds.Add($processId)
      }
    }
    $treeProcessIds = Get-ProcessTreeIds @($ownedProcessIds)
    foreach ($processId in $treeProcessIds) {
      [void] $ownedProcessIds.Add($processId)
    }
    foreach ($name in @($ownedSessionNames)) {
      if (@(Get-ZmxSessionProcessIds $name).Count -ne 0) {
        & $zmx kill $name *> $null
      }
    }
    foreach ($processId in @($ownedProcessIds)) {
      if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
      }
    }
    foreach ($name in @($ownedSessionNames)) {
      try {
        Assert-ZmxSessionAbsent $name
      } catch {
        $cleanupFailures.Add($_.Exception.Message)
      }
    }
    if ($env:GRAPHCODE_TERMINAL_GATE_INJECT_CLEANUP_FAILURE -eq "1") {
      $cleanupFailures.Add("injected cleanup failure")
    }
    if ($cleanupFailures.Count -ne 0) {
      throw "terminal gate cleanup failed: $($cleanupFailures -join '; ')"
    }
  }
}
finally {
  foreach ($path in $gateOutputFiles) {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  }
  Remove-Item Env:GRAPHCODE_ZMX -ErrorAction SilentlyContinue
  Remove-Item Env:GRAPHCODE_GATE_CWD -ErrorAction SilentlyContinue
  Remove-Item Env:GRAPHCODE_TERMINAL_SESSION_PREFIX -ErrorAction SilentlyContinue
}

exit 0
