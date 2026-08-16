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

function Get-ZmxSessionLines([string] $name) {
  $escaped = [regex]::Escape($name)
  $output = @(& $zmx list 2>&1)
  if ($LASTEXITCODE -ne 0) {
    return @()
  }
  return @(
    $output |
      ForEach-Object { $_.ToString() } |
      Where-Object { $_ -match "(?m)(?:^|\s)name=$escaped(?:\s|$)" }
  )
}

function Get-ZmxSessionRecords {
  @(& $zmx list 2>$null | ForEach-Object {
    if ($_ -match "name=([^\s]+)\s+pid=(\d+)") {
      [pscustomobject]@{ Name = $Matches[1]; Pid = [int] $Matches[2] }
    }
  })
}

function Record-TestOwnedSessions {
  foreach ($record in @(Get-ZmxSessionRecords)) {
    if ($names -contains $record.Name) {
      [void] $ownedSessionNames.Add($record.Name)
      [void] $ownedProcessIds.Add($record.Pid)
    }
  }

}

function Write-OwnedResourceMetrics {
  $metrics = @($ownedProcessIds | ForEach-Object {
      $p = Get-Process -Id $_ -ErrorAction SilentlyContinue
      if ($p) {
        [pscustomobject]@{
          pid = $_
          role = if ($p.ProcessName -match "zmx") { "zmx" } else { $p.ProcessName }
          handles = [int64]$p.HandleCount
          privateBytes = [int64]$p.PrivateMemorySize64
        }
      }
    })
  Write-Host ("PRODUCT_RESOURCE_METRICS_JSON=" + (@{
      sessions = @($ownedSessionNames)
      processes = $metrics
    } | ConvertTo-Json -Compress -Depth 5))
}

function Get-ZmxSessionProcessIds([string] $name) {
  $ids = [System.Collections.Generic.List[int]]::new()
  foreach ($line in @(Get-ZmxSessionLines $name)) {
    if ($line -match "\bpid=(\d+)\b") {
      $ids.Add([int] $Matches[1])
    }
  }
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
    $lines = @(Get-ZmxSessionLines $name)
    $processIds = @(Get-ZmxSessionProcessIds $name)
    $liveLines = @($lines | Where-Object {
        $_ -notmatch "(?i)status=unreachable|err=ConnectionRefused"
      })
    if ($liveLines.Count -eq 0 -and $processIds.Count -eq 0) {
      return
    }

    Start-Sleep -Milliseconds 250
  }
  $details = @($lines + ($processIds | ForEach-Object { "pid=$_" })) -join "; "
  throw "cleanup left zmx session '$name' registered or running: $details"
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
    Invoke-Native "zmx Windows provider artifact" {
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
      & $app --smoke
    }
    Record-TestOwnedSessions
    Write-OwnedResourceMetrics
    Write-Host "terminal gate sessions after attach:"
    & $zmx list | Select-String $sessionPrefix
    Invoke-Native "first-session health" {
      & $zmx get $names[0]
      & $zmx get $names[1]
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
      & $app --smoke
    }
    Record-TestOwnedSessions
    Invoke-Native "restart-session health" {
      & $zmx get $names[0]
      & $zmx get $names[1]
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
      & $app --smoke --same-session
    }
    Record-TestOwnedSessions
    Invoke-Native "same-session health" {
      & $zmx get $names[2]
    }
    Invoke-Native "seed shared persistent shell output" {
      & $zmx send $names[2] "echo GraphCode shared VT output`r"
    }
    Assert-HistoryContains $names[2] `
      "GraphCode shared VT output" "same-session history"
    Invoke-Native "terminal gate same-session restart smoke" {
      & $app --smoke --same-session
    }
    Record-TestOwnedSessions
    Assert-HistoryContains $names[2] `
      "GraphCode shared VT output" "same-session restart history"
    if ($Stress) {
      Invoke-Native "terminal gate destroy/recreate stress" {
        & $app --smoke --stress
      }
      Record-TestOwnedSessions
      Invoke-Native "post-stress session health" {
        & $zmx get $names[0]
        & $zmx get $names[1]
      }
    }
    Write-Host "Windows terminal gate smoke/stress: PASS"
  }
  finally {
    $cleanupFailures = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($ownedSessionNames)) {
      foreach ($processId in @(Get-ZmxSessionProcessIds $name)) {
        [void] $ownedProcessIds.Add($processId)
      }
    }
    $treeProcessIds = Get-ProcessTreeIds @($ownedProcessIds)
    foreach ($processId in $treeProcessIds) {
      [void] $ownedProcessIds.Add($processId)
    }
    foreach ($name in @($ownedSessionNames)) {
      & $zmx kill $name *> $null
      if ($LASTEXITCODE -ne 0) {
        $cleanupFailures.Add("$name kill exited with $LASTEXITCODE")
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
  Remove-Item Env:GRAPHCODE_ZMX -ErrorAction SilentlyContinue
  Remove-Item Env:GRAPHCODE_GATE_CWD -ErrorAction SilentlyContinue
  Remove-Item Env:GRAPHCODE_TERMINAL_SESSION_PREFIX -ErrorAction SilentlyContinue
}

exit 0
