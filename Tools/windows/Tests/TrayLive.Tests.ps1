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
  [StructLayout(LayoutKind.Sequential)]
  public struct Point { public int x, y; }
  [DllImport("user32.dll")]
  public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")]
  public static extern bool IsWindow(IntPtr hwnd);
  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")]
  public static extern bool PostMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")]
  public static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr GetProp(IntPtr hwnd, string name);
  [DllImport("user32.dll")]
  public static extern IntPtr MonitorFromPoint(Point point, uint flags);
  [DllImport("user32.dll")]
  public static extern uint GetDpiForWindow(IntPtr hwnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr FindWindow(string className, string title);
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
  [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
  public static extern bool Shell_NotifyIcon(uint message, ref NotifyIconIdentifier identifier);
}
"@
}

$script:NIM_DELETE = 0x0002
$script:WM_CLOSE = 0x0010
$script:WM_COMMAND = 0x0111
$script:WM_SYSCOMMAND = 0x0112
$script:WM_LBUTTONDBLCLK = 0x0203
$script:WM_CONTEXTMENU = 0x007B
$script:SC_CLOSE = 0xF060
$script:MONITOR_DEFAULTTONULL = 0
$script:TRAY_OPEN = 1
$script:TRAY_CONTEXT = 2
$script:TRAY_EXIT_COMMAND = 0x5002

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
  return $rect
}

function Wait-PhysicalTrayIcon([IntPtr] $hwnd) {
  for ($i = 0; $i -lt 30; $i++) {
    try {
      $rect = Assert-TrayIcon $hwnd
      $point = [GraphCodeTrayLiveNative+Point]::new()
      $point.x = [int](($rect.left + $rect.right) / 2)
      $point.y = [int](($rect.top + $rect.bottom) / 2)
      if ([GraphCodeTrayLiveNative]::FindWindow("Shell_TrayWnd", $null) -eq [IntPtr]::Zero) {
        throw "Shell_TrayWnd is unavailable for tray icon discovery"
      }
      if ([GraphCodeTrayLiveNative]::MonitorFromPoint($point, $script:MONITOR_DEFAULTTONULL) -eq [IntPtr]::Zero) {
        throw "Shell_NotifyIconGetRect returned coordinates outside every monitor"
      }
      if ([GraphCodeTrayLiveNative]::GetDpiForWindow($hwnd) -eq 0) {
        throw "GraphCode shell has no effective DPI for physical tray coordinates"
      }
      return $rect
    } catch {
      if ($i -eq 29) { throw }
      Start-Sleep -Milliseconds 100
    }
  }
}

