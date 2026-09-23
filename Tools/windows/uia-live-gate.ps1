[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Shell,
  [string] $Zmx = "",
  [string[]] $ArgumentList = @(),
  [switch] $SidebarParityOnly
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Automation;
public static class GraphCodeUiaGateState {
  public static volatile bool LiveObserved;
  public static volatile bool NamePropertyObserved;
  public static volatile bool FocusObserved;
  public static int LiveEvents;
  public static int NamePropertyEvents;
  public static int SelectedEvents;
  public static int AddedEvents;
  public static int RemovedEvents;
  public static int TogglePropertyEvents;
  public static string LiveSourceAutomationId;
  public static string LiveSourceName;
  public static string LiveSourceRuntimeId;
  public static string NamePropertySourceAutomationId;
  public static string FocusSourceAutomationId;
  public static string SelectionSourceAutomationId;
  public static string TogglePropertySourceAutomationId;
  public static readonly AutomationEventHandler LiveHandler = HandleLive;
  public static readonly AutomationPropertyChangedEventHandler NamePropertyHandler = HandleNameProperty;
  public static readonly AutomationFocusChangedEventHandler FocusHandler = HandleFocus;
  public static readonly AutomationEventHandler SelectedHandler = HandleSelected;
  public static readonly AutomationEventHandler AddedHandler = HandleAdded;
  public static readonly AutomationEventHandler RemovedHandler = HandleRemoved;
  public static readonly AutomationPropertyChangedEventHandler TogglePropertyHandler = HandleToggleProperty;
  private static void HandleLive(object sender, AutomationEventArgs eventArgs) {
    var element = sender as AutomationElement;
    if (element == null) return;
    LiveSourceAutomationId = element.Current.AutomationId;
    LiveSourceName = element.Current.Name;
    LiveSourceRuntimeId = String.Join(",", element.GetRuntimeId());
    LiveEvents++;
    LiveObserved = true;
  }
  private static void HandleNameProperty(object sender, AutomationPropertyChangedEventArgs eventArgs) {
    var element = sender as AutomationElement;
    if (element != null) NamePropertySourceAutomationId = element.Current.AutomationId;
    NamePropertyEvents++;
    NamePropertyObserved = true;
  }
  private static void HandleFocus(object sender, AutomationFocusChangedEventArgs eventArgs) {
    var element = sender as AutomationElement;
    if (element != null) FocusSourceAutomationId = element.Current.AutomationId;
    FocusObserved = true;
  }
  private static void HandleSelected(object sender, AutomationEventArgs eventArgs) {
    var element = sender as AutomationElement;
    if (element != null) SelectionSourceAutomationId = element.Current.AutomationId;
    SelectedEvents++;
  }
  private static void HandleAdded(object sender, AutomationEventArgs eventArgs) {
    var element = sender as AutomationElement;
    if (element != null) SelectionSourceAutomationId = element.Current.AutomationId;
    AddedEvents++;
  }
  private static void HandleRemoved(object sender, AutomationEventArgs eventArgs) {
    var element = sender as AutomationElement;
    if (element != null) SelectionSourceAutomationId = element.Current.AutomationId;
    RemovedEvents++;
  }
  private static void HandleToggleProperty(object sender, AutomationPropertyChangedEventArgs eventArgs) {
    var element = sender as AutomationElement;
    if (element != null) TogglePropertySourceAutomationId = element.Current.AutomationId;
    TogglePropertyEvents++;
  }
  [DllImport("user32.dll", SetLastError = true)]
  private static extern bool PostMessage(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")]
  private static extern IntPtr SendMessage(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
  private static extern IntPtr SendMessageText(
    IntPtr window, uint message, UIntPtr wParam, StringBuilder lParam
  );
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string windowName);
  private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
  [DllImport("user32.dll")]
  private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
  [DllImport("user32.dll")]
  private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern int GetClassName(IntPtr window, StringBuilder className, int capacity);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern bool SetWindowText(IntPtr window, string text);
  [DllImport("user32.dll")]
  private static extern int GetDlgCtrlID(IntPtr window);
  [DllImport("user32.dll")]
  private static extern IntPtr SetFocus(IntPtr window);
  [DllImport("user32.dll")]
  private static extern IntPtr GetFocus();
  [DllImport("user32.dll")]
  private static extern bool SetForegroundWindow(IntPtr window);
  [DllImport("user32.dll")]
  private static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")]
  private static extern bool BringWindowToTop(IntPtr window);
  [DllImport("kernel32.dll")]
  private static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")]
  private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern int GetWindowTextLength(IntPtr window);
  [DllImport("user32.dll")]
  private static extern bool ShowWindow(IntPtr window, int command);
  [DllImport("user32.dll")]
  private static extern IntPtr SetActiveWindow(IntPtr window);
  [DllImport("user32.dll")]
  private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);
  public static IntPtr FindChild(IntPtr parent, string className) {
    return FindWindowEx(parent, IntPtr.Zero, className, null);
  }
  public static IntPtr FindTopLevel(string className, uint processId) {
    IntPtr result = IntPtr.Zero;
    EnumWindows(delegate(IntPtr window, IntPtr parameter) {
      uint owner;
      GetWindowThreadProcessId(window, out owner);
      if (owner != processId) return true;
      var actualClass = new StringBuilder(256);
      GetClassName(window, actualClass, actualClass.Capacity);
      if (!String.Equals(actualClass.ToString(), className, StringComparison.Ordinal)) return true;
      result = window;
      return false;
    }, IntPtr.Zero);
    return result;
  }
  public static string[] GetListItems(IntPtr list) {
    if (list == IntPtr.Zero) return new string[0];
    int count = (int)SendMessage(list, 0x018B, UIntPtr.Zero, IntPtr.Zero);
    var result = new string[count];
    for (int index = 0; index < count; index++) {
      int length = (int)SendMessage(list, 0x018A, (UIntPtr)index, IntPtr.Zero);
      var text = new StringBuilder(length + 1);
      SendMessageText(list, 0x0189, (UIntPtr)index, text);
      result[index] = text.ToString();
    }
    return result;
  }
  public static bool PostFixtureMutation(IntPtr window, uint mutation) {
    return PostMessage(window, 0x802A, (UIntPtr)mutation, IntPtr.Zero);
  }
  public static bool PostPaletteRefresh(IntPtr window) {
    return PostMessage(window, 0x802B, UIntPtr.Zero, IntPtr.Zero);
  }
  public static bool PostTaggedExitCollision(IntPtr window) {
    return PostMessage(window, 0x0111, new UIntPtr(0x8000000000001008UL), IntPtr.Zero);
  }
  public static bool PostKeyboard(IntPtr window, uint key) {
    return PostMessage(window, 0x0100, (UIntPtr)key, IntPtr.Zero) &&
      PostMessage(window, 0x0101, (UIntPtr)key, IntPtr.Zero);
  }
  public static bool SendReturn(IntPtr window) {
    if (window == IntPtr.Zero) return false;
    SendMessage(window, 0x0100, (UIntPtr)0x0D, IntPtr.Zero);
    return true;
  }
  public static bool SendCommand(IntPtr window, uint command) {
    if (window == IntPtr.Zero) return false;
    SendMessage(window, 0x0111, (UIntPtr)command, IntPtr.Zero);
    return true;
  }
  public static int GetCheckState(IntPtr window) {
    if (window == IntPtr.Zero) return -1;
    return (int)SendMessage(window, 0x00F0, UIntPtr.Zero, IntPtr.Zero);
  }
  public static bool FocusControl(IntPtr parent, IntPtr control) {
    if (parent == IntPtr.Zero || control == IntPtr.Zero) return false;
    ActivateWindow(parent);
    uint ignoredProcessId;
    uint parentThread = GetWindowThreadProcessId(parent, out ignoredProcessId);
    uint currentThread = GetCurrentThreadId();
    bool attached = currentThread != parentThread &&
      AttachThreadInput(currentThread, parentThread, true);
    try {
      SetFocus(control);
      return IsForegroundWindow(parent) && GetFocus() == control;
    } finally {
      if (attached) AttachThreadInput(currentThread, parentThread, false);
    }
  }
  public static bool ActivateWindow(IntPtr window) {
    if (window == IntPtr.Zero) return false;
    IntPtr foreground = GetForegroundWindow();
    uint ignoredForegroundProcessId;
    uint foregroundThread = foreground == IntPtr.Zero ? 0 :
      GetWindowThreadProcessId(foreground, out ignoredForegroundProcessId);
    uint ignoredTargetProcessId;
    uint targetThread = GetWindowThreadProcessId(window, out ignoredTargetProcessId);
    uint currentThread = GetCurrentThreadId();
    bool attachForeground = foregroundThread != 0 &&
      currentThread != foregroundThread &&
      AttachThreadInput(currentThread, foregroundThread, true);
    bool attachTarget = currentThread != targetThread &&
      AttachThreadInput(currentThread, targetThread, true);
    try {
      ShowWindow(window, 9);
      BringWindowToTop(window);
      keybd_event(0x12, 0, 0, UIntPtr.Zero);
      keybd_event(0x12, 0, 0x0002, UIntPtr.Zero);
      SetActiveWindow(window);
      SetForegroundWindow(window);
      return IsForegroundWindow(window);
    } finally {
      if (attachTarget) AttachThreadInput(currentThread, targetThread, false);
      if (attachForeground) AttachThreadInput(currentThread, foregroundThread, false);
    }
  }
  public static bool IsForegroundWindow(IntPtr window) {
    return window != IntPtr.Zero && GetForegroundWindow() == window;
  }
  public static IntPtr CurrentForegroundWindow() {
    return GetForegroundWindow();
  }
  public static uint WindowProcessId(IntPtr window) {
    if (window == IntPtr.Zero) return 0;
    uint processId;
    GetWindowThreadProcessId(window, out processId);
    return processId;
  }
  public static string WindowClass(IntPtr window) {
    if (window == IntPtr.Zero) return "";
    var text = new StringBuilder(256);
    GetClassName(window, text, text.Capacity);
    return text.ToString();
  }
  public static string WindowTitle(IntPtr window) {
    if (window == IntPtr.Zero) return "";
    int length = GetWindowTextLength(window);
    var text = new StringBuilder(length + 1);
    GetWindowText(window, text, text.Capacity);
    return text.ToString();
  }
  public static void HideWindow(IntPtr window) {
    if (window != IntPtr.Zero) ShowWindow(window, 0);
  }
  public static void HideProcessWindows(uint processId) {
    EnumWindows(delegate(IntPtr window, IntPtr parameter) {
      uint owner;
      GetWindowThreadProcessId(window, out owner);
      if (owner == processId) HideWindow(window);
      return true;
    }, IntPtr.Zero);
  }
  public static bool PostMouseClick(IntPtr window) {
    return PostMessage(window, 0x0201, UIntPtr.Zero, IntPtr.Zero);
  }
  public static bool PostCommand(IntPtr window, uint command) {
    return PostMessage(window, 0x0111, (UIntPtr)command, IntPtr.Zero);
  }
  public static bool PostClose(IntPtr window) {
    return PostMessage(window, 0x0010, UIntPtr.Zero, IntPtr.Zero);
  }
  public static bool SetFirstEditText(IntPtr parent, string text) {
    var edit = FindWindowEx(parent, IntPtr.Zero, "Edit", null);
    if (edit == IntPtr.Zero || !SetWindowText(edit, text)) return false;
    ulong command = ((ulong)0x0300 << 16) | (uint)GetDlgCtrlID(edit);
    SendMessage(parent, 0x0111, (UIntPtr)command, edit);
    return true;
  }
}
"@ -ReferencedAssemblies @(
  [System.Windows.Automation.AutomationElement].Assembly.Location,
  [System.Windows.Automation.AutomationEventArgs].Assembly.Location
)

function Require([bool] $condition, [string] $message) {
  if (-not $condition) { throw $message }
}

function Format-WindowHandle([IntPtr] $handle) {
  return "0x$($handle.ToInt64().ToString('x'))"
}

function Format-AutomationElement(
  [System.Windows.Automation.AutomationElement] $element
) {
  if ($null -eq $element) {
    return "unavailable"
  }
  try {
    return "$($element.Current.AutomationId):$($element.Current.Name)"
  } catch {
    return "unavailable:$($_.Exception.Message)"
  }
}

function Get-FocusDiagnostics([IntPtr] $expectedWindow) {
  $foreground = [GraphCodeUiaGateState]::CurrentForegroundWindow()
  $foregroundProcessId = [GraphCodeUiaGateState]::WindowProcessId($foreground)
  $foregroundProcess = if ($foregroundProcessId -ne 0) {
    Get-Process -Id $foregroundProcessId -ErrorAction SilentlyContinue
  } else {
    $null
  }
  $focusedDescription = "unavailable"
  try {
    $focusedElement = [System.Windows.Automation.AutomationElement]::FocusedElement
    $focusedDescription = "automationId='$($focusedElement.Current.AutomationId)' name='$($focusedElement.Current.Name)' processId=$($focusedElement.Current.ProcessId)"
  } catch {
    $focusedDescription = "error='$($_.Exception.Message)'"
  }
  return "foreground=$(Format-WindowHandle $foreground) expected=$(Format-WindowHandle $expectedWindow) expectedIsForeground=$([GraphCodeUiaGateState]::IsForegroundWindow($expectedWindow)) foregroundPid=$foregroundProcessId foregroundProcess='$($foregroundProcess.ProcessName)' foregroundClass='$([GraphCodeUiaGateState]::WindowClass($foreground))' foregroundTitle='$([GraphCodeUiaGateState]::WindowTitle($foreground))' focused={$focusedDescription}"
}

function Wait-ForDesktopElement(
  [System.Windows.Automation.AutomationElement] $desktop,
  [System.Windows.Automation.Condition] $condition,
  [string] $label,
  [IntPtr] $diagnosticWindow = [IntPtr]::Zero,
  [int] $TimeoutMilliseconds = 10000,
  [int] $PollMilliseconds = 50,
  [switch] $RecoverForeground
) {
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
  $element = $null
  $foregroundRecoveries = 0
  while ([DateTime]::UtcNow -lt $deadline -and $null -eq $element) {
    $element = $desktop.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $condition
    )
    if ($null -eq $element) {
      if ($RecoverForeground -and $diagnosticWindow -ne [IntPtr]::Zero -and
          -not [GraphCodeUiaGateState]::IsForegroundWindow($diagnosticWindow)) {
        $remainingMilliseconds = [Math]::Max(
          1, [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        )
        $recoveryTimeout = [Math]::Min(1000, $remainingMilliseconds)
        $foregroundRecoveries++
        Write-Host "UIA_WAIT_FOREGROUND_RECOVERY label=$label attempt=$foregroundRecoveries phase=lost $(Get-FocusDiagnostics $diagnosticWindow)"
        $recovered = Ensure-ShellForeground `
          -window $diagnosticWindow `
          -label "$label modal-open recovery" `
          -TimeoutMilliseconds $recoveryTimeout `
          -PollMilliseconds $PollMilliseconds
        if (-not $recovered) {
          Write-Host "UIA_WAIT_FOREGROUND_RECOVERY label=$label attempt=$foregroundRecoveries phase=unrecovered $(Get-FocusDiagnostics $diagnosticWindow)"
        }
      }
      Start-Sleep -Milliseconds $PollMilliseconds
    }
  }
  if ($null -eq $element -and $diagnosticWindow -ne [IntPtr]::Zero) {
    Write-Host "UIA_WAIT_DIAGNOSTICS label=$label foregroundRecoveries=$foregroundRecoveries $(Get-FocusDiagnostics $diagnosticWindow)"
  }
  return $element
}

function Wait-ForDesktopElementGone(
  [System.Windows.Automation.AutomationElement] $desktop,
  [System.Windows.Automation.Condition] $condition,
  [string] $label,
  [IntPtr] $diagnosticWindow = [IntPtr]::Zero,
  [int] $TimeoutMilliseconds = 10000,
  [int] $PollMilliseconds = 50
) {
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
  $element = $desktop.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    $condition
  )
  while ([DateTime]::UtcNow -lt $deadline -and $null -ne $element) {
    Start-Sleep -Milliseconds $PollMilliseconds
    $element = $desktop.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $condition
    )
  }
  if ($null -ne $element -and $diagnosticWindow -ne [IntPtr]::Zero) {
    Write-Host "UIA_WAIT_DIAGNOSTICS label=$label-still-present $(Get-FocusDiagnostics $diagnosticWindow)"
  }
  return $null -eq $element
}

