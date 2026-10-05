[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $Executable
)

$ErrorActionPreference = "Stop"
$script:WM_QUIT = 0x0012
$daemonExecutable = Join-Path (Split-Path -Parent $Executable) "graphcoded.exe"
$cliExecutable = Join-Path (Split-Path -Parent $Executable) "graphcode.exe"
$supportDirectory = Join-Path (Split-Path -Parent $Executable) ".handoff-live-$PID"
$daemonPipe = "\\.\pipe\graphcode-handoff-live-$PID"

if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
  throw "shell executable is missing: $Executable"
}
foreach ($path in @($daemonExecutable, $cliExecutable)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "handoff live test requires sibling $(Split-Path -Leaf $path)"
  }
}

if (-not ("GraphCodeDaemonHandoffNative" -as [type])) {
  Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class GraphCodeDaemonHandoffNative {
  public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
  [DllImport("user32.dll")]
  public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
  [DllImport("user32.dll")]
  public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr GetProp(IntPtr hwnd, string name);
  [DllImport("user32.dll")]
  public static extern bool PostThreadMessage(uint threadId, uint message, IntPtr wParam, IntPtr lParam);
}
"@
}

function Start-HandoffShell(
  [string] $userName,
  [string] $daemonStatePath
) {
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $Executable
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.WorkingDirectory = Split-Path -Parent $Executable
  [void] $startInfo.Environment.Remove("GRAPHCODE_DAEMON_STARTUP_EVENT")
  [void] $startInfo.Environment.Remove("GRAPHCODE_DAEMON_HANDOFF_READY_EVENT")
  [void] $startInfo.Environment.Remove("GRAPHCODE_DAEMON_SHUTDOWN_EVENT")
  $startInfo.Environment["GRAPHCODE_SUPPORT_DIR"] = $supportDirectory
  $startInfo.Environment["GRAPHCODE_DAEMON_PIPE"] = $daemonPipe
  $startInfo.Environment["GRAPHCODE_SHELL_REQUIRE_DAEMON"] = "0"
  $startInfo.Environment["GRAPHCODE_DAEMON_HANDOFF_TEST_STATE"] = $daemonStatePath
  $startInfo.Environment["GRAPHCODE_DAEMON_SUPERVISOR_TEST_HOOK"] = "1"
  $startInfo.Environment["GRAPHCODE_DAEMON_HANDOFF_TEST_USER"] = $userName
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    throw "could not start shell $userName"
  }
  [void] $process.Handle
  return $process
}

function Get-DaemonChildren([int[]] $parentIds) {
  $expected = [IO.Path]::GetFullPath($daemonExecutable)
  return @(
    Get-CimInstance Win32_Process -ErrorAction Stop |
      Where-Object {
        $_.Name -ieq "graphcoded.exe" -and
        $parentIds -contains [int]$_.ParentProcessId -and
        $_.ExecutablePath -and
        [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $expected
      }
  )
}

function Get-ShellThread([int] $processId) {
  $script:handoffThread = [uint32]0
  $callback = [GraphCodeDaemonHandoffNative+EnumWindowsProc]{
    param($hwnd, $unused)
    [uint32]$owner = 0
    [uint32]$thread = [GraphCodeDaemonHandoffNative]::GetWindowThreadProcessId(
      $hwnd, [ref]$owner)
    if ($owner -eq $processId) {
      $script:handoffThread = $thread
      return $false
    }
    return $true
  }
  [void][GraphCodeDaemonHandoffNative]::EnumWindows($callback, [IntPtr]::Zero)
  return $script:handoffThread
}

function Get-ShellSupervisorState([int] $processId) {
  $script:handoffWindow = [IntPtr]::Zero
  $callback = [GraphCodeDaemonHandoffNative+EnumWindowsProc]{
    param($hwnd, $unused)
    [uint32]$owner = 0
    [void][GraphCodeDaemonHandoffNative]::GetWindowThreadProcessId($hwnd, [ref]$owner)
    if ($owner -eq $processId) {
      $script:handoffWindow = $hwnd
      return $false
    }
    return $true
  }
  [void][GraphCodeDaemonHandoffNative]::EnumWindows($callback, [IntPtr]::Zero)
  if ($script:handoffWindow -eq [IntPtr]::Zero) { return 0 }
  return [GraphCodeDaemonHandoffNative]::GetProp(
    $script:handoffWindow, "GraphCode.Windows.DaemonSupervisorState").ToInt64()
}

function Stop-ShellNormally([Diagnostics.Process] $process, [string] $role) {
  for ($i = 0; $i -lt 80; $i++) {
    $thread = Get-ShellThread $process.Id
    if ($thread -ne 0) {
      if (-not [GraphCodeDaemonHandoffNative]::PostThreadMessage(
          $thread, $script:WM_QUIT, [IntPtr]::Zero, [IntPtr]::Zero)) {
        throw "could not post WM_QUIT to $role shell"
      }
      if (-not $process.WaitForExit(7000)) {
        throw "$role shell did not exit normally"
      }
      return
    }
    Start-Sleep -Milliseconds 100
  }
  throw "$role shell did not create a UI message queue"
}

function Assert-EndpointReachable {
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $cliExecutable
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.WorkingDirectory = Split-Path -Parent $Executable
  $startInfo.Environment["GRAPHCODE_SUPPORT_DIR"] = $supportDirectory
  $startInfo.Environment["GRAPHCODE_DAEMON_PIPE"] = $daemonPipe
  [void] $startInfo.ArgumentList.Add("projects")
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start() -or -not $process.WaitForExit(7000)) {
    throw "daemon endpoint was not reachable through graphcode.exe"
  }
  $stderr = $process.StandardError.ReadToEnd()
  if ($process.ExitCode -ne 0) {
    throw "daemon endpoint rejected graphcode.exe: $stderr"
  }
  $process.Dispose()
}

