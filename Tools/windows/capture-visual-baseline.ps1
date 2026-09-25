[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Shell,
  [Parameter(Mandatory)] [string] $Zmx,
  [Parameter(Mandatory)] [string] $OutputDirectory,
  [string] $ForegroundLease = "",
  [ValidateRange(30, 300)] [int] $TimeoutSeconds = 120,
  [switch] $PreflightOnly,
  [switch] $Worker
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Shell = (Resolve-Path -LiteralPath $Shell).Path
$Zmx = (Resolve-Path -LiteralPath $Zmx).Path
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
foreach ($path in @($Shell, $Zmx)) {
  if (-not $path.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Capture requires own-worktree binaries: $path"
  }
}
if (-not $PreflightOnly -and [string]::IsNullOrWhiteSpace($ForegroundLease)) {
  throw "An explicit coordinator foreground lease is required"
}
if (Test-Path -LiteralPath (Join-Path (Split-Path $Shell) 'graphcoded.exe')) {
  throw "Fixture-only capture rejects a sibling graphcoded.exe; no real daemon may replace the fixture"
}
if ($Shell -ne (Join-Path $repoRoot 'graphcode-windows\zig-out\bin\graphcode-windows.exe') -or
    $Zmx -ne (Join-Path $repoRoot '.graphcode-tools\providers\zmx\zig-out\bin\zmx.exe')) {
  throw 'Capture requires the standard own-worktree pinned build artifacts'
}

function Get-CaptureUtcTicks($Value) {
  if ($Value -is [DateTime]) {
    if ($Value.Kind -eq [DateTimeKind]::Unspecified) { throw "Capture process creation time must include a timezone" }
    return $Value.ToUniversalTime().Ticks
  }
  if ($Value -is [DateTimeOffset]) { return $Value.UtcTicks }
  if ([string]$Value -notmatch '^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$') {
    throw "Capture process creation time must include a timezone"
  }
  return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture).UtcTicks
}

function Test-CaptureProcessIdentity($Process, $Record) {
  return $null -ne $Process -and
    $Process.StartTime.ToUniversalTime().Ticks -eq (Get-CaptureUtcTicks $Record.createdAt) -and
    $Process.Path -eq $Record.executable
}

function Stop-CaptureProcesses {
  $recordsPath = Join-Path $OutputDirectory 'processes.json'
  if (-not (Test-Path -LiteralPath $recordsPath)) { return }
  $records = @(Get-Content -LiteralPath $recordsPath -Raw | ConvertFrom-Json)
  foreach ($record in ($records | Sort-Object createdAt -Descending)) {
    $current = Get-Process -Id $record.pid -ErrorAction SilentlyContinue
    if (Test-CaptureProcessIdentity $current $record) {
      Stop-Process -Id $record.pid -Force -ErrorAction Stop
      if (-not $current.WaitForExit(5000)) { throw "Owned capture PID $($record.pid) did not exit" }
    }
  }
}

