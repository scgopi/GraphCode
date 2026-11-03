#nullable disable
using System;
using static GraphCode.Windows.UiaInputSafety;
using GraphCode.Windows;
namespace GraphCode.Validation.Ui.Fixtures {
public sealed class InputFixture : IUiaInputOperations {






  public bool Alive, Foreground, Visible, Enabled, FocusOnSelect, FocusOnRead, HitLoss, CursorLoss, Covered, Hover;
  public int Injected, HitQueries, CursorQueries, Moves;
  public IntPtr Focus;
  public ScreenPoint Cursor;
  public void Reset() {
    Alive = Foreground = Visible = Enabled = true;
    FocusOnSelect = FocusOnRead = HitLoss = CursorLoss = Covered = Hover = false;
    Injected = HitQueries = CursorQueries = Moves = 0; Focus = new IntPtr(20); Cursor = new ScreenPoint { X = 5, Y = 5 };
  }
  public bool IsRetainedProcessAlive(uint pid) { return Alive && pid == 123; }
  public uint WindowProcessId(IntPtr window) {
    return window == new IntPtr(10) || window == new IntPtr(20) || window == new IntPtr(21) || window == new IntPtr(30) ? 123u : 999u;
  }
  public bool WindowIsVisible(IntPtr window) { return Visible; }
  public bool WindowIsEnabled(IntPtr window) { return Enabled; }
  public IntPtr GetForegroundWindow() { return new IntPtr(Foreground ? 10 : 99); }
  public IntPtr FocusedControlInDialog(IntPtr window) { return Focus; }
  public IntPtr GetAncestor(IntPtr window, uint flag) {
    if (window == new IntPtr(30)) return window;
    return window == new IntPtr(10) || window == new IntPtr(20) || window == new IntPtr(21) ? new IntPtr(10) : new IntPtr(99);
  }
  public bool GetCursorPos(out ScreenPoint point) {
    CursorQueries++; point = Cursor; if (CursorLoss && CursorQueries > 1) point.X++; return true;
  }
  public bool SetCursorPos(int x, int y) { Moves++; Cursor = new ScreenPoint { X = x, Y = y }; return true; }
  public IntPtr WindowFromPoint(ScreenPoint point) {
    HitQueries++; return new IntPtr(Covered || (HitLoss && HitQueries > 1) ? 99 : (Hover ? 30 : 20));
  }
  public bool IsWindowVisible(IntPtr window) { return Visible; }
  public bool GetMenuItemRect(IntPtr owner, IntPtr menu, uint position, out RECT item) {
    item = new RECT { Left = 0, Top = 0, Right = 10, Bottom = 10 }; return true;
  }
  public uint GetWindowThreadProcessId(IntPtr owner, out uint pid) { pid = WindowProcessId(owner); return 1; }
  public IntPtr FindPopupForMenu(uint pid, IntPtr menu) { return new IntPtr(30); }
  public bool ScreenToClient(IntPtr popup, ref ScreenPoint point) { return true; }
  public IntPtr MouseLParam(int x, int y) { return IntPtr.Zero; }
  public uint GetMenuState(IntPtr menu, uint position, uint flags) { return 0x80; }
  public void Sleep(uint milliseconds) {}
  public bool ResolvesToControl(IntPtr target, IntPtr owner, ScreenPoint point) { return target == new IntPtr(20); }
  public uint SendInput(uint count, Input[] inputs, int size) { Injected++; return count; }
  public uint SendKeyInputs(uint count, KeyInputRecord[] inputs, int size) { Injected++; return count; }
  public IntPtr ControlById(IntPtr owner, int id) { return new IntPtr(20); }
  public bool FocusControl(IntPtr owner, IntPtr edit) { Focus = edit; return true; }
  public IntPtr SendMessage(IntPtr edit, uint message, UIntPtr first, IntPtr last) {
    if (FocusOnSelect) Focus = new IntPtr(99); return IntPtr.Zero;
  }
  public string EditBufferText(IntPtr edit) { if (FocusOnRead) Focus = new IntPtr(99); return ""; }
  public string EditTextById(IntPtr owner, int id) { return "test"; }
  public IntPtr SendMessageString(IntPtr edit, uint message, UIntPtr first, string text) { return IntPtr.Zero; }

  public IntPtr PopupMenuHandle(IntPtr popup) => throw new InvalidOperationException("Input fixture does not test popup clicks");
  public uint PopupMenuItemId(IntPtr menu, int position) => throw new InvalidOperationException("Input fixture does not test popup clicks");
  public bool PostMessage(IntPtr window, uint message, UIntPtr first, IntPtr last) => throw new InvalidOperationException("Input fixture does not post keyboard input");
}
}