function Get-HandoffElapsed([Diagnostics.Stopwatch] $clock) {
  return "{0:n2}s" -f $clock.Elapsed.TotalSeconds
}

function Get-DaemonTestState([string] $path) {
  if (Test-Path -LiteralPath $path) {
    return (Get-Content -LiteralPath $path -Raw).Trim()
  }
  return "<missing>"
}

function Get-ProcessStatus([Diagnostics.Process] $process, [string] $role) {
  if (-not $process) { return "$role=<not-started>" }
  $process.Refresh()
  return "$role(pid=$($process.Id), exited=$($process.HasExited), exitCode=$(
    if ($process.HasExited) { $process.ExitCode } else { '<running>' }))"
}

function Assert-ShellsAlive(
  [Diagnostics.Process] $shellA,
  [Diagnostics.Process] $shellB,
  [string] $diagnostics
) {
  foreach ($entry in @(
      @{ Process = $shellA; Role = "shellA" },
      @{ Process = $shellB; Role = "shellB" }
    )) {
    if (-not $entry.Process) { continue }
    $entry.Process.Refresh()
    if ($entry.Process.HasExited) {
      throw "$($entry.Role) exited before daemon handoff completed: $diagnostics"
    }
  }
}

function Get-HandoffDiagnostics(
  [Diagnostics.Process] $shellA,
  [Diagnostics.Process] $shellB,
  [string] $daemonStateA,
  [string] $daemonStateB,
  [Diagnostics.Stopwatch] $clock,
  [Diagnostics.Process] $daemonProcess = $null,
  [object] $selectedChild = $null
) {
  $ownerState = if ($shellA) { Get-ShellSupervisorState $shellA.Id } else { "<missing>" }
  $contenderState = if ($shellB) { Get-ShellSupervisorState $shellB.Id } else { "<missing>" }
  $daemonStatus = if ($daemonProcess) {
    $daemonProcess.Refresh()
    "daemon(pid=$($daemonProcess.Id), exited=$($daemonProcess.HasExited), exitCode=$(
      if ($daemonProcess.HasExited) { $daemonProcess.ExitCode } else { '<running>' }))"
  } elseif ($selectedChild) {
    "daemon(pid=$($selectedChild.ProcessId), parent=$($selectedChild.ParentProcessId), executable=$($selectedChild.ExecutablePath))"
  } else {
    "daemon=<missing>"
  }
  return @(
    "elapsed=$(Get-HandoffElapsed $clock)",
    (Get-ProcessStatus $shellA "shellA"),
    (Get-ProcessStatus $shellB "shellB"),
    $daemonStatus,
    "daemonA=$(Get-DaemonTestState $daemonStateA)",
    "daemonB=$(Get-DaemonTestState $daemonStateB)",
    "shellStateA=$ownerState",
    "shellStateB=$contenderState"
  ) -join "; "
}

