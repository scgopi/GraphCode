#nullable disable
using GraphCode.Windows;
using static GraphCode.Windows.UiaInputSafety;
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Automation;
public static class GraphCodeUiaGateState {
  private static readonly object ClientSideProviderRegistration = new object();
  private static string RegisteredClientSideProvider;
  // WPF inspects caller types while initializing proxies; a PowerShell dynamic frame has no type.
  [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
  public static void RegisterClientSideProviderAssembly(System.Reflection.AssemblyName assemblyName) {
    ArgumentNullException.ThrowIfNull(assemblyName);
    lock (ClientSideProviderRegistration) {
      if (RegisteredClientSideProvider == assemblyName.FullName) return;
      ClientSettings.RegisterClientSideProviderAssembly(assemblyName);
      GC.KeepAlive(assemblyName);
      RegisteredClientSideProvider = assemblyName.FullName;
    }
  }

  private sealed class NativeInputOperations : IUiaInputOperations {
    public bool IsRetainedProcessAlive(uint processId) { return GraphCodeUiaGateState.IsRetainedProcessAlive(processId); }
    public uint WindowProcessId(IntPtr window) { return GraphCodeUiaGateState.WindowProcessId(window); }
    public bool WindowIsVisible(IntPtr window) { return GraphCodeUiaGateState.WindowIsVisible(window); }
    public bool WindowIsEnabled(IntPtr window) { return GraphCodeUiaGateState.WindowIsEnabled(window); }
    public IntPtr GetForegroundWindow() { return GraphCodeUiaGateState.GetForegroundWindow(); }
    public IntPtr FocusedControlInDialog(IntPtr window) { return GraphCodeUiaGateState.FocusedControlInDialog(window); }
    public IntPtr GetAncestor(IntPtr window, uint flags) { return GraphCodeUiaGateState.GetAncestor(window, flags); }
    public bool GetCursorPos(out ScreenPoint point) { return GraphCodeUiaGateState.GetCursorPos(out point); }
    public bool SetCursorPos(int x, int y) { return GraphCodeUiaGateState.SetCursorPos(x, y); }
    public IntPtr WindowFromPoint(ScreenPoint point) { return GraphCodeUiaGateState.WindowFromPoint(point); }
    public bool IsWindowVisible(IntPtr window) { return GraphCodeUiaGateState.IsWindowVisible(window); }
    public bool GetMenuItemRect(IntPtr owner, IntPtr menu, uint position, out RECT item) { return GraphCodeUiaGateState.GetMenuItemRect(owner, menu, position, out item); }
    public IntPtr FindPopupForMenu(uint processId, IntPtr menu) { return GraphCodeUiaGateState.FindPopupForMenu(processId, menu); }
    public bool ScreenToClient(IntPtr window, ref ScreenPoint point) { return GraphCodeUiaGateState.ScreenToClient(window, ref point); }
    public IntPtr MouseLParam(int x, int y) { return GraphCodeUiaGateState.MouseLParam(x, y); }
    public uint GetMenuState(IntPtr menu, uint position, uint flags) { return GraphCodeUiaGateState.GetMenuState(menu, position, flags); }
    public void Sleep(uint milliseconds) { GraphCodeUiaGateState.Sleep(milliseconds); }
    public bool ResolvesToControl(IntPtr target, IntPtr owner, ScreenPoint point) { return GraphCodeUiaGateState.ResolvesToControl(target, owner, point); }
    public uint SendInput(uint count, Input[] inputs, int size) { return GraphCodeUiaGateState.SendInput(count, inputs, size); }
    public uint SendKeyInputs(uint count, KeyInputRecord[] inputs, int size) { return GraphCodeUiaGateState.SendKeyInputs(count, inputs, size); }
    public IntPtr ControlById(IntPtr owner, int id) { return GraphCodeUiaGateState.ControlById(owner, id); }
    public bool FocusControl(IntPtr owner, IntPtr edit) { return GraphCodeUiaGateState.FocusControl(owner, edit); }
    public IntPtr SendMessage(IntPtr edit, uint message, UIntPtr first, IntPtr last) { return GraphCodeUiaGateState.SendMessage(edit, message, first, last); }
    public string EditBufferText(IntPtr edit) { return GraphCodeUiaGateState.EditBufferText(edit); }
    public string EditTextById(IntPtr owner, int id) { return GraphCodeUiaGateState.EditTextById(owner, id); }
    public IntPtr SendMessageString(IntPtr edit, uint message, UIntPtr first, string text) { return GraphCodeUiaGateState.SendMessageString(edit, message, first, text); }
    public IntPtr PopupMenuHandle(IntPtr popup) { return GraphCodeUiaGateState.PopupMenuHandle(popup); }
    public uint PopupMenuItemId(IntPtr menu, int position) { return GraphCodeUiaGateState.PopupMenuItemId(menu, position); }
    public bool PostMessage(IntPtr window, uint message, UIntPtr first, IntPtr last) { return GraphCodeUiaGateState.PostMessage(window, message, first, last); }
  }
  private static readonly UiaInputSafety InputSafety = new UiaInputSafety(new NativeInputOperations());

  public static volatile bool LiveObserved;
  public static volatile bool NamePropertyObserved;
  public static volatile bool FocusObserved;
  public static int LiveEvents;
  public static int NamePropertyEvents;
  public static int SelectedEvents;
  public static int AddedEvents;
  public static int RemovedEvents;
  public static int TogglePropertyEvents;
  public static uint LastEditClearExpected { get => InputSafety.LastEditClearExpected; set => InputSafety.LastEditClearExpected = value; }
  public static uint LastEditClearSent { get => InputSafety.LastEditClearSent; set => InputSafety.LastEditClearSent = value; }
  public static uint LastEditTextExpected { get => InputSafety.LastEditTextExpected; set => InputSafety.LastEditTextExpected = value; }
  public static uint LastEditTextSent { get => InputSafety.LastEditTextSent; set => InputSafety.LastEditTextSent = value; }
  public static bool LastEditUsedMessageFallback { get => InputSafety.LastEditUsedMessageFallback; set => InputSafety.LastEditUsedMessageFallback = value; }
  public static string LiveSourceAutomationId;
  public static string LiveSourceName;
  public static string LiveSourceRuntimeId;
  public static string NamePropertySourceAutomationId;
  public static string FocusSourceAutomationId;
  public static string SelectionSourceAutomationId;
  public static string SelectionSourceRuntimeId;
  public static int SelectionSourceProcessId;
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
    if (element != null) {
      SelectionSourceAutomationId = element.Current.AutomationId;
      SelectionSourceRuntimeId = String.Join(",", element.GetRuntimeId());
      SelectionSourceProcessId = element.Current.ProcessId;
    }
    SelectedEvents++;
  }
  private static void HandleAdded(object sender, AutomationEventArgs eventArgs) {
    var element = sender as AutomationElement;
    if (element != null) {
      SelectionSourceAutomationId = element.Current.AutomationId;
      SelectionSourceRuntimeId = String.Join(",", element.GetRuntimeId());
    }
    AddedEvents++;
  }
  private static void HandleRemoved(object sender, AutomationEventArgs eventArgs) {
    var element = sender as AutomationElement;
    if (element != null) {
      SelectionSourceAutomationId = element.Current.AutomationId;
      SelectionSourceRuntimeId = String.Join(",", element.GetRuntimeId());
    }
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
  [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", SetLastError = true)]
  private static extern IntPtr SendMessageTimeout(
    IntPtr window, uint message, UIntPtr wParam, IntPtr lParam,
    uint flags, uint timeoutMilliseconds, out UIntPtr result
  );
  [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
  private static extern IntPtr SendMessageString(IntPtr window, uint message, UIntPtr wParam, string lParam);
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
  [DllImport("user32.dll")]
  private static extern int GetDlgCtrlID(IntPtr window);
  [DllImport("user32.dll")]
  private static extern IntPtr GetDlgItem(IntPtr dialog, int controlId);
  [DllImport("user32.dll")]
  private static extern IntPtr SetFocus(IntPtr window);
  [DllImport("user32.dll")]
  private static extern IntPtr GetFocus();
  [DllImport("user32.dll", SetLastError = true)]
  private static extern bool SetForegroundWindow(IntPtr window);
  [DllImport("user32.dll")]
  private static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", SetLastError = true)]
  private static extern bool BringWindowToTop(IntPtr window);
  [DllImport("kernel32.dll")]
  private static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")]
  private static extern IntPtr GetThreadDpiAwarenessContext();
  [DllImport("user32.dll", SetLastError = true)]
  private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")]
  private static extern bool AreDpiAwarenessContextsEqual(IntPtr first, IntPtr second);

  public readonly struct ThreadDpiContext {
    public IntPtr Context { get; }
    public uint ThreadId { get; }
    public ThreadDpiContext(IntPtr context, uint threadId) { Context = context; ThreadId = threadId; }
  }

  public static ThreadDpiContext EnterPhysicalDpiCoordinates() {
    var scope = new ThreadDpiContext(GetThreadDpiAwarenessContext(), GetCurrentThreadId());
    if (scope.Context == IntPtr.Zero)
      throw new InvalidOperationException("Cannot capture UIA thread DPI context");
    IntPtr result = SetThreadDpiAwarenessContext(new IntPtr(-4));
    int error = Marshal.GetLastWin32Error();
    if (result == IntPtr.Zero)
      throw new InvalidOperationException("Cannot enter UIA thread PMv2 context: native set failed, error=" + error);
    IntPtr observed = GetThreadDpiAwarenessContext();
    if (!AreDpiAwarenessContextsEqual(observed, new IntPtr(-4))) {
      var failure = new InvalidOperationException("UIA thread did not admit PMv2 awareness");
      try { RestorePhysicalDpiCoordinates(scope); }
      catch (InvalidOperationException restoreFailure) {
        failure.Data["UiaDpiRestoreFailure"] = restoreFailure;
        Console.Error.WriteLine("UIA_DPI_RESTORE_ERROR=" + restoreFailure.Message);
      }
      throw failure;
    }
    Console.WriteLine("UIA_DPI_ENTER thread={0} captured={1:X} observed={2:X}",
      scope.ThreadId, scope.Context.ToInt64(), observed.ToInt64());
    return scope;
  }

  public static void RestorePhysicalDpiCoordinates(ThreadDpiContext scope) {
    if (scope.Context == IntPtr.Zero)
      throw new InvalidOperationException("Cannot restore an invalid UIA thread DPI context");
    uint thread = GetCurrentThreadId();
    if (thread != scope.ThreadId)
      throw new InvalidOperationException("UIA DPI scope must restore on its capture thread");
    // The setter's inherited return token is not the stable pre-entry context.
    IntPtr result = SetThreadDpiAwarenessContext(scope.Context);
    int error = Marshal.GetLastWin32Error();
    if (result == IntPtr.Zero)
      throw new InvalidOperationException("Cannot restore UIA thread DPI context: native set failed, error=" + error);
    IntPtr observed = GetThreadDpiAwarenessContext();
    if (!AreDpiAwarenessContextsEqual(observed, scope.Context))
      throw new InvalidOperationException("Cannot restore UIA thread DPI context: exact context comparison failed");
    Console.WriteLine("UIA_DPI_RESTORE thread={0} captured={1:X} observed={2:X} exact=true",
      thread, scope.Context.ToInt64(), observed.ToInt64());
  }

  [DllImport("kernel32.dll")]
  private static extern void Sleep(uint milliseconds);
  [DllImport("user32.dll", SetLastError = true)]
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
  private static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")]
  private static extern bool IsWindowEnabled(IntPtr window);
  [DllImport("user32.dll")]
  private static extern int GetMenuItemCount(IntPtr menu);
  [DllImport("user32.dll")]
  private static extern uint GetMenuItemID(IntPtr menu, int position);
  [DllImport("user32.dll")]
  private static extern uint GetMenuState(IntPtr menu, uint item, uint flags);
  [DllImport("user32.dll")]
  private static extern bool GetMenuItemRect(IntPtr window, IntPtr menu, uint position, out RECT rect);
  [DllImport("user32.dll", SetLastError = true)]
  private static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll", SetLastError = true)]
  private static extern bool GetCursorPos(out ScreenPoint point);


  [DllImport("user32.dll", SetLastError = true)]
  private static extern uint SendInput(uint count, Input[] inputs, int size);
  [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetMenuStringW")]
  private static extern int GetMenuString(IntPtr menu, uint item, StringBuilder text, int max, uint flags);
  // The File/Loop/Terminal/Workspace/View/Help bar is a real SetMenu menu bar,
  // not a TrackPopupMenu popup, so (unlike the popup context menu below) its
  // live enabled state is readable directly through the Win32 menu API against
  // GetMenu(shell) -- no MN_GETHMENU / popup-window workaround required.
  // MF_BYCOMMAND (0) searches the whole menu tree for the command identifier.
  public static uint MenuCommandState(IntPtr menuBar, uint command) {
    if (menuBar == IntPtr.Zero) return 0xFFFFFFFF;
    return GetMenuState(menuBar, command, 0x0000);
  }
  public static IntPtr GetMenuBar(IntPtr window) {
    return GetMenu(window);
  }
  public static IntPtr FindPopupMenuWindow(uint processId) {
    IntPtr result = IntPtr.Zero;
    EnumWindows(delegate(IntPtr window, IntPtr parameter) {
      uint owner;
      GetWindowThreadProcessId(window, out owner);
      if (owner != processId) return true;
      var actualClass = new StringBuilder(256);
      GetClassName(window, actualClass, actualClass.Capacity);
      if (!String.Equals(actualClass.ToString(), "#32768", StringComparison.Ordinal)) return true;
      if (!IsWindowVisible(window)) return true;
      result = window;
      return false;
    }, IntPtr.Zero);
    return result;
  }
  public static IntPtr FindVisibleOwnedSheetByContentClass(
      uint processId, IntPtr expectedOwner, string contentClass) {
    IntPtr result = IntPtr.Zero;
    EnumWindows(delegate(IntPtr window, IntPtr parameter) {
      uint owner;
      GetWindowThreadProcessId(window, out owner);
      if (owner == processId && IsWindowVisible(window) &&
          GetWindow(window, 4) == expectedOwner &&
          String.Equals(WindowClass(window), "GraphCodeSheetHost", StringComparison.Ordinal) &&
          String.Equals(SheetContentClass(window), contentClass, StringComparison.Ordinal)) {
        result = window;
        return false;
      }
      return true;
    }, IntPtr.Zero);
    return result;
  }
  public static int CountVisibleOwnedSheetsByContentClass(
      uint processId, IntPtr expectedOwner, string contentClass) {
    int count = 0;
    EnumWindows(delegate(IntPtr window, IntPtr parameter) {
      uint owner;
      GetWindowThreadProcessId(window, out owner);
      if (owner == processId && IsWindowVisible(window) &&
          GetWindow(window, 4) == expectedOwner &&
          String.Equals(WindowClass(window), "GraphCodeSheetHost", StringComparison.Ordinal) &&
          String.Equals(SheetContentClass(window), contentClass, StringComparison.Ordinal)) {
        count++;
      }
      return true;
    }, IntPtr.Zero);
    return count;
  }
  public static IntPtr FindVisibleOwnedSheet(uint processId, string title) {
    IntPtr result = IntPtr.Zero;
    EnumWindows(delegate(IntPtr window, IntPtr parameter) {
      uint owner;
      GetWindowThreadProcessId(window, out owner);
      if (owner == processId && IsWindowVisible(window) &&
          String.Equals(WindowClass(window), "GraphCodeSheetHost", StringComparison.Ordinal) &&
          String.Equals(WindowTitle(window), title, StringComparison.Ordinal)) {
        result = window;
        return false;
      }
      return true;
    }, IntPtr.Zero);
    return result;
  }
  // MN_GETHMENU. The live UIA tree exposes a popup menu only as an empty Pane
  // with no MenuItem children, so the menu itself is read through the Win32
  // menu API against the real HMENU the shell handed to TrackPopupMenu.
  public static IntPtr PopupMenuHandle(IntPtr popup) {
    if (popup == IntPtr.Zero) return IntPtr.Zero;
    return SendMessage(popup, 0x01E1, UIntPtr.Zero, IntPtr.Zero);
  }
  public static IntPtr FindPopupForMenu(uint processId, IntPtr menu) {
    IntPtr result = IntPtr.Zero;
    EnumWindows(delegate(IntPtr window, IntPtr parameter) {
      uint owner;
      GetWindowThreadProcessId(window, out owner);
      if (owner == processId && IsWindowVisible(window) &&
          String.Equals(ClassOf(window), "#32768", StringComparison.Ordinal) &&
          PopupMenuHandle(window) == menu) {
        result = window;
        return false;
      }
      return true;
    }, IntPtr.Zero);
    return result;
  }
  public static bool HoverPopupMenuItem(IntPtr owner, IntPtr menu, int position) { return InputSafety.HoverPopupMenuItem(owner, menu, position); }
  // Keyboard reveal of a real submenu: hilite the parent item (MN_SELECTITEM)
  // and post VK_RIGHT, the same navigation a keyboard user performs. Unlike a
  // WM_COMMAND posted to the shell (which TrackPopupMenu/TPM_RETURNCMD menus
  // never route), this opens the shell's own submenu popup.
  public static bool RevealSubmenuByKeyboard(IntPtr popup, IntPtr menu, int position) {
    if (popup == IntPtr.Zero || menu == IntPtr.Zero || !IsWindowVisible(popup)) return false;
    SendMessage(popup, 0x01E5, (UIntPtr)position, IntPtr.Zero);
    if ((GetMenuState(menu, (uint)position, 0x0400) & 0x0080) == 0) return false;
    return PostMessage(popup, 0x0100, (UIntPtr)0x27, IntPtr.Zero) &&
      PostMessage(popup, 0x0101, (UIntPtr)0x27, IntPtr.Zero);
  }
  public static int PopupMenuItemCount(IntPtr menu) {
    if (menu == IntPtr.Zero) return -1;
    return GetMenuItemCount(menu);
  }
  public static uint PopupMenuItemId(IntPtr menu, int position) {
    if (menu == IntPtr.Zero) return 0;
    return GetMenuItemID(menu, position);
  }
  public static string PopupMenuItemText(IntPtr menu, int position) {
    if (menu == IntPtr.Zero) return "";
    var text = new StringBuilder(512);
    GetMenuString(menu, (uint)position, text, text.Capacity, 0x0400);
    return text.ToString();
  }
  public static uint PopupMenuItemState(IntPtr menu, int position) {
    if (menu == IntPtr.Zero) return 0xFFFFFFFF;
    return GetMenuState(menu, (uint)position, 0x0400);
  }
  // MainWindow.wm_uia_context_menu (WM_APP + 44).
  public static bool PostContextMenu(IntPtr window, uint target) {
    return PostMessage(window, 0x802C, (UIntPtr)target, IntPtr.Zero);
  }
  // MainWindow.wm_uia_present_form (WM_APP + 45).
  public static bool PostPresentForm(IntPtr window, uint form) {
    return PostMessage(window, 0x802D, (UIntPtr)form, IntPtr.Zero);
  }
  public static bool DismissPopupMenu(IntPtr popup, IntPtr owner) {
    bool posted = popup != IntPtr.Zero &&
      PostMessage(popup, 0x0100, (UIntPtr)0x1B, IntPtr.Zero);
    if (!posted && owner != IntPtr.Zero) {
      SendMessage(owner, 0x001F, UIntPtr.Zero, IntPtr.Zero);
    }
    return posted;
  }
  public static void CancelPopupMenu(IntPtr owner) {
    if (owner != IntPtr.Zero) PostMessage(owner, 0x001F, UIntPtr.Zero, IntPtr.Zero);
  }
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
    UIntPtr result;
    return SendMessageTimeout(
      window, 0x0111, (UIntPtr)command, IntPtr.Zero,
      0x0001 | 0x0002, 5000, out result
    ) != IntPtr.Zero;
  }
  public static bool ClickButton(IntPtr button) {
    if (button == IntPtr.Zero) return false;
    SendMessage(button, 0x00F5, UIntPtr.Zero, IntPtr.Zero);
    return true;
  }
  public static int GetCheckState(IntPtr window) {
    if (window == IntPtr.Zero) return -1;
    return (int)SendMessage(window, 0x00F0, UIntPtr.Zero, IntPtr.Zero);
  }
  public static bool FocusControl(IntPtr parent, IntPtr control) {
    if (parent == IntPtr.Zero || control == IntPtr.Zero) return false;
    uint expectedProcessId = WindowProcessId(parent);
    RequireOwnedInputWindow(parent, expectedProcessId);
    if (WindowProcessId(control) != expectedProcessId || GetAncestor(control, 2) != parent ||
        !ActivateWindow(parent)) return false;
    uint ignoredProcessId;
    uint parentThread = GetWindowThreadProcessId(parent, out ignoredProcessId);
    uint currentThread = GetCurrentThreadId();
    bool attached = currentThread != parentThread &&
      AttachThreadInput(currentThread, parentThread, true);
    try {
      RequireOwnedForeground(parent, expectedProcessId);
      SetFocus(control);
      return IsForegroundWindow(parent) && FocusedControlInDialog(parent) == control;
    } finally {
      if (attached) AttachThreadInput(currentThread, parentThread, false);
    }
  }
  [StructLayout(LayoutKind.Sequential)]
  private struct GuiThreadInfo {
    public int Size;
    public uint Flags;
    public IntPtr Active, Focus, Capture, MenuOwner, MoveSize, Caret;
    public RECT CaretRectangle;
  }
  [DllImport("user32.dll", SetLastError = true)]
  private static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
  public static IntPtr FocusedControlInDialog(IntPtr parent) {
    uint processId;
    uint thread = GetWindowThreadProcessId(parent, out processId);
    var info = new GuiThreadInfo { Size = Marshal.SizeOf(typeof(GuiThreadInfo)) };
    if (thread == 0 || !GetGUIThreadInfo(thread, ref info))
      throw new InvalidOperationException("Owned focus could not be observed through GetGUIThreadInfo");
    return info.Focus;
  }
  private static readonly System.Collections.Generic.Dictionary<uint, System.Diagnostics.Process>
    RetainedProcesses = new System.Collections.Generic.Dictionary<uint, System.Diagnostics.Process>();
  public static void RetainProcess(System.Diagnostics.Process process) {
    if (process == null || process.Handle == IntPtr.Zero)
      throw new InvalidOperationException("UIA process has no retained launch handle");
    RetainedProcesses[checked((uint)process.Id)] = process;
  }
  private static bool IsRetainedProcessAlive(uint processId) {
    System.Diagnostics.Process process;
    if (!RetainedProcesses.TryGetValue(processId, out process)) return false;
    try { return process.Handle != IntPtr.Zero && !process.HasExited; }
    catch (ObjectDisposedException) { return false; }
    catch (InvalidOperationException) { return false; }
  }
  private static void RequireOwnedInputWindow(IntPtr owner, uint expectedProcessId) { InputSafety.RequireOwnedInputWindow(owner, expectedProcessId); }
  private static void RequireOwnedForeground(IntPtr owner, uint expectedProcessId) { InputSafety.RequireOwnedForeground(owner, expectedProcessId); }
  public static void RequireOwnedKeyboardInput(IntPtr owner, uint expectedProcessId, IntPtr expectedFocus) { InputSafety.RequireOwnedKeyboardInput(owner, expectedProcessId, expectedFocus); }
  private static void RequireOwnedMouseInput(
    IntPtr owner, uint expectedProcessId, ScreenPoint expected, IntPtr expectedControl
  ) { InputSafety.RequireOwnedMouseInput(owner, expectedProcessId, expected, expectedControl); }
  public static bool IsControlOwnedBy(IntPtr parent, IntPtr control, int controlId) {
    return parent != IntPtr.Zero && control != IntPtr.Zero &&
      GetDlgCtrlID(control) == controlId && GetAncestor(control, 2) == parent;
  }
  public static int ControlIdOf(IntPtr control) {
    return control == IntPtr.Zero ? 0 : GetDlgCtrlID(control);
  }
  public static bool IsReadonlyEdit(IntPtr window) {
    if (window == IntPtr.Zero || !String.Equals(WindowClass(window), "Edit", StringComparison.Ordinal))
      throw new InvalidOperationException("Readonly endpoint requires a native Edit control.");
    long style = GetWindowLongPtr(window, -16).ToInt64();
    if (style == 0)
      throw new InvalidOperationException("Readonly endpoint style query failed: " + Marshal.GetLastWin32Error());
    return (style & 0x0800) != 0;
  }
  public static bool HasVisibleBounds(IntPtr window) {
    RECT rect;
    return window != IntPtr.Zero && IsWindowVisible(window) &&
      GetWindowRect(window, out rect) && rect.Right > rect.Left && rect.Bottom > rect.Top;
  }
  public static string LastActivationDiagnostic = "not attempted";
  private sealed class WindowActivationOperations : GraphCode.Windows.IUiaWindowActivationOperations {
    public uint WindowProcessId(IntPtr window) {
      return GraphCodeUiaGateState.WindowProcessId(window);
    }
    public bool IsRetainedProcessAlive(uint processId) {
      return GraphCodeUiaGateState.IsRetainedProcessAlive(processId);
    }
    public void ShowWindow(IntPtr window, int command) {
      GraphCodeUiaGateState.ShowWindow(window, command);
    }
    public GraphCode.Windows.UiaActivationCallResult BringWindowToTop(IntPtr window) {
      bool succeeded = GraphCodeUiaGateState.BringWindowToTop(window);
      int error = Marshal.GetLastWin32Error();
      return new GraphCode.Windows.UiaActivationCallResult(succeeded, error);
    }
    public GraphCode.Windows.UiaActivationCallResult SetForegroundWindow(IntPtr window) {
      bool succeeded = GraphCodeUiaGateState.SetForegroundWindow(window);
      int error = Marshal.GetLastWin32Error();
      return new GraphCode.Windows.UiaActivationCallResult(succeeded, error);
    }
    public bool IsForegroundWindow(IntPtr window) {
      return GraphCodeUiaGateState.IsForegroundWindow(window);
    }
  }
  private static readonly GraphCode.Windows.IUiaWindowActivationOperations ActivationOperations =
    new WindowActivationOperations();
  public static bool ActivateWindow(IntPtr window) {
    return GraphCode.Windows.UiaWindowActivation.ActivateWindow(
      ActivationOperations, window, out LastActivationDiagnostic);
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
  // Diagnostic only (Tools/windows/uia-live-gate.ps1's Get-DirectChildren
  // exhaustion path): enumerates every top-level window currently owned by
  // processId with its class, visibility, and title, so a failure that
  // reports MainWindowHandle == 0 can be told apart as window-destroyed
  // (empty result), window-hidden (a result exists but is not visible), or
  // handle-churn (a visible, healthy-looking window exists under a handle
  // Process.MainWindowHandle no longer reports). Does not filter or assert
  // anything - it is read verbatim into a log line.
  public static string[] DescribeTopLevelWindows(uint processId) {
    var results = new System.Collections.ArrayList();
    EnumWindows(delegate(IntPtr window, IntPtr parameter) {
      uint owner;
      GetWindowThreadProcessId(window, out owner);
      if (owner != processId) return true;
      var classText = new StringBuilder(256);
      GetClassName(window, classText, classText.Capacity);
      int titleLength = GetWindowTextLength(window);
      var titleText = new StringBuilder(titleLength + 1);
      GetWindowText(window, titleText, titleText.Capacity);
      bool visible = IsWindowVisible(window);
      results.Add(window.ToInt64() + ":" + classText.ToString() + ":" +
        (visible ? "visible" : "hidden") + ":" + titleText.ToString());
      return true;
    }, IntPtr.Zero);
    return (string[])results.ToArray(typeof(string));
  }
  public static bool PostMouseClick(IntPtr window) {
    return PostMessage(window, 0x0201, UIntPtr.Zero, IntPtr.Zero);
  }
  // A modal disables its owner for as long as it is up. Win32 refuses a caption
  // close against a WS_DISABLED window, so the owner must be observed enabled
  // again before a close can be attributed to the shell rather than to a modal
  // that has not finished tearing down.
  public static bool WindowIsEnabled(IntPtr window) {
    return IsWindowEnabled(window);
  }
  public static bool WindowIsVisible(IntPtr window) {
    return window != IntPtr.Zero && IsWindowVisible(window);
  }
  public static IntPtr WindowOwner(IntPtr window) {
    return window == IntPtr.Zero ? IntPtr.Zero : GetWindow(window, 4);
  }
  public static bool IsCaptionlessSheet(IntPtr window) {
    if (window == IntPtr.Zero ||
        !String.Equals(WindowClass(window), "GraphCodeSheetHost", StringComparison.Ordinal))
      return false;
    ulong style = unchecked((ulong)GetWindowLongPtr(window, -16).ToInt64());
    return (style & 0x80000000UL) != 0 && (style & 0x00C00000UL) == 0;
  }
  public static string SheetContentClass(IntPtr window) {
    if (window == IntPtr.Zero ||
        !String.Equals(WindowClass(window), "GraphCodeSheetHost", StringComparison.Ordinal))
      return "";
    IntPtr viewport = FindWindowEx(window, IntPtr.Zero, "GraphCodeSheetViewport", null);
    if (viewport == IntPtr.Zero) return "";
    string[] contentClasses = new[] {
      "GraphCodeWindowsDialogContent",
      "GraphCodeNativeForm",
      "GraphCodeProductSettings",
      "GraphCodeWorkspaceManager",
      "GraphCodeRepositoryIngressDialog",
      "GraphCodeRepositoryOperationDialog",
      "GraphCodeCodespaceIngressDialog",
      "GraphCodeUpdateOffer",
      "GraphCodeUpdateInstall"
    };
    foreach (string contentClass in contentClasses)
      if (FindWindowEx(viewport, IntPtr.Zero, contentClass, null) != IntPtr.Zero)
        return contentClass;
    return "";
  }
  public static IntPtr FindVisibleProcessWindow(uint processId, string title) {
    IntPtr result = IntPtr.Zero;
    EnumWindows(delegate(IntPtr window, IntPtr parameter) {
      uint owner;
      GetWindowThreadProcessId(window, out owner);
      if (owner == processId && IsWindowVisible(window) &&
          String.Equals(WindowTitle(window), title, StringComparison.Ordinal)) {
        result = window;
        return false;
      }
      return true;
    }, IntPtr.Zero);
    return result;
  }
  // Real client-coordinate mouse messages posted directly to the target window,
  // matching the same WM_MOUSEMOVE/WM_LBUTTONDOWN/WM_LBUTTONUP messages the OS
  // delivers for genuine mouse input, without moving the shared desktop's real
  // cursor (multiple fleet sessions share this desktop). PostMouseButtonAt sets
  // the MK_LBUTTON flag in wParam, matching the wParam a real WM_LBUTTONDOWN/UP
  // carries; ClickAt below (and its existing sidebar-update-banner caller) keep
  // working unchanged since App.zig's click handling only decodes the lParam
  // x/y, not the button-state bits in wParam.
  private static IntPtr MouseLParam(int x, int y) {
    return (IntPtr)(((y & 0xFFFF) << 16) | (x & 0xFFFF));
  }
  public static bool PostMouseButtonAt(IntPtr window, uint message, int x, int y) {
    return PostMessage(window, message, (UIntPtr)0x0001, MouseLParam(x, y));
  }
  public static bool ClickAt(IntPtr window, int x, int y) {
    return PostMouseButtonAt(window, 0x0201, x, y) && PostMouseButtonAt(window, 0x0202, x, y);
  }
  public static bool PostMouseMoveAt(IntPtr window, int clientX, int clientY) {
    return PostMessage(window, 0x0200, UIntPtr.Zero, MouseLParam(clientX, clientY));
  }
  public static bool PostMouseDragMoveAt(IntPtr window, int clientX, int clientY) {
    return PostMessage(window, 0x0200, (UIntPtr)0x0001, MouseLParam(clientX, clientY));
  }
  public static IntPtr SendMouseButtonAt(IntPtr window, uint message, int clientX, int clientY) {
    return SendMessage(window, message, (UIntPtr)0x0001, MouseLParam(clientX, clientY));
  }
  public static bool PostMouseClickAt(IntPtr window, int clientX, int clientY) {
    return PostMouseButtonAt(window, 0x0201, clientX, clientY) &&
      PostMouseButtonAt(window, 0x0202, clientX, clientY);
  }
  public static bool PostRightClickAt(IntPtr window, int clientX, int clientY) {
    IntPtr point = MouseLParam(clientX, clientY);
    return PostMessage(window, 0x0204, (UIntPtr)0x0002, point) &&
      PostMessage(window, 0x0205, UIntPtr.Zero, point);
  }
  public static int[] ClickOwnedScreenRectangle(IntPtr owner, int left, int top, int right, int bottom, bool rightClick) { return InputSafety.ClickOwnedScreenRectangle(owner, left, top, right, bottom, rightClick); }
  public static bool PostOwnedScreenPoint(IntPtr owner, int screenX, int screenY, bool rightClick) {
    if (!WindowIsVisible(owner)) return false;
    var point = new ScreenPoint { X = screenX, Y = screenY };
    IntPtr hit = WindowFromPoint(point);
    if (hit == IntPtr.Zero || GetAncestor(hit, 2) != owner || !ScreenToClient(owner, ref point))
      return false;
    if (rightClick) {
      return PostMessage(owner, 0x0204, (UIntPtr)0x0002, MouseLParam(point.X, point.Y)) &&
        PostMessage(owner, 0x0205, UIntPtr.Zero, MouseLParam(point.X, point.Y));
    }
    return PostMessage(owner, 0x0201, (UIntPtr)0x0001, MouseLParam(point.X, point.Y)) &&
      PostMessage(owner, 0x0202, UIntPtr.Zero, MouseLParam(point.X, point.Y));
  }
  public static bool IsOwnedPopupInput(
    IntPtr owner, IntPtr popup, uint expectedProcessId, uint popupProcessId,
    uint foregroundProcessId, IntPtr foregroundRoot, uint pointProcessId,
    IntPtr pointRoot, bool popupVisible
  ) { return UiaInputSafety.IsOwnedPopupInput(owner, popup, expectedProcessId, popupProcessId, foregroundProcessId, foregroundRoot, pointProcessId, pointRoot, popupVisible); }

  public static PopupItemHit ClickPopupMenuItem(IntPtr popup, IntPtr owner, int position, int commandId, uint expectedProcessId) { return InputSafety.ClickPopupMenuItem(popup, owner, position, commandId, expectedProcessId); }
  public static PopupItemHit ClickPopupMenuItemStrict(IntPtr popup, IntPtr owner, int position, int commandId, uint expectedProcessId) { return InputSafety.ClickPopupMenuItemStrict(popup, owner, position, commandId, expectedProcessId); }
  private static void RequireOwnedPopupForeground(IntPtr popup, IntPtr owner, uint expectedProcessId) { InputSafety.RequireOwnedPopupForeground(popup, owner, expectedProcessId); }
  // Sidebar.updateBannerRect/updateBannerAt are pixel-only hit-test geometry with
  // no UIA identity of their own, so a genuine click requires the real live client
  // height rather than an assumed window size.
  public static int ClientHeight(IntPtr window) {
    RECT rect;
    if (window == IntPtr.Zero || !GetClientRect(window, out rect)) return 0;
    return rect.Bottom - rect.Top;
  }
  // Posts the WM_MOUSEWHEEL the OS delivers to the window under the cursor. Its
  // lParam is in screen coordinates; delta is in wheel units (negative scrolls
  // content up, so the sidebar advances).
  [DllImport("user32.dll")]
  private static extern bool ClientToScreen(IntPtr window, ref ScreenPoint point);
  public static bool WheelAt(IntPtr window, int clientX, int clientY, int delta) {
    var point = new ScreenPoint { X = clientX, Y = clientY };
    if (window == IntPtr.Zero || !ClientToScreen(window, ref point)) return false;
    return PostMessage(window, 0x020A, new UIntPtr((uint)((delta & 0xFFFF) << 16)), MouseLParam(point.X, point.Y));
  }

  [DllImport("user32.dll")]
  private static extern bool GetClientRect(IntPtr window, out RECT rect);
  [DllImport("user32.dll")]
  private static extern IntPtr GetMenu(IntPtr window);
  [DllImport("user32.dll")]
  private static extern IntPtr GetSubMenu(IntPtr menu, int position);
  public static IntPtr NativeMenu(IntPtr window) {
    return window == IntPtr.Zero ? IntPtr.Zero : GetMenu(window);
  }
  public static IntPtr NativeSubMenu(IntPtr menu, int position) {
    return menu == IntPtr.Zero ? IntPtr.Zero : GetSubMenu(menu, position);
  }
  // App.zig only rebuilds recent_folders (and the rest of the native chrome)
  // from the live GraphModel on WM_INITMENUPOPUP - the same message real
  // Windows sends right before a menu bar popup is displayed. Reading the
  // HMENU without first sending this leaves it holding whatever was current
  // the last time a menu was actually opened (or, at startup, an empty
  // "No recent folders" placeholder installed before the fixture loaded).
  // Sending it here reproduces the exact real trigger, not a shortcut.
  public static void RefreshNativeMenuFromLiveModel(IntPtr window, IntPtr menu) {
    SendMessage(window, 0x0117, (UIntPtr)(ulong)menu.ToInt64(), IntPtr.Zero);
  }

  [DllImport("user32.dll")]
  private static extern bool ScreenToClient(IntPtr window, ref ScreenPoint point);
  [DllImport("user32.dll")]
  private static extern bool IsIconic(IntPtr window);
  public static bool IsWindowMinimized(IntPtr window) { return IsIconic(window); }
  public static bool ScreenToClientPoint(IntPtr window, int screenX, int screenY, out int clientX, out int clientY) {
    var point = new ScreenPoint { X = screenX, Y = screenY };
    bool ok = ScreenToClient(window, ref point);
    clientX = point.X;
    clientY = point.Y;
    return ok;
  }
  public static int[] ClientScreenBounds(IntPtr window) {
    RECT rect;
    if (window == IntPtr.Zero || !GetClientRect(window, out rect)) return null;
    var topLeft = new ScreenPoint { X = rect.Left, Y = rect.Top };
    var bottomRight = new ScreenPoint { X = rect.Right, Y = rect.Bottom };
    if (!ClientToScreen(window, ref topLeft) || !ClientToScreen(window, ref bottomRight))
      return null;
    return new[] { topLeft.X, topLeft.Y, bottomRight.X, bottomRight.Y };
  }
  public static bool PostCommand(IntPtr window, uint command) {
    return PostMessage(window, 0x0111, (UIntPtr)command, IntPtr.Zero);
  }
  public static bool PostClose(IntPtr window) {
    return PostMessage(window, 0x0010, UIntPtr.Zero, IntPtr.Zero);
  }
  public static bool SetFirstEditText(IntPtr parent, string text) {
    var edit = FindWindowEx(parent, IntPtr.Zero, "Edit", null);
    return edit != IntPtr.Zero && SetEditTextById(parent, GetDlgCtrlID(edit), text);
  }
  public static bool SetEditTextById(IntPtr parent, int controlId, string text) {
    var edit = ControlById(parent, controlId);
    // Cross-process SetWindowText only updates the stored caption; WM_SETTEXT reaches the EDIT buffer.
    if (edit == IntPtr.Zero || SendMessageString(edit, 0x000C, UIntPtr.Zero, text) == IntPtr.Zero) return false;
    ulong command = ((ulong)0x0300 << 16) | (uint)controlId;
    SendMessage(parent, 0x0111, (UIntPtr)command, edit);
    return true;
  }
  public static string EditTextById(IntPtr parent, int controlId) {
    var edit = ControlById(parent, controlId);
    if (edit == IntPtr.Zero) return null;
    return EditBufferText(edit);
  }
  private static string EditBufferText(IntPtr edit) {
    // Cross-process GetWindowText returns the stored caption; WM_GETTEXT reads the EDIT buffer.
    int length = (int)SendMessage(edit, 0x000E, UIntPtr.Zero, IntPtr.Zero);
    var text = new StringBuilder(length + 1);
    SendMessageText(edit, 0x000D, (UIntPtr)text.Capacity, text);
    return text.ToString();
  }
  public static string FirstEditText(IntPtr parent) {
    var edit = ControlById(parent, 9100);
    if (edit == IntPtr.Zero) edit = ControlById(parent, 9904);
    if (edit == IntPtr.Zero) edit = FindWindowEx(parent, IntPtr.Zero, "Edit", null);
    if (edit == IntPtr.Zero) return null;
    return EditBufferText(edit);
  }
  // Node creation sheet helpers. Every click below is a real cursor move plus
  // SendInput at the live window rectangle of the target control, and the
  // window under that point is checked first so a covered or mis-scaled target
  // fails instead of silently clicking something else.
  [DllImport("user32.dll")]
  private static extern bool GetWindowRect(IntPtr window, out RECT rect);
  [DllImport("user32.dll")]
  private static extern IntPtr WindowFromPoint(ScreenPoint point);
  private delegate bool EnumChildProc(IntPtr window, IntPtr parameter);
  [DllImport("user32.dll")]
  private static extern bool EnumChildWindows(IntPtr parent, EnumChildProc callback, IntPtr parameter);

  // INPUT is a union sized by MOUSEINPUT; the trailing padding keeps this
  // keyboard record the same size so SendInput accepts cbSize.

  [DllImport("user32.dll", SetLastError = true, EntryPoint = "SendInput")]
  private static extern uint SendKeyInputs(uint count, KeyInputRecord[] inputs, int size);
  [DllImport("user32.dll", SetLastError = true, EntryPoint = "SystemParametersInfoW")]
  private static extern bool SystemParametersInfoRect(uint action, uint param, out RECT rect, uint winIni);
  [DllImport("user32.dll")]
  private static extern IntPtr GetAncestor(IntPtr window, uint flags);
  [DllImport("user32.dll")]
  private static extern IntPtr RealChildWindowFromPoint(IntPtr parent, ScreenPoint clientPoint);
  [DllImport("user32.dll")]
  private static extern IntPtr GetWindow(IntPtr window, uint command);
  [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
  private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
  public sealed class ControlClick {
    public int ControlId, Left, Top, Right, Bottom, ScreenX, ScreenY;
    public int CursorBeforeX, CursorBeforeY, CursorAtX, CursorAtY;
    public bool HitTarget;
    public int WindowAtPointId;
    public string WindowAtPointClass, WindowAtPointRootClass, WindowAtPointText;
    public int WindowAtPointProcessId;
    public int RealChildId;
    public string RealChildClass, RealChildText;
    public bool SameTopLevel;
    public bool VisibleEmpty;
    public int WorkLeft, WorkTop, WorkRight, WorkBottom;
    public bool OutsideWorkArea;
    public int CenterX, CenterY;
    public bool CenterHitTarget;
    public string WindowAtCenterClass, WindowAtCenterRootClass;
    public bool ScanUsed;
    public int ScannedPoints, CoveredPoints;
    public int CoveringId, CoveringLeft, CoveringTop, CoveringRight, CoveringBottom;
    public string CoveringClass, CoveringText;
    public string[] Samples;
    public string[] CoveringWindows;
    public int[][] UncoveredRectangles;
    public int[] ChosenUncoveredRectangle;
    public bool NarrowUncovered;
  }
  public static int[][] SubtractCoveredRectangles(int[] visible, int[][] covers) {
    var remaining = new System.Collections.ArrayList();
    if (visible[2] > visible[0] && visible[3] > visible[1]) remaining.Add(visible);
    foreach (int[] cover in covers) {
      var next = new System.Collections.ArrayList();
      foreach (int[] piece in remaining) {
        int left = Math.Max(piece[0], cover[0]), top = Math.Max(piece[1], cover[1]);
        int right = Math.Min(piece[2], cover[2]), bottom = Math.Min(piece[3], cover[3]);
        if (left >= right || top >= bottom) { next.Add(piece); continue; }
        if (piece[0] < left) next.Add(new[] { piece[0], piece[1], left, piece[3] });
        if (right < piece[2]) next.Add(new[] { right, piece[1], piece[2], piece[3] });
        if (piece[1] < top) next.Add(new[] { left, piece[1], right, top });
        if (bottom < piece[3]) next.Add(new[] { left, bottom, right, piece[3] });
      }
      remaining = next;
    }
    var result = new int[remaining.Count][];
    remaining.CopyTo(result);
    Array.Sort(result, delegate(int[] a, int[] b) {
      long areaA = (long)(a[2] - a[0]) * (a[3] - a[1]);
      long areaB = (long)(b[2] - b[0]) * (b[3] - b[1]);
      int byArea = areaB.CompareTo(areaA);
      if (byArea != 0) return byArea;
      int byTop = a[1].CompareTo(b[1]);
      return byTop != 0 ? byTop : a[0].CompareTo(b[0]);
    });
    return result;
  }
  private static IntPtr ResolveChild(IntPtr dialog, ScreenPoint point) {
    var clientPoint = point;
    if (!ScreenToClient(dialog, ref clientPoint)) return IntPtr.Zero;
    return RealChildWindowFromPoint(dialog, clientPoint);
  }
  private static bool ResolvesToControl(IntPtr target, IntPtr dialog, ScreenPoint point) {
    IntPtr parent = GetAncestor(target, 1);
    IntPtr root = GetAncestor(target, 2);
    uint processId = WindowProcessId(target);
    RECT bounds;
    if (target == IntPtr.Zero || parent == IntPtr.Zero || root == IntPtr.Zero || processId == 0 ||
        (dialog != parent && dialog != root) || GetAncestor(parent, 2) != root ||
        WindowProcessId(parent) != processId || WindowProcessId(root) != processId ||
        !IsRetainedProcessAlive(processId) || !GetWindowRect(target, out bounds) ||
        point.X < bounds.Left || point.X >= bounds.Right || point.Y < bounds.Top || point.Y >= bounds.Bottom)
      return false;
    IntPtr atPoint = WindowFromPoint(point);
    if (atPoint == IntPtr.Zero || GetAncestor(atPoint, 2) != root || WindowProcessId(atPoint) != processId) return false;
    dialog = parent;
    var clientPoint = point;
    if (!ScreenToClient(dialog, ref clientPoint) || GetAncestor(target, 1) != parent ||
        GetAncestor(target, 2) != root || WindowProcessId(target) != processId) return false;
    return RealChildWindowFromPoint(dialog, clientPoint) == target;
  }
  private static IntPtr RequireControlClickRoot(IntPtr target, IntPtr parent) {
    IntPtr root = GetAncestor(target, 2);
    uint processId = WindowProcessId(target);
    if (target == IntPtr.Zero || parent == IntPtr.Zero || root == IntPtr.Zero ||
        GetAncestor(target, 1) != parent || GetAncestor(parent, 2) != root ||
        processId == 0 || WindowProcessId(parent) != processId || WindowProcessId(root) != processId ||
        !IsRetainedProcessAlive(processId))
      throw new InvalidOperationException("Control click target lost its exact parent/root ownership; no input was injected");
    return root;
  }
  private static string ClassOf(IntPtr window) {
    if (window == IntPtr.Zero) return "";
    var name = new StringBuilder(128);
    GetClassName(window, name, name.Capacity);
    return name.ToString();
  }
  public static int[] WindowBounds(IntPtr window) {
    RECT rect;
    if (window == IntPtr.Zero || !GetWindowRect(window, out rect)) return null;
    return new[] { rect.Left, rect.Top, rect.Right, rect.Bottom };
  }
  public static IntPtr ControlById(IntPtr parent, int controlId) {
    if (parent == IntPtr.Zero) return IntPtr.Zero;
    IntPtr direct = GetDlgItem(parent, controlId);
    if (direct != IntPtr.Zero) return direct;
    if (!String.Equals(ClassOf(parent), "GraphCodeSheetHost", StringComparison.Ordinal))
      return IntPtr.Zero;
    IntPtr viewport = FindWindowEx(parent, IntPtr.Zero, "GraphCodeSheetViewport", null);
    if (viewport == IntPtr.Zero) return IntPtr.Zero;
    string[] contentClasses = new[] {
      "GraphCodeWindowsDialogContent",
      "GraphCodeNativeForm",
      "GraphCodeProductSettings",
      "GraphCodeWorkspaceManager",
      "GraphCodeRepositoryIngressDialog",
      "GraphCodeRepositoryOperationDialog",
      "GraphCodeCodespaceIngressDialog",
      "GraphCodeUpdateOffer",
      "GraphCodeUpdateInstall"
    };
    foreach (string contentClass in contentClasses) {
      IntPtr content = FindWindowEx(viewport, IntPtr.Zero, contentClass, null);
      if (content == IntPtr.Zero) continue;
      IntPtr nested = GetDlgItem(content, controlId);
      if (nested != IntPtr.Zero) return nested;
    }
    return IntPtr.Zero;
  }
  public static ControlClick ClickScreenPoint(IntPtr target) {
    RECT rect;
    if (target == IntPtr.Zero || !GetWindowRect(target, out rect) ||
        rect.Right <= rect.Left || rect.Bottom <= rect.Top) return null;
    RECT work;
    if (!SystemParametersInfoRect(0x0030, 0, out work, 0))
      throw new InvalidOperationException(String.Format("SPI_GETWORKAREA failed: Win32Error={0}", Marshal.GetLastWin32Error()));
    var rectCenter = new ScreenPoint { X = (rect.Left + rect.Right) / 2, Y = (rect.Top + rect.Bottom) / 2 };
    IntPtr atRectCenter = WindowFromPoint(rectCenter);
    // A user clicks the part of a control they can see. When the control lies
    // inside the work area this is exactly its centre; only when it crosses the
    // work-area edge does the point move into the visible portion. A control with
    // no visible portion is reported as VisibleEmpty and never clicked.
    int visibleLeft = Math.Max(rect.Left, work.Left), visibleTop = Math.Max(rect.Top, work.Top);
    int visibleRight = Math.Min(rect.Right, work.Right), visibleBottom = Math.Min(rect.Bottom, work.Bottom);
    var center = new ScreenPoint { X = (visibleLeft + visibleRight) / 2, Y = (visibleTop + visibleBottom) / 2 };
    bool visibleEmpty = visibleRight <= visibleLeft || visibleBottom <= visibleTop;
    IntPtr atPoint = visibleEmpty ? IntPtr.Zero : WindowFromPoint(center);
    IntPtr rootAtPoint = atPoint == IntPtr.Zero ? IntPtr.Zero : GetAncestor(atPoint, 2);
    uint ownerProcess = 0;
    if (rootAtPoint != IntPtr.Zero) GetWindowThreadProcessId(rootAtPoint, out ownerProcess);
    // Real mouse input skips HTTRANSPARENT children such as plain static text;
    // cross-process WindowFromPoint does not. RealChildWindowFromPoint applies
    // the same rule within the dialog, and the top-level check still rejects
    // any other window (for example the taskbar) covering the point.
    IntPtr dialog = GetAncestor(target, 1);
    IntPtr realChild = IntPtr.Zero;
    if (!visibleEmpty && dialog != IntPtr.Zero) {
      var clientPoint = center;
      if (ScreenToClient(dialog, ref clientPoint)) realChild = RealChildWindowFromPoint(dialog, clientPoint);
    }
    bool sameTopLevel = rootAtPoint != IntPtr.Zero && rootAtPoint == GetAncestor(target, 2);
    var hit = new ControlClick {
      ControlId = GetDlgCtrlID(target), Left = rect.Left, Top = rect.Top, Right = rect.Right,
      Bottom = rect.Bottom, ScreenX = center.X, ScreenY = center.Y,
      HitTarget = !visibleEmpty && sameTopLevel && realChild == target,
      VisibleEmpty = visibleEmpty,
      WindowAtPointId = atPoint == IntPtr.Zero ? 0 : GetDlgCtrlID(atPoint),
      WindowAtPointClass = ClassOf(atPoint),
      WindowAtPointText = atPoint == IntPtr.Zero ? "" : EditBufferText(atPoint),
      WindowAtPointRootClass = ClassOf(rootAtPoint),
      WindowAtPointProcessId = (int)ownerProcess,
      RealChildId = realChild == IntPtr.Zero ? 0 : GetDlgCtrlID(realChild),
      RealChildClass = ClassOf(realChild),
      RealChildText = realChild == IntPtr.Zero ? "" : EditBufferText(realChild),
      SameTopLevel = sameTopLevel,
      WorkLeft = work.Left, WorkTop = work.Top, WorkRight = work.Right, WorkBottom = work.Bottom,
      OutsideWorkArea = rect.Left < work.Left || rect.Top < work.Top || rect.Right > work.Right || rect.Bottom > work.Bottom,
      CenterX = rectCenter.X, CenterY = rectCenter.Y,
      CenterHitTarget = atRectCenter == target,
      WindowAtCenterClass = ClassOf(atRectCenter),
      WindowAtCenterRootClass = ClassOf(atRectCenter == IntPtr.Zero ? IntPtr.Zero : GetAncestor(atRectCenter, 2))
    };
    // Subtract visible siblings above the target in Z order. A narrow uncovered
    // strip can fall between grid rows, so try the largest residual rectangle
    // before scanning the fixed grid as a diagnostic fallback.
    if (!hit.HitTarget && !visibleEmpty && dialog != IntPtr.Zero) {
      IntPtr covering = realChild != IntPtr.Zero && realChild != target && realChild != dialog ? realChild : atPoint;
      RECT coveringRect;
      if (covering != IntPtr.Zero && GetWindowRect(covering, out coveringRect)) {
        hit.CoveringLeft = coveringRect.Left; hit.CoveringTop = coveringRect.Top;
        hit.CoveringRight = coveringRect.Right; hit.CoveringBottom = coveringRect.Bottom;
      }
      hit.CoveringId = covering == IntPtr.Zero ? 0 : GetDlgCtrlID(covering);
      hit.CoveringClass = ClassOf(covering);
      hit.CoveringText = covering == IntPtr.Zero ? "" : EditBufferText(covering);
      var covers = new System.Collections.ArrayList();
      var coveringWindows = new System.Collections.ArrayList();
      for (IntPtr sibling = GetWindow(target, 3); sibling != IntPtr.Zero; sibling = GetWindow(sibling, 3)) {
        RECT siblingRect;
        if (!IsWindowVisible(sibling) || !GetWindowRect(sibling, out siblingRect)) continue;
        int left = Math.Max(visibleLeft, siblingRect.Left), top = Math.Max(visibleTop, siblingRect.Top);
        int right = Math.Min(visibleRight, siblingRect.Right), bottom = Math.Min(visibleBottom, siblingRect.Bottom);
        if (left >= right || top >= bottom) continue;
        var overlapCenter = new ScreenPoint { X = (left + right) / 2, Y = (top + bottom) / 2 };
        if (ResolveChild(dialog, overlapCenter) != sibling) continue;
        covers.Add(new[] { siblingRect.Left, siblingRect.Top, siblingRect.Right, siblingRect.Bottom });
        coveringWindows.Add(String.Format("{0}|{1}|{2}|{3},{4},{5},{6}", GetDlgCtrlID(sibling),
          ClassOf(sibling), EditBufferText(sibling), siblingRect.Left, siblingRect.Top, siblingRect.Right, siblingRect.Bottom));
      }
      hit.CoveringWindows = (string[])coveringWindows.ToArray(typeof(string));
      hit.UncoveredRectangles = SubtractCoveredRectangles(new[] { visibleLeft, visibleTop, visibleRight, visibleBottom },
        (int[][])covers.ToArray(typeof(int[])));
      foreach (int[] piece in hit.UncoveredRectangles) {
        var candidate = new ScreenPoint { X = (piece[0] + piece[2]) / 2, Y = (piece[1] + piece[3]) / 2 };
        if (!ResolvesToControl(target, dialog, candidate)) continue;
        if (piece[2] - piece[0] < 3 || piece[3] - piece[1] < 3) {
          hit.NarrowUncovered = true;
          continue;
        }
        center = candidate;
        hit.ScreenX = candidate.X; hit.ScreenY = candidate.Y;
        hit.HitTarget = true;
        hit.ScanUsed = true;
        hit.ChosenUncoveredRectangle = piece;
        break;
      }
      int width = visibleRight - visibleLeft, height = visibleBottom - visibleTop;
      var samples = new string[15];
      for (int row = 1; row <= 3; row++) {
        for (int column = 1; column <= 5; column++) {
          var candidate = new ScreenPoint { X = visibleLeft + column * width / 6, Y = visibleTop + row * height / 4 };
          IntPtr resolved = ResolveChild(dialog, candidate);
          bool uncovered = ResolvesToControl(target, dialog, candidate);
          if (uncovered && hit.NarrowUncovered) uncovered = false;
          samples[hit.ScannedPoints++] = String.Format("{0},{1}|{2}|{3}|{4}|{5}", candidate.X, candidate.Y,
            resolved == IntPtr.Zero ? 0 : GetDlgCtrlID(resolved), ClassOf(resolved), uncovered ? "control" : "covered",
            resolved == IntPtr.Zero ? "" : EditBufferText(resolved));
          if (!uncovered) {
            hit.CoveredPoints++;
          } else if (!hit.HitTarget) {
            center = candidate;
            hit.ScreenX = candidate.X; hit.ScreenY = candidate.Y;
            hit.HitTarget = true;
            hit.ScanUsed = true;
          }
        }
      }
      hit.Samples = samples;
    }
    if (!hit.HitTarget) return hit;
    IntPtr inputRoot = RequireControlClickRoot(target, dialog);
    uint expectedProcessId = WindowProcessId(inputRoot);
    RequireOwnedForeground(inputRoot, expectedProcessId);
    ScreenPoint before, at;
    if (!GetCursorPos(out before))
      throw new InvalidOperationException(String.Format("GetCursorPos before control click failed: Win32Error={0}", Marshal.GetLastWin32Error()));
    if (!SetCursorPos(center.X, center.Y))
      throw new InvalidOperationException(String.Format("SetCursorPos for control click failed: Win32Error={0}", Marshal.GetLastWin32Error()));
    if (!GetCursorPos(out at))
      throw new InvalidOperationException(String.Format("GetCursorPos after control move failed: Win32Error={0}", Marshal.GetLastWin32Error()));
    if (at.X != center.X || at.Y != center.Y)
      throw new InvalidOperationException(String.Format("Control cursor landed at ({0},{1}), expected ({2},{3})", at.X, at.Y, center.X, center.Y));
    hit.CursorBeforeX = before.X; hit.CursorBeforeY = before.Y;
    hit.CursorAtX = at.X; hit.CursorAtY = at.Y;
    var inputs = new[] {
      new Input { Type = 0, Mouse = new MouseInput { Flags = 0x0002 } },
      new Input { Type = 0, Mouse = new MouseInput { Flags = 0x0004 } }
    };
    if (RequireControlClickRoot(target, dialog) != inputRoot)
      throw new InvalidOperationException("Control click target root changed; no input was injected");
    RequireOwnedMouseInput(inputRoot, expectedProcessId, center, target);
    uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(Input)));
    if (sent != inputs.Length)
      throw new InvalidOperationException(String.Format("SendInput injected {0} of {1} control mouse events: Win32Error={2}", sent, inputs.Length, Marshal.GetLastWin32Error()));
    return hit;
  }
  public static int SendKeyInput(IntPtr owner, uint expectedProcessId, IntPtr expectedFocus, ushort virtualKey, int count) { return InputSafety.SendKeyInput(owner, expectedProcessId, expectedFocus, virtualKey, count); }
  public static int SendKeyInput(IntPtr owner, uint expectedProcessId, IntPtr expectedFocus, ushort virtualKey, int count, bool controlModifier) { return InputSafety.SendKeyInput(owner, expectedProcessId, expectedFocus, virtualKey, count, controlModifier); }
  public static int[] SendUnicodeInput(IntPtr owner, uint expectedProcessId, IntPtr expectedFocus, string text) { return InputSafety.SendUnicodeInput(owner, expectedProcessId, expectedFocus, text); }
  public static bool TypeEditTextById(IntPtr parent, int controlId, string text) { return InputSafety.TypeEditTextById(parent, controlId, text); }
  public static int[] VisibleChildIds(IntPtr parent, int first, int last) {
    var buffer = new int[Math.Max(0, last - first + 1)];
    int found = 0;
    for (int id = first; id <= last; id++) {
      IntPtr child = ControlById(parent, id);
      if (child != IntPtr.Zero && IsWindowVisible(child)) buffer[found++] = id;
    }
    var result = new int[found];
    Array.Copy(buffer, result, found);
    return result;
  }
  public static string[] VisibleStaticTexts(IntPtr parent) {
    var buffer = new string[256];
    int found = 0;
    if (parent == IntPtr.Zero) return new string[0];
    EnumChildWindows(parent, delegate(IntPtr window, IntPtr parameter) {
      var actualClass = new StringBuilder(64);
      GetClassName(window, actualClass, actualClass.Capacity);
      if (String.Equals(actualClass.ToString(), "Static", StringComparison.OrdinalIgnoreCase) &&
          IsWindowVisible(window) && found < buffer.Length) {
        buffer[found++] = EditBufferText(window);
      }
      return true;
    }, IntPtr.Zero);
    var result = new string[found];
    Array.Copy(buffer, result, found);
    return result;
  }
  public static string WindowTextOf(IntPtr window) {
    return window == IntPtr.Zero ? null : EditBufferText(window);
  }
  public static string ComboSelection(IntPtr parent, int controlId) {
    IntPtr combo = ControlById(parent, controlId);
    if (combo == IntPtr.Zero) return null;
    int index = (int)SendMessage(combo, 0x0147, UIntPtr.Zero, IntPtr.Zero);
    if (index < 0) return index + "|";
    int length = (int)SendMessage(combo, 0x0149, (UIntPtr)index, IntPtr.Zero);
    var text = new StringBuilder(Math.Max(length, 0) + 1);
    SendMessageText(combo, 0x0148, (UIntPtr)index, text);
    return index + "|" + text.ToString();
  }
}
