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
  [StructLayout(LayoutKind.Sequential)]
  public struct MouseInput {
    public int dx, dy;
    public uint mouseData, flags, time;
    public UIntPtr extraInfo;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct Input {
    public uint type;
    public MouseInput mouse;
  }
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
  [DllImport("user32.dll")]
  public static extern uint SendInput(uint count, Input[] inputs, int size);
  [DllImport("user32.dll")]
  public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")]
  public static extern IntPtr WindowFromPoint(Point point);
  [DllImport("user32.dll")]
  public static extern int GetSystemMetrics(int index);
  [DllImport("user32.dll")]
  public static extern bool GetMenuItemRect(
    IntPtr hwnd, IntPtr menu, uint item, out Rect rect);
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
  [DllImport("user32.dll")]
  public static extern int GetMenuItemCount(IntPtr menu);
  [DllImport("user32.dll")]
  public static extern uint GetMenuItemID(IntPtr menu, int position);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern int GetMenuString(
    IntPtr menu, uint item, System.Text.StringBuilder text, int maxCount, uint flags);
  [DllImport("shell32.dll")]
  public static extern int Shell_NotifyIconGetRect(ref NotifyIconIdentifier identifier, out Rect rect);
  [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
  public static extern bool Shell_NotifyIcon(uint message, ref NotifyIconIdentifier identifier);
}
"@
}

$script:NIM_DELETE = 0x0002
$script:WM_CLOSE = 0x0010
$script:WM_SYSCOMMAND = 0x0112
$script:WM_LBUTTONDBLCLK = 0x0203
$script:WM_CONTEXTMENU = 0x007B
$script:SC_CLOSE = 0xF060
$script:MOUSEEVENTF_RIGHTDOWN = 0x0008
$script:MOUSEEVENTF_RIGHTUP = 0x0010
$script:MOUSEEVENTF_MOVE = 0x0001
$script:MOUSEEVENTF_ABSOLUTE = 0x8000
$script:MOUSEEVENTF_VIRTUALDESK = 0x4000
$script:MF_BYPOSITION = 0x0400
$script:MONITOR_DEFAULTTONULL = 0
$script:TRAY_OPEN = 1
$script:TRAY_CONTEXT = 2
$script:TRAY_MENU = 3
$script:TRAY_OPEN_COMMAND = 0x5001
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

function Get-TrayMenu([IntPtr] $hwnd) {
  $message = [GraphCodeTrayLiveNative]::RegisterWindowMessage("GraphCode.Windows.TrayTestHook")
  if ($message -eq 0) { throw "Could not register GraphCode tray test hook" }
  $menu = [GraphCodeTrayLiveNative]::SendMessage(
    $hwnd, [int]$message, [IntPtr]$script:TRAY_MENU, [IntPtr]::Zero)
  if ($menu -eq [IntPtr]::Zero) { throw "Tray test hook did not expose its popup menu" }
  return $menu
}

function Assert-TrayMenuContract([IntPtr] $menu) {
  if ([GraphCodeTrayLiveNative]::GetMenuItemCount($menu) -ne 2) {
    throw "Tray popup menu did not contain exactly Open and Exit"
  }
  $openLabel = New-Object Text.StringBuilder 128
  $exitLabel = New-Object Text.StringBuilder 128
  [void][GraphCodeTrayLiveNative]::GetMenuString(
    $menu, 0, $openLabel, $openLabel.Capacity, $script:MF_BYPOSITION)
  [void][GraphCodeTrayLiveNative]::GetMenuString(
    $menu, 1, $exitLabel, $exitLabel.Capacity, $script:MF_BYPOSITION)
  if ($openLabel.ToString() -ne "Open GraphCode" -or $exitLabel.ToString() -ne "Exit" -or
      [GraphCodeTrayLiveNative]::GetMenuItemID($menu, 0) -ne $script:TRAY_OPEN_COMMAND -or
      [GraphCodeTrayLiveNative]::GetMenuItemID($menu, 1) -ne $script:TRAY_EXIT_COMMAND) {
    throw "Tray popup labels or command identities did not match production"
  }
}

function Wait-TrayPopup([int] $processId) {
  for ($i = 0; $i -lt 30; $i++) {
    $script:trayPopup = [IntPtr]::Zero
    $callback = [GraphCodeTrayLiveNative+EnumWindowsProc]{
      param($hwnd, $unused)
      $class = New-Object Text.StringBuilder 128
      [void][GraphCodeTrayLiveNative]::GetClassName($hwnd, $class, $class.Capacity)
      [uint32]$owner = 0
      [void][GraphCodeTrayLiveNative]::GetWindowThreadProcessId($hwnd, [ref]$owner)
      if ([GraphCodeTrayLiveNative]::IsWindowVisible($hwnd) -and
          $owner -eq $processId -and $class.ToString() -eq "#32768") {
        $script:trayPopup = $hwnd
        return $false
      }
      return $true
    }
    [void][GraphCodeTrayLiveNative]::EnumWindows($callback, [IntPtr]::Zero)
    if ($script:trayPopup -ne [IntPtr]::Zero) { return $script:trayPopup }
    Start-Sleep -Milliseconds 100
  }
  throw "Tray context callback did not create a visible popup menu window"
}

