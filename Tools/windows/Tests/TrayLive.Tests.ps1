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
  public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
  [DllImport("user32.dll")]
  public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
  [DllImport("user32.dll")]
  public static extern IntPtr GetMenu(IntPtr hwnd);
  [DllImport("user32.dll")]
  public static extern int GetMenuItemCount(IntPtr menu);
  [DllImport("user32.dll")]
  public static extern bool GetMenuItemRect(IntPtr hwnd, IntPtr menu, uint item, out Rect rect);
  [DllImport("user32.dll")]
  public static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);
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

$script:MOUSEEVENTF_LEFTDOWN = 0x0002
$script:MOUSEEVENTF_LEFTUP = 0x0004
$script:MOUSEEVENTF_RIGHTDOWN = 0x0008
$script:MOUSEEVENTF_RIGHTUP = 0x0010
$script:KEYEVENTF_KEYUP = 0x0002
$script:NIM_DELETE = 0x0002

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

function Wait-TrayIcon([IntPtr] $hwnd) {
  for ($i = 0; $i -lt 30; $i++) {
    try { return Assert-TrayIcon $hwnd } catch { Start-Sleep -Milliseconds 100 }
  }
  return Assert-TrayIcon $hwnd
}

function Invoke-MouseClick([GraphCodeTrayLiveNative+Rect] $rect, [bool] $double = $false) {
  $x = [int](($rect.left + $rect.right) / 2)
  $y = [int](($rect.top + $rect.bottom) / 2)
  [void][GraphCodeTrayLiveNative]::SetCursorPos($x, $y)
  [GraphCodeTrayLiveNative]::mouse_event($script:MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
  [GraphCodeTrayLiveNative]::mouse_event($script:MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
  if ($double) {
    Start-Sleep -Milliseconds 80
    [GraphCodeTrayLiveNative]::mouse_event($script:MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
    [GraphCodeTrayLiveNative]::mouse_event($script:MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
  }
}

function Invoke-TrayContextMenu([GraphCodeTrayLiveNative+Rect] $rect, [ValidateSet("Open", "Exit")] [string] $action) {
  $x = [int](($rect.left + $rect.right) / 2)
  $y = [int](($rect.top + $rect.bottom) / 2)
  [void][GraphCodeTrayLiveNative]::SetCursorPos($x, $y)
  [void][GraphCodeTrayLiveNative]::SetForegroundWindow($script:trayWindow)
  Start-Sleep -Milliseconds 100
  [GraphCodeTrayLiveNative]::mouse_event($script:MOUSEEVENTF_RIGHTDOWN, 0, 0, 0, [UIntPtr]::Zero)
  [GraphCodeTrayLiveNative]::mouse_event($script:MOUSEEVENTF_RIGHTUP, 0, 0, 0, [UIntPtr]::Zero)
  $menu = [IntPtr]::Zero
  for ($i = 0; $i -lt 30 -and $menu -eq [IntPtr]::Zero; $i++) {
    Start-Sleep -Milliseconds 50
    $menu = [GraphCodeTrayLiveNative]::FindWindow("#32768", $null)
  }
  if ($menu -eq [IntPtr]::Zero) { throw "Tray context menu did not open" }
  $menuRect = [GraphCodeTrayLiveNative+Rect]::new()
  if (-not [GraphCodeTrayLiveNative]::GetWindowRect($menu, [ref]$menuRect)) {
    throw "Could not locate tray context menu bounds"
  }
  $nativeMenu = [GraphCodeTrayLiveNative]::GetMenu($menu)
  $itemIndex = if ($action -eq "Open") { 0 } else { 1 }
  if ($nativeMenu -eq [IntPtr]::Zero -or
      [GraphCodeTrayLiveNative]::GetMenuItemCount($nativeMenu) -lt 2) {
    throw "Tray context menu did not expose the expected accessible items"
  }
  $itemRect = [GraphCodeTrayLiveNative+Rect]::new()
  if (-not [GraphCodeTrayLiveNative]::GetMenuItemRect(
      $menu, $nativeMenu, [uint32]$itemIndex, [ref]$itemRect)) {
    throw "Could not locate tray context menu item bounds"
  }
  $itemX = [int](($itemRect.left + $itemRect.right) / 2)
  $itemY = [int](($itemRect.top + $itemRect.bottom) / 2)
  [void][GraphCodeTrayLiveNative]::SetCursorPos($itemX, $itemY)
  [GraphCodeTrayLiveNative]::mouse_event($script:MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
  [GraphCodeTrayLiveNative]::mouse_event($script:MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
}

function Invoke-AltF4 {
  [GraphCodeTrayLiveNative]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
  [GraphCodeTrayLiveNative]::keybd_event(0x73, 0, 0, [UIntPtr]::Zero)
  [GraphCodeTrayLiveNative]::keybd_event(0x73, 0, $script:KEYEVENTF_KEYUP, [UIntPtr]::Zero)
  [GraphCodeTrayLiveNative]::keybd_event(0x12, 0, $script:KEYEVENTF_KEYUP, [UIntPtr]::Zero)
}

function Invoke-WindowClose([IntPtr] $hwnd) {
  [void][GraphCodeTrayLiveNative]::SendMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
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
  Assert-NoConsoleWindow $process.Id
  $trayRect = Wait-TrayIcon $hwnd

  $racer = Start-Process -FilePath $Executable -PassThru
  if (-not $racer.WaitForExit(5000)) { throw "Competing shell start did not complete" }
  if ($racer.ExitCode -ne 0) { throw "Competing shell start exited with code $($racer.ExitCode)" }
  Start-Sleep -Milliseconds 250
  if (-not [GraphCodeTrayLiveNative]::IsWindowVisible($hwnd)) {
    throw "Competing shell start did not preserve the existing window"
  }

  Invoke-WindowClose $hwnd
  Start-Sleep -Milliseconds 750
  if ([GraphCodeTrayLiveNative]::IsWindowVisible($hwnd)) { throw "WM_CLOSE did not hide the shell" }
  $trayRect = Wait-TrayIcon $hwnd

  Invoke-MouseClick $trayRect $true
  Start-Sleep -Milliseconds 250
  if (-not [GraphCodeTrayLiveNative]::IsWindowVisible($hwnd)) { throw "Tray double-click did not restore the shell" }

  Invoke-WindowClose $hwnd
  Start-Sleep -Milliseconds 200
  if ([GraphCodeTrayLiveNative]::IsWindowVisible($hwnd)) { throw "Alt+F4 did not hide the shell" }
  $second = Start-Process -FilePath $Executable -PassThru
  if (-not $second.WaitForExit(5000)) { throw "Second launch did not return after requesting restore" }
  if ($second.ExitCode -ne 0) { throw "Second launch exited with code $($second.ExitCode)" }
  Start-Sleep -Milliseconds 250
  if (-not [GraphCodeTrayLiveNative]::IsWindowVisible($hwnd)) { throw "Second launch did not restore the existing shell" }

  $icon = [GraphCodeTrayLiveNative+NotifyIconIdentifier]::new()
  $icon.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($icon)
  $icon.hWnd = $hwnd
  $icon.uID = 1
  if (-not [GraphCodeTrayLiveNative]::Shell_NotifyIcon($script:NIM_DELETE, [ref]$icon)) {
    throw "Could not remove tray icon for Explorer-loss simulation"
  }
  $taskbar = [GraphCodeTrayLiveNative]::RegisterWindowMessage("TaskbarCreated")
  [void][GraphCodeTrayLiveNative]::PostMessage($hwnd, [int]$taskbar, [IntPtr]::Zero, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 250
  $trayRect = Wait-TrayIcon $hwnd
  $script:trayWindow = $hwnd

  Invoke-TrayContextMenu $trayRect "Exit"
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