# An outer process deadline also bounds a stuck cross-process UIA call.
if (-not $Worker -and -not $PreflightOnly) {
  if (Test-Path -LiteralPath $OutputDirectory) { throw "Capture output directory must be fresh" }
  $null = New-Item -ItemType Directory -Path $OutputDirectory
  $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
  $start.UseShellExecute = $false
  foreach ($arg in @('-NoProfile', '-File', $PSCommandPath, '-Shell', $Shell, '-Zmx', $Zmx,
      '-OutputDirectory', $OutputDirectory, '-ForegroundLease', $ForegroundLease,
      '-TimeoutSeconds', "$TimeoutSeconds", '-Worker')) { $start.ArgumentList.Add($arg) }
  $workerProcess = [Diagnostics.Process]::Start($start)
  try {
    if (-not $workerProcess.WaitForExit($TimeoutSeconds * 1000)) {
      Stop-Process -Id $workerProcess.Id -Force
      throw "Visual capture exceeded its $TimeoutSeconds second wall-clock deadline; partial artifacts retained"
    }
    if ($workerProcess.ExitCode -ne 0) { throw "Visual capture worker failed with exit code $($workerProcess.ExitCode)" }
  } finally {
    Stop-CaptureProcesses
    $workerProcess.Dispose()
  }
  exit 0
}
if ($PreflightOnly) {
  if (Test-Path -LiteralPath $OutputDirectory) { throw 'Preflight output directory must be fresh' }
  $null = New-Item -ItemType Directory -Path $OutputDirectory
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
public static class VisualWindow {
  public static string ActivationDiagnostics;
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] private struct MONITORINFO { public int Size; public RECT Monitor, Work; public uint Flags; }
  private delegate bool EnumProc(IntPtr window, IntPtr value);
  [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr value);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
  [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr window);
  [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
  [DllImport("user32.dll")] private static extern IntPtr SetActiveWindow(IntPtr window);
  [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
  [DllImport("user32.dll", SetLastError=true)] private static extern bool AttachThreadInput(uint from, uint to, bool attach);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr window);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool GetClientRect(IntPtr window, out RECT rect);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool ClientToScreen(IntPtr window, ref POINT point);
  [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out RECT rect);
  [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr window, uint command);
  [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
  [DllImport("user32.dll")] private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder text, int length);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, UIntPtr wparam, IntPtr lparam);
  [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] private static extern bool SystemParametersInfo(uint action, uint param, out uint value, uint flags);
  [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr window, uint attribute, out uint value, int size);
  public static void EnableDpi() {
    if (SetThreadDpiAwarenessContext(new IntPtr(-4)) == IntPtr.Zero)
      throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot enable per-monitor capture coordinates");
  }
  public static uint FontSetting(uint action) {
    uint value;
    if (!SystemParametersInfo(action, 0, out value, 0)) throw new Win32Exception();
    return value;
  }
  public static bool Activate(IntPtr window) {
    if (GetForegroundWindow() == window) {
      ActivationDiagnostics = "already foreground";
      return true;
    }
    uint ignored;
    var foreground = GetForegroundWindow();
    uint foregroundThread = foreground == IntPtr.Zero ? 0 : GetWindowThreadProcessId(foreground, out ignored);
    uint targetThread = GetWindowThreadProcessId(window, out ignored);
    uint currentThread = GetCurrentThreadId();
    bool attachedForeground = foregroundThread != 0 && foregroundThread != currentThread &&
      AttachThreadInput(currentThread, foregroundThread, true);
    int foregroundError = attachedForeground ? 0 : Marshal.GetLastWin32Error();
    bool attachedTarget = targetThread != currentThread && targetThread != foregroundThread &&
      AttachThreadInput(currentThread, targetThread, true);
    int targetError = attachedTarget ? 0 : Marshal.GetLastWin32Error();
    try {
      bool wasVisible = ShowWindow(window, 9);
      bool raised = BringWindowToTop(window);
      IntPtr previousActive = SetActiveWindow(window);
      bool requested = SetForegroundWindow(window);
      ActivationDiagnostics = $"attachForeground={attachedForeground} win32={foregroundError}; " +
        $"attachTarget={attachedTarget} win32={targetError}; wasVisible={wasVisible}; " +
        $"raised={raised}; previousActive={previousActive}; setForeground={requested}";
      return GetForegroundWindow() == window;
    } finally {
      int detachError = 0;
      if (attachedTarget && !AttachThreadInput(currentThread, targetThread, false))
        detachError = Marshal.GetLastWin32Error();
      if (attachedForeground && !AttachThreadInput(currentThread, foregroundThread, false))
        detachError = Marshal.GetLastWin32Error();
      if (detachError != 0) throw new Win32Exception(detachError, "Capture thread input detach failed");
    }
  }
  public static IntPtr Find(uint pid, string className) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((window, value) => {
      uint owner; GetWindowThreadProcessId(window, out owner);
      if (owner != pid || !IsWindowVisible(window)) return true;
      var text = new StringBuilder(256); GetClassName(window, text, text.Capacity);
      if (text.ToString() == className) { found = window; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static Rectangle Client(IntPtr window) {
    RECT rect; var point = new POINT();
    if (!GetClientRect(window, out rect) || !ClientToScreen(window, ref point)) throw new Win32Exception();
    return new Rectangle(point.X, point.Y, rect.Right - rect.Left, rect.Bottom - rect.Top);
  }
  public static Rectangle Verify(IntPtr window, uint pid) {
    uint owner; GetWindowThreadProcessId(window, out owner);
    if (owner != pid || !IsWindowVisible(window) || IsIconic(window) || GetForegroundWindow() != window)
      throw new InvalidOperationException("Capture ownership/visibility/foreground guard failed");
    var rect = Client(window);
    if (rect.Width <= 0 || rect.Height <= 0) throw new InvalidOperationException("Empty capture client");
    var monitor = new MONITORINFO { Size = Marshal.SizeOf<MONITORINFO>() };
    if (!GetMonitorInfo(MonitorFromWindow(window, 0), ref monitor) ||
        !Rectangle.FromLTRB(monitor.Monitor.Left, monitor.Monitor.Top, monitor.Monitor.Right, monitor.Monitor.Bottom).Contains(rect))
      throw new InvalidOperationException("Capture client is not fully visible on one monitor");
    // GW_HWNDPREV walks only higher Z-order windows; do not read their content.
    for (var above = GetWindow(window, 3); above != IntPtr.Zero; above = GetWindow(above, 3)) {
      if (!IsWindowVisible(above) || IsIconic(above)) continue;
      uint cloaked;
      if (DwmGetWindowAttribute(above, 14, out cloaked, 4) == 0 && cloaked != 0) continue;
      RECT other;
      if (GetWindowRect(above, out other) &&
          rect.IntersectsWith(Rectangle.FromLTRB(other.Left, other.Top, other.Right, other.Bottom)))
        throw new InvalidOperationException("Capture client is overlapped; no desktop pixels saved");
    }
    return rect;
  }
}
'@
[VisualWindow]::EnableDpi()
$clock = [Diagnostics.Stopwatch]::StartNew()
$owned = [Collections.Generic.Dictionary[int,object]]::new()
$actions = [Collections.Generic.List[object]]::new()
$app = $null
$images = [Collections.Generic.List[object]]::new()

function Record-OwnedProcesses {
  $all = @(Get-CimInstance Win32_Process)
  $changed = $true
  while ($changed) {
    $changed = $false
    foreach ($candidate in $all) {
      $parentId = [int]$candidate.ParentProcessId
      if ($owned.ContainsKey([int]$candidate.ProcessId) -or -not $owned.ContainsKey($parentId)) { continue }
      $parent = Get-Process -Id $parentId -ErrorAction SilentlyContinue
      if (-not (Test-CaptureProcessIdentity $parent $owned[$parentId])) { continue }
      $process = Get-Process -Id $candidate.ProcessId -ErrorAction SilentlyContinue
      if (-not $process -or $process.StartTime -lt $parent.StartTime) { continue }
      $owned[[int]$candidate.ProcessId] = [ordered]@{
        pid = [int]$candidate.ProcessId; parentPid = $parentId
        createdAt = $process.StartTime.ToUniversalTime().ToString('o')
        executable = $candidate.ExecutablePath; commandLine = $candidate.CommandLine
      }
      $changed = $true
    }
  }
  $temporary = Join-Path $OutputDirectory 'processes.tmp'
  @($owned.Values) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary
  Move-Item -LiteralPath $temporary -Destination (Join-Path $OutputDirectory 'processes.json') -Force
}

function Wait-Visual([scriptblock] $Condition, [string] $Description) {
  do {
    if ($clock.Elapsed.TotalSeconds -gt $TimeoutSeconds - 5) { throw "Capture deadline: $Description" }
    if ($app.HasExited) { throw "App exited before $Description; see stderr.log" }
    Record-OwnedProcesses
    $value = & $Condition
    if ($value) { return $value }
    Start-Sleep -Milliseconds 100
  } while ($true)
}

function Read-Elements([IntPtr] $Window) {
  $root = [Windows.Automation.AutomationElement]::FromHandle($Window)
  $queue = [Collections.Generic.Queue[object]]::new()
  $queue.Enqueue($root)
  $result = [Collections.Generic.List[object]]::new()
  $walker = [Windows.Automation.TreeWalker]::RawViewWalker
  while ($queue.Count -gt 0) {
    if ($result.Count -gt 512) { throw "Unexpectedly large app UIA tree" }
    $element = $queue.Dequeue()
    $result.Add($element)
    $child = $walker.GetFirstChild($element)
    while ($null -ne $child) { $queue.Enqueue($child); $child = $walker.GetNextSibling($child) }
  }
  return $result.ToArray()
}

function Invoke-VisualElement([IntPtr] $Window, [string] $IdPattern, [string] $Name) {
  $matches = @(Read-Elements $Window | Where-Object {
    $_.Current.AutomationId -match $IdPattern -and $_.Current.Name -eq $Name
  })
  if ($matches.Count -ne 1) { throw "Expected one UIA action $IdPattern / $Name; found $($matches.Count)" }
  $matches[0].GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
  $actions.Add([ordered]@{ kind = 'UIA InvokePattern'; id = $matches[0].Current.AutomationId; name = $Name })
}

function Post-Menu([IntPtr] $Window, [uint32] $Command) {
  if (-not [VisualWindow]::PostMessage($Window, 0x0111, [UIntPtr]$Command, [IntPtr]::Zero)) {
    throw "WM_COMMAND $Command failed"
  }
  $actions.Add([ordered]@{ kind = 'native WM_COMMAND'; command = $Command })
}

function Get-ClientRelativeBounds($Bounds, [Drawing.Rectangle] $Client) {
  return @(($Bounds.X - $Client.X), ($Bounds.Y - $Client.Y), $Bounds.Width, $Bounds.Height)
}

function Get-CaptureBuildSnapshot {
  $sources = @(& (Join-Path $PSScriptRoot 'Test-RenderedVisualBaseline.ps1') -SourceSnapshot)
  $pins = Get-Content -LiteralPath (Join-Path $repoRoot 'graphcode-windows\provider-pins.json') -Raw | ConvertFrom-Json
  $providers = [ordered]@{}
  foreach ($name in @('zmx','winghostty')) {
    $providerRoot = Join-Path $repoRoot ".graphcode-tools\providers\$name"
    $head = git -C $providerRoot rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $head -cne $pins.$name.sha) { throw "$name provider pin mismatch" }
    $status = @(git -C $providerRoot status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) { throw "$name provider worktree is not clean" }
    $artifact = ".graphcode-tools\providers\$name\" + $pins.$name.artifact.Replace('/','\')
    $providers[$name] = @{ pin = $head; artifact = $artifact
      sha256 = (Get-FileHash -LiteralPath (Join-Path $repoRoot $artifact)).Hash.ToLowerInvariant() }
  }
  return [ordered]@{
    sources = $sources; providers = $providers
    executable = @{ artifact = 'graphcode-windows\zig-out\bin\graphcode-windows.exe'
      sha256 = (Get-FileHash -LiteralPath $Shell).Hash.ToLowerInvariant() }
  }
}

function Save-AppClient([IntPtr] $Window, [string] $Id, [string] $State) {
  if (-not [VisualWindow]::Activate($Window)) {
    $foreground = [VisualWindow]::GetForegroundWindow()
    [uint32]$foregroundPid = 0
    $null = [VisualWindow]::GetWindowThreadProcessId($foreground, [ref]$foregroundPid)
    throw "Could not foreground owned $Id window: target=$Window pid=$($app.Id); foreground=$foreground pid=$foregroundPid; $([VisualWindow]::ActivationDiagnostics)"
  }
  $null = Wait-Visual { [VisualWindow]::GetForegroundWindow() -eq $Window } "$Id foreground"
  $app.Refresh()
  if (-not (Test-CaptureProcessIdentity $app $owned[$app.Id])) { throw "App process identity changed" }
  $rect = [VisualWindow]::Verify($Window, $app.Id)
  $dpi = [VisualWindow]::GetDpiForWindow($Window)
  $elements = @(Read-Elements $Window | ForEach-Object {
    $current = $_.Current
    [ordered]@{ id = $current.AutomationId; name = $current.Name; type = $current.ControlType.ProgrammaticName
      bounds = @(Get-ClientRelativeBounds $current.BoundingRectangle $rect) }
  })
  $bitmap = [Drawing.Bitmap]::new($rect.Width, $rect.Height)
  try {
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try { $graphics.CopyFromScreen($rect.Location, [Drawing.Point]::Empty, $rect.Size) }
    finally { $graphics.Dispose() }
    $after = [VisualWindow]::Verify($Window, $app.Id)
    if ($after -ne $rect -or [VisualWindow]::GetDpiForWindow($Window) -ne $dpi) {
      throw "Window geometry/DPI changed during capture"
    }
    $file = "$Id.png"
    $path = Join-Path $OutputDirectory $file
    $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
  } finally { $bitmap.Dispose() }
  $images.Add([ordered]@{
    id = $Id; file = $file; sha256 = (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
    width = $rect.Width; height = $rect.Height; dpi = $dpi; state = $State
    window = @{ hwnd = $Window.ToInt64(); pid = $app.Id; createdAt = $owned[$app.Id].createdAt
      screenClient = @($rect.X, $rect.Y, $rect.Width, $rect.Height) }
    elements = $elements; regions = @()
  })
  $images | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'captured-images.json')
  Write-Host "CAPTURED: $Id $($rect.Width)x$($rect.Height) dpi=$dpi"
}

try {
  $buildSnapshot = Get-CaptureBuildSnapshot
  $buildSnapshot | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'build-snapshot.json')
  if ($PreflightOnly) {
    Write-Output 'Capture preflight: PASS (sources, scripts, pinned providers and binary hashes; no app launch)'
    return
  }
  # The worker's environment cannot escape to the invoking shell or other runs.
  Get-ChildItem Env:GRAPHCODE_*,Env:ZMX_* | Remove-Item
  $runId = [guid]::NewGuid().ToString('N')
  foreach ($dir in @('support','localappdata','cwd','zmx')) {
    $null = New-Item -ItemType Directory -Path (Join-Path $OutputDirectory $dir)
  }
  $env:GRAPHCODE_DAEMON_PIPE = "\\.\pipe\graphcode-visual-$runId"
  $env:GRAPHCODE_SUPPORT_DIR = Join-Path $OutputDirectory 'support'
  $env:LOCALAPPDATA = Join-Path $OutputDirectory 'localappdata'
  $env:GRAPHCODE_GATE_CWD = Join-Path $OutputDirectory 'cwd'
  $env:GRAPHCODE_ZMX = $Zmx
  $env:ZMX_DIR = Join-Path $OutputDirectory 'zmx'
  $env:ZMX_SESSION_PREFIX = "v3-$($runId.Substring(0,8))"
  $env:GRAPHCODE_WORKSPACE_LAYOUT = Join-Path $OutputDirectory 'workspace.json'
  $env:GRAPHCODE_WORKSPACE_PROJECT = 'graphcode-visual-fixture'
  $env:GRAPHCODE_UIA_FIXTURE_ROWS = 'C:\fixture-safe|safe,C:\fixture-unsafe|unsafe'
  $env:GRAPHCODE_UIA_RESET_SIDEBAR = '1'
  $env:GRAPHCODE_UIA_UPDATE_AVAILABLE = '1'
  $markerDir = Join-Path $env:LOCALAPPDATA 'GraphCode'
  $null = New-Item -ItemType Directory -Path $markerDir
  $null = New-Item -ItemType File -Path (Join-Path $markerDir 'onboarding-seen')
  @(Get-ChildItem Env: | Where-Object Name -match '^(GRAPHCODE_|ZMX_|LOCALAPPDATA$)') |
    Select-Object Name,Value | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'launch-environment.json')
  $app = Start-Process -FilePath $Shell -WorkingDirectory $env:GRAPHCODE_GATE_CWD -PassThru `
    -RedirectStandardError (Join-Path $OutputDirectory 'stderr.log') `
    -RedirectStandardOutput (Join-Path $OutputDirectory 'stdout.log')
  $owned[$app.Id] = [ordered]@{
    pid = $app.Id; parentPid = $PID; executable = $Shell; commandLine = $Shell
    createdAt = $app.StartTime.ToUniversalTime().ToString('o')
  }
  Record-OwnedProcesses
  $window = Wait-Visual { [VisualWindow]::Find($app.Id, 'GraphCodeWindowsShell') } 'main HWND'
  $null = Wait-Visual {
    @(Read-Elements $window | Where-Object { $_.Current.Name -eq 'UIA project' }).Count -gt 0
  } 'fixture project'
  Invoke-VisualElement $window '^open-project-' 'UIA project'
  Post-Menu $window 4408
  $null = Wait-Visual {
    @(Read-Elements $window | Where-Object {
      $_.Current.AutomationId -match '^canvas-card-' -and $_.Current.Name -match '^UIA loop [AB]'
    }).Count -eq 2
  } 'fixture canvas'
  Save-AppClient $window 'canvas-sidebar' 'fixture-project-disconnected'
  Post-Menu $window 4403
  $dialog = Wait-Visual { [VisualWindow]::Find($app.Id, 'GraphCodeProductSettings') } 'Product Settings'
  Save-AppClient $dialog 'dialog' 'product-settings-unmodified'
  if (-not [VisualWindow]::PostMessage($dialog, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero)) {
    throw "Could not close Product Settings"
  }
  $null = Wait-Visual { [VisualWindow]::Find($app.Id, 'GraphCodeProductSettings') -eq [IntPtr]::Zero } 'dialog close'
  Invoke-VisualElement $window '^loop-row-' 'UIA loop A'
  $null = Wait-Visual {
    @(Read-Elements $window | Where-Object { $_.Current.Name -eq 'New Tab' }).Count -gt 0
  } 'real workspace chrome'
  Record-OwnedProcesses
  $attachments = @($owned.Values | Where-Object { $_.executable -eq $Zmx -and $_.commandLine -match '\battach\b' })
  if ($attachments.Count -eq 0) { throw "Workspace lacks a proven-owned real zmx attach process" }
  Save-AppClient $window 'workspace' 'fixture-loop-attached'
  if (@($owned.Values | Where-Object { [IO.Path]::GetFileName($_.executable) -eq 'graphcoded.exe' }).Count -gt 0) {
    throw "Unexpected daemon child in disconnected fixture capture"
  }
  $afterSnapshot = Get-CaptureBuildSnapshot
  if (($afterSnapshot | ConvertTo-Json -Depth 6 -Compress) -cne ($buildSnapshot | ConvertTo-Json -Depth 6 -Compress)) {
    throw 'Source/script/provider/binary hashes changed during capture'
  }
  $evidence = [ordered]@{
    schemaVersion = 1; kind = 'windows-production-renderer-fixture'
    capturedAt = [DateTime]::UtcNow.ToString('o'); os = [Environment]::OSVersion.VersionString
    sourceCommit = (git -C $repoRoot rev-parse HEAD); sourceTree = (git -C $repoRoot rev-parse 'HEAD^{tree}')
    dirtyFiles = @(git -C $repoRoot status --porcelain); sources = @($buildSnapshot.sources)
    executable = $buildSnapshot.executable; providers = $buildSnapshot.providers
    process = @{ pid = $app.Id; createdAt = $owned[$app.Id].createdAt }
    attachments = @($attachments | ForEach-Object { @{ pid = $_.pid; createdAt = $_.createdAt; parentPid = $_.parentPid } })
    foregroundLease = $ForegroundLease; dpi = $images[0].dpi
    fontSmoothing = @{ enabled = [VisualWindow]::FontSetting(0x004A); type = [VisualWindow]::FontSetting(0x200A) }
    renderer = @{ uiaGate = $false; daemonSupervisorHook = $false }
    fixture = @{ name = 'App.installUiaFixture'; daemonState = 'disconnected'; zoom = 1 }
    captureMethod = 'CopyFromScreen; owned visible client only; before/after Z-order/identity/DPI guards'
    actions = @($actions); images = @($images)
    review = 'Regions deliberately empty until source-mapped review; capture alone is not PASS.'
  }
  $evidence | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'evidence.json')
  Post-Menu $window 4104
  if (-not $app.WaitForExit(5000)) { throw "App did not exit normally after capture" }
  Write-Host 'Windows capture complete; review regions before running Test-RenderedVisualBaseline.ps1.'
} finally {
  try { if ($app) { Record-OwnedProcesses } }
  finally { Stop-CaptureProcesses }
}
