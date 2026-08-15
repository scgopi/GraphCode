[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $WinghosttyRoot,
  [Parameter(Mandatory)]
  [string] $ZmxRoot,
  [string] $Zig0152 = "zig",
  [string] $Zig0160 = "zig",
  [switch] $SkipBuild,
  [switch] $Stress,
  [switch] $UseStubDaemon
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$shellRoot = Join-Path $repoRoot "graphcode-windows"
$pins = Get-Content (Join-Path $shellRoot "provider-pins.json") -Raw | ConvertFrom-Json
$app = Join-Path $shellRoot "zig-out\bin\graphcode-windows.exe"
$stubProcess = $null
$busyStubProcess = $null
$stubResult = Join-Path $shellRoot "stub-result-$PID.json"
$busyResult = Join-Path $shellRoot "busy-stub-result-$PID.json"
$busyError = Join-Path $shellRoot "busy-stub-error-$PID.txt"
$oldPipe = [Environment]::GetEnvironmentVariable("GRAPHCODE_DAEMON_PIPE")
$oldRequireDaemon = [Environment]::GetEnvironmentVariable("GRAPHCODE_SHELL_REQUIRE_DAEMON")

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
        $_.Name -match "(?i)^graphcode-windows(?:\.exe)?$" -or
        ($_.Name -match "(?i)^zmx(?:\.exe)?$" -and
          $_.CommandLine -and $_.CommandLine -match "graphcode-windows")
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
    Invoke-Native "Winghostty host artifact" {
      Push-Location $WinghosttyRoot
      try { & $Zig0152 build -Demit-win32-host=true } finally { Pop-Location }
    }
    Invoke-Native "zmx Windows provider artifact" {
      Push-Location $ZmxRoot
      try { & $Zig0160 build -Dtarget=x86_64-windows-gnu } finally { Pop-Location }
    }
    Invoke-Native "GraphCode Windows shell" {
      Push-Location $shellRoot
      try {
        & $Zig0152 build `
          "-Dwinghostty-dir=$WinghosttyRoot" `
          "-Dwinghostty-lib=$(Join-Path $WinghosttyRoot 'zig-out\lib\winghostty-win32-host.lib')" `
          -Doptimize=ReleaseSafe
      } finally { Pop-Location }
    }
  }

  if (-not (Test-Path -LiteralPath $app)) {
    throw "GraphCode Windows shell executable is missing: $app"
  }
  $env:GRAPHCODE_ZMX = Join-Path $ZmxRoot "zig-out\bin\zmx.exe"
  $env:GRAPHCODE_GATE_CWD = $repoRoot
  if ($UseStubDaemon) {
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
      $stubResult
    )
    $env:GRAPHCODE_DAEMON_PIPE = "\\.\pipe\$pipeName"
    $env:GRAPHCODE_SHELL_REQUIRE_DAEMON = "1"
  }
  $arguments = @("--smoke")
  if ($Stress) { $arguments += "--stress" }
  Invoke-Native "GraphCode Windows shell smoke/stress" {
    & $app @arguments
  }
  if ($UseStubDaemon) {
    Invoke-Native "GraphCode Windows shell restart smoke" {
      & $app @arguments
    }
  }
  if ($UseStubDaemon) {
    if (-not (Test-Path -LiteralPath $stubResult)) {
      throw "Stub daemon did not write protocol evidence"
    }
    $evidence = Get-Content -LiteralPath $stubResult -Raw | ConvertFrom-Json
    foreach ($property in @(
        "protocolConnected",
        "correlatedRequests",
        "subscriptionSeen",
        "reconnectObserved",
        "graphSent"
      )) {
      if (-not [bool] $evidence.$property) {
        throw "Stub daemon evidence failed: $property"
      }
    }
    if ($evidence.error) {
      throw "Stub daemon reported an error: $($evidence.error)"
    }
    foreach ($command in @("listRecentProjects", "openProject", "graphCommand")) {
      if (@($evidence.commands) -notcontains $command) {
      throw "Stub daemon did not observe command: $command"
      }
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
    if (-not $busyApp.WaitForExit(8000)) {
      Stop-Process -Id $busyApp.Id -Force
      throw "Busy daemon smoke blocked the UI beyond the bounded timeout"
    }
    if ($busyApp.ExitCode -eq 0) {
      throw "Busy daemon smoke did not surface a transport error"
    }
    $busyEvidence = Get-Content -LiteralPath $busyResult -Raw | ConvertFrom-Json
    if (-not [bool] $busyEvidence.busyObserved) {
      throw "Busy daemon smoke did not accept a non-reading connection"
    }
    $busyErrorText = Get-Content -LiteralPath $busyError -Raw
    if ($busyErrorText -notmatch "(?i)Smoke daemon status: .*daemon") {
      throw "Busy daemon smoke did not post a daemon transport error"
    }
  }
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
    foreach ($session in @(
        "11111111-1111-4111-8111-111111111111",
        "22222222-2222-4222-8222-222222222222"
      )) {
      & $env:GRAPHCODE_ZMX kill --force $session *> $null
    }
  }
  Remove-Item Env:GRAPHCODE_ZMX -ErrorAction SilentlyContinue
  Remove-Item Env:GRAPHCODE_GATE_CWD -ErrorAction SilentlyContinue
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
  Remove-Item -LiteralPath $stubResult -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $busyResult,$busyError -Force -ErrorAction SilentlyContinue
  Assert-NoOrphanShellProcesses
}

exit 0
