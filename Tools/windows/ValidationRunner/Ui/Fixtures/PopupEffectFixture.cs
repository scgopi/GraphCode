#nullable disable
using static GraphCode.Windows.UiaInputSafety;
using GraphCode.Windows;
namespace GraphCode.Validation.Ui.Fixtures {
using System;
using System.Runtime.InteropServices;
public sealed class PopupEffectFixture : IUiaInputOperations {
  public string Scenario = "";
  public int MouseCalls, KeyCalls, CursorMoves;
  public bool Visible;
  public int CursorX, CursorY, CursorReads, ForegroundReads;
  public void Reset(string scenario) {
    Scenario = scenario; MouseCalls = KeyCalls = CursorMoves = 0;
    Visible = scenario != "hidden-popup"; CursorX = CursorY = CursorReads = ForegroundReads = 0;
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
  public IntPtr SendMessage(IntPtr window, uint message, UIntPtr wparam, IntPtr lparam) { return IntPtr.Zero; }
  public IntPtr MouseLParam(int x, int y) { return (IntPtr)((y << 16) | x); }
  public uint GetMenuState(IntPtr menu, uint position, uint flags) { return 128; }
  public void Sleep(uint milliseconds) { }
  public uint SendInput(uint count, Input[] inputs, int size) {
    MouseCalls++; Visible = Scenario == "foreign-before-enter" || Scenario == "owned-enter"; return count;
  }
  public bool IsWindowVisible(IntPtr popup) { return Visible; }
  public bool PostMessage(IntPtr window, uint message, UIntPtr wparam, IntPtr lparam) { KeyCalls++; return true; }
  public IntPtr GetForegroundWindow() {
    ForegroundReads++;
    return Scenario == "foreign-foreground" ||
      (Scenario == "foreign-after-hover" && ForegroundReads == 2) ||
      (Scenario == "foreign-before-enter" && ForegroundReads == 3) ? (IntPtr)99 : (IntPtr)42;
  }
  public IntPtr WindowFromPoint(ScreenPoint point) { return Scenario == "underlying-shell-hit" ? (IntPtr)42 : (IntPtr)44; }
  public bool IsRetainedProcessAlive(uint processId) { return processId == 4242 && Scenario != "foreign-owner-all"; }
  public uint WindowProcessId(IntPtr window) {
    return Scenario == "foreign-owner-all" || window == (IntPtr)99 ||
      (window == (IntPtr)44 && Scenario == "foreign-hit") ? 7777u : 4242u;
  }
  public IntPtr GetAncestor(IntPtr window, uint flags) { return window == (IntPtr)44 ? (IntPtr)43 : window; }
  public bool WindowIsVisible(IntPtr window) => IsWindowVisible(window);
  public bool WindowIsEnabled(IntPtr window) => throw new InvalidOperationException("Not a popup operation");
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