function Invoke-PhysicalExit([IntPtr] $popup, [int] $x, [int] $y) {
  if (-not [GraphCodeTrayLiveNative]::SetCursorPos($x, $y - 12)) {
    throw "Could not prime pointer tracking for the visible tray Exit item"
  }
  Start-Sleep -Milliseconds 100
  $left = [GraphCodeTrayLiveNative]::GetSystemMetrics(76)
  $top = [GraphCodeTrayLiveNative]::GetSystemMetrics(77)
  $width = [GraphCodeTrayLiveNative]::GetSystemMetrics(78)
  $height = [GraphCodeTrayLiveNative]::GetSystemMetrics(79)
  if ($width -le 1 -or $height -le 1) { throw "Could not determine virtual desktop bounds" }
  $move = [GraphCodeTrayLiveNative+Input]::new()
  $move.type = 0
  $move.mouse.dx = [int](($x - $left) * 65535 / ($width - 1))
  $move.mouse.dy = [int](($y - $top) * 65535 / ($height - 1))
  $move.mouse.flags = $script:MOUSEEVENTF_MOVE -bor
    $script:MOUSEEVENTF_ABSOLUTE -bor $script:MOUSEEVENTF_VIRTUALDESK
  $moveInputs = [GraphCodeTrayLiveNative+Input[]]@($move)
  $inputSize = [Runtime.InteropServices.Marshal]::SizeOf($move)
  if ($inputSize -ne 40) { throw "SendInput mouse INPUT layout was $inputSize bytes, not 40" }
  if ([GraphCodeTrayLiveNative]::SendInput(1, $moveInputs, $inputSize) -ne 1) {
    throw "SendInput could not move to the visible tray Exit item"
  }
  Start-Sleep -Milliseconds 100
  $point = [GraphCodeTrayLiveNative+Point]::new()
  $point.x = $x
  $point.y = $y
  if ([GraphCodeTrayLiveNative]::WindowFromPoint($point) -ne $popup) {
    throw "DPI-correct Exit point did not target the active tray popup"
  }
  $input = [GraphCodeTrayLiveNative+Input]::new()
  $input.type = 0
  $input.mouse.flags = $script:MOUSEEVENTF_RIGHTDOWN
  $inputs = [GraphCodeTrayLiveNative+Input[]]@($input)
  if ([GraphCodeTrayLiveNative]::SendInput(1, $inputs, $inputSize) -ne 1) {
    throw "SendInput could not press the visible tray Exit item"
  }
  Start-Sleep -Milliseconds 100
  $input.mouse.flags = $script:MOUSEEVENTF_RIGHTUP
  $inputs = [GraphCodeTrayLiveNative+Input[]]@($input)
  if ([GraphCodeTrayLiveNative]::SendInput(1, $inputs, $inputSize) -ne 1) {
    throw "SendInput could not activate the visible tray Exit item"
  }
}

function Invoke-AccessibleExit([int] $x, [int] $y) {
  Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
  Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
  Add-Type -AssemblyName WindowsBase -ErrorAction Stop
  for ($i = 0; $i -lt 30; $i++) {
    $element = [System.Windows.Automation.AutomationElement]::FromPoint(
      [System.Windows.Point]::new([double]$x, [double]$y))
    if ($element -and $element.Current.Name -eq "Exit" -and
        $element.Current.ControlType -eq [System.Windows.Automation.ControlType]::MenuItem) {
      $pattern = $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
      ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
      return $true
    }
    Start-Sleep -Milliseconds 100
  }
  return $false
}

function Invoke-PopupKeyboardFallback([IntPtr] $popup) {
  if (-not [GraphCodeTrayLiveNative]::PostMessage(
      $popup, 0x0100, [IntPtr]0x23, [IntPtr]::Zero) -or
      -not [GraphCodeTrayLiveNative]::PostMessage(
        $popup, 0x0101, [IntPtr]0x23, [IntPtr]::Zero) -or
      -not [GraphCodeTrayLiveNative]::PostMessage(
        $popup, 0x0100, [IntPtr]0x0D, [IntPtr]::Zero) -or
      -not [GraphCodeTrayLiveNative]::PostMessage(
        $popup, 0x0101, [IntPtr]0x0D, [IntPtr]::Zero)) {
    throw "Could not dispatch the visible tray Exit keyboard interaction"
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
  $observed = [IntPtr]::Zero
  for ($i = 0; $i -lt 30; $i++) {
    $observed = [GraphCodeTrayLiveNative]::GetProp(
      $owner, "GraphCode.Windows.TrayTestCallback")
    if ($observed.ToInt64() -eq $event) { return }
    Start-Sleep -Milliseconds 100
  }
  throw "Tray test hook did not reach notification callback $event; observed $($observed.ToInt64())"
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

  $menu = Get-TrayMenu $hwnd
  Assert-TrayMenuContract $menu
  Invoke-TrayCallback $hwnd "Context"
  Wait-TrayCallback $hwnd $script:WM_CONTEXTMENU
  $popup = Wait-TrayPopup $process.Id
  $exitRect = [GraphCodeTrayLiveNative+Rect]::new()
  if (-not [GraphCodeTrayLiveNative]::GetMenuItemRect(
      $popup, $menu, 1, [ref]$exitRect)) {
    throw "Could not locate the visible tray Exit item bounds"
  }
  if ($exitRect.right -le $exitRect.left -or $exitRect.bottom -le $exitRect.top) {
    throw "Visible tray Exit item bounds were invalid"
  }
  $exitPoint = [GraphCodeTrayLiveNative+Point]::new()
  $exitPoint.x = [int](($exitRect.left + $exitRect.right) / 2)
  $exitPoint.y = $exitRect.bottom - 2
  $accessibleExit = Invoke-AccessibleExit $exitPoint.x $exitPoint.y
  if (-not $accessibleExit) {
    Invoke-PhysicalExit $popup $exitPoint.x $exitPoint.y
  }
  if (-not $process.WaitForExit(250)) {
    Invoke-PopupKeyboardFallback $popup
  }
  if (-not $process.WaitForExit(5000)) {
    throw "Tray Exit command did not terminate the shell"
  }
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