function Invoke-WindowClose([IntPtr] $hwnd) {
  [void][GraphCodeTrayLiveNative]::SendMessage(
    $hwnd, $script:WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Invoke-CaptionClose([IntPtr] $hwnd) {
  [void][GraphCodeTrayLiveNative]::SendMessage(
    $hwnd, $script:WM_SYSCOMMAND, [IntPtr]$script:SC_CLOSE, [IntPtr]::Zero)
}

function Invoke-TrayCallback([IntPtr] $hwnd, [ValidateSet("Open", "Context")] [string] $action) {
  $message = [GraphCodeTrayLiveNative]::RegisterWindowMessage("GraphCode.Windows.TrayTestHook")
  if ($message -eq 0) { throw "Could not register GraphCode tray test hook" }
  $event = if ($action -eq "Open") { $script:TRAY_OPEN } else { $script:TRAY_CONTEXT }
  if (-not [GraphCodeTrayLiveNative]::PostMessage(
      $hwnd, [int]$message, [IntPtr]$event, [IntPtr]::Zero)) {
    throw "Could not dispatch GraphCode tray test hook"
  }
}

function Wait-WindowVisibility([IntPtr] $hwnd, [bool] $visible, [string] $label) {
  for ($i = 0; $i -lt 30; $i++) {
    if (-not [GraphCodeTrayLiveNative]::IsWindow($hwnd)) {
      throw "$label destroyed the shell HWND"
    }
    if ([GraphCodeTrayLiveNative]::IsWindowVisible($hwnd) -eq $visible) { return }
    Start-Sleep -Milliseconds 100
  }
  throw "$label did not set shell visibility to $visible"
}

function Wait-ShellForeground([IntPtr] $hwnd, [string] $label) {
  for ($i = 0; $i -lt 30; $i++) {
    if ([GraphCodeTrayLiveNative]::GetForegroundWindow() -eq $hwnd) { return }
    Start-Sleep -Milliseconds 100
  }
  throw "$label did not foreground the shell"
}

function Wait-TrayCallback([IntPtr] $owner, [uint32] $event) {
  for ($i = 0; $i -lt 30; $i++) {
    $observed = [GraphCodeTrayLiveNative]::GetProp(
      $owner, "GraphCode.Windows.TrayCallback")
    if ($observed.ToInt64() -eq $event) { return }
    Start-Sleep -Milliseconds 100
  }
  throw "Tray test hook did not reach the production notification callback"
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
$oldTrayTestHook = [Environment]::GetEnvironmentVariable("GRAPHCODE_TRAY_TEST_HOOK")
$process = $null
try {
  $env:GRAPHCODE_DAEMON_PIPE = "\\.\pipe\$PipeName"
  $env:GRAPHCODE_SHELL_REQUIRE_DAEMON = "0"
  $env:GRAPHCODE_TRAY_TEST_HOOK = "1"
  $process = Start-Process -FilePath $Executable -PassThru
  $hwnd = [IntPtr]::Zero
  for ($i = 0; $i -lt 60 -and $hwnd -eq [IntPtr]::Zero; $i++) {
    Start-Sleep -Milliseconds 100
    $hwnd = Get-ShellWindow $process.Id
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "GraphCode GUI window did not start" }
  for ($i = 0; $i -lt 20 -and -not [GraphCodeTrayLiveNative]::IsWindowVisible($hwnd); $i++) {
    Start-Sleep -Milliseconds 100
  }
  if (-not [GraphCodeTrayLiveNative]::IsWindowVisible($hwnd)) {
    throw "GraphCode GUI window did not become visible"
  }
  $script:trayWindow = $hwnd
  Assert-NoConsoleWindow $process.Id
  $trayRect = Wait-PhysicalTrayIcon $hwnd

  $racer = Start-Process -FilePath $Executable -PassThru
  if (-not $racer.WaitForExit(5000)) { throw "Competing shell start did not complete" }
  if ($racer.ExitCode -ne 0) { throw "Competing shell start exited with code $($racer.ExitCode)" }
  Start-Sleep -Milliseconds 250
  if (-not [GraphCodeTrayLiveNative]::IsWindowVisible($hwnd)) {
    throw "Competing shell start did not preserve the existing window"
  }

  Invoke-WindowClose $hwnd
  Wait-WindowVisibility $hwnd $false "WM_CLOSE"
  $trayRect = Wait-PhysicalTrayIcon $hwnd

  Invoke-TrayCallback $hwnd "Open"
  Wait-TrayCallback $hwnd $script:WM_LBUTTONDBLCLK
  Wait-WindowVisibility $hwnd $true "Tray callback Open"
  Wait-ShellForeground $hwnd "Tray callback Open"

  Invoke-CaptionClose $hwnd
  Wait-WindowVisibility $hwnd $false "Caption close command"
  Invoke-TrayCallback $hwnd "Open"
  Wait-TrayCallback $hwnd $script:WM_LBUTTONDBLCLK
  Wait-WindowVisibility $hwnd $true "Second tray callback Open"
  Wait-ShellForeground $hwnd "Second tray callback Open"

  Invoke-WindowClose $hwnd
  Wait-WindowVisibility $hwnd $false "Hidden single-instance restore setup"
  $second = Start-Process -FilePath $Executable -PassThru
  if (-not $second.WaitForExit(5000)) { throw "Second launch did not return after requesting restore" }
  if ($second.ExitCode -ne 0) { throw "Second launch exited with code $($second.ExitCode)" }
  Wait-WindowVisibility $hwnd $true "Second launch"
  Wait-ShellForeground $hwnd "Second launch"

  $icon = [GraphCodeTrayLiveNative+NotifyIconIdentifier]::new()
  $icon.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($icon)
  $icon.hWnd = $hwnd
  $icon.uID = 1
  if (-not [GraphCodeTrayLiveNative]::Shell_NotifyIcon($script:NIM_DELETE, [ref]$icon)) {
    throw "Could not remove tray icon for Explorer-loss simulation"
  }
  $taskbar = [GraphCodeTrayLiveNative]::RegisterWindowMessage("TaskbarCreated")
  if ($taskbar -eq 0) { throw "Could not register TaskbarCreated" }
  [void][GraphCodeTrayLiveNative]::PostMessage($hwnd, [int]$taskbar, [IntPtr]::Zero, [IntPtr]::Zero)
  $trayRect = Wait-PhysicalTrayIcon $hwnd

  Invoke-TrayCallback $hwnd "Context"
  Wait-TrayCallback $hwnd $script:WM_CONTEXTMENU
  if (-not [GraphCodeTrayLiveNative]::PostMessage(
      $hwnd, $script:WM_COMMAND, [IntPtr]$script:TRAY_EXIT_COMMAND, [IntPtr]::Zero)) {
    throw "Could not dispatch the active tray Exit menu command"
  }
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
  if ($null -eq $oldTrayTestHook) { Remove-Item Env:GRAPHCODE_TRAY_TEST_HOOK -ErrorAction SilentlyContinue }
  else { $env:GRAPHCODE_TRAY_TEST_HOOK = $oldTrayTestHook }
}
