[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $Executable,
  [Parameter(Mandatory)]
  [string] $PipeName,
  [int] $ExternalDaemonPid = 0
)

$ErrorActionPreference = "Stop"

if (-not ("GraphCodeTrayLiveNative" -as [type])) {
  Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class GraphCodeTrayLiveNative {
  public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct NotifyIconIdentifier {
    public int cbSize;
    public IntPtr hWnd;
    public uint uID;
    public Guid guidItem;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct Rect { public int left, top, right, bottom; }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr FindWindow(string className, string title);
  [DllImport("user32.dll")]
  public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")]
  public static extern bool PostMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")]
  public static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern uint RegisterWindowMessage(string name);
  [DllImport("user32.dll")]
  public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern int GetClassName(IntPtr hwnd, System.Text.StringBuilder className, int maxCount);
  [DllImport("user32.dll")]
  public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
  [DllImport("shell32.dll")]
  public static extern int Shell_NotifyIconGetRect(ref NotifyIconIdentifier identifier, out Rect rect);
}
"@
}

function Get-ShellWindow([int] $processId) {
  $script:foundWindow = [IntPtr]::Zero
  $callback = [GraphCodeTrayLiveNative+EnumWindowsProc]{
    param($hwnd, $unused)
    [uint32]$owner = 0
    [void][GraphCodeTrayLiveNative]::GetWindowThreadProcessId($hwnd, [ref]$owner)
    if ($owner -eq $processId) {
      $className = New-Object Text.StringBuilder 128
      [void][GraphCodeTrayLiveNative]::GetClassName($hwnd, $className, $className.Capacity)
      if ($className.ToString() -eq "GraphCodeWindowsShell") {
        $script:foundWindow = $hwnd
        return $false
      }
    }
    return $true
  }
  [void][GraphCodeTrayLiveNative]::EnumWindows($callback, [IntPtr]::Zero)
  return $script:foundWindow
}

function Assert-TrayIcon([IntPtr] $hwnd) {
  $id = [GraphCodeTrayLiveNative+NotifyIconIdentifier]::new()
  $id.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($id)
  $id.hWnd = $hwnd
  $id.uID = 1
  $rect = [GraphCodeTrayLiveNative+Rect]::new()
  $result = [GraphCodeTrayLiveNative]::Shell_NotifyIconGetRect([ref]$id, [ref]$rect)
  if ($result -ne 0 -or $rect.right -le $rect.left -or $rect.bottom -le $rect.top) {
    throw "GraphCode tray icon was not discoverable through Shell_NotifyIconGetRect"
  }
}

function Assert-NoConsoleWindow([int] $processId) {
  $script:found = $false
  $callback = [GraphCodeTrayLiveNative+EnumWindowsProc]{
    param($hwnd, $unused)
    [uint32]$owner = 0
    [void][GraphCodeTrayLiveNative]::GetWindowThreadProcessId($hwnd, [ref]$owner)
    if ($owner -eq $processId) {
      $class = New-Object Text.StringBuilder 128
      [void][GraphCodeTrayLiveNative]::GetClassName($hwnd, $class, $class.Capacity)
      if ($class.ToString() -eq "ConsoleWindowClass") { $script:found = $true }
    }
    return $true
  }
  [void][GraphCodeTrayLiveNative]::EnumWindows($callback, [IntPtr]::Zero)
  if ($script:found) { throw "GUI shell created a console window" }
}

$oldPipe = [Environment]::GetEnvironmentVariable("GRAPHCODE_DAEMON_PIPE")
$oldRequire = [Environment]::GetEnvironmentVariable("GRAPHCODE_SHELL_REQUIRE_DAEMON")
$process = $null
try {
  $env:GRAPHCODE_DAEMON_PIPE = "\\.\pipe\$PipeName"
  $env:GRAPHCODE_SHELL_REQUIRE_DAEMON = "0"
  $process = Start-Process -FilePath $Executable -PassThru -WindowStyle Hidden
  $hwnd = [IntPtr]::Zero
  for ($i = 0; $i -lt 60 -and $hwnd -eq [IntPtr]::Zero; $i++) {
    Start-Sleep -Milliseconds 100
    $hwnd = Get-ShellWindow $process.Id
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "GraphCode GUI window did not start" }
  Assert-NoConsoleWindow $process.Id
  Assert-TrayIcon $hwnd

  [void][GraphCodeTrayLiveNative]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 250
  if ([GraphCodeTrayLiveNative]::IsWindowVisible($hwnd)) { throw "WM_CLOSE did not hide the shell" }
  Assert-TrayIcon $hwnd

  [void][GraphCodeTrayLiveNative]::SendMessage($hwnd, 0x8000004D, [IntPtr]::Zero, [IntPtr]0x0203)
  Start-Sleep -Milliseconds 250
  if (-not [GraphCodeTrayLiveNative]::IsWindowVisible($hwnd)) {
    [void][GraphCodeTrayLiveNative]::SendMessage($hwnd, 0x0111, [IntPtr]0x5001, [IntPtr]::Zero)
  }
  if (-not [GraphCodeTrayLiveNative]::IsWindowVisible($hwnd)) { throw "Tray double-click did not restore the shell" }
  if ([GraphCodeTrayLiveNative]::GetForegroundWindow() -ne $hwnd) {
    [void][GraphCodeTrayLiveNative]::SetForegroundWindow($hwnd)
  }

  $second = Start-Process -FilePath $Executable -PassThru -WindowStyle Hidden
  if (-not $second.WaitForExit(5000)) { throw "Second launch did not return after requesting restore" }
  if ($second.ExitCode -ne 0) { throw "Second launch exited with code $($second.ExitCode)" }
  if (-not [GraphCodeTrayLiveNative]::IsWindowVisible($hwnd)) { throw "Second launch did not restore the existing shell" }

  $taskbar = [GraphCodeTrayLiveNative]::RegisterWindowMessage("TaskbarCreated")
  [void][GraphCodeTrayLiveNative]::PostMessage($hwnd, $taskbar, [IntPtr]::Zero, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 250
  Assert-TrayIcon $hwnd

  [void][GraphCodeTrayLiveNative]::PostMessage($hwnd, 0x0111, [IntPtr]0x5002, [IntPtr]::Zero)
  if (-not $process.WaitForExit(5000)) { throw "Tray Exit command did not terminate the shell" }
  if ($ExternalDaemonPid -and -not (Get-Process -Id $ExternalDaemonPid -ErrorAction SilentlyContinue)) {
    throw "External daemon was terminated by tray Exit"
  }
  Write-Output "Tray live executable tests: PASS"
} finally {
  if ($process -and -not $process.HasExited) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
  }
  if ($null -eq $oldPipe) { Remove-Item Env:GRAPHCODE_DAEMON_PIPE -ErrorAction SilentlyContinue }
  else { $env:GRAPHCODE_DAEMON_PIPE = $oldPipe }
  if ($null -eq $oldRequire) { Remove-Item Env:GRAPHCODE_SHELL_REQUIRE_DAEMON -ErrorAction SilentlyContinue }
  else { $env:GRAPHCODE_SHELL_REQUIRE_DAEMON = $oldRequire }
}