$shellA = $null
$shellB = $null
$daemonProcess = $null
$handoffClock = [Diagnostics.Stopwatch]::StartNew()
try {
  New-Item -ItemType Directory -Force -Path $supportDirectory | Out-Null
  $daemonStateA = Join-Path $supportDirectory "daemon-a.state"
  $daemonStateB = Join-Path $supportDirectory "daemon-b.state"
  $shellA = Start-HandoffShell `
    "graphcode-handoff-a-$PID" $daemonStateA
  $shellB = Start-HandoffShell `
    "graphcode-handoff-b-$PID" $daemonStateB
  $parents = @($shellA.Id, $shellB.Id)
  $children = @()
  $selectedChild = $null
  $spawnDeadline = [DateTime]::UtcNow.AddSeconds(20)
  while ([DateTime]::UtcNow -lt $spawnDeadline) {
    Assert-ShellsAlive $shellA $shellB (
      Get-HandoffDiagnostics $shellA $shellB $daemonStateA $daemonStateB $handoffClock
    )
    $children = @(Get-DaemonChildren $parents)
    if ($children.Count -eq 1) {
      $candidate = Get-Process -Id $children[0].ProcessId -ErrorAction SilentlyContinue
      if ($candidate) {
        $daemonProcess = $candidate
        $selectedChild = $children[0]
        break
      }
      $children = @()
    }
    if ($children.Count -gt 1) {
      throw "concurrent shells spawned $($children.Count) graphcoded children"
    }
    Start-Sleep -Milliseconds 100
  }
  if (-not $daemonProcess -or -not $selectedChild) {
    throw (
      "concurrent shells did not spawn exactly one graphcoded child before the deadline: " +
      (Get-HandoffDiagnostics $shellA $shellB $daemonStateA $daemonStateB $handoffClock)
    )
  }
  $owner = if ($selectedChild.ParentProcessId -eq $shellA.Id) { $shellA } else { $shellB }
  $contender = if ($owner.Id -eq $shellA.Id) { $shellB } else { $shellA }
  $classificationDeadline = [DateTime]::UtcNow.AddSeconds(30)
  while ([DateTime]::UtcNow -lt $classificationDeadline) {
    Assert-ShellsAlive $shellA $shellB (
      Get-HandoffDiagnostics $shellA $shellB $daemonStateA $daemonStateB $handoffClock $daemonProcess $selectedChild
    )
    $daemonProcess.Refresh()
    if ($daemonProcess.HasExited) {
      throw (
        "graphcoded exited before shell ownership classification completed: " +
        (Get-HandoffDiagnostics $shellA $shellB $daemonStateA $daemonStateB $handoffClock $daemonProcess $selectedChild)
      )
    }
    $ownerState = Get-ShellSupervisorState $owner.Id
    $contenderState = Get-ShellSupervisorState $contender.Id
    if ($ownerState -eq 1 -and $contenderState -eq 2) {
      break
    }
    Start-Sleep -Milliseconds 100
  }
  $ownerState = Get-ShellSupervisorState $owner.Id
  $contenderState = Get-ShellSupervisorState $contender.Id
  if ($ownerState -ne 1 -or $contenderState -ne 2) {
    throw (
      "shell ownership classification did not reach owner=1 and contender=2 before the deadline: " +
      "owner=$ownerState, contender=$contenderState; " +
      (Get-HandoffDiagnostics $shellA $shellB $daemonStateA $daemonStateB $handoffClock $daemonProcess $selectedChild)
    )
  }
  Assert-EndpointReachable

  Stop-ShellNormally $contender "non-owning"
  Start-Sleep -Milliseconds 250
  $daemonProcess.Refresh()
  if ($daemonProcess.HasExited) {
    throw "non-owning shell exit stopped the externally owned daemon"
  }

  Stop-ShellNormally $owner "owning"
  if (-not $daemonProcess.WaitForExit(7000)) {
    throw "owning shell exit did not stop its graphcoded child"
  }
  Write-Output "Concurrent two-shell daemon handoff: PASS"
} finally {
  foreach ($process in @($shellA, $shellB)) {
    if ($process -and -not $process.HasExited) {
      Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    if ($process) { $process.Dispose() }
  }
  if ($daemonProcess -and -not $daemonProcess.HasExited) {
    Stop-Process -Id $daemonProcess.Id -Force -ErrorAction SilentlyContinue
  }
  $expectedDaemonPath = [IO.Path]::GetFullPath($daemonExecutable)
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Name -ieq "graphcoded.exe" -and $_.ExecutablePath -and
      [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $expectedDaemonPath
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $supportDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
