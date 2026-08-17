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
  $startInfo.Environment["USERNAME"] = $userName
  $startInfo.Environment["USER"] = $userName
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

$shellA = $null
$shellB = $null
$daemonProcess = $null
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
  for ($i = 0; $i -lt 100; $i++) {
    $children = @(Get-DaemonChildren $parents)
    if ($children.Count -eq 1) { break }
    if ($children.Count -gt 1) {
      throw "concurrent shells spawned $($children.Count) graphcoded children"
    }
    Start-Sleep -Milliseconds 100
  }
  if ($children.Count -ne 1) {
    $states = @($shellA, $shellB | ForEach-Object {
        $_.Refresh()
        "pid=$($_.Id), exited=$($_.HasExited), exitCode=$(
          if ($_.HasExited) { $_.ExitCode } else { '<running>' })"
      }) -join "; "
    $daemonStates = @($daemonStateA, $daemonStateB |
      ForEach-Object {
        "$(Split-Path -Leaf $_)=$(if (Test-Path -LiteralPath $_) {
          Get-Content -LiteralPath $_ -Raw
        } else { '<missing>' })"
      }) -join "; "
    throw (
      "concurrent shells did not spawn exactly one graphcoded child: $states; $daemonStates; " +
      "shellStateA=$(Get-ShellSupervisorState $shellA.Id), shellStateB=$(Get-ShellSupervisorState $shellB.Id)"
    )
  }
  $daemonProcess = Get-Process -Id $children[0].ProcessId -ErrorAction Stop
  $owner = if ($children[0].ParentProcessId -eq $shellA.Id) { $shellA } else { $shellB }
  $contender = if ($owner.Id -eq $shellA.Id) { $shellB } else { $shellA }
  for ($i = 0; $i -lt 80; $i++) {
    if ((Get-ShellSupervisorState $owner.Id) -eq 1 -and
        (Get-ShellSupervisorState $contender.Id) -eq 2) {
      break
    }
    Start-Sleep -Milliseconds 100
  }
  $ownerState = Get-ShellSupervisorState $owner.Id
  $contenderState = Get-ShellSupervisorState $contender.Id
  if ($ownerState -ne 1 -or $contenderState -ne 2) {
    throw (
      "shell ownership classification was incorrect: owner=$ownerState, contender=$contenderState, " +
      "daemonA=$(if (Test-Path $daemonStateA) { Get-Content $daemonStateA -Raw } else { '<missing>' }), " +
      "daemonB=$(if (Test-Path $daemonStateB) { Get-Content $daemonStateB -Raw } else { '<missing>' })"
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
