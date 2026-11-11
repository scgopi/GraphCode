#nullable disable
using static GraphCode.Windows.UiaInputSafety;
using GraphCode.Windows;
namespace GraphCode.Validation.Ui.Fixtures {
using System;
using System.Runtime.InteropServices;
public sealed class PopupEffectFixture : IUiaInputOperations {
  public string Scenario = "";
  public int MouseCalls, KeyCalls, CursorMoves, SelectItemCalls, MovePosts, MoveSends;
  public bool Visible;
  public int CursorX, CursorY, CursorReads, ForegroundReads;
  public uint? ReturnedCommand;
  public void Reset(string scenario) {
    Scenario = scenario; MouseCalls = KeyCalls = CursorMoves = SelectItemCalls = MovePosts = MoveSends = 0;
    Visible = scenario != "hidden-popup"; CursorX = CursorY = CursorReads = ForegroundReads = 0;
    ReturnedCommand = null;
  }




  public IntPtr PopupMenuHandle(IntPtr popup) { return (IntPtr)7; }
  public bool GetMenuItemRect(IntPtr owner, IntPtr menu, uint position, out RECT item) {
    item = new RECT { Left = 100, Top = 100, Right = 300, Bottom = 150 }; return true;
  }
  public uint PopupMenuItemId(IntPtr menu, int position) { return 5103; }
  public bool ScreenToClient(IntPtr popup, ref ScreenPoint point) { point.X -= 100; point.Y -= 100; return true; }
  public bool GetCursorPos(out ScreenPoint point) {
    CursorReads++;
    point = new ScreenPoint { X = CursorX + (Scenario == "cursor-changed" && CursorReads == 3 ? 1 : 0), Y = CursorY };
    return Scenario != "cursor-unreadable" || CursorReads != 3;
  }
  public bool SetCursorPos(int x, int y) { CursorMoves++; CursorX = x; CursorY = y; return true; }
  public IntPtr SendMessage(IntPtr window, uint message, UIntPtr wparam, IntPtr lparam) {
    if (message == 0x01E5) SelectItemCalls++;
    if (message == 0x0200) MoveSends++;
    return IntPtr.Zero;
  }
  public IntPtr MouseLParam(int x, int y) { return (IntPtr)((y << 16) | x); }
  public uint GetMenuState(IntPtr menu, uint position, uint flags) {
    return Scenario == "invalid-state" ? uint.MaxValue :
      Scenario == "native-hover" && CursorMoves == 0 ? 0u :
      Scenario == "synthetic-hover" && MovePosts == 0 && MoveSends == 0 ? 0u :
      Scenario == "unhilited" || Scenario == "unhilited-metadata-fault" ? 0u : 128u;
  }
  public void Sleep(uint milliseconds) { }
  public uint SendInput(uint count, Input[] inputs, int size) {
    MouseCalls++; Visible = Scenario == "foreign-before-enter" || Scenario == "owned-enter" ||
      Scenario.StartsWith("modal", StringComparison.Ordinal);
    if (Scenario == "cancel-after-queued-input") ReturnedCommand = 0;
    return count;
  }
  public bool IsWindowVisible(IntPtr popup) { return Visible; }
  public bool PostMessage(IntPtr window, uint message, UIntPtr wparam, IntPtr lparam) {
    if (message == 0x0200) { MovePosts++; return true; }
    KeyCalls++; return true;
  }
  public IntPtr GetForegroundWindow() {
    ForegroundReads++;
    if (Scenario.StartsWith("modal", StringComparison.Ordinal) && MouseCalls > 0) {
      if (Scenario == "modal-no-transition") return (IntPtr)42;
      if (Scenario == "modal-late" && ForegroundReads == 3) return (IntPtr)42;
      if (Scenario != "modal-popup-open") Visible = false;
      return Scenario == "modal-foreign" ? (IntPtr)99 : (IntPtr)45;
    }
    if (Scenario == "unhilited-metadata-fault" && ForegroundReads == 2)
      throw new InvalidOperationException("Owned metadata fixture fault");
    return Scenario == "foreign-foreground" ||
      (Scenario == "cancel-after-queued-input" && MouseCalls > 0) ||
      (Scenario == "foreign-after-hover" && ForegroundReads == 2) ||
      (Scenario == "foreign-before-enter" && ForegroundReads == 3) ? (IntPtr)99 : (IntPtr)42;
  }
  public IntPtr WindowFromPoint(ScreenPoint point) {
    if (Scenario == "cancel-after-queued-input" && MouseCalls > 0) return (IntPtr)99;
    return Scenario == "underlying-shell-hit" ? (IntPtr)42 : (IntPtr)44;
  }
  public bool IsRetainedProcessAlive(uint processId) {
    return processId == 4242 && Scenario != "foreign-owner-all" &&
      !(Scenario == "modal-stale-owner" && MouseCalls > 0);
  }
  public uint WindowProcessId(IntPtr window) {
    return Scenario == "foreign-owner-all" || window == (IntPtr)99 ||
      (window == (IntPtr)45 && Scenario == "modal-wrong-pid") ||
      (window == (IntPtr)44 && Scenario == "foreign-hit") ? 7777u : 4242u;
  }
  public IntPtr GetAncestor(IntPtr window, uint flags) { return window == (IntPtr)44 ? (IntPtr)43 : window; }
  public bool WindowIsVisible(IntPtr window) => window == (IntPtr)45 ? Scenario != "modal-hidden" : IsWindowVisible(window);
  public bool WindowIsEnabled(IntPtr window) => window == (IntPtr)45 && Scenario != "modal-disabled";
  public IntPtr WindowOwner(IntPtr window) => Scenario == "modal-wrong-owner" ? (IntPtr)99 : (IntPtr)42;
  public string WindowClass(IntPtr window) => Scenario == "modal-wrong-class" ? "Other" : "GraphCodeSheetHost";
  public string WindowTitle(IntPtr window) => Scenario == "modal-wrong-title" ? "Other" : "Promote sketch to Goal";
  public IntPtr FocusedControlInDialog(IntPtr window) => throw new InvalidOperationException("Not a popup operation");
  public IntPtr FindPopupForMenu(uint processId, IntPtr menu) => throw new InvalidOperationException("Not a popup operation");
  public bool ResolvesToControl(IntPtr target, IntPtr owner, ScreenPoint point) => throw new InvalidOperationException("Not a popup operation");
  public uint SendKeyInputs(uint count, KeyInputRecord[] inputs, int size) => throw new InvalidOperationException("Not a popup operation");
  public IntPtr ControlById(IntPtr owner, int id) => throw new InvalidOperationException("Not a popup operation");
  public bool FocusControl(IntPtr owner, IntPtr edit) => throw new InvalidOperationException("Not a popup operation");
  public string EditBufferText(IntPtr edit) => throw new InvalidOperationException("Not a popup operation");
  public string EditTextById(IntPtr owner, int id) => throw new InvalidOperationException("Not a popup operation");
  public IntPtr SendMessageString(IntPtr edit, uint message, UIntPtr first, string text) => throw new InvalidOperationException("Not a popup operation");

}
}
#nullable enable
namespace GraphCode.Validation.Ui.Fixtures {
internal sealed class NativePopupEffectWindow : System.Windows.Forms.Form {
  internal const string HostTitle = "GraphCode owned native popup effect fixture";
  internal const uint ExpectedCommand = 5122;
  internal const uint TrackFlags = 0x0100 | 0x0080 | 0x0002;
  private IntPtr menuHandle;
  private int opens, completed, callbacks;
  private int admissionMessages;
  internal IntPtr MenuHandle => System.Threading.Volatile.Read(ref menuHandle);
  internal int Opens => System.Threading.Volatile.Read(ref opens);
  internal int Completed => System.Threading.Volatile.Read(ref completed);
  internal int Callbacks => System.Threading.Volatile.Read(ref callbacks);
  internal uint SelectedCommand { get; private set; }
  internal int NativeError { get; private set; }
  internal Exception? Failure { get; private set; }
  [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
  private static extern IntPtr CreatePopupMenu();
  [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
  private static extern bool AppendMenuW(IntPtr menu, uint flags, UIntPtr command, string text);
  [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
  private static extern uint TrackPopupMenu(IntPtr menu, uint flags, int x, int y, int reserved, IntPtr owner, IntPtr parameters);
  [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
  private static extern bool DestroyMenu(IntPtr menu);

  internal NativePopupEffectWindow() {
    Text = HostTitle;
    AutoScaleMode = System.Windows.Forms.AutoScaleMode.None;
  }
  protected override void WndProc(ref System.Windows.Forms.Message message) {
    if (admissionMessages < 16 && message.Msg is 0x0006 or 0x0021 or 0x0086 or 0x00A1 or 0x00A2 or 0x0201 or 0x0202) {
      admissionMessages++;
      Console.WriteLine("NATIVE_POPUP_ADMISSION_MESSAGE=" + System.Text.Json.JsonSerializer.Serialize(new {
        owner = message.HWnd.ToInt64(), message = message.Msg,
        wparam = message.WParam.ToInt64(), lparam = message.LParam.ToInt64(),
        thread = PromptLookupFixture.GetCurrentThreadId(), at = DateTimeOffset.UtcNow }));
    }
    // Match native button-up routing without WinForms' button-down mouse capture.
    if (message.Msg == 0x0204) return;
    if (message.Msg != 0x0205) { base.WndProc(ref message); return; }
    int sequence = System.Threading.Interlocked.Increment(ref opens);
    IntPtr menu = IntPtr.Zero;
    Exception? primary = null;
    try {
      menu = CreatePopupMenu();
      if (menu == IntPtr.Zero ||
          !AppendMenuW(menu, 0, (UIntPtr)5103u, "Inspect") ||
          !AppendMenuW(menu, 0, (UIntPtr)5113u, "Open Group") ||
          !AppendMenuW(menu, 0, (UIntPtr)ExpectedCommand, "Change to Timed..."))
        throw new InvalidOperationException("Native popup fixture menu construction failed: " +
          System.Runtime.InteropServices.Marshal.GetLastWin32Error());
      var location = PointToScreen(new System.Drawing.Point(
        unchecked((short)message.LParam.ToInt64()), unchecked((short)(message.LParam.ToInt64() >> 16))));
      System.Threading.Volatile.Write(ref menuHandle, menu);
      Console.WriteLine("NATIVE_POPUP_TRACK_BEGIN=" + System.Text.Json.JsonSerializer.Serialize(new {
        sequence, owner = Handle.ToInt64(), menu = menu.ToInt64(), flags = TrackFlags,
        thread = PromptLookupFixture.GetCurrentThreadId(), dpi = PromptLookupFixture.GetDpiForWindow(Handle),
        x = location.X, y = location.Y, at = DateTimeOffset.UtcNow }));
      SelectedCommand = TrackPopupMenu(menu, TrackFlags, location.X, location.Y, 0, Handle, IntPtr.Zero);
      NativeError = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
      if (SelectedCommand == ExpectedCommand) System.Threading.Interlocked.Increment(ref callbacks);
      Console.WriteLine("NATIVE_POPUP_TRACK_RETURN=" + System.Text.Json.JsonSerializer.Serialize(new {
        sequence, selectedCommand = SelectedCommand, callbacks = Callbacks, nativeError = NativeError,
        at = DateTimeOffset.UtcNow }));
    } catch (Exception error) { primary = error; }
    finally {
      System.Threading.Volatile.Write(ref menuHandle, IntPtr.Zero);
      if (menu != IntPtr.Zero && !DestroyMenu(menu)) {
        var cleanup = new InvalidOperationException("Native popup fixture DestroyMenu failed: " +
          System.Runtime.InteropServices.Marshal.GetLastWin32Error());
        primary = primary is null ? cleanup : new AggregateException(primary, cleanup);
      }
      Failure = primary;
      System.Threading.Volatile.Write(ref completed, sequence);
    }
  }
}
}
