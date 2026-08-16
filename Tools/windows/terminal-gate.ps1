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
$baselineSessionNames = [System.Collections.Generic.HashSet[string]]::new()
$ownedSessionNames = [System.Collections.Generic.HashSet[string]]::new()
$ownedProcessIds = [System.Collections.Generic.HashSet[int]]::new()

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
    if ($_ -match "^name=([^\s]+)\s+pid=(\d+)") {
      [pscustomobject]@{ Name = $Matches[1]; Pid = [int] $Matches[2] }
    }
  })
}

function Record-TestOwnedSessions {
  foreach ($record in @(Get-ZmxSessionRecords)) {
    if (-not $baselineSessionNames.Contains($record.Name)) {
      [void] $ownedSessionNames.Add($record.Name)
      [void] $ownedProcessIds.Add($record.Pid)
    }
  }
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
    if ($lines.Count -eq 0 -and $processIds.Count -eq 0) {
      return
    }
    Start-Sleep -Milliseconds 250
  }
  $details = @($lines + ($processIds | ForEach-Object { "pid=$_" })) -join "; "
  throw "cleanup left zmx session '$name' registered or running: $details"
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
  foreach ($record in @(Get-ZmxSessionRecords)) {
    [void] $baselineSessionNames.Add($record.Name)
  }
  $names = @(
    "graphcode-terminal-gate-a",
    "graphcode-terminal-gate-b",
    "graphcode-terminal-gate-shared"
  )
  try {
    Invoke-Native "terminal gate first attach smoke" {
      & $app --smoke
    }
    Record-TestOwnedSessions
    Invoke-Native "first-session health" {
      & $zmx get graphcode-terminal-gate-a
      & $zmx get graphcode-terminal-gate-b
    }
    Invoke-Native "session shell pwd/cwd" {
      & $zmx send graphcode-terminal-gate-a "cd`r"
      & $zmx send graphcode-terminal-gate-b "cd`r"
    }
    $expectedCwd = ([System.IO.Path]::GetFullPath($repoRoot)).TrimEnd("\")
    Assert-HistoryContains "graphcode-terminal-gate-a" `
      $expectedCwd "session A cwd"
    Assert-HistoryContains "graphcode-terminal-gate-b" `
      $expectedCwd "session B cwd"
    Assert-HistoryContains "graphcode-terminal-gate-a" `
      "GraphCode typed output A" "typed A output"
    Assert-HistoryContains "graphcode-terminal-gate-b" `
      "GraphCode typed output B" "typed B output"
    Invoke-Native "seed persistent shell output" {
      & $zmx send graphcode-terminal-gate-a "echo GraphCode persistent VT output A`r"
      & $zmx send graphcode-terminal-gate-b "echo GraphCode persistent VT output B`r"
    }
    Assert-HistoryContains "graphcode-terminal-gate-a" `
      "GraphCode persistent VT output A" "first-session A history"
    Assert-HistoryContains "graphcode-terminal-gate-b" `
      "GraphCode persistent VT output B" "first-session B history"
    Invoke-Native "terminal gate independent restart attach smoke" {
      & $app --smoke
    }
    Record-TestOwnedSessions
    Invoke-Native "restart-session health" {
      & $zmx get graphcode-terminal-gate-a
      & $zmx get graphcode-terminal-gate-b
    }
    Assert-HistoryContains "graphcode-terminal-gate-a" `
      "GraphCode persistent VT output A" "restart A history"
    Assert-HistoryContains "graphcode-terminal-gate-b" `
      "GraphCode persistent VT output B" "restart B history"
    Assert-HistoryContains "graphcode-terminal-gate-a" `
      "GraphCode typed output A" "restart typed A history"
    Assert-HistoryContains "graphcode-terminal-gate-b" `
      "GraphCode typed output B" "restart typed B history"
    Invoke-Native "terminal gate same-session attach smoke" {
      & $app --smoke --same-session
    }
    Record-TestOwnedSessions
    Invoke-Native "same-session health" {
      & $zmx get graphcode-terminal-gate-shared
    }
    Invoke-Native "seed shared persistent shell output" {
      & $zmx send graphcode-terminal-gate-shared "echo GraphCode shared VT output`r"
    }
    Assert-HistoryContains "graphcode-terminal-gate-shared" `
      "GraphCode shared VT output" "same-session history"
    Invoke-Native "terminal gate same-session restart smoke" {
      & $app --smoke --same-session
    }
    Assert-HistoryContains "graphcode-terminal-gate-shared" `
      "GraphCode shared VT output" "same-session restart history"
    if ($Stress) {
      Invoke-Native "terminal gate destroy/recreate stress" {
        & $app --smoke --stress
      }
      Record-TestOwnedSessions
      Invoke-Native "post-stress session health" {
        & $zmx get graphcode-terminal-gate-a
        & $zmx get graphcode-terminal-gate-b
      }
    }
    Write-Host "Windows terminal gate smoke/stress: PASS"
  }
  finally {
    $cleanupFailures = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($ownedSessionNames)) {
      & $zmx kill $name *> $null
      if ($LASTEXITCODE -ne 0) {
        $cleanupFailures.Add("$name kill exited with $LASTEXITCODE")
      }
    }
    foreach ($name in @($ownedSessionNames)) {
      try {
        Assert-ZmxSessionAbsent $name
      } catch {
        $cleanupFailures.Add($_.Exception.Message)
      }
    }
    foreach ($processId in @($ownedProcessIds)) {
      if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
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
}

exit 0