function Hide-TestProviderZmxWindows {
  if (-not $env:GRAPHCODE_ZMX) { return }
  $providerZmx = [IO.Path]::GetFullPath($env:GRAPHCODE_ZMX)
  foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -match "(?i)^zmx(?:\.exe)?$" -and
        (([string]$_.ExecutablePath) -eq $providerZmx -or
         ([string]$_.CommandLine) -like "*$providerZmx*")
      })) {
    [GraphCodeUiaGateState]::HideProcessWindows([uint32]$process.ProcessId)
  }
  $foreground = [GraphCodeUiaGateState]::CurrentForegroundWindow()
  $foregroundTitle = [GraphCodeUiaGateState]::WindowTitle($foreground)
  if ($foregroundTitle -eq $providerZmx -or
      $foregroundTitle -like "*\zmx.exe") {
    [GraphCodeUiaGateState]::HideWindow($foreground)
  }
}

function Test-FocusedElementIdentity(
  [System.Windows.Automation.AutomationElement] $candidate,
  [System.Windows.Automation.AutomationElement] $expected,
  [string] $expectedAutomationId
) {
  if ($null -eq $candidate -or $null -eq $expected) { return $false }
  try {
    if ($expectedAutomationId -and
        $candidate.Current.AutomationId -eq $expectedAutomationId) {
      return $true
    }
    if ($expected.Current.NativeWindowHandle -ne 0 -and
        $candidate.Current.NativeWindowHandle -eq $expected.Current.NativeWindowHandle) {
      return $true
    }
    return (Get-RuntimeIdentity $candidate) -eq (Get-RuntimeIdentity $expected)
  } catch {
    return $false
  }
}

function Retain-FocusWithRetry(
  [IntPtr] $window,
  [System.Windows.Automation.AutomationElement] $element,
  [string] $expectedAutomationId,
  [string] $label,
  [int] $Attempts = 600
) {
  $candidate = $null
  Hide-TestProviderZmxWindows
  Start-Sleep -Milliseconds 250
  Write-Host "UIA_FOCUS_DIAGNOSTICS phase=$label $(Get-FocusDiagnostics $window)"
  for ($index = 0; $index -lt $Attempts; $index++) {
    Hide-TestProviderZmxWindows
    $activated = [GraphCodeUiaGateState]::ActivateWindow($window)
    Start-Sleep -Milliseconds 50
    try {
      $element.SetFocus()
    } catch {
      $null = [GraphCodeUiaGateState]::FocusControl(
        $window, [IntPtr]$element.Current.NativeWindowHandle
      )
    }
    Start-Sleep -Milliseconds 50
    try {
      $candidate = [System.Windows.Automation.AutomationElement]::FocusedElement
    } catch {
      $candidate = $null
    }
    if ($activated -and
        [GraphCodeUiaGateState]::IsForegroundWindow($window) -and
        (Test-FocusedElementIdentity $candidate $element $expectedAutomationId)) {
      return [pscustomobject]@{ Focused = $candidate; Candidate = $candidate }
    }
  }
  return [pscustomobject]@{ Focused = $null; Candidate = $candidate }
}

function Ensure-ShellForeground(
  [IntPtr] $window,
  [string] $label,
  [int] $TimeoutMilliseconds = 5000,
  [int] $PollMilliseconds = 50
) {
  # GitHub's hosted runner agent (or other host chrome) can steal the
  # foreground window between UIA steps. Reacquire and verify true
  # foreground ownership of the GraphCode shell immediately before any
  # command/UIA path that depends on the shell being foreground, retrying
  # within a bounded deadline instead of assuming a prior activation holds.
  #
  # Only fall back to ActivateWindow's invasive Alt-tap foreground-lock
  # bypass (keybd_event + SetForegroundWindow) when the shell does not
  # already hold true foreground ownership: that trick injects a global
  # synthetic Alt key press/release, and issuing it when it is not needed
  # (the shell is already foreground) races the very next native window
  # this gate creates and can desynchronize its subsequent close handling.
  if ([GraphCodeUiaGateState]::IsForegroundWindow($window)) {
    return $true
  }
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
  $acquired = $false
  do {
    Hide-TestProviderZmxWindows
    $activated = [GraphCodeUiaGateState]::ActivateWindow($window)
    $acquired = $activated -and [GraphCodeUiaGateState]::IsForegroundWindow($window)
    if (-not $acquired) {
      Start-Sleep -Milliseconds $PollMilliseconds
    }
  } while (-not $acquired -and [DateTime]::UtcNow -lt $deadline)
  if (-not $acquired) {
    Write-Host "UIA_FOREGROUND_DIAGNOSTICS phase=$label $(Get-FocusDiagnostics $window)"
  }
  return $acquired
}

function Get-DirectChildren(
  [System.Windows.Automation.AutomationElement] $element,
  [System.Windows.Automation.TreeWalker] $walker
) {
  $children = New-Object System.Collections.Generic.List[System.Windows.Automation.AutomationElement]
  $child = $walker.GetFirstChild($element)
  while ($null -ne $child) {
    $children.Add($child)
    $child = $walker.GetNextSibling($child)
  }
  return @($children.ToArray())
}

function Assert-Ids([string[]] $actual, [string[]] $expected, [string] $label) {
  Require (@($actual).Count -eq @($expected).Count) "$label count expected $($expected.Count) but found $($actual.Count): $($actual -join ',')"
  Require ((@($actual) -join "|") -eq (@($expected) -join "|")) "$label expected $($expected -join ',') but found $($actual -join ',')"
}

function Get-RuntimeIdentity([System.Windows.Automation.AutomationElement] $element) {
  return (@($element.GetRuntimeId()) -join ",")
}

function Find-FragmentById(
  [System.Windows.Automation.AutomationElement] $root,
  [string] $automationId,
  [System.Windows.Automation.TreeWalker] $walker
) {
  $pending = New-Object System.Collections.Generic.Queue[System.Windows.Automation.AutomationElement]
  $pending.Enqueue($root)
  while ($pending.Count -gt 0) {
    $current = $pending.Dequeue()
    foreach ($child in @(Get-DirectChildren $current $walker)) {
      if ($child.Current.AutomationId -eq $automationId) { return $child }
      $pending.Enqueue($child)
    }
  }
  return $null
}

function Assert-FragmentLinks(
  [System.Windows.Automation.AutomationElement] $parent,
  [System.Windows.Automation.TreeWalker] $walker,
  [string[]] $expectedIds,
  [string] $label
) {
  $allChildren = @(Get-DirectChildren $parent $walker)
  $allowedNativeIds = if ($label -match "root$") { @("4601", "4602") } else { @() }
  $unexpectedIds = @($allChildren | ForEach-Object { $_.Current.AutomationId } |
    Where-Object { $_ -and $_ -notin $expectedIds -and $_ -notin $allowedNativeIds })
  Require ($unexpectedIds.Count -eq 0) "$label exposed unexpected children: $($unexpectedIds -join ',')"
  $children = @($allChildren | Where-Object { $_.Current.AutomationId -in $expectedIds })
  $ids = @($children | ForEach-Object { $_.Current.AutomationId })
  Assert-Ids $ids $expectedIds "$label direct children"
  for ($i = 0; $i -lt $children.Count; $i++) {
    $child = $children[$i]
    Require ($walker.GetParent($child).Current.AutomationId -eq $parent.Current.AutomationId) "$label parent mismatch for $($ids[$i])"
    $previous = $walker.GetPreviousSibling($child)
    $next = $walker.GetNextSibling($child)
    while ($null -ne $previous -and $previous.Current.AutomationId -notin $expectedIds) {
      $previous = $walker.GetPreviousSibling($previous)
    }
    while ($null -ne $next -and $next.Current.AutomationId -notin $expectedIds) {
      $next = $walker.GetNextSibling($next)
    }
    if ($i -eq 0) {
      Require ($null -eq $previous) "$label first child has a previous sibling"
    } else {
      Require ($previous.Current.AutomationId -eq $ids[$i - 1]) "$label previous sibling mismatch for $($ids[$i])"
    }
    if ($i -eq $children.Count - 1) {
      Require ($null -eq $next) "$label last child has a next sibling"
    } else {
      Require ($next.Current.AutomationId -eq $ids[$i + 1]) "$label next sibling mismatch for $($ids[$i])"
    }
  }
  return $children
}

$oldZmx = [Environment]::GetEnvironmentVariable("GRAPHCODE_ZMX")
$oldCwd = [Environment]::GetEnvironmentVariable("GRAPHCODE_GATE_CWD")
$oldGate = [Environment]::GetEnvironmentVariable("GRAPHCODE_UIA_GATE")
$oldConnectionFailure = [Environment]::GetEnvironmentVariable("GRAPHCODE_UIA_CONNECTION_FAILURE")
$oldUser = [Environment]::GetEnvironmentVariable("USERNAME")
$oldFixture = [Environment]::GetEnvironmentVariable("GRAPHCODE_UIA_FIXTURE_ROWS")
$oldDaemonPipe = [Environment]::GetEnvironmentVariable("GRAPHCODE_DAEMON_PIPE")
$oldSupportDirectory = [Environment]::GetEnvironmentVariable("GRAPHCODE_SUPPORT_DIR")
$oldResetSidebar = [Environment]::GetEnvironmentVariable("GRAPHCODE_UIA_RESET_SIDEBAR")
$oldUpdateAvailable = [Environment]::GetEnvironmentVariable("GRAPHCODE_UIA_UPDATE_AVAILABLE")
$oldShowUpdate = [Environment]::GetEnvironmentVariable("GRAPHCODE_UIA_SHOW_UPDATE")
$oldIngressError = [Environment]::GetEnvironmentVariable("GRAPHCODE_UIA_INGRESS_ERROR")
$oldDaemonCommandLog = [Environment]::GetEnvironmentVariable("GRAPHCODE_UIA_DAEMON_COMMAND_LOG")
$oldShellExecuteLog = [Environment]::GetEnvironmentVariable("GRAPHCODE_UIA_SHELL_EXECUTE_LOG")
$oldLocalAppData = [Environment]::GetEnvironmentVariable("LOCALAPPDATA")
$process = $null
$settingsProcess = $null
$status = $null
$liveRegionEvent = $null
$eventHandler = $null
$propertyHandler = $null
$focusHandler = $null
$liveEventRegistered = $false
$propertyEventRegistered = $false
$focusEventRegistered = $false
$stressJob = $null
$policyDirectory = $null
$policyPath = $null
$policyDirectoryExisted = $false
$policyExisted = $false
$policyContents = $null
$settingsDirectory = $null
$settingsPath = $null
$settingsErrorPath = $null
$daemonCommandLogPath = $null
$shellExecuteLogPath = $null
$templateDirectory = $null
try {
  if ($Zmx) { $env:GRAPHCODE_ZMX = $Zmx }
  $env:GRAPHCODE_GATE_CWD = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
  $env:GRAPHCODE_UIA_GATE = "1"
  $env:GRAPHCODE_UIA_CONNECTION_FAILURE = "1"
  $env:GRAPHCODE_UIA_UPDATE_AVAILABLE = "1"
  $env:GRAPHCODE_UIA_SHOW_UPDATE = "1"
  $env:USERNAME = "GraphCodeUIAGate"
  $env:GRAPHCODE_UIA_FIXTURE_ROWS = "C:\fixture-safe|safe,C:\fixture-unsafe|unsafe"
  $env:GRAPHCODE_DAEMON_PIPE = "\\.\pipe\graphcode-uia-gate-$PID"
  $daemonCommandLogPath = Join-Path $env:GRAPHCODE_GATE_CWD ".graphcode-uia-daemon-command-$PID.json"
  $shellExecuteLogPath = Join-Path $env:GRAPHCODE_GATE_CWD ".graphcode-uia-shell-execute-$PID.log"
  Remove-Item -LiteralPath $daemonCommandLogPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $shellExecuteLogPath -Force -ErrorAction SilentlyContinue
  $env:GRAPHCODE_UIA_DAEMON_COMMAND_LOG = $daemonCommandLogPath
  $env:GRAPHCODE_UIA_SHELL_EXECUTE_LOG = $shellExecuteLogPath
  $templateDirectory = Join-Path ([IO.Path]::GetTempPath()) "graphcode-uia-templates-$PID"
  $env:LOCALAPPDATA = $templateDirectory
  $savedTemplates = Join-Path $templateDirectory "GraphCode\templates"
  New-Item -ItemType Directory -Path $savedTemplates -Force | Out-Null
  [IO.File]::WriteAllText(
    (Join-Path $savedTemplates "uia-release-review.md"),
    "---`nid: 11111111-1111-4111-8111-111111111111`nname: UIA release review`nshape: turn`n---`nReview the release diff.`n"
  )
  $settingsDirectory = Join-Path $env:GRAPHCODE_GATE_CWD ".graphcode-uia-product-settings-$PID"
  $settingsPath = Join-Path $settingsDirectory "settings.json"
  $settingsErrorPath = Join-Path $settingsDirectory "stderr.log"
  New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
  [IO.File]::WriteAllText(
    $settingsPath,
    '{"defaultBackend":"claudeCode","defaultModelTier":"capable",' +
    '"claudePermissionMode":"auto","copilotPermissions":"allowEverything",' +
    '"codexApprovals":"workspace","showsActivityStrip":true,' +
    '"briefsSessionsAboutTheGraph":false,"betaUpdates":true,' +
    '"autoSelectsModel":true,"gateSentinel":"preserve"}'
  )
  $env:GRAPHCODE_SUPPORT_DIR = $settingsDirectory
  $env:GRAPHCODE_UIA_RESET_SIDEBAR = "1"
  $policyDirectory = Join-Path $env:GRAPHCODE_GATE_CWD ".graphcode"
  $policyPath = Join-Path $policyDirectory "worktree-policy.json"
  $policyDirectoryExisted = Test-Path -LiteralPath $policyDirectory
  $policyExisted = Test-Path -LiteralPath $policyPath
  if ($policyExisted) { $policyContents = [IO.File]::ReadAllBytes($policyPath) }
  if ($ArgumentList.Count -gt 0) {
    $process = Start-Process -FilePath $Shell -ArgumentList $ArgumentList -PassThru -WindowStyle Normal
  } else {
    $process = Start-Process -FilePath $Shell -PassThru -WindowStyle Normal
  }

  $root = $null
  for ($i = 0; $i -lt 160; $i++) {
    Start-Sleep -Milliseconds 250
    $process.Refresh()
    if ($process.HasExited) { throw "shell exited with code $($process.ExitCode)" }
    if ($process.MainWindowHandle -ne 0) {
      $candidate = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
      if ($candidate.Current.AutomationId -eq "graphcode-root") {
        $root = $candidate
        break
      }
    }
  }
  if ($null -eq $root) { throw "shell did not expose graphcode-root through WM_GETOBJECT" }

  $expectedRootIds = @("projects", "loops", "worktrees", "graph", "actions", "status", "workspaces")
  $rawWalker = [System.Windows.Automation.TreeWalker]::RawViewWalker
  $controlWalker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $shellWindow = $process.MainWindowHandle
  $desktop = [System.Windows.Automation.AutomationElement]::RootElement
  $updateDialog = $desktop.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty,
      "GraphCode Update Available"
    ))
  )
  Require ($null -ne $updateDialog) "update offer dialog did not appear"
  Start-Sleep -Milliseconds 250
  $updateDialog = $desktop.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty,
      "GraphCode Update Available"
    ))
  )
  $installButton = $updateDialog.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty,
      "Install"
    ))
  )
  $releaseNotesButton = $updateDialog.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty,
      "Release Notes"
    ))
  )
  $laterButton = $updateDialog.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty,
      "Later"
    ))
  )
  Require (($null -ne $installButton) -and (-not $installButton.Current.IsEnabled)) `
    "update offer did not expose a disabled Install action"
  Require (($null -ne $releaseNotesButton) -and ($null -ne $laterButton)) `
    "update offer did not expose Release Notes and Later actions"
  Require ([GraphCodeUiaGateState]::SendCommand([IntPtr]$updateDialog.Current.NativeWindowHandle, 9703)) `
    "update offer Later action could not be invoked"
  Start-Sleep -Milliseconds 150
  $status = Find-FragmentById $root "status" $controlWalker
  $rawRootChildren = @(Assert-FragmentLinks $root $rawWalker $expectedRootIds "RawView root")
  $controlRootChildren = @(Assert-FragmentLinks $root $controlWalker $expectedRootIds "ControlView root")

  $workspaces = Find-FragmentById $root "workspaces" $rawWalker
  Require ($null -ne $workspaces) "Workspace lifecycle menu was not exposed"
  $null = $workspaces.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
  $workspaceLifecycle = @(
    @{ Id = "workspace-new"; Name = "New Workspace" },
    @{ Id = "workspace-rename"; Name = "Rename Workspace" },
    @{ Id = "workspace-delete"; Name = "Delete Workspace" }
  )
  foreach ($expected in $workspaceLifecycle) {
    $element = Find-FragmentById $workspaces $expected.Id $rawWalker
    Require (($null -ne $element) -and ($element.Current.Name -eq $expected.Name)) `
      "$($expected.Name) was not exposed under the Workspace lifecycle menu"
    $null = $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  }
  $workspaceSwitches = @(Get-DirectChildren $workspaces $rawWalker |
    Where-Object { $_.Current.AutomationId -match '^workspace-switch-' })
  Require ($workspaceSwitches.Count -ge 1) "Workspace lifecycle menu did not expose the current workspace"
  $expectedWorkspaceIds = @($workspaceLifecycle.Id) +
    @($workspaceSwitches | ForEach-Object { $_.Current.AutomationId })
  $null = @(Assert-FragmentLinks $workspaces $rawWalker $expectedWorkspaceIds "RawView Workspaces")
  $null = @(Assert-FragmentLinks $workspaces $controlWalker $expectedWorkspaceIds "ControlView Workspaces")

  $projects = Find-FragmentById $root "projects" $rawWalker
  $loops = Find-FragmentById $root "loops" $rawWalker
  $graph = Find-FragmentById $root "graph" $rawWalker
  Require (($null -ne $projects) -and ($null -ne $loops) -and ($null -ne $graph)) "missing Projects, Loops, or Graph fragments"
  $connectionAlert = $root.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty,
      "GraphCode daemon unavailable. Navigation remains available while reconnection continues."
    ))
  )
  Require ($null -ne $connectionAlert) "connection failure did not expose its inline canvas banner"
  Require (($connectionAlert.Current.BoundingRectangle.Width -gt 0) -and
           ($connectionAlert.Current.BoundingRectangle.Height -gt 0)) `
    "connection failure banner had empty bounds"
  $navigationIds = @("overview-destination", "quick-chats-destination")
  $canvasActionIds = @("canvas-primary-action", "zoom-out", "actual-size", "zoom-in", "fit-canvas")
  $projectRows = @(Get-DirectChildren $projects $rawWalker | Where-Object { $_.Current.AutomationId -match '^project-row-' })
  $openProjectRows = @(Get-DirectChildren $projects $rawWalker | Where-Object { $_.Current.AutomationId -match '^open-project-' })
  $graphDestination = Find-FragmentById $root "overview-destination" $rawWalker
  Require (($null -ne $graphDestination) -and ($graphDestination.Current.Name -eq "Graph")) `
    "global sidebar destination did not expose the pinned Graph identity"
  Require ($projectRows.Count -eq 1) "Projects did not expose grouped recent rows"
  Require ($openProjectRows.Count -eq 1) "Projects did not expose the separate open-project row"
  Require ((@($projectRows | ForEach-Object { $_.Current.Name }) -join "|") -eq "Fixture remote") "recent project row names were not synchronized"
  Require ($openProjectRows[0].Current.Name -eq "UIA project") "open project row name was not synchronized"
  foreach ($projectRow in $projectRows) {
    Require (($projectRow.Current.BoundingRectangle.Width -gt 0) -and
             ($projectRow.Current.BoundingRectangle.Height -gt 0)) "dynamic project row has empty bounds"
  }
  foreach ($projectRow in $openProjectRows) {
    Require (($projectRow.Current.BoundingRectangle.Width -gt 0) -and
             ($projectRow.Current.BoundingRectangle.Height -gt 0)) "open project row has empty bounds"
  }
  $needsYouRows = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^needs-you-row-'
  })
  $activityRows = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^activity-row-'
  })
  $activityControls = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^activity-control-'
  })
  $needsYouHeaders = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^needs-you-header-'
  })
  $activityHeaders = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^activity-header-'
  })
  if ($needsYouRows.Count -gt 0 -or $needsYouHeaders.Count -gt 0) {
    Require ($needsYouHeaders.Count -eq 1) "Needs-you rows omitted their stable header"
    Require ($needsYouHeaders[0].Current.Name -eq "Needs you") "Needs-you header name changed"
  }
  if ($activityRows.Count -gt 0 -or $activityControls.Count -gt 0 -or $activityHeaders.Count -gt 0) {
    Require ($activityHeaders.Count -eq 1) "Activity controls omitted their stable header"
    Require ($activityHeaders[0].Current.Name -eq "Activity") "Activity header name changed"
  }
  if ($needsYouRows.Count -gt 0) {
    Require ($needsYouRows.Count -le 4) "Needs-you exposed more than four sidebar rows"
    $needsYouIds = @($needsYouRows | ForEach-Object { $_.Current.AutomationId })
    Require (($needsYouIds | Where-Object { $_ -notmatch '^needs-you-row-[0-9]+$' }).Count -eq 0) `
      "Needs-you rows did not use stable dynamic IDs"
    foreach ($row in $needsYouRows) {
      Require ($row.Current.Name.Length -gt 0) "Needs-you row omitted its name"
      Require (($row.Current.BoundingRectangle.Width -gt 0) -and
               ($row.Current.BoundingRectangle.Height -gt 0)) "Needs-you row has empty bounds"
    }
  }
  if ($activityRows.Count -gt 0) {
    Require ($activityRows.Count -le 4) "Activity exposed more than four sidebar rows"
    $activityIds = @($activityRows | ForEach-Object { $_.Current.AutomationId })
    Require (($activityIds | Where-Object { $_ -notmatch '^activity-row-[0-9]+$' }).Count -eq 0) `
      "Activity rows did not use stable dynamic IDs"
    foreach ($row in $activityRows) {
      Require ($row.Current.Name.Length -gt 0) "Activity row omitted its name"
      Require (($row.Current.BoundingRectangle.Width -gt 0) -and
               ($row.Current.BoundingRectangle.Height -gt 0)) "Activity row has empty bounds"
    }
  }
  foreach ($control in $activityControls) {
    Require (($control.Current.BoundingRectangle.Width -gt 0) -and
             ($control.Current.BoundingRectangle.Height -gt 0)) "Activity control has empty bounds"
    $null = $control.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  }
  $null = $projects.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
  $null = $projectRows[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
  $projectRowInvoke = $projectRows[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  $projectRowIds = @($projectRows | ForEach-Object { $_.Current.AutomationId })
  $projectChildIds = @(Get-DirectChildren $projects $rawWalker |
    ForEach-Object { $_.Current.AutomationId } | Where-Object { $_ })
  $null = Assert-FragmentLinks $projects $rawWalker $projectChildIds "RawView Projects"
  $null = Assert-FragmentLinks $projects $controlWalker $projectChildIds "ControlView Projects"
  $remoteSection = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^sidebar-section-' -and $_.Current.Name -eq "Remote Repositories"
  }) | Select-Object -First 1
  Require ($null -ne $remoteSection) "Remote sidebar section did not expose its section action"
  $remoteRowId = @($projectRows | Where-Object { $_.Current.Name -eq "Fixture remote" })[0].Current.AutomationId
  $remoteSection.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150
  $collapsedProjectNames = @(Get-DirectChildren $projects $rawWalker |
    Where-Object { $_.Current.AutomationId -match '^(project-row|open-project)-' } |
    ForEach-Object { $_.Current.Name })
  Require (("Fixture remote" -notin $collapsedProjectNames) -and
           ("UIA project" -in $collapsedProjectNames)) `
    "Remote section collapse did not hide only the unopened recent folder"
  $openProjectAfterRemoteCollapse = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^open-project-' -and $_.Current.Name -eq 'UIA project'
  }) | Select-Object -First 1
  Require ($null -ne $openProjectAfterRemoteCollapse) "open project row disappeared when collapsing recents"
  $remoteSection = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^sidebar-section-' -and $_.Current.Name -eq "Remote Repositories"
  }) | Select-Object -First 1
  $remoteSection.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150

  $loopRows = @(Get-DirectChildren $loops $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^loop-row-'
  })
  Require (($loopRows.Count -eq 1) -and ($loopRows[0].Current.Name -eq "UIA loop A")) `
    "nested loop tree did not start collapsed at its root"
  $loopDisclosure = @(Get-DirectChildren $loops $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^loop-disclosure-' -and
    $_.Current.Name -eq "Expand loop children"
  }) | Select-Object -First 1
  Require ($null -ne $loopDisclosure) "nested root omitted its disclosure action"
  $rootLoopId = $loopRows[0].Current.AutomationId
  $loopDisclosure.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150
  $loopRows = @(Get-DirectChildren $loops $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^loop-row-'
  })
  Require (($loopRows.Count -eq 2) -and
           ((@($loopRows | ForEach-Object { $_.Current.Name }) -join "|") -eq "UIA loop A|UIA loop B") -and
           ($loopRows[0].Current.AutomationId -eq $rootLoopId)) `
    "nested disclosure did not reveal its child while preserving root identity"
  $projectDisclosure = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^project-disclosure-' -and
    $_.Current.Name -eq "Collapse project"
  }) | Select-Object -First 1
  Require ($null -ne $projectDisclosure) "open project omitted its disclosure action"
  $projectDisclosure.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150
  Require (@(Get-DirectChildren $loops $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^loop-row-'
  }).Count -eq 0) "project disclosure did not collapse its loop tree"
  $projectDisclosure = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^project-disclosure-' -and
    $_.Current.Name -eq "Expand project"
  }) | Select-Object -First 1
  Require ($null -ne $projectDisclosure) "project disclosure did not expose collapsed state"
  $projectDisclosure.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150
  $loopRows = @(Get-DirectChildren $loops $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^loop-row-'
  })
  Require (($loopRows.Count -eq 2) -and
           ($loopRows[0].Current.AutomationId -eq $rootLoopId)) `
    "project expansion did not restore its stable nested loop tree"
  $projectNewLoop = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^project-new-loop-' -and $_.Current.Name -eq "New Loop"
  }) | Select-Object -First 1
  Require ($null -ne $projectNewLoop) "project row omitted New Loop"
  Require (Ensure-ShellForeground $shellWindow "project-row New Loop") `
    "GraphCode shell did not reacquire foreground before invoking project-row New Loop"
  $projectNewLoop.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  $sidebarNodeForm = $null
  $sidebarNodeFormCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id
    )),
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Create or edit node"
    ))
  )
  $sidebarNodeForm = Wait-ForDesktopElement `
    -desktop $desktop `
    -condition $sidebarNodeFormCondition `
    -label "project-row New Loop node form" `
    -diagnosticWindow $shellWindow `
    -RecoverForeground
  Require ($null -ne $sidebarNodeForm) "project-row New Loop did not open the node form"
  $templatesButton = $sidebarNodeForm.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Templates"
    ))
  )
  Require ($null -ne $templatesButton) "node form omitted the explicit Templates action"
  Require ($templatesButton.Current.AutomationId -eq "4") `
    "Templates action did not expose its stable native command identity"
  Require ([GraphCodeUiaGateState]::PostCommand(
    [IntPtr]$sidebarNodeForm.Current.NativeWindowHandle, 4
  )) "Templates action rejected invocation"
  $templatePickerCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id
    )),
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Choose a saved template"
    ))
  )
  $templatePicker = Wait-ForDesktopElement `
    -desktop $desktop `
    -condition $templatePickerCondition `
    -label "project-row New Loop template picker" `
    -diagnosticWindow $shellWindow `
    -RecoverForeground
  Require ($null -ne $templatePicker) "project-row New Loop did not expose the saved template picker"
  Require ([GraphCodeUiaGateState]::PostKeyboard(
    [IntPtr]$templatePicker.Current.NativeWindowHandle, 0x0D
  )) "template picker rejected keyboard application"
  $sidebarNodeForm = Wait-ForDesktopElement `
    -desktop $desktop `
    -condition $sidebarNodeFormCondition `
    -label "project-row New Loop node form" `
    -diagnosticWindow $shellWindow `
    -RecoverForeground
  Require ($null -ne $sidebarNodeForm) "project-row New Loop did not open the node form"
  Require ([GraphCodeUiaGateState]::PostClose(
    [IntPtr]$sidebarNodeForm.Current.NativeWindowHandle
  )) "project-row New Loop form rejected cancellation"
  Require (Wait-ForDesktopElementGone `
    -desktop $desktop `
    -condition $sidebarNodeFormCondition `
    -label "project-row New Loop node form close" `
    -diagnosticWindow $shellWindow) "project-row New Loop form did not close after cancellation"
  $loopIds = @($loopRows | ForEach-Object { $_.Current.AutomationId })
  $null = $loops.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
  foreach ($row in $loopRows) {
    $null = $row.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $null = $row.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  }
  $loopChildIds = @(Get-DirectChildren $loops $rawWalker |
    ForEach-Object { $_.Current.AutomationId } | Where-Object { $_ })
  $null = Assert-FragmentLinks $loops $rawWalker $loopChildIds "RawView Loops"
  $null = Assert-FragmentLinks $loops $controlWalker $loopChildIds "ControlView Loops"
  $projectCards = @(Get-DirectChildren $graph $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^canvas-card-' -and
    $_.Current.Name -in @("UIA loop A", "UIA loop B")
  })
  Require (($projectCards.Count -eq 2) -and
           ((@($projectCards | ForEach-Object { $_.Current.Name }) -join "|") -eq "UIA loop A|UIA loop B")) "Graph did not expose synchronized project cards"
  foreach ($card in $projectCards) {
    Require (($card.Current.BoundingRectangle.Width -gt 0) -and
             ($card.Current.BoundingRectangle.Height -gt 0)) "dynamic project card has empty bounds"
    $null = $card.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $null = $card.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
  }
  $projectCardIds = @($projectCards | ForEach-Object { $_.Current.AutomationId })
  $attentionAction = @(Get-DirectChildren $graph $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^attention-action-' -and $_.Current.Name -eq "Reply"
  }) | Select-Object -First 1
  Require ($null -ne $attentionAction) "NEEDS YOU card omitted its reason-specific Reply action"
  Require (($attentionAction.Current.BoundingRectangle.Width -gt 0) -and
           ($attentionAction.Current.BoundingRectangle.Height -gt 0)) "Reply attention action had empty bounds"
  $null = $attentionAction.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  $reclaimOffer = @(Get-DirectChildren $graph $rawWalker | Where-Object { $_.Current.Name -eq "Reclaim" }) | Select-Object -First 1
  $keepOffer = @(Get-DirectChildren $graph $rawWalker | Where-Object { $_.Current.Name -eq "Keep" }) | Select-Object -First 1
  Require ($null -ne $reclaimOffer) "resolved card with a reclaimable worktree omitted its Reclaim descendant"
  Require ($null -ne $keepOffer) "resolved card with a reclaimable worktree omitted its Keep descendant"
  Require (($reclaimOffer.Current.BoundingRectangle.Width -gt 0) -and
           ($reclaimOffer.Current.BoundingRectangle.Height -gt 0)) "Reclaim descendant had empty bounds"
  Require (($keepOffer.Current.BoundingRectangle.Width -gt 0) -and
           ($keepOffer.Current.BoundingRectangle.Height -gt 0)) "Keep descendant had empty bounds"
  $null = $reclaimOffer.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  $null = $keepOffer.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  # The Reclaim/Keep descendants for a resolved card are siblings placed immediately
  # after that card, so derive the expected order from the live tree (as with Loops
  # and Projects above) instead of assuming cards and the offer are contiguous blocks.
  $graphChildIds = @(Get-DirectChildren $graph $rawWalker |
    ForEach-Object { $_.Current.AutomationId } | Where-Object { $_ })
  $expectedGraphIds = @($projectCardIds + @($attentionAction.Current.AutomationId, $connectionAlert.Current.AutomationId, $reclaimOffer.Current.AutomationId, $keepOffer.Current.AutomationId) + $canvasActionIds)
  Require ((@($graphChildIds | Sort-Object) -join ",") -eq (@($expectedGraphIds | Sort-Object) -join ",")) `
    "Graph exposed unexpected or missing children: $($graphChildIds -join ',')"
  $null = Assert-FragmentLinks $graph $rawWalker $graphChildIds "RawView Graph"
  $null = Assert-FragmentLinks $graph $controlWalker $graphChildIds "ControlView Graph"
  $projectCards[1].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150
  $compositeChildren = @(Get-DirectChildren $graph $rawWalker | Where-Object { $_.Current.AutomationId -match '^canvas-card-' })
  $nestedCards = @($compositeChildren | Where-Object { $_.Current.Name -match '^UIA nested ' })
  Require (($nestedCards.Count -eq 2) -and
           ((@($nestedCards | ForEach-Object { $_.Current.Name }) -join "|") -eq "UIA nested A|UIA nested B")) `
    "Open Group did not expose the nested composite canvas"
  $compositeBack = @($compositeChildren | Where-Object { $_.Current.Name -eq "Back to UIA project" })
  Require ($compositeBack.Count -eq 1) `
    "Composite canvas did not expose its Back breadcrumb: $(@($compositeChildren | ForEach-Object { $_.Current.Name }) -join '|')"
  Require (($compositeBack[0].Current.BoundingRectangle.Width -gt 0) -and
           ($compositeBack[0].Current.BoundingRectangle.Height -gt 0)) "Composite Back breadcrumb has empty bounds"
  $compositeBack[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150
  $restoredProjectCards = @(Get-DirectChildren $graph $rawWalker | Where-Object {
      $_.Current.AutomationId -match '^canvas-card-' -and $_.Current.Name -match '^UIA loop '
    })
  Require (($restoredProjectCards.Count -eq 2) -and
           ((@($restoredProjectCards | ForEach-Object { $_.Current.Name }) -join "|") -eq "UIA loop A|UIA loop B")) `
    "Composite Back did not restore the parent project canvas"
  $surfaceActionPatterns = @{}
  foreach ($id in @($navigationIds + $canvasActionIds)) {
    $element = Find-FragmentById $root $id $rawWalker
    Require ($null -ne $element) "missing $id fragment"
    Require (($element.Current.BoundingRectangle.Width -gt 0) -and
             ($element.Current.BoundingRectangle.Height -gt 0)) "$id has empty bounds"
    $surfaceActionPatterns[$id] = $element.GetCurrentPattern(
      [System.Windows.Automation.InvokePattern]::Pattern)
  }
  $surfaceActionPatterns["overview-destination"].Invoke()
  Start-Sleep -Milliseconds 150
  $overviewCards = @(Get-DirectChildren $graph $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^canvas-card-' -and $_.Current.Name -match '^UIA loop '
  })
  Require (($overviewCards.Count -eq 2) -and
           ((@($overviewCards | ForEach-Object { $_.Current.Name }) -join "|") -eq "UIA loop A|UIA loop B")) "Overview did not expose synchronized cards"
  $surfaceActionPatterns["quick-chats-destination"].Invoke()
  Start-Sleep -Milliseconds 150
  $quickChatCards = @(Get-DirectChildren $graph $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^canvas-card-' -and $_.Current.Name -match '^UIA chat '
  })
  Require (($quickChatCards.Count -eq 2) -and
           ((@($quickChatCards | ForEach-Object { $_.Current.Name }) -join "|") -eq "UIA chat A|UIA chat B")) "Quick Chats did not expose synchronized cards: $(@($quickChatCards | ForEach-Object { $_.Current.Name }) -join '|')"
  $surfaceActionPatterns["canvas-primary-action"].Invoke()
  Start-Sleep -Milliseconds 150
  Require ((Find-FragmentById $root "status" $rawWalker).Current.Name -eq "Creating quick chat...") `
    "Populated Quick Chats canvas omitted its New Chat action"
  $quickChatRows = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^quick-chat-row-'
  })
  Require (($quickChatRows.Count -eq 2) -and
           ((@($quickChatRows | ForEach-Object { $_.Current.Name }) -join "|") -eq "UIA chat A|UIA chat B")) `
    "Quick Chats sidebar children were not exposed as stable rows"
  foreach ($chatRow in $quickChatRows) {
    $null = $chatRow.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  }
  $quickDisclosure = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^quick-chats-disclosure-'
  }) | Select-Object -First 1
  Require (($null -ne $quickDisclosure) -and
           ($quickDisclosure.Current.Name -eq "Collapse Quick Chats")) `
    "Quick Chats disclosure did not expose its expanded state"
  $firstQuickRowId = $quickChatRows[0].Current.AutomationId
  $quickDisclosure.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150
  Require (@(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^quick-chat-row-'
  }).Count -eq 0) "Quick Chats disclosure did not collapse child rows"
  $quickDisclosure = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^quick-chats-disclosure-'
  }) | Select-Object -First 1
  Require ($quickDisclosure.Current.Name -eq "Expand Quick Chats") `
    "Quick Chats disclosure state did not update after collapse"
  $quickDisclosure.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150
  $restoredQuickRows = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^quick-chat-row-'
  })
  Require (($restoredQuickRows.Count -eq 2) -and
           ($restoredQuickRows[0].Current.AutomationId -eq $firstQuickRowId)) `
    "Quick Chats expansion did not preserve stable child identity"
  $newChatAction = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^quick-chat-new-' -and $_.Current.Name -eq "New Chat"
  }) | Select-Object -First 1
  Require ($null -ne $newChatAction) "Quick Chats header omitted New Chat"
  $newChatAction.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150
  Require ((Find-FragmentById $root "status" $rawWalker).Current.Name -eq "Creating quick chat...") `
    "Quick Chats New Chat action did not execute"
  $quickChatCardIds = @($quickChatCards | ForEach-Object { $_.Current.AutomationId })
  $quickChatCards[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150
  Require ((Find-FragmentById $root "status" $rawWalker).Current.Name -eq "Opening quick chat...") `
    "Quick Chat invocation did not perform its expected action"
  $graph = Find-FragmentById $root "graph" $rawWalker
  $quickChatWorkspace = @(Get-DirectChildren $graph $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^quick-chat-workspace-' -and
    $_.Current.Name -eq "Quick Chat terminal workspace"
  }) | Select-Object -First 1
  Require ($null -ne $quickChatWorkspace) "Quick Chat invocation did not expose its terminal workspace"
  Require (($quickChatWorkspace.Current.BoundingRectangle.Width -gt 0) -and
           ($quickChatWorkspace.Current.BoundingRectangle.Height -gt 0)) `
    "Quick Chat terminal workspace has empty bounds"
  $surfaceActionPatterns["zoom-in"].Invoke()
  $surfaceActionPatterns["actual-size"].Invoke()
  $surfaceActionPatterns["zoom-out"].Invoke()
  $surfaceActionPatterns["fit-canvas"].Invoke()
  Start-Sleep -Milliseconds 250
  $process.Refresh()
  Require (-not $process.HasExited) "surface UIA actions terminated the shell"
  $activeProjectRow = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^open-project-' -and $_.Current.Name -eq "UIA project"
  }) | Select-Object -First 1
  $activeLoopRow = @(Get-DirectChildren $loops $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^loop-row-' -and $_.Current.Name -eq "UIA loop A"
  }) | Select-Object -First 1
  Require (($null -ne $activeProjectRow) -and ($null -ne $activeLoopRow)) `
    "sidebar rows were unavailable before dynamic invocation"
  $activeProjectRow.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  $activeLoopRow.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 250
  $process.Refresh()
  Require (-not $process.HasExited) "dynamic project or loop invocation terminated the shell"
  $workspaceCards = @(Get-DirectChildren $graph $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^canvas-card-' -and $_.Current.Name -match '^UIA loop '
  })
  Require (($workspaceCards.Count -eq 2) -and
           ((@($workspaceCards | ForEach-Object { $_.Current.Name }) -join "|") -eq "UIA loop A|UIA loop B") -and
           $workspaceCards[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected) `
    "loop invocation did not transition to the selected workspace loop"
  $workspaceToolbar = $null
  $workspaceShowGraph = $null
  $workspaceTabs = @()
  $workspaceControls = @()
  $workspacePanelToggle = $null
  $workspaceSparkline = $null
  $workspaceStart = $null
  $workspaceUsage = $null
  for ($attempt = 0; $attempt -lt 100; $attempt++) {
    $workspaceChildren = @(Get-DirectChildren $graph $rawWalker)
    $workspaceToolbar = @($workspaceChildren | Where-Object {
      $_.Current.AutomationId -match '^workspace-toolbar-' -and $_.Current.Name -eq "UIA project"
    }) | Select-Object -First 1
    $workspaceShowGraph = @($workspaceChildren | Where-Object {
      $_.Current.AutomationId -match '^workspace-show-graph-' -and $_.Current.Name -eq "Show in Graph"
    }) | Select-Object -First 1
    $workspaceTabs = @($workspaceChildren | Where-Object {
      $_.Current.AutomationId -match '^workspace-tab-' -and $_.Current.Name -match 'tab$'
    })
    $workspaceControls = @($workspaceChildren | Where-Object {
      $_.Current.AutomationId -match '^workspace-(new-tab|split-right|split-down)-' -and
        $_.Current.Name -in @("New Tab", "Split Right", "Split Down")
    })
    $workspacePanelToggle = @($workspaceChildren | Where-Object {
      $_.Current.AutomationId -match '^workspace-toggle-panel-' -and $_.Current.Name -eq "Collapse loop panel"
    }) | Select-Object -First 1
    $workspaceSparkline = @($workspaceChildren | Where-Object {
      $_.Current.AutomationId -match '^workspace-detail-sparkline-' -and $_.Current.Name -eq "Metric sparkline"
    }) | Select-Object -First 1
    $workspaceStart = @($workspaceChildren | Where-Object {
      $_.Current.AutomationId -match '^workspace-detail-start-' -and $_.Current.Name -eq "Start time"
    }) | Select-Object -First 1
    $workspaceUsage = @($workspaceChildren | Where-Object {
      $_.Current.AutomationId -match '^workspace-detail-usage-' -and $_.Current.Name -match 'tokens$'
    }) | Select-Object -First 1
    if (($null -ne $workspaceToolbar) -and ($null -ne $workspaceShowGraph) -and
        ($workspaceTabs.Count -ge 1) -and ($workspaceControls.Count -eq 3) -and
        ($null -ne $workspacePanelToggle) -and ($null -ne $workspaceSparkline) -and
        ($null -ne $workspaceStart) -and ($null -ne $workspaceUsage)) {
      break
    }
    Start-Sleep -Milliseconds 100
  }
  Require ($null -ne $workspaceToolbar) `
    "workspace chrome omitted the toolbar identity child"
  Require ($null -ne $workspaceShowGraph) `
    "workspace chrome omitted the Show in Graph child"
  Require ($workspaceControls.Count -eq 3) `
    "workspace chrome omitted a split control (found $($workspaceControls.Count) of 3: $(@($workspaceControls | ForEach-Object { $_.Current.Name }) -join '|'))"
  Require ($workspaceTabs.Count -ge 1) `
    "workspace chrome exposed no tab children; found $(@($workspaceChildren | ForEach-Object { $_.Current.AutomationId }) -join '|')"
  Require ($null -ne $workspacePanelToggle) "workspace right panel omitted collapse control"
  Require ($null -ne $workspaceSparkline) "workspace right panel omitted metric sparkline child"
  Require ($null -ne $workspaceStart) "workspace right panel omitted start-time child"
  Require ($null -ne $workspaceUsage) "workspace right panel omitted token-usage child"
  foreach ($detailChild in @($workspacePanelToggle, $workspaceSparkline, $workspaceStart, $workspaceUsage)) {
    Require (($detailChild.Current.BoundingRectangle.Width -gt 0) -and
             ($detailChild.Current.BoundingRectangle.Height -gt 0)) `
      "workspace right panel child $($detailChild.Current.AutomationId) has empty bounds"
  }
  $workspacePanelToggle.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150
  $workspaceChildren = @(Get-DirectChildren $graph $rawWalker)
  $workspacePanelToggle = @($workspaceChildren | Where-Object {
    $_.Current.AutomationId -match '^workspace-toggle-panel-' -and $_.Current.Name -eq "Expand loop panel"
  }) | Select-Object -First 1
  Require ($null -ne $workspacePanelToggle) "workspace right panel did not expose expand control after collapse"
  $workspacePanelToggle.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150
  $workspaceChildren = @(Get-DirectChildren $graph $rawWalker)
  $workspaceTabs = @($workspaceChildren | Where-Object {
    $_.Current.AutomationId -match '^workspace-tab-' -and $_.Current.Name -match 'tab$'
  })
  $initialWorkspaceTabId = $workspaceTabs[0].Current.AutomationId
  $newTab = @($workspaceChildren | Where-Object {
    $_.Current.AutomationId -match '^workspace-new-tab-' -and $_.Current.Name -eq "New Tab"
  }) | Select-Object -First 1
  Require ($null -ne $newTab) "workspace omitted New Tab before mounted-tab preservation check"
  $newTab.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  for ($attempt = 0; $attempt -lt 60; $attempt++) {
    Start-Sleep -Milliseconds 100
    $workspaceChildren = @(Get-DirectChildren $graph $rawWalker)
    $workspaceTabs = @($workspaceChildren | Where-Object {
      $_.Current.AutomationId -match '^workspace-tab-' -and $_.Current.Name -match 'tab$'
    })
    if ($workspaceTabs.Count -ge 2) { break }
  }
  Require ($workspaceTabs.Count -ge 2) "New Tab did not expose a mounted background tab"
  $newWorkspaceTabId = $workspaceTabs[1].Current.AutomationId
  $workspaceTabs[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150
  $workspaceTabs = @(Get-DirectChildren $graph $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^workspace-tab-' -and $_.Current.Name -match 'tab$'
  })
  Require (($workspaceTabs[0].Current.AutomationId -eq $initialWorkspaceTabId) -and
           ($workspaceTabs[1].Current.AutomationId -eq $newWorkspaceTabId)) `
    "switching to the mounted background tab changed terminal tab identity"
  $workspaceTabs[1].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150
  $workspaceTabs = @(Get-DirectChildren $graph $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^workspace-tab-' -and $_.Current.Name -match 'tab$'
  })
  Require (($workspaceTabs[0].Current.AutomationId -eq $initialWorkspaceTabId) -and
           ($workspaceTabs[1].Current.AutomationId -eq $newWorkspaceTabId)) `
    "switching back from the mounted background tab changed terminal tab identity"
  $surfaceActionPatterns["overview-destination"].Invoke()
  Start-Sleep -Milliseconds 150
  Require ([GraphCodeUiaGateState]::PostTaggedExitCollision($process.MainWindowHandle)) `
    "tagged command collision message was rejected"
  Start-Sleep -Milliseconds 150
  $process.Refresh()
  Require (-not $process.HasExited) "tagged UIA payload fell through to the Exit menu command"

  $worktrees = Find-FragmentById $root "worktrees" $rawWalker
  Require ($null -ne $worktrees) "missing Worktrees fragment"
  $initialRowIds = @()
  for ($attempt = 0; $attempt -lt 50; $attempt++) {
    $initialRowIds = @(Get-DirectChildren $worktrees $rawWalker |
      ForEach-Object { $_.Current.AutomationId } |
      Where-Object { $_ })
    if ($initialRowIds.Count -eq 2) { break }
    Start-Sleep -Milliseconds 100
  }
  Require (($initialRowIds.Count -eq 2) -and
           ($initialRowIds | ForEach-Object { $_ -match '^worktree-row-[0-9]+$' } | Where-Object { -not $_ }).Count -eq 0) `
    "Worktrees did not expose two stable dynamic row IDs: $($initialRowIds -join ','); status=$((Find-FragmentById $root 'status' $rawWalker).Current.Name)"
  $rawRows = @(Assert-FragmentLinks $worktrees $rawWalker $initialRowIds "RawView Worktrees")
  $controlRows = @(Assert-FragmentLinks $worktrees $controlWalker $initialRowIds "ControlView Worktrees")
  Require ((@($rawRows | ForEach-Object { $_.Current.Name }) -join "|") -eq
           "C:\fixture-safe|C:\fixture-unsafe") "fixture worktree names were not ordered as expected"

  $selection = $worktrees.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
  $safeRow = @($rawRows | Where-Object { $_.Current.Name -eq "C:\fixture-safe" })[0]
  $unsafeRow = @($rawRows | Where-Object { $_.Current.Name -eq "C:\fixture-unsafe" })[0]
  $safeFocusRow = @($controlRows | Where-Object { $_.Current.Name -eq "C:\fixture-safe" })[0]
  Require (($null -ne $safeRow) -and ($null -ne $unsafeRow) -and ($null -ne $safeFocusRow)) "missing fixture worktree rows"
  $safeRowId = $safeRow.Current.AutomationId
  $safeRowRuntimeId = Get-RuntimeIdentity $safeRow
  $safeSelection = $safeRow.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
  $unsafeSelection = $unsafeRow.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
  [GraphCodeUiaGateState]::SelectedEvents = 0
  [GraphCodeUiaGateState]::AddedEvents = 0
  [GraphCodeUiaGateState]::RemovedEvents = 0
  [GraphCodeUiaGateState]::SelectionSourceAutomationId = $null
  $selectedEvent = [System.Windows.Automation.SelectionItemPattern]::ElementSelectedEvent
  $addedEvent = [System.Windows.Automation.SelectionItemPattern]::ElementAddedToSelectionEvent
  $removedEvent = [System.Windows.Automation.SelectionItemPattern]::ElementRemovedFromSelectionEvent
  $selectedHandler = [GraphCodeUiaGateState]::SelectedHandler
  $addedHandler = [GraphCodeUiaGateState]::AddedHandler
  $removedHandler = [GraphCodeUiaGateState]::RemovedHandler
  [System.Windows.Automation.Automation]::AddAutomationEventHandler(
    $selectedEvent, $safeRow, [System.Windows.Automation.TreeScope]::Element, $selectedHandler
  )
  [System.Windows.Automation.Automation]::AddAutomationEventHandler(
    $addedEvent, $safeRow, [System.Windows.Automation.TreeScope]::Element, $addedHandler
  )
  [System.Windows.Automation.Automation]::AddAutomationEventHandler(
    $removedEvent, $safeRow, [System.Windows.Automation.TreeScope]::Element, $removedHandler
  )
  try {
    $safeSelection.Select()
    for ($index = 0; $index -lt 20 -and [GraphCodeUiaGateState]::SelectedEvents -lt 1; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require (($safeSelection.Current.IsSelected) -and
             ([GraphCodeUiaGateState]::SelectedEvents -eq 1)) "Select did not raise ElementSelected exactly once"
    $safeSelection.Select()
    Start-Sleep -Milliseconds 150
    Require ([GraphCodeUiaGateState]::SelectedEvents -eq 1) "idempotent Select raised a duplicate event"
    $unsafeRejected = $false
    try { $unsafeSelection.Select() } catch { $unsafeRejected = $true }
    Require $unsafeRejected "unsafe SelectionItem.Select was accepted"
    $safeSelection.RemoveFromSelection()
    for ($index = 0; $index -lt 20 -and [GraphCodeUiaGateState]::RemovedEvents -lt 1; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require (($selection.Current.GetSelection().Count -eq 0) -and
             ([GraphCodeUiaGateState]::RemovedEvents -eq 1)) "RemoveFromSelection did not raise ElementRemovedFromSelection"
    $safeSelection.RemoveFromSelection()
    Start-Sleep -Milliseconds 150
    Require ([GraphCodeUiaGateState]::RemovedEvents -eq 1) "idempotent RemoveFromSelection raised a duplicate event"
    $safeSelection.AddToSelection()
    for ($index = 0; $index -lt 20 -and [GraphCodeUiaGateState]::AddedEvents -lt 1; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require ([GraphCodeUiaGateState]::AddedEvents -eq 1) "AddToSelection did not raise ElementAddedToSelection"
    $safeSelection.AddToSelection()
    Start-Sleep -Milliseconds 150
    Require ([GraphCodeUiaGateState]::AddedEvents -eq 1) "idempotent AddToSelection raised a duplicate event"
    $safeSelection.RemoveFromSelection()
    for ($index = 0; $index -lt 20 -and [GraphCodeUiaGateState]::RemovedEvents -lt 2; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require ([GraphCodeUiaGateState]::RemovedEvents -eq 2) "second RemoveFromSelection did not raise an event"
    Require ([GraphCodeUiaGateState]::PostKeyboard($process.MainWindowHandle, 0x28)) "keyboard selection message was rejected"
    for ($index = 0; $index -lt 20 -and [GraphCodeUiaGateState]::SelectedEvents -lt 2; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require ([GraphCodeUiaGateState]::SelectedEvents -eq 2) "App keyboard selection did not raise ElementSelected"
    Require ([GraphCodeUiaGateState]::PostMouseClick($process.MainWindowHandle)) "mouse selection message was rejected"
    for ($index = 0; $index -lt 20 -and [GraphCodeUiaGateState]::RemovedEvents -lt 3; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require ([GraphCodeUiaGateState]::RemovedEvents -eq 3) "App mouse selection did not raise ElementRemovedFromSelection"
    Require ([GraphCodeUiaGateState]::SelectionSourceAutomationId -eq $safeRowId) "selection event source identity changed"
  } finally {
    [System.Windows.Automation.Automation]::RemoveAutomationEventHandler($selectedEvent, $safeRow, $selectedHandler)
    [System.Windows.Automation.Automation]::RemoveAutomationEventHandler($addedEvent, $safeRow, $addedHandler)
    [System.Windows.Automation.Automation]::RemoveAutomationEventHandler($removedEvent, $safeRow, $removedHandler)
  }
  $selectionEventEvidence = @{
    selected = [GraphCodeUiaGateState]::SelectedEvents
    added = [GraphCodeUiaGateState]::AddedEvents
    removed = [GraphCodeUiaGateState]::RemovedEvents
    source = [GraphCodeUiaGateState]::SelectionSourceAutomationId
  }

  $actions = @{}
  foreach ($actionId in @("inspect-worktrees", "reclaim-worktrees", "reveal-worktree",
                          "edit-worktree-policy", "save-worktree-policy",
                          "allow-reclaim", "confirm-each-reclaim")) {
    $action = Find-FragmentById $root $actionId $rawWalker
    Require ($null -ne $action) "missing action $actionId"
    $actions[$actionId] = $action.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  }
  $allowReclaim = Find-FragmentById $root "allow-reclaim" $controlWalker
  $confirmReclaim = Find-FragmentById $root "confirm-each-reclaim" $controlWalker
  Require (($null -ne $allowReclaim) -and ($null -ne $confirmReclaim)) "missing worktree policy toggles"
  $allowToggle = $allowReclaim.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
  $confirmToggle = $confirmReclaim.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
  [GraphCodeUiaGateState]::TogglePropertyEvents = 0
  [GraphCodeUiaGateState]::TogglePropertySourceAutomationId = $null
  $togglePropertyHandler = [GraphCodeUiaGateState]::TogglePropertyHandler
  [System.Windows.Automation.Automation]::AddAutomationPropertyChangedEventHandler(
    $allowReclaim, [System.Windows.Automation.TreeScope]::Element, $togglePropertyHandler,
    [System.Windows.Automation.TogglePattern]::ToggleStateProperty
  )
  [System.Windows.Automation.Automation]::AddAutomationPropertyChangedEventHandler(
    $confirmReclaim, [System.Windows.Automation.TreeScope]::Element, $togglePropertyHandler,
    [System.Windows.Automation.TogglePattern]::ToggleStateProperty
  )
  try {
    $allowToggle.Toggle()
    for ($index = 0; $index -lt 20 -and [GraphCodeUiaGateState]::TogglePropertyEvents -lt 1; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require (([GraphCodeUiaGateState]::TogglePropertyEvents -eq 1) -and
             ([GraphCodeUiaGateState]::TogglePropertySourceAutomationId -eq "allow-reclaim")) "allow reclaim did not raise ToggleState property change"
    $confirmToggle.Toggle()
    for ($index = 0; $index -lt 20 -and [GraphCodeUiaGateState]::TogglePropertyEvents -lt 2; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require (([GraphCodeUiaGateState]::TogglePropertyEvents -eq 2) -and
             ([GraphCodeUiaGateState]::TogglePropertySourceAutomationId -eq "confirm-each-reclaim")) "confirm reclaim did not raise ToggleState property change"
  } finally {
    [System.Windows.Automation.Automation]::RemoveAutomationPropertyChangedEventHandler(
      $allowReclaim, $togglePropertyHandler
    )
    [System.Windows.Automation.Automation]::RemoveAutomationPropertyChangedEventHandler(
      $confirmReclaim, $togglePropertyHandler
    )
  }

  $status = Find-FragmentById $root "status" $controlWalker
  Require ($null -ne $status) "missing status element"
  $initialStatus = $status.Current.Name
  $statusRuntimeId = Get-RuntimeIdentity $status
  [GraphCodeUiaGateState]::LiveObserved = $false
  [GraphCodeUiaGateState]::NamePropertyObserved = $false
  [GraphCodeUiaGateState]::LiveEvents = 0
  [GraphCodeUiaGateState]::NamePropertyEvents = 0
  [GraphCodeUiaGateState]::LiveSourceAutomationId = $null
  [GraphCodeUiaGateState]::LiveSourceName = $null
  [GraphCodeUiaGateState]::LiveSourceRuntimeId = $null
  [GraphCodeUiaGateState]::NamePropertySourceAutomationId = $null
  [GraphCodeUiaGateState]::FocusObserved = $false
  [GraphCodeUiaGateState]::FocusSourceAutomationId = $null
  $eventHandler = [GraphCodeUiaGateState]::LiveHandler
  $liveRegionEvent = [System.Windows.Automation.AutomationEvent]::LookupById(20024)
  $propertyHandler = [GraphCodeUiaGateState]::NamePropertyHandler
  $focusHandler = [GraphCodeUiaGateState]::FocusHandler
  [System.Windows.Automation.Automation]::AddAutomationEventHandler(
    $liveRegionEvent, $status, [System.Windows.Automation.TreeScope]::Element, $eventHandler
  )
  $liveEventRegistered = $true
  [System.Windows.Automation.Automation]::AddAutomationPropertyChangedEventHandler(
    $status, [System.Windows.Automation.TreeScope]::Element, $propertyHandler,
    [System.Windows.Automation.AutomationElement]::NameProperty
  )
  $propertyEventRegistered = $true
  [System.Windows.Automation.Automation]::AddAutomationFocusChangedEventHandler($focusHandler)
  $focusEventRegistered = $true
  try {
    Require ([GraphCodeUiaGateState]::PostKeyboard($process.MainWindowHandle, 0x28)) "negative keyboard selection message was rejected"
    Start-Sleep -Milliseconds 150
    Require ([GraphCodeUiaGateState]::PostMouseClick($process.MainWindowHandle)) "negative mouse selection message was rejected"
    Start-Sleep -Milliseconds 150

    Require ([GraphCodeUiaGateState]::PostFixtureMutation($process.MainWindowHandle, 1)) "negative fixture reorder message was rejected"
    Start-Sleep -Milliseconds 150
    Assert-Ids @((Get-DirectChildren $worktrees $rawWalker | ForEach-Object { $_.Current.AutomationId })) `
      @($initialRowIds[1], $initialRowIds[0]) "negative reordered Worktrees"
    Require ([GraphCodeUiaGateState]::PostFixtureMutation($process.MainWindowHandle, 1)) "fixture reorder restore message was rejected"
    Start-Sleep -Milliseconds 150
    Assert-Ids @((Get-DirectChildren $worktrees $rawWalker | ForEach-Object { $_.Current.AutomationId })) `
      $initialRowIds "restored Worktrees"

    Require ([GraphCodeUiaGateState]::PostFixtureMutation($process.MainWindowHandle, 3)) "eligibility mutation message was rejected"
    Start-Sleep -Milliseconds 150
    $unsafeSelection.Select()
    Start-Sleep -Milliseconds 150
    Require $unsafeSelection.Current.IsSelected "eligibility-only sync did not make the fixture row selectable"

    $allowStateBefore = $allowToggle.Current.ToggleState
    Require ([GraphCodeUiaGateState]::PostFixtureMutation($process.MainWindowHandle, 4)) "allow policy sync message was rejected"
    for ($index = 0; $index -lt 20 -and $allowToggle.Current.ToggleState -eq $allowStateBefore; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require ($allowToggle.Current.ToggleState -ne $allowStateBefore) "allow policy-only sync was not observed"
    $confirmStateBefore = $confirmToggle.Current.ToggleState
    Require ([GraphCodeUiaGateState]::PostFixtureMutation($process.MainWindowHandle, 5)) "confirm policy sync message was rejected"
    for ($index = 0; $index -lt 20 -and $confirmToggle.Current.ToggleState -eq $confirmStateBefore; $index++) {
      Start-Sleep -Milliseconds 50
    }
    Require ($confirmToggle.Current.ToggleState -ne $confirmStateBefore) "confirm policy-only sync was not observed"

    Start-Sleep -Milliseconds 250
    $statusNoChangeLiveEvents = [GraphCodeUiaGateState]::LiveEvents
    $statusNoChangeNameEvents = [GraphCodeUiaGateState]::NamePropertyEvents
    Require ($status.Current.Name -eq $initialStatus) "non-status sync changed status text from '$initialStatus' to '$($status.Current.Name)'"
    Require ($statusNoChangeLiveEvents -eq 0) "non-status sync raised LiveRegionChanged"
    Require ($statusNoChangeNameEvents -eq 0) "non-status sync raised a status Name property change"

    $actions["save-worktree-policy"].Invoke()
    for ($i = 0; $i -lt 40 -and [GraphCodeUiaGateState]::LiveEvents -lt 1; $i++) {
      Start-Sleep -Milliseconds 50
    }
  } finally {
    if ($propertyEventRegistered) {
      [System.Windows.Automation.Automation]::RemoveAutomationPropertyChangedEventHandler(
        $status, $propertyHandler
      )
      $propertyEventRegistered = $false
    }
    if ($liveEventRegistered) {
      [System.Windows.Automation.Automation]::RemoveAutomationEventHandler(
        $liveRegionEvent, $status, $eventHandler
      )
      $liveEventRegistered = $false
    }
  }

  $statusAfter = Find-FragmentById $root "status" $controlWalker
  $statusTextAfter = [string]$statusAfter.Current.Name
  $statusEventObserved = [GraphCodeUiaGateState]::LiveObserved
  Require $statusEventObserved "LiveRegionChanged was not delivered for status"
  Require ([GraphCodeUiaGateState]::LiveEvents -eq 1) "status change did not raise exactly one LiveRegionChanged event"
  Require ([GraphCodeUiaGateState]::LiveSourceAutomationId -eq "status") "LiveRegionChanged source was not status"
  Require ([GraphCodeUiaGateState]::LiveSourceRuntimeId -eq $statusRuntimeId) "LiveRegionChanged source identity changed"
  Require ([GraphCodeUiaGateState]::NamePropertyObserved) "status Name property change was not delivered"
  Require ([GraphCodeUiaGateState]::NamePropertyEvents -eq 1) "status change did not raise exactly one Name property change"
  Require ([GraphCodeUiaGateState]::NamePropertySourceAutomationId -eq "status") "status Name property source was not status"
  Require (($statusTextAfter -ne $initialStatus) -and
           ([GraphCodeUiaGateState]::LiveSourceName -eq $statusTextAfter)) "status LiveRegionChanged did not expose updated text"

  $currentRowsBeforeFocus = @(Get-DirectChildren $worktrees $rawWalker)
  $currentSafe = @($currentRowsBeforeFocus | Where-Object { $_.Current.Name -eq "C:\fixture-safe" })[0]
  Require ($null -ne $currentSafe) "safe worktree row disappeared before focus: $(@($currentRowsBeforeFocus | ForEach-Object { $_.Current.AutomationId }) -join ',')"
  Require ($currentSafe.Current.AutomationId -eq $safeRowId) "safe worktree identity changed before focus: $safeRowId -> $($currentSafe.Current.AutomationId)"
  Require ($safeFocusRow.Current.Name -eq "C:\fixture-safe") "safe worktree provider became unavailable before focus"
  $focusResult = Retain-FocusWithRetry $shellWindow $safeFocusRow $safeRowId "before-retention"
  $focused = $focusResult.Focused
  Require ($null -ne $focused) "worktree row could not retain focus against concurrent desktop focus changes; focused=$(Format-AutomationElement $focusResult.Candidate); $(Get-FocusDiagnostics $shellWindow)"
  Require ($focused.Current.AutomationId -eq $safeRowId) "focus source identity was '$($focused.Current.AutomationId)', expected '$safeRowId'"
  Require ((Get-RuntimeIdentity $focused) -eq (Get-RuntimeIdentity $safeFocusRow)) "focus runtime identity changed"
  for ($index = 0; $index -lt 20 -and -not [GraphCodeUiaGateState]::FocusObserved; $index++) {
    Start-Sleep -Milliseconds 50
  }
  Require ([GraphCodeUiaGateState]::FocusObserved) "FocusChanged was not delivered"
  Require ([GraphCodeUiaGateState]::FocusSourceAutomationId -eq $safeRowId) "FocusChanged source identity changed"
  $initialFocusSource = [GraphCodeUiaGateState]::FocusSourceAutomationId

  $stressJob = Start-Job -ArgumentList ([int64]$process.MainWindowHandle) -ScriptBlock {
    param([int64] $window)
    $ErrorActionPreference = "Stop"
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $element = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$window)
    for ($index = 0; $index -lt 100; $index++) {
      $null = $element.Current.Name
      Start-Sleep -Milliseconds 5
    }
  }
  Require ([GraphCodeUiaGateState]::PostFixtureMutation($process.MainWindowHandle, 1)) "fixture reorder message was rejected"
  Start-Sleep -Milliseconds 150
  $reorderedRows = @(Get-DirectChildren $worktrees $rawWalker)
  $reorderedRowIds = @($reorderedRows | ForEach-Object { $_.Current.AutomationId })
  Assert-Ids $reorderedRowIds @($initialRowIds[1], $initialRowIds[0]) "reordered Worktrees"
  $reorderedSafe = Find-FragmentById $root $safeRowId $rawWalker
  Require (($null -ne $reorderedSafe) -and
           ((Get-RuntimeIdentity $reorderedSafe) -eq $safeRowRuntimeId)) "reordered safe row lost its identity"
  Require ($rawWalker.GetParent($reorderedSafe).Current.AutomationId -eq "worktrees") "reordered safe row lost its parent"

  Require ([GraphCodeUiaGateState]::PostFixtureMutation($process.MainWindowHandle, 2)) "fixture removal message was rejected"
  Start-Sleep -Milliseconds 150
  $null = Wait-Job -Job $stressJob -Timeout 10
  $stressErrors = @()
  Receive-Job -Job $stressJob -ErrorAction SilentlyContinue -ErrorVariable +stressErrors | Out-Null
  Require ($stressJob.State -eq "Completed") "UIA read stress did not finish: $($stressJob.State) $($stressErrors -join '; ')"
  Remove-Job -Job $stressJob -Force
  $remainingRows = @(Get-DirectChildren $worktrees $rawWalker)
  $remainingRowIds = @($remainingRows | ForEach-Object { $_.Current.AutomationId })
  Assert-Ids $remainingRowIds @($unsafeRow.Current.AutomationId) "removed Worktrees"
  $removedProviderUnavailable = $false
  try {
    $null = $safeRow.GetCurrentPropertyValue([System.Windows.Automation.AutomationElement]::NameProperty)
  } catch [System.Windows.Automation.ElementNotAvailableException] {
    $removedProviderUnavailable = $true
  }
  Require $removedProviderUnavailable "removed worktree provider remained available"
  for ($index = 0; $index -lt 20 -and
       [GraphCodeUiaGateState]::FocusSourceAutomationId -ne "graphcode-root"; $index++) {
    Start-Sleep -Milliseconds 50
  }
  Require ([GraphCodeUiaGateState]::FocusSourceAutomationId -eq "graphcode-root") "removed focus did not fall back to the root"
  [System.Windows.Automation.Automation]::RemoveAutomationFocusChangedEventHandler($focusHandler)
  $focusEventRegistered = $false

  $rootName = $root.Current.Name
  $rootAutomationId = $root.Current.AutomationId
  $rootControlType = $root.Current.ControlType.ProgrammaticName
  $rawRootChildIds = @($rawRootChildren | ForEach-Object { $_.Current.AutomationId })
  $controlRootChildIds = @($controlRootChildren | ForEach-Object { $_.Current.AutomationId })
  $rawWorktreeRowIds = $initialRowIds
  $controlWorktreeRowIds = $initialRowIds
  $focusIdentity = $safeRowId


  $shellWindow = $process.MainWindowHandle
  Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 7)) "Rename Loop fixture command was rejected"
  $renameDialog = $null
  $desktop = [System.Windows.Automation.AutomationElement]::RootElement
  $renameWindowCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Rename Loop"
    )),
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Window
    ))
  )
  $renameCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id
    )),
    $renameWindowCondition
  )
  for ($index = 0; $index -lt 40 -and $null -eq $renameDialog; $index++) {
    Start-Sleep -Milliseconds 50
    $renameDialog = $desktop.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $renameCondition
    )
  }
  Require ($null -ne $renameDialog) "Rename Loop command did not open its native dialog"
  $renameElements = @($renameDialog.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  ))
  $renameContent = @($renameElements | ForEach-Object { $_.Current.Name }) -join "`n"
  Require ($renameContent -match "Choose the title shown") "Rename Loop dialog omitted its explanation"
  Require ($renameContent -match "(?m)^Title$") "Rename Loop dialog omitted its Title field label"
  Require ($renameContent -match "UIA loop A") "Rename Loop dialog did not populate the current title"
  Require ([GraphCodeUiaGateState]::SetFirstEditText(
    [IntPtr]$renameDialog.Current.NativeWindowHandle, "UIA renamed loop"
  )) "Rename Loop dialog omitted its native editable title field"
  Require ([GraphCodeUiaGateState]::SendReturn(
    [IntPtr]$renameDialog.Current.NativeWindowHandle
  )) "Rename Loop dialog rejected Return"
  for ($index = 0; $index -lt 40; $index++) {
    Start-Sleep -Milliseconds 50
    $remainingRename = $desktop.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $renameCondition
    )
    if ($null -eq $remainingRename) { break }
  }
  Require ($null -eq $remainingRename) "Return did not submit and close the Rename Loop dialog"

  Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 14)) `
    "jump palette fixture command was rejected"
  $jumpPalette = $null
  $jumpPaletteCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id
    )),
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Jump to loop"
    ))
  )
  for ($index = 0; $index -lt 40 -and $null -eq $jumpPalette; $index++) {
    Start-Sleep -Milliseconds 50
    $jumpPalette = $desktop.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $jumpPaletteCondition
    )
  }
  Require ($null -ne $jumpPalette) "jump command did not open the native palette"
  $jumpSearch = $jumpPalette.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ClassNameProperty, "Edit"
    ))
  )
  $jumpSearchLabel = $jumpPalette.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Search loops"
    ))
  )
  Require (($null -ne $jumpSearch) -and ($null -ne $jumpSearchLabel)) `
    "jump palette did not expose its visible search field"
  Require (($jumpSearch.Current.BoundingRectangle.Width -gt 0) -and
           ($jumpSearch.Current.BoundingRectangle.Height -gt 0)) `
    "jump palette search field had empty bounds"
  $jumpList = $jumpPalette.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ClassNameProperty, "ListBox"
    ))
  )
  Require (($null -ne $jumpList) -and
           ($jumpList.Current.BoundingRectangle.Width -gt 0) -and
           ($jumpList.Current.BoundingRectangle.Height -gt 0)) `
    "jump palette did not expose its visible ranked result list"
  $jumpListHandle = [GraphCodeUiaGateState]::FindChild(
    [IntPtr]$jumpPalette.Current.NativeWindowHandle, "ListBox"
  )
  $jumpNames = @([GraphCodeUiaGateState]::GetListItems($jumpListHandle))
  Require ($jumpNames.Count -ge 2) "jump palette did not expose at least two ranked results"
  Require (($jumpNames -match 'UIA loop A.*UIA project.*Goal.*succeeded').Count -ge 1) `
    "jump palette omitted project, loop type, or state context for UIA loop A"
  Require (($jumpNames -match 'UIA loop C.*Jump fixture.*Timed.*awaitingInput').Count -ge 1) `
    "jump palette did not expose a contextual cross-project result"
  $jumpWindow = [IntPtr]$jumpPalette.Current.NativeWindowHandle
  Require ([GraphCodeUiaGateState]::SetFirstEditText($jumpWindow, "UIA loop B")) `
    "jump palette rejected live query input"
  Require ([GraphCodeUiaGateState]::PostPaletteRefresh($jumpWindow)) `
    "jump palette rejected deterministic live-filter refresh"
  Start-Sleep -Milliseconds 100
  $filteredJumpNames = @([GraphCodeUiaGateState]::GetListItems($jumpListHandle))
  Require (($filteredJumpNames.Count -eq 1) -and
           ($filteredJumpNames[0] -match 'UIA loop B.*UIA project.*Proactive.*running')) `
    "jump palette did not live-filter to the ranked keyboard destination ($($filteredJumpNames -join '|'))"
  Require ([GraphCodeUiaGateState]::PostKeyboard($jumpWindow, 0x0D)) `
    "jump palette rejected Return activation"
  for ($index = 0; $index -lt 40; $index++) {
    Start-Sleep -Milliseconds 50
    $remainingJump = $desktop.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $jumpPaletteCondition
    )
    if ($null -eq $remainingJump) { break }
  }
  Require ($null -eq $remainingJump) "Return did not activate and close the jump palette"
  $loopsAfterJump = Find-FragmentById $root "loops" $rawWalker
  $loopBAfterJump = @(Get-DirectChildren $loopsAfterJump $rawWalker |
    Where-Object { $_.Current.Name -eq "UIA loop B" }) | Select-Object -First 1
  Require ($null -ne $loopBAfterJump) "jump navigation did not retain the destination loop row"
  $selectedAfterJump = $loopBAfterJump.GetCurrentPattern(
    [System.Windows.Automation.SelectionItemPattern]::Pattern
  ).Current.IsSelected
  Require $selectedAfterJump "jump palette activation did not navigate to UIA loop B"

  Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 8)) "inline ingress-error fixture command was rejected"
  $inlineError = $null
  $inlineErrorCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::NameProperty, "Folder could not be opened"
  )
  for ($index = 0; $index -lt 40 -and $null -eq $inlineError; $index++) {
    Start-Sleep -Milliseconds 50
    $inlineError = $root.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $inlineErrorCondition
    )
  }
  Require ($null -ne $inlineError) "canvas did not expose the scoped ingress error"
  Require (($inlineError.Current.BoundingRectangle.Width -gt 0) -and
           ($inlineError.Current.BoundingRectangle.Height -gt 0)) `
    "inline ingress error had empty canvas bounds"

  Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 9)) "empty overview fixture command was rejected"
  Start-Sleep -Milliseconds 200
  $openFolderButton = Find-FragmentById $root "4601" $rawWalker
  $emptyOverviewLoopButton = Find-FragmentById $root "4602" $rawWalker
  Require (($null -ne $openFolderButton) -and ($openFolderButton.Current.Name -eq "Open Folder...")) `
    "empty global graph omitted its Open Folder action"
  Require (($null -ne $emptyOverviewLoopButton) -and ($emptyOverviewLoopButton.Current.Name -eq "New Loop")) `
    "empty global graph omitted its New Loop action"
  Require ((-not $openFolderButton.Current.IsOffscreen) -and
           (-not $emptyOverviewLoopButton.Current.IsOffscreen)) `
    "empty global graph actions were not visible"
  Require ([GraphCodeUiaGateState]::PostCommand($shellWindow, 4601)) `
    "empty global Open Folder command was rejected"
  $folderPicker = $null
  $folderPickerWindowCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty,
      "Open GraphCode folder or Git repository"
    )),
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Window
    ))
  )
  $folderPickerCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id
    )),
    $folderPickerWindowCondition
  )
  $folderPicker = Wait-ForDesktopElement `
    -desktop $desktop `
    -condition $folderPickerCondition `
    -label "Open Folder picker" `
    -diagnosticWindow $shellWindow
  Require ($null -ne $folderPicker) "Open Folder did not launch the native folder picker"
  Require ([GraphCodeUiaGateState]::PostClose(
    [IntPtr]$folderPicker.Current.NativeWindowHandle
  )) "native folder picker rejected cancellation"
  Require (Wait-ForDesktopElementGone `
    -desktop $desktop `
    -condition $folderPickerCondition `
    -label "Open Folder picker close" `
    -diagnosticWindow $shellWindow) "native folder picker did not close after cancellation"

  Require (Ensure-ShellForeground $shellWindow "empty global New Loop") `
    "GraphCode shell did not reacquire foreground before empty global New Loop command"
  Require ([GraphCodeUiaGateState]::PostCommand($shellWindow, 4602)) `
    "empty global New Loop command was rejected"
  $nodeForm = $null
  $nodeFormWindowCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Create or edit node"
    )),
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Window
    ))
  )
  $nodeFormCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id
    )),
    $nodeFormWindowCondition
  )
  $nodeForm = Wait-ForDesktopElement `
    -desktop $desktop `
    -condition $nodeFormCondition `
    -label "empty global New Loop node form" `
    -diagnosticWindow $shellWindow `
    -RecoverForeground
  Require ($null -ne $nodeForm) "empty global New Loop did not open the node form"
  Require ([GraphCodeUiaGateState]::PostClose(
    [IntPtr]$nodeForm.Current.NativeWindowHandle
  )) "empty global node form rejected cancellation"
  Require (Wait-ForDesktopElementGone `
    -desktop $desktop `
    -condition $nodeFormCondition `
    -label "empty global New Loop node form close" `
    -diagnosticWindow $shellWindow) "empty global node form did not close after cancellation"

  Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 10)) "empty project fixture command was rejected"
  Start-Sleep -Milliseconds 200
  $emptyProjectLoopButton = Find-FragmentById $root "4602" $rawWalker
  Require (($null -ne $emptyProjectLoopButton) -and
           ($emptyProjectLoopButton.Current.Name -eq "New Loop") -and
           (-not $emptyProjectLoopButton.Current.IsOffscreen)) `
    "empty project canvas omitted its visible New Loop action"
  Require (Ensure-ShellForeground $shellWindow "empty project New Loop") `
    "GraphCode shell did not reacquire foreground before empty project New Loop command"
  Require ([GraphCodeUiaGateState]::PostCommand($shellWindow, 4602)) `
    "empty project New Loop command was rejected"
  $projectNodeForm = $null
  $projectNodeForm = Wait-ForDesktopElement `
    -desktop $desktop `
    -condition $nodeFormCondition `
    -label "empty project New Loop node form" `
    -diagnosticWindow $shellWindow `
    -RecoverForeground
  Require ($null -ne $projectNodeForm) "empty project New Loop did not open the node form"
  Require ([GraphCodeUiaGateState]::PostClose(
    [IntPtr]$projectNodeForm.Current.NativeWindowHandle
  )) "empty project node form rejected cancellation"
  Require (Wait-ForDesktopElementGone `
    -desktop $desktop `
    -condition $nodeFormCondition `
    -label "empty project New Loop node form close" `
    -diagnosticWindow $shellWindow) "empty project node form did not close after cancellation"

  Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 11)) `
    "Remote Connection fixture command was rejected"
  $remoteDialog = $null
  $remoteWindowCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Remote Connection"
    )),
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Window
    ))
  )
  $remoteCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id
    )),
    $remoteWindowCondition
  )
  for ($index = 0; $index -lt 40 -and $null -eq $remoteDialog; $index++) {
    Start-Sleep -Milliseconds 50
    $remoteDialog = $desktop.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $remoteCondition
    )
  }
  Require ($null -ne $remoteDialog) "Remote Connection action did not open its read-only sheet"
  $remoteContent = @($remoteDialog.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  ) | ForEach-Object { $_.Current.Name }) -join "`n"
  Require ($remoteContent -match "ssh://builder/GraphCode") `
    "Remote Connection sheet omitted the encoded project identity"
  Require ($remoteContent -match "removing and adding the remote project") `
    "Remote Connection sheet omitted its management guidance"
  Require ([GraphCodeUiaGateState]::PostClose(
    [IntPtr]$remoteDialog.Current.NativeWindowHandle
  )) "Remote Connection sheet rejected close"
  Start-Sleep -Milliseconds 200

  Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 12)) `
    "Delete All Loops fixture command was rejected"
  $deleteLoopsDialog = $null
  $deleteLoopsWindowCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Delete All Loops"
    )),
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Window
    ))
  )
  $deleteLoopsCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id
    )),
    $deleteLoopsWindowCondition
  )
  for ($index = 0; $index -lt 40 -and $null -eq $deleteLoopsDialog; $index++) {
    Start-Sleep -Milliseconds 50
    $deleteLoopsDialog = $desktop.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $deleteLoopsCondition
    )
  }
  Require ($null -ne $deleteLoopsDialog) "Delete All Loops did not open its confirmation"
  $deleteLoopsContent = @($deleteLoopsDialog.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  ) | ForEach-Object { $_.Current.Name }) -join "`n"
  Require ($deleteLoopsContent -match "every loop and graph connection") `
    "Delete All Loops confirmation omitted graph consequences"
  Require ($deleteLoopsContent -match "project files remain on disk") `
    "Delete All Loops confirmation omitted filesystem consequences"
  Require ([GraphCodeUiaGateState]::SendCommand(
    [IntPtr]$deleteLoopsDialog.Current.NativeWindowHandle, 7
  )) "Delete All Loops confirmation rejected its safe No action"
  Start-Sleep -Milliseconds 200

  Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 13)) `
    "Delete Edge fixture command was rejected"
  $deleteEdgeDialog = $null
  $deleteEdgeWindowCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Delete Edge"
    )),
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Window
    ))
  )
  $deleteEdgeCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id
    )),
    $deleteEdgeWindowCondition
  )
  for ($index = 0; $index -lt 40 -and $null -eq $deleteEdgeDialog; $index++) {
    Start-Sleep -Milliseconds 50
    $deleteEdgeDialog = $desktop.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $deleteEdgeCondition
    )
  }
  Require ($null -ne $deleteEdgeDialog) "Delete Edge did not open its confirmation"
  $deleteEdgeContent = @($deleteEdgeDialog.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  ) | ForEach-Object { $_.Current.Name }) -join "`n"
  Require (($deleteEdgeContent -match "Planner") -and ($deleteEdgeContent -match "Builder")) `
    "Delete Edge confirmation omitted its endpoint loop names"
  Require ($deleteEdgeContent -match "handoff graph connection") `
    "Delete Edge confirmation omitted the connection kind and graph consequence"
  Require ($deleteEdgeContent -match "loops themselves remain") `
    "Delete Edge confirmation omitted the retained-loop consequence"
  Require ([GraphCodeUiaGateState]::SendCommand(
    [IntPtr]$deleteEdgeDialog.Current.NativeWindowHandle, 7
  )) "Delete Edge confirmation rejected its safe No action"
  Start-Sleep -Milliseconds 200

  Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 6)) "About dialog fixture command was rejected"
  $aboutDialog = $null
  $aboutWindowCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, "About GraphCode"
    )),
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Window
    ))
  )
  $aboutCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id
    )),
    $aboutWindowCondition
  )
  for ($index = 0; $index -lt 40 -and $null -eq $aboutDialog; $index++) {
    Start-Sleep -Milliseconds 50
    $aboutDialog = $desktop.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $aboutCondition
    )
  }
  if ($null -eq $aboutDialog) {
    $processWindowCondition = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id
    )
    $windowNames = @($desktop.FindAll(
      [System.Windows.Automation.TreeScope]::Descendants,
      $processWindowCondition
    ) | ForEach-Object { $_.Current.Name })
    throw "About command did not open the native About GraphCode dialog; process windows: $($windowNames -join ', '); status: $($status.Current.Name)"
  }
  $aboutElements = @($aboutDialog.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  ))
  $aboutContent = @($aboutElements | ForEach-Object { $_.Current.Name }) -join "`n"
  $aboutDescendants = @($aboutElements | ForEach-Object { "$($_.Current.ControlType.ProgrammaticName):$($_.Current.Name)" })
  Require ($aboutContent -match "GraphCode\s+for Windows") "About dialog omitted the product identity: $($aboutDescendants -join ' | ')"
  Require ($aboutContent -match "Version\s+\S+") "About dialog omitted the application version: $($aboutDescendants -join ' | ')"
  $aboutOk = $aboutDialog.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty,
      "OK"
    ))
  )
  Require ($null -ne $aboutOk) "About dialog omitted its OK action"
  Require ([GraphCodeUiaGateState]::PostClose(
    [IntPtr]$aboutDialog.Current.NativeWindowHandle
  )) "About dialog rejected its close command"
  Start-Sleep -Milliseconds 250

  Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 20)) `
    "sidebar parity fixture reset was rejected"
  Start-Sleep -Milliseconds 200
  Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 19)) `
    "sidebar ingress-error fixture mutation was rejected"
  Start-Sleep -Milliseconds 150
  $sidebarErrorFooter = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^sidebar-error-footer-' -and
      $_.Current.Name -eq 'Folder could not be opened because the background service returned a detailed error that should wrap cleanly in the sidebar footer.'
  }) | Select-Object -First 1
  Require ($null -ne $sidebarErrorFooter) "sidebar error footer omitted its dedicated UIA identity"
  Require (($sidebarErrorFooter.Current.BoundingRectangle.Width -gt 0) -and
           ($sidebarErrorFooter.Current.BoundingRectangle.Height -gt 24)) `
    "sidebar error footer did not expose wrapped multi-line bounds"

  $needsYouStop = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^needs-you-stop-' -and $_.Current.Name -eq "Stop loop"
  }) | Select-Object -First 1
  Require ($null -ne $needsYouStop) "Needs-you row omitted its Stop action"
  Remove-Item -LiteralPath $daemonCommandLogPath -Force -ErrorAction SilentlyContinue
  $needsYouStop.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  for ($index = 0; $index -lt 40 -and -not (Test-Path -LiteralPath $daemonCommandLogPath); $index++) {
    Start-Sleep -Milliseconds 50
  }
  Require (Test-Path -LiteralPath $daemonCommandLogPath) "Needs-you Stop did not emit a daemon command"
  $needsYouStopCommand = [IO.File]::ReadAllText($daemonCommandLogPath)
  Require ($needsYouStopCommand -match '"projectPath":"C:\\\\GraphCode\\\\fixture"') `
    "Needs-you Stop routed to the wrong project: $needsYouStopCommand"
  Require ($needsYouStopCommand -match '"stopNode":\{"_0":"22222222-2222-4222-8222-222222222222"\}') `
    "Needs-you Stop routed to the wrong loop: $needsYouStopCommand"

  Remove-Item -LiteralPath $daemonCommandLogPath -Force -ErrorAction SilentlyContinue
  Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 16)) `
    "sidebar root reorder fixture mutation was rejected"
  for ($index = 0; $index -lt 40 -and -not (Test-Path -LiteralPath $daemonCommandLogPath); $index++) {
    Start-Sleep -Milliseconds 50
  }
  $reorderedLoopRows = @(Get-DirectChildren $loops $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^loop-row-'
  })
  $reorderedRootNames = @($reorderedLoopRows | Where-Object {
    $_.Current.Name -in @("UIA loop A", "UIA loop C")
  } | ForEach-Object { $_.Current.Name })
  Require ((($reorderedRootNames -join '|') -eq 'UIA loop C|UIA loop A') -or
           (($reorderedRootNames -join '|') -eq 'UIA loop C|UIA loop A|UIA loop B')) `
    "sidebar root reorder was not observable in the loop tree: $($reorderedRootNames -join '|')"
  Require (Test-Path -LiteralPath $daemonCommandLogPath) "sidebar root reorder did not emit a daemon command"
  $reorderCommand = [IO.File]::ReadAllText($daemonCommandLogPath)
  Require ($reorderCommand -match '"sidebarNodesReordered"') `
    "sidebar root reorder did not use the sidebar-order daemon command: $reorderCommand"

  $moveProjectUnavailableReason = "Project relocation is unavailable: the daemon wire contract has no authoritative moveProject command."
  # The live native project right-click context menu (GraphContextMenu.zig,
  # a real Win32 TrackPopupMenu) always renders "Move Project... (unavailable:
  # daemon support required)" grayed via MF_GRAYED -- see the direct,
  # deterministic proof of that exact item's id/text/enabled state in
  # GraphContextMenu.zig's "the real Move Project menu item is disabled with
  # its explicit reason inline" test, which exercises the very function
  # show() uses to build the popup. This harness has no existing capability
  # to open/inspect a transient native Win32 popup menu live (no action in
  # this gate does; TrackPopupMenu blocks the message loop while displayed),
  # so instead we assert the two behaviors this gate CAN observe live: that
  # invoking the stale/legacy command path never opens Explorer, and that it
  # surfaces the exact unavailable-status reason.
  Remove-Item -LiteralPath $shellExecuteLogPath -Force -ErrorAction SilentlyContinue
  Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 17)) `
    "project Move fixture mutation was rejected"
  Start-Sleep -Milliseconds 250
  Require (-not (Test-Path -LiteralPath $shellExecuteLogPath)) `
    "project Move stale command routing must not open Explorer once relocation is unavailable"
  $moveProjectStatus = Find-FragmentById $root "status" $rawWalker
  Require ($moveProjectStatus.Current.Name -eq $moveProjectUnavailableReason) `
    "project Move stale command routing did not surface the explicit unavailable-status reason: $($moveProjectStatus.Current.Name)"

  Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 18)) `
    "activity fixture mutation was rejected"
  Start-Sleep -Milliseconds 200
  $activityFilter = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^activity-filter-'
  }) | Select-Object -First 1
  $activityRight = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^activity-control-' -and $_.Current.Name -eq 'Scroll activity right'
  }) | Select-Object -First 1
  Require (($null -ne $activityFilter) -and ($null -ne $activityRight)) `
    "activity strip omitted its filter or scroll affordances"
  $activityBeforeScroll = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^activity-row-'
  } | ForEach-Object { $_.Current.Name })
  Require (($activityBeforeScroll -join '|') -eq 'Activity E|Activity D') `
    "activity strip did not expose the expected initial viewport: $($activityBeforeScroll -join '|')"
  $activityRight.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150
  $activityAfterScroll = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^activity-row-'
  } | ForEach-Object { $_.Current.Name })
  Require (($activityAfterScroll -join '|') -eq 'Activity D|Activity C') `
    "activity strip scroll-right did not advance the live viewport: $($activityAfterScroll -join '|')"
  $activityFilter.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 150
  $filteredActivityRows = @(Get-DirectChildren $projects $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^activity-row-'
  })
  $filteredActivityNames = @($filteredActivityRows | ForEach-Object { $_.Current.Name })
  Require (($filteredActivityNames -join '|') -eq 'Activity C|Activity B') `
    "activity attention-only filter did not reduce the strip to attention rows: $($filteredActivityNames -join '|')"
  $activityNavigationRow = @($filteredActivityRows | Where-Object { $_.Current.Name -eq 'Activity C' }) | Select-Object -First 1
  Require ($null -ne $activityNavigationRow) "activity strip omitted the Activity C card after filtering"
  $activityNavigationRow.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 250
  $workspaceLoopBar = @(Get-DirectChildren $graph $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^workspace-loop-bar-'
  }) | Select-Object -First 1
  Require ($null -ne $workspaceLoopBar) "activity navigation did not open a workspace"
  $selectedWorkspaceCard = @(Get-DirectChildren $graph $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^canvas-card-' -and
      $_.Current.Name -eq 'Activity C' -and
      $_.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected
  }) | Select-Object -First 1
  Require ($null -ne $selectedWorkspaceCard) "activity navigation did not select the targeted loop"
  if ($SidebarParityOnly) { return }

  Require $process.CloseMainWindow() "shell refused caption close"
  Start-Sleep -Milliseconds 250
  $process.Refresh()
  Require (-not $process.HasExited) "caption close terminated the tray-resident shell"
  Require ([GraphCodeUiaGateState]::PostCommand($shellWindow, 0x5002)) "tray Exit command was rejected"
  Require $process.WaitForExit(5000) "shell did not exit after the tray Exit command"
  Require ($process.ExitCode -eq 0) "shell exited with code $($process.ExitCode) during provider teardown"
  $retainedProviderSafe = $false
  try {
    $null = $status.Current.Name
    $retainedProviderSafe = $true
  } catch [System.Windows.Automation.ElementNotAvailableException] {
    $retainedProviderSafe = $true
  }
  Require $retainedProviderSafe "retained status provider was unsafe after teardown"
  $env:GRAPHCODE_UIA_RESET_SIDEBAR = "0"
  if ($ArgumentList.Count -gt 0) {
    $settingsProcess = Start-Process -FilePath $Shell -ArgumentList $ArgumentList -PassThru `
      -WindowStyle Normal -RedirectStandardError $settingsErrorPath
  } else {
    $settingsProcess = Start-Process -FilePath $Shell -PassThru -WindowStyle Normal `
      -RedirectStandardError $settingsErrorPath
  }
  for ($index = 0; $index -lt 160 -and $settingsProcess.MainWindowHandle -eq 0; $index++) {
    Start-Sleep -Milliseconds 250
    $settingsProcess.Refresh()
    Require (-not $settingsProcess.HasExited) "Product Settings fixture shell exited during startup"
  }
  Require ($settingsProcess.MainWindowHandle -ne 0) "Product Settings fixture shell did not create its main window"
  $settingsRoot = $null
  for ($index = 0; $index -lt 160 -and $null -eq $settingsRoot; $index++) {
    Start-Sleep -Milliseconds 250
    $settingsProcess.Refresh()
    Require (-not $settingsProcess.HasExited) "Product Settings fixture shell exited before UIA readiness"
    $candidate = [System.Windows.Automation.AutomationElement]::FromHandle(
      $settingsProcess.MainWindowHandle
    )
    if ($candidate.Current.AutomationId -eq "graphcode-root") {
      $settingsRoot = $candidate
    }
  }
  Require ($null -ne $settingsRoot) "Product Settings fixture shell did not reach UIA readiness"
  $settingsFixtureReady = $false
  for ($index = 0; $index -lt 160 -and -not $settingsFixtureReady; $index++) {
    Start-Sleep -Milliseconds 250
    $settingsWorktrees = Find-FragmentById $settingsRoot "worktrees" $rawWalker
    if ($null -ne $settingsWorktrees) {
      $settingsFixtureReady = @(Get-DirectChildren $settingsWorktrees $rawWalker).Count -eq 2
    }
  }
  Require $settingsFixtureReady "Product Settings fixture shell did not finish startup"
  $settingsLoops = Find-FragmentById $settingsRoot "loops" $rawWalker
  $persistedLoopRows = @(Get-DirectChildren $settingsLoops $rawWalker | Where-Object {
    $_.Current.AutomationId -match '^loop-row-'
  })
  Require (($persistedLoopRows.Count -eq 2) -and
           ((@($persistedLoopRows | ForEach-Object { $_.Current.Name }) -join "|") -eq
            "UIA loop A|UIA loop B")) `
    "nested loop expansion did not persist across shell restart"
  $settingsShellWindow = $settingsProcess.MainWindowHandle
  $settingsMessageLoopReady = $false
  for ($attempt = 0; $attempt -lt 20 -and -not $settingsMessageLoopReady; $attempt++) {
    $null = [GraphCodeUiaGateState]::PostFixtureMutation($settingsShellWindow, 1)
    Start-Sleep -Milliseconds 250
    $settingsRowNames = @(Get-DirectChildren $settingsWorktrees $rawWalker |
      ForEach-Object { $_.Current.Name })
    $settingsMessageLoopReady = ($settingsRowNames -join "|") -eq
      "C:\fixture-unsafe|C:\fixture-safe"
  }
  Require $settingsMessageLoopReady "Product Settings fixture shell message loop did not become ready"
  Require ([GraphCodeUiaGateState]::PostFixtureMutation($settingsShellWindow, 1)) `
    "Product Settings fixture shell rejected readiness restore"
  Start-Sleep -Milliseconds 250
  Start-Sleep -Milliseconds 1500
  $settingsHandle = [IntPtr]::Zero
  for ($attempt = 0; $attempt -lt 3 -and
       $settingsHandle -eq [IntPtr]::Zero; $attempt++) {
    $null = [GraphCodeUiaGateState]::PostFixtureMutation($settingsShellWindow, 15)
    Start-Sleep -Milliseconds 500
    for ($index = 0; $index -lt 100 -and
         $settingsHandle -eq [IntPtr]::Zero; $index++) {
      Start-Sleep -Milliseconds 50
      $settingsHandle = [GraphCodeUiaGateState]::FindTopLevel(
        "GraphCodeProductSettings", [uint32]$settingsProcess.Id
      )
    }
  }
  if ($settingsHandle -eq [IntPtr]::Zero) {
    $settingsProcess.Refresh()
    if ($settingsProcess.HasExited) {
      $settingsError = if (Test-Path -LiteralPath $settingsErrorPath) {
        Get-Content -LiteralPath $settingsErrorPath -Raw
      } else { "" }
      throw "Product Settings fixture shell exited with code $($settingsProcess.ExitCode) while opening settings: $settingsError"
    }
    $processWindowCondition = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $settingsProcess.Id
    )
    $windowNames = @($desktop.FindAll(
      [System.Windows.Automation.TreeScope]::Descendants,
      $processWindowCondition
    ) | ForEach-Object { $_.Current.Name })
    $settingsStatus = Find-FragmentById $settingsRoot "status" $controlWalker
    throw "Product Settings fixture did not open the real settings window; process windows: $($windowNames -join ', '); status=$($settingsStatus.Current.Name)"
  }
  $productSettings = [System.Windows.Automation.AutomationElement]::FromHandle($settingsHandle)
  $settingsElements = @($productSettings.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  ))
  $settingsNames = @($settingsElements | ForEach-Object { $_.Current.Name })
  $requiredSettingsNames = @(
    "New loops use: Claude Code",
    "Claude Code: Auto (recommended)",
    "Copilot CLI: YOLO (recommended)",
    "Codex: Workspace (recommended)",
    "Default model: Capable",
    "Pick a model for each loop",
    "Show the activity strip",
    "Tell sessions they're part of a graph",
    "Get beta releases",
    "Save",
    "Cancel"
  )
  foreach ($requiredName in $requiredSettingsNames) {
    $element = @($settingsElements | Where-Object { $_.Current.Name -eq $requiredName }) |
      Select-Object -First 1
    Require ($null -ne $element) "Product Settings omitted '$requiredName'; descendants: $(@($settingsElements | ForEach-Object { ""$($_.Current.ControlType.ProgrammaticName):$($_.Current.Name)"" }) -join ' | ')"
    Require (($element.Current.BoundingRectangle.Width -gt 0) -and
             ($element.Current.BoundingRectangle.Height -gt 0) -and
             (-not $element.Current.IsOffscreen)) "Product Settings hid '$requiredName'"
  }
  $settingsContent = $settingsNames -join "`n"
  foreach ($copy in @(
    "Which backend a new loop starts on. You can still change it per loop.",
    "Approves the ordinary work of a coding session and keeps its guardrails.",
    "Copilot's --yolo: tools, paths, and URLs all approved",
    "Runs without asking, and may write inside the project it was given.",
    "nobody is there to answer a permission prompt",
    "The default model tier is copied into new loops",
    "A strip along the window's bottom lists passes",
    "Lets a loop create more loops when work genuinely splits",
    "Check for Updates offers pre-releases as well as stable releases"
  )) {
    Require ($settingsContent -match [regex]::Escape($copy)) `
      "Product Settings omitted explanatory copy '$copy'"
  }
  $expectedToggles = @{
    "Pick a model for each loop" = 1
    "Show the activity strip" = 1
    "Tell sessions they're part of a graph" = 0
    "Get beta releases" = 1
  }
  foreach ($entry in $expectedToggles.GetEnumerator()) {
    $toggleElement = @($settingsElements | Where-Object { $_.Current.Name -eq $entry.Key }) |
      Select-Object -First 1
    Require ([GraphCodeUiaGateState]::GetCheckState(
      [IntPtr]$toggleElement.Current.NativeWindowHandle
    ) -eq $entry.Value) `
      "Product Settings toggle '$($entry.Key)' did not load the isolated fixture"
  }

  $settingsWindow = $settingsHandle
  $backendButton = @($settingsElements | Where-Object {
    $_.Current.Name -eq "New loops use: Claude Code"
  }) | Select-Object -First 1
  Require ($null -ne $backendButton) "Product Settings backend control became unavailable"
  Require ([GraphCodeUiaGateState]::SendCommand($settingsWindow, 6112)) `
    "Product Settings backend fixture mutation was rejected"
  $backendFocus = Retain-FocusWithRetry `
    $settingsWindow $backendButton $backendButton.Current.AutomationId `
    "product-settings-return"
  Require ($null -ne $backendFocus.Focused) "Product Settings backend control could not retain foreground focus; focused=$(Format-AutomationElement $backendFocus.Candidate); $(Get-FocusDiagnostics $settingsWindow)"
  Require ([GraphCodeUiaGateState]::PostKeyboard(
    [IntPtr]$backendButton.Current.NativeWindowHandle, 0x0D
  )) "Product Settings focused control rejected Return"
  for ($index = 0; $index -lt 40; $index++) {
    Start-Sleep -Milliseconds 50
    $remainingSettings = [GraphCodeUiaGateState]::FindTopLevel(
      "GraphCodeProductSettings", [uint32]$settingsProcess.Id
    )
    if ($remainingSettings -eq [IntPtr]::Zero) { break }
  }
  Require ($remainingSettings -eq [IntPtr]::Zero) "Return did not activate Save and close Product Settings"
  $savedSettings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
  Require (($savedSettings.defaultBackend -eq "copilotCLI") -and
           ($savedSettings.gateSentinel -eq "preserve")) `
    "Return did not save Product Settings or preserve unrelated settings"
  $savedSettingsBytes = [IO.File]::ReadAllBytes($settingsPath)

  Require ([GraphCodeUiaGateState]::PostFixtureMutation($settingsShellWindow, 15)) `
    "Product Settings Escape fixture command was rejected"
  Start-Sleep -Milliseconds 500
  $cancelHandle = [IntPtr]::Zero
  for ($index = 0; $index -lt 300 -and
       $cancelHandle -eq [IntPtr]::Zero; $index++) {
    Start-Sleep -Milliseconds 50
    $cancelHandle = [GraphCodeUiaGateState]::FindTopLevel(
      "GraphCodeProductSettings", [uint32]$settingsProcess.Id
    )
  }
  Require ($cancelHandle -ne [IntPtr]::Zero) "Product Settings did not reopen for Escape verification"
  $cancelSettings = [System.Windows.Automation.AutomationElement]::FromHandle($cancelHandle)
  $cancelWindow = $cancelHandle
  Require ([GraphCodeUiaGateState]::SendCommand($cancelWindow, 6112)) `
    "Product Settings cancel mutation was rejected"
  $cancelModel = $cancelSettings.FindFirst(
    [System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Default model: Capable"
    ))
  )
  Require ($null -ne $cancelModel) "Product Settings omitted its model picker on reopen"
  $cancelFocus = Retain-FocusWithRetry `
    $cancelWindow $cancelModel $cancelModel.Current.AutomationId `
    "product-settings-escape"
  Require ($null -ne $cancelFocus.Focused) "Product Settings model control could not retain foreground focus; focused=$(Format-AutomationElement $cancelFocus.Candidate); $(Get-FocusDiagnostics $cancelWindow)"
  Require ([GraphCodeUiaGateState]::PostKeyboard(
    [IntPtr]$cancelModel.Current.NativeWindowHandle, 0x1B
  )) "Product Settings focused control rejected Escape"
  for ($index = 0; $index -lt 40; $index++) {
    Start-Sleep -Milliseconds 50
    $remainingCancelSettings = [GraphCodeUiaGateState]::FindTopLevel(
      "GraphCodeProductSettings", [uint32]$settingsProcess.Id
    )
    if ($remainingCancelSettings -eq [IntPtr]::Zero) { break }
  }
  Require ($remainingCancelSettings -eq [IntPtr]::Zero) "Escape did not cancel and close Product Settings"
  Require (([Convert]::ToBase64String([IO.File]::ReadAllBytes($settingsPath))) -eq
           ([Convert]::ToBase64String($savedSettingsBytes))) `
    "Escape changed persisted Product Settings"
  Require ([GraphCodeUiaGateState]::PostCommand($settingsShellWindow, 0x5002)) `
    "Product Settings fixture shell rejected exit"
  Require $settingsProcess.WaitForExit(5000) "Product Settings fixture shell did not exit"
  Require ($settingsProcess.ExitCode -eq 0) "Product Settings fixture shell exited with code $($settingsProcess.ExitCode)"
  $settingsProcess = $null

  [pscustomobject]@{
    name = $rootName
    automationId = $rootAutomationId
    controlType = $rootControlType
    rawRootChildren = $rawRootChildIds
    controlRootChildren = $controlRootChildIds
    rawWorktreeRows = $rawWorktreeRowIds
    controlWorktreeRows = $controlWorktreeRowIds
    reorderedWorktreeRows = $reorderedRowIds
    remainingWorktreeRows = $remainingRowIds
    removedProviderUnavailable = $removedProviderUnavailable
    concurrencyStressPassed = $true
    selectionPattern = $true
    fixtureRows = 2
    unsafeSelectionRejected = $unsafeRejected
    repeatedSelectionObserved = $true
    selectionEvents = $selectionEventEvidence
    togglePropertyEvents = [GraphCodeUiaGateState]::TogglePropertyEvents
    togglePropertySource = [GraphCodeUiaGateState]::TogglePropertySourceAutomationId
    actionPatterns = @($actions.Keys | Sort-Object)
    surfaceActionPatterns = @($surfaceActionPatterns.Keys | Sort-Object)
    dynamicProjectRows = $projectRowIds
    needsYouRows = @($needsYouRows | ForEach-Object { $_.Current.AutomationId })
    needsYouHeader = @($needsYouHeaders | ForEach-Object { $_.Current.AutomationId })
    activityRows = @($activityRows | ForEach-Object { $_.Current.AutomationId })
    activityHeader = @($activityHeaders | ForEach-Object { $_.Current.AutomationId })
    activityControls = @($activityControls | ForEach-Object { $_.Current.AutomationId })
    dynamicLoopRows = $loopIds
    dynamicProjectCards = $projectCardIds
    dynamicQuickChatCards = $quickChatCardIds
    dynamicInvocationsPassed = $true
    compositeNavigationPassed = $true
    renameDialogPassed = $true
    jumpPalettePassed = $true
    inlineIngressErrorPassed = $true
    openFolderPickerPassed = $true
    emptyOverviewPassed = $true
    emptyProjectPassed = $true
    remoteConnectionInfoPassed = $true
    deleteProjectLoopsPassed = $true
    deleteEdgePassed = $true
    productSettingsPassed = $true
    productSettingsReturnSaved = ($savedSettings.defaultBackend -eq "copilotCLI")
    productSettingsEscapeCancelled = $true
    aboutDialogPassed = $true
    statusText = $statusTextAfter
    statusChanged = ($statusTextAfter -ne $initialStatus)
    statusNoChangeLiveEvents = $statusNoChangeLiveEvents
    statusNoChangeNameEvents = $statusNoChangeNameEvents
    statusLiveEvents = [GraphCodeUiaGateState]::LiveEvents
    statusNamePropertyEvents = [GraphCodeUiaGateState]::NamePropertyEvents
    statusEventObserved = $statusEventObserved
    statusNamePropertyObserved = [GraphCodeUiaGateState]::NamePropertyObserved
    statusNamePropertySource = [GraphCodeUiaGateState]::NamePropertySourceAutomationId
    statusEventSource = [GraphCodeUiaGateState]::LiveSourceAutomationId
    statusEventText = [GraphCodeUiaGateState]::LiveSourceName
    focusIdentity = $focusIdentity
    focusEventObserved = [GraphCodeUiaGateState]::FocusObserved
    initialFocusEventSource = $initialFocusSource
    focusFallbackSource = [GraphCodeUiaGateState]::FocusSourceAutomationId
    providerTeardownSafe = $retainedProviderSafe
    connectionFailureBannerPassed = $true
  } | ConvertTo-Json -Compress
} finally {
  if ($stressJob) {
    Remove-Job -Job $stressJob -Force -ErrorAction SilentlyContinue
  }
  if ($propertyEventRegistered) {
    [System.Windows.Automation.Automation]::RemoveAutomationPropertyChangedEventHandler(
      $status, $propertyHandler
    )
  }
  if ($liveEventRegistered) {
    [System.Windows.Automation.Automation]::RemoveAutomationEventHandler(
      $liveRegionEvent, $status, $eventHandler
    )
  }
  if ($focusEventRegistered) {
    [System.Windows.Automation.Automation]::RemoveAutomationFocusChangedEventHandler($focusHandler)
  }
  if ($process -and -not $process.HasExited) {
    $process.Kill()
    $process.WaitForExit()
  }
  if ($settingsProcess -and -not $settingsProcess.HasExited) {
    $settingsProcess.Kill()
    $settingsProcess.WaitForExit()
  }
  if ($policyExisted) {
    [IO.File]::WriteAllBytes($policyPath, $policyContents)
  } elseif ($policyPath) {
    Remove-Item -LiteralPath $policyPath -Force -ErrorAction SilentlyContinue
    if (-not $policyDirectoryExisted -and
        -not (Get-ChildItem -LiteralPath $policyDirectory -Force -ErrorAction SilentlyContinue |
          Select-Object -First 1)) {
      Remove-Item -LiteralPath $policyDirectory -Force -ErrorAction SilentlyContinue
    }
  }
  if ($settingsDirectory) {
    Remove-Item -LiteralPath $settingsDirectory -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($daemonCommandLogPath) {
    Remove-Item -LiteralPath $daemonCommandLogPath -Force -ErrorAction SilentlyContinue
  }
  if ($shellExecuteLogPath) {
    Remove-Item -LiteralPath $shellExecuteLogPath -Force -ErrorAction SilentlyContinue
  }
  if ($templateDirectory) {
    Remove-Item -LiteralPath $templateDirectory -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($null -eq $oldZmx) { Remove-Item Env:GRAPHCODE_ZMX -ErrorAction SilentlyContinue }
  else { $env:GRAPHCODE_ZMX = $oldZmx }
  if ($null -eq $oldCwd) { Remove-Item Env:GRAPHCODE_GATE_CWD -ErrorAction SilentlyContinue }
  else { $env:GRAPHCODE_GATE_CWD = $oldCwd }
  if ($null -eq $oldGate) { Remove-Item Env:GRAPHCODE_UIA_GATE -ErrorAction SilentlyContinue }
  else { $env:GRAPHCODE_UIA_GATE = $oldGate }
  if ($null -eq $oldConnectionFailure) {
    Remove-Item Env:GRAPHCODE_UIA_CONNECTION_FAILURE -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_UIA_CONNECTION_FAILURE = $oldConnectionFailure
  }
  if ($null -eq $oldUser) { Remove-Item Env:USERNAME -ErrorAction SilentlyContinue }
  else { $env:USERNAME = $oldUser }
  if ($null -eq $oldFixture) { Remove-Item Env:GRAPHCODE_UIA_FIXTURE_ROWS -ErrorAction SilentlyContinue }
  else { $env:GRAPHCODE_UIA_FIXTURE_ROWS = $oldFixture }
  if ($null -eq $oldDaemonPipe) { Remove-Item Env:GRAPHCODE_DAEMON_PIPE -ErrorAction SilentlyContinue }
  else { $env:GRAPHCODE_DAEMON_PIPE = $oldDaemonPipe }
  if ($null -eq $oldSupportDirectory) {
    Remove-Item Env:GRAPHCODE_SUPPORT_DIR -ErrorAction SilentlyContinue
  } else { $env:GRAPHCODE_SUPPORT_DIR = $oldSupportDirectory }
  if ($null -eq $oldResetSidebar) {
    Remove-Item Env:GRAPHCODE_UIA_RESET_SIDEBAR -ErrorAction SilentlyContinue
  } else { $env:GRAPHCODE_UIA_RESET_SIDEBAR = $oldResetSidebar }
  if ($null -eq $oldUpdateAvailable) {
    Remove-Item Env:GRAPHCODE_UIA_UPDATE_AVAILABLE -ErrorAction SilentlyContinue
  } else { $env:GRAPHCODE_UIA_UPDATE_AVAILABLE = $oldUpdateAvailable }
  if ($null -eq $oldShowUpdate) {
    Remove-Item Env:GRAPHCODE_UIA_SHOW_UPDATE -ErrorAction SilentlyContinue
  } else { $env:GRAPHCODE_UIA_SHOW_UPDATE = $oldShowUpdate }
  if ($null -eq $oldIngressError) {
    Remove-Item Env:GRAPHCODE_UIA_INGRESS_ERROR -ErrorAction SilentlyContinue
  } else { $env:GRAPHCODE_UIA_INGRESS_ERROR = $oldIngressError }
  if ($null -eq $oldDaemonCommandLog) {
    Remove-Item Env:GRAPHCODE_UIA_DAEMON_COMMAND_LOG -ErrorAction SilentlyContinue
  } else { $env:GRAPHCODE_UIA_DAEMON_COMMAND_LOG = $oldDaemonCommandLog }
  if ($null -eq $oldShellExecuteLog) {
    Remove-Item Env:GRAPHCODE_UIA_SHELL_EXECUTE_LOG -ErrorAction SilentlyContinue
  } else { $env:GRAPHCODE_UIA_SHELL_EXECUTE_LOG = $oldShellExecuteLog }
  if ($null -eq $oldLocalAppData) {
    Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue
  } else { $env:LOCALAPPDATA = $oldLocalAppData }
}
