#nullable disable
using System;
using System.Runtime.InteropServices;
using static GraphCode.Windows.UiaInputSafety;

namespace GraphCode.Windows {
public interface IUiaInputOperations {
  bool IsRetainedProcessAlive(uint processId);
  uint WindowProcessId(IntPtr window);
  bool WindowIsVisible(IntPtr window);
  bool WindowIsEnabled(IntPtr window);
  IntPtr GetForegroundWindow();
  IntPtr FocusedControlInDialog(IntPtr window);
  IntPtr GetAncestor(IntPtr window, uint flags);
  bool GetCursorPos(out ScreenPoint point);
  bool SetCursorPos(int x, int y);
  IntPtr WindowFromPoint(ScreenPoint point);
  bool IsWindowVisible(IntPtr window);
  bool GetMenuItemRect(IntPtr owner, IntPtr menu, uint position, out RECT item);
  IntPtr FindPopupForMenu(uint processId, IntPtr menu);
  bool ScreenToClient(IntPtr window, ref ScreenPoint point);
  IntPtr MouseLParam(int x, int y);
  uint GetMenuState(IntPtr menu, uint position, uint flags);
  void Sleep(uint milliseconds);
  bool ResolvesToControl(IntPtr target, IntPtr owner, ScreenPoint point);
  uint SendInput(uint count, Input[] inputs, int size);
  uint SendKeyInputs(uint count, KeyInputRecord[] inputs, int size);
  IntPtr ControlById(IntPtr owner, int id);
  bool FocusControl(IntPtr owner, IntPtr edit);
  IntPtr SendMessage(IntPtr edit, uint message, UIntPtr first, IntPtr last);
  string EditBufferText(IntPtr edit);
  string EditTextById(IntPtr owner, int id);
  IntPtr SendMessageString(IntPtr edit, uint message, UIntPtr first, string text);
  IntPtr PopupMenuHandle(IntPtr popup);
  uint PopupMenuItemId(IntPtr menu, int position);
  bool PostMessage(IntPtr window, uint message, UIntPtr first, IntPtr last);
}
public sealed class UiaInputSafety {
  private readonly IUiaInputOperations operations;
  public UiaInputSafety(IUiaInputOperations operations) { this.operations = operations ?? throw new ArgumentNullException(nameof(operations)); }
[StructLayout(LayoutKind.Sequential)]
public struct MouseInput {
    public int X, Y;
    public uint MouseData, Flags, Time;
    public UIntPtr ExtraInfo;
  }
[StructLayout(LayoutKind.Sequential)]
public struct Input {
    public uint Type;
    public MouseInput Mouse;
  }
[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[StructLayout(LayoutKind.Sequential)]
public struct ScreenPoint { public int X; public int Y; }
[StructLayout(LayoutKind.Sequential)]
public struct KeybdInput {
    public ushort VirtualKey, ScanCode;
    public uint Flags, Time;
    public UIntPtr ExtraInfo;
  }
[StructLayout(LayoutKind.Sequential)]
public struct KeyInputRecord {
    public uint Type;
    public KeybdInput Key;
    public uint Pad0, Pad1;
  }
public sealed class PopupItemHit {
    public int Position, ItemId, Left, Top, Right, Bottom;
    public int ScreenX, ScreenY, ClientX, ClientY, CursorBeforeX, CursorBeforeY;
    public int CursorAtX, CursorAtY;
    public bool Hilite, UsedKeyboardFallback, UsedSelectItemFallback;
    public bool HiliteAtEnterFallback, HiliteBeforeEnter;
  }
public uint LastEditClearExpected;
public uint LastEditClearSent;
public uint LastEditTextExpected;
public uint LastEditTextSent;
public bool LastEditUsedMessageFallback;
public void RequireOwnedInputWindow(IntPtr owner, uint expectedProcessId) {
    if (owner == IntPtr.Zero || expectedProcessId == 0 || !operations.IsRetainedProcessAlive(expectedProcessId) ||
        operations.WindowProcessId(owner) != expectedProcessId || !operations.WindowIsVisible(owner) || !operations.WindowIsEnabled(owner))
      throw new InvalidOperationException("Input target lost retained process/window ownership; no input was injected");
  }
public void RequireOwnedForeground(IntPtr owner, uint expectedProcessId) {
    RequireOwnedInputWindow(owner, expectedProcessId);
    IntPtr foreground = operations.GetForegroundWindow();
    if (foreground != owner || operations.WindowProcessId(foreground) != expectedProcessId)
      throw new InvalidOperationException("Owned foreground changed; no input was injected");
  }
public void RequireOwnedKeyboardInput(IntPtr owner, uint expectedProcessId, IntPtr expectedFocus) {
    RequireOwnedForeground(owner, expectedProcessId);
    IntPtr focus = operations.FocusedControlInDialog(owner);
    if (focus == IntPtr.Zero || operations.WindowProcessId(focus) != expectedProcessId ||
        operations.GetAncestor(focus, 2) != owner || (expectedFocus != IntPtr.Zero && focus != expectedFocus))
      throw new InvalidOperationException("Owned keyboard focus changed; no key input was injected");
    RequireOwnedForeground(owner, expectedProcessId);
  }
public void RequireOwnedMouseInput(
    IntPtr owner, uint expectedProcessId, ScreenPoint expected, IntPtr expectedControl
  ) {
    RequireOwnedForeground(owner, expectedProcessId);
    ScreenPoint actual;
    if (!operations.GetCursorPos(out actual) || actual.X != expected.X || actual.Y != expected.Y)
      throw new InvalidOperationException("Owned mouse cursor changed; no mouse input was injected");
    IntPtr hit = operations.WindowFromPoint(actual);
    if (hit == IntPtr.Zero || operations.GetAncestor(hit, 2) != owner || operations.WindowProcessId(hit) != expectedProcessId ||
        (expectedControl != IntPtr.Zero && !operations.ResolvesToControl(expectedControl, owner, actual)))
      throw new InvalidOperationException("Owned mouse hit changed; no mouse input was injected");
  }
public int SendKeyInput(IntPtr owner, uint expectedProcessId, IntPtr expectedFocus, ushort virtualKey, int count) {
    if (count <= 0) return 0;
    var inputs = new KeyInputRecord[count * 2];
    for (int index = 0; index < count; index++) {
      inputs[index * 2] = new KeyInputRecord { Type = 1, Key = new KeybdInput { VirtualKey = virtualKey } };
      inputs[index * 2 + 1] = new KeyInputRecord { Type = 1, Key = new KeybdInput { VirtualKey = virtualKey, Flags = 0x0002 } };
    }
    RequireOwnedKeyboardInput(owner, expectedProcessId, expectedFocus);
    uint sent = operations.SendKeyInputs((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(KeyInputRecord)));
    if (sent != inputs.Length)
      throw new InvalidOperationException(String.Format("SendInput injected {0} of {1} key events (cbSize={2}): Win32Error={3}", sent, inputs.Length, Marshal.SizeOf(typeof(KeyInputRecord)), Marshal.GetLastWin32Error()));
    return count;
  }
public int[] SendUnicodeInput(IntPtr owner, uint expectedProcessId, IntPtr expectedFocus, string text) {
    var records = new KeyInputRecord[text.Length * 2];
    int offset = 0;
    foreach (char character in text) {
      records[offset++] = new KeyInputRecord { Type = 1, Key = new KeybdInput { ScanCode = character, Flags = 4 } };
      records[offset++] = new KeyInputRecord { Type = 1, Key = new KeybdInput { ScanCode = character, Flags = 6 } };
    }
    if (records.Length == 0) return new int[] { 0, 0 };
    RequireOwnedKeyboardInput(owner, expectedProcessId, expectedFocus);
    uint sent = operations.SendKeyInputs((uint)records.Length, records, Marshal.SizeOf(typeof(KeyInputRecord)));
    if (sent != records.Length)
      throw new InvalidOperationException(String.Format("Owned Unicode SendInput injected {0}/{1}", sent, records.Length));
    return new int[] { checked((int)sent), records.Length };
  }
public bool TypeEditTextById(IntPtr parent, int controlId, string text) {
    LastEditClearExpected = LastEditClearSent = 0;
    LastEditTextExpected = LastEditTextSent = 0;
    LastEditUsedMessageFallback = false;
    IntPtr edit = operations.ControlById(parent, controlId);
    if (edit == IntPtr.Zero || !operations.FocusControl(parent, edit)) return false;
    uint expectedProcessId = operations.WindowProcessId(parent);
    operations.SendMessage(edit, 0x00B1, UIntPtr.Zero, new IntPtr(-1));
    var clear = new KeyInputRecord[2];
    clear[0] = new KeyInputRecord { Type = 1, Key = new KeybdInput { VirtualKey = 0x2E } };
    clear[1] = new KeyInputRecord { Type = 1, Key = new KeybdInput { VirtualKey = 0x2E, Flags = 2 } };
    LastEditClearExpected = (uint)clear.Length;
    RequireOwnedKeyboardInput(parent, expectedProcessId, edit);
    LastEditClearSent = operations.SendKeyInputs(LastEditClearExpected, clear, Marshal.SizeOf(typeof(KeyInputRecord)));
    if (LastEditClearSent != LastEditClearExpected) return false;
    bool cleared = String.IsNullOrEmpty(operations.EditBufferText(edit));
    int[] typed = SendUnicodeInput(parent, expectedProcessId, edit, text);
    LastEditTextExpected = checked((uint)typed[1]);
    LastEditTextSent = checked((uint)typed[0]);
    bool matched = cleared && String.Equals(operations.EditTextById(parent, controlId), text, StringComparison.Ordinal);
    if (!matched) {
      operations.SendMessageString(edit, 0x000C, UIntPtr.Zero, text);
      LastEditUsedMessageFallback = true;
      matched = String.Equals(operations.EditTextById(parent, controlId), text, StringComparison.Ordinal);
    }
    return matched;
  }
public int[] ClickOwnedScreenRectangle(IntPtr owner, int left, int top, int right, int bottom, bool rightClick) {
    uint expectedProcessId = operations.WindowProcessId(owner);
    RequireOwnedForeground(owner, expectedProcessId);
    if (!operations.WindowIsVisible(owner) || right <= left || bottom <= top)
      throw new InvalidOperationException("Owned rectangle is not visibly hittable");
    var point = new ScreenPoint { X = (left + right) / 2, Y = (top + bottom) / 2 };
    IntPtr hit = operations.WindowFromPoint(point);
    if (hit == IntPtr.Zero || operations.GetAncestor(hit, 2) != owner)
      throw new InvalidOperationException("Live rectangle is covered by another top-level window");
    if (!operations.SetCursorPos(point.X, point.Y))
      throw new InvalidOperationException("Unable to move cursor into owned live rectangle");
    ScreenPoint actual;
    if (!operations.GetCursorPos(out actual) || actual.X != point.X || actual.Y != point.Y)
      throw new InvalidOperationException("Owned live-rectangle cursor position differs");
    var inputs = new Input[] {
      new Input { Type = 0, Mouse = new MouseInput { Flags = rightClick ? 0x0008u : 0x0002u } },
      new Input { Type = 0, Mouse = new MouseInput { Flags = rightClick ? 0x0010u : 0x0004u } }
    };
    RequireOwnedMouseInput(owner, expectedProcessId, point, IntPtr.Zero);
    uint sent = operations.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(Input)));
    if (sent != inputs.Length)
      throw new InvalidOperationException(String.Format("Owned rectangle SendInput sent {0}/{1}", sent, inputs.Length));
    return new int[] { left, top, right, bottom, actual.X, actual.Y, (int)sent, inputs.Length };
  }
public void RequireOwnedPopupForeground(IntPtr popup, IntPtr owner, uint expectedProcessId) {
    IntPtr foreground = operations.GetForegroundWindow();
    IntPtr foregroundRoot = operations.GetAncestor(foreground, 2);
    if (expectedProcessId == 0 || !operations.IsRetainedProcessAlive(expectedProcessId) || operations.WindowProcessId(owner) != expectedProcessId ||
      operations.WindowProcessId(popup) != expectedProcessId || operations.WindowProcessId(foreground) != expectedProcessId ||
      (foregroundRoot != owner && foregroundRoot != popup) || !operations.IsWindowVisible(popup))
      throw new InvalidOperationException("Popup input ownership changed; no further input was injected");
  }
public bool HoverPopupMenuItem(IntPtr owner, IntPtr menu, int position) {
    RECT item;
    if (menu == IntPtr.Zero || !operations.GetMenuItemRect(owner, menu, (uint)position, out item)) return false;
    int x = item.Right - Math.Min(12, (item.Right - item.Left) / 2);
    int y = (item.Top + item.Bottom) / 2;
    uint ownerProcess = operations.WindowProcessId(owner);
    IntPtr popup = operations.FindPopupForMenu(ownerProcess, menu);
    if (popup == IntPtr.Zero) return false;
    RequireOwnedPopupForeground(popup, owner, ownerProcess);
    IntPtr hit = operations.WindowFromPoint(new ScreenPoint { X = x, Y = y });
    if (operations.GetAncestor(hit, 2) != popup || operations.WindowProcessId(hit) != ownerProcess)
      throw new InvalidOperationException("Submenu hover point is covered; no cursor movement was injected");
    if (!operations.SetCursorPos(x, y))
      throw new InvalidOperationException(String.Format("SetCursorPos for submenu failed: Win32Error={0}", Marshal.GetLastWin32Error()));
    ScreenPoint at;
    if (!operations.GetCursorPos(out at)) return false;
    var client = new ScreenPoint { X = x, Y = y };
    if (!operations.ScreenToClient(popup, ref client)) return false;
    RequireOwnedPopupForeground(popup, owner, ownerProcess);
    operations.SendMessage(popup, 0x0200, UIntPtr.Zero, operations.MouseLParam(client.X, client.Y));
    bool hilite = false;
    for (int attempt = 0; attempt < 50 && !hilite; attempt++) {
      hilite = (operations.GetMenuState(menu, (uint)position, 0x0400) & 0x0080) != 0;
      if (!hilite) operations.Sleep(10);
    }
    return at.X == x && at.Y == y && hilite;
  }
public static bool IsOwnedPopupInput(
    IntPtr owner, IntPtr popup, uint expectedProcessId, uint popupProcessId,
    uint foregroundProcessId, IntPtr foregroundRoot, uint pointProcessId,
    IntPtr pointRoot, bool popupVisible
  ) {
    return owner != IntPtr.Zero && popup != IntPtr.Zero && expectedProcessId != 0 &&
      popupProcessId == expectedProcessId && foregroundProcessId == expectedProcessId &&
      (foregroundRoot == owner || foregroundRoot == popup) &&
      pointProcessId == expectedProcessId && pointRoot == popup && popupVisible;
  }
public PopupItemHit ClickPopupMenuItem(IntPtr popup, IntPtr owner, int position, int commandId, uint expectedProcessId) {
    if (popup == IntPtr.Zero || position < 0) return null;
    IntPtr menu = operations.PopupMenuHandle(popup);
    RECT item;
    if (menu == IntPtr.Zero || !operations.GetMenuItemRect(owner, menu, (uint)position, out item) ||
        item.Right <= item.Left || item.Bottom <= item.Top ||
        operations.PopupMenuItemId(menu, position) != (uint)commandId) return null;
    int screenX = (item.Left + item.Right) / 2;
    int screenY = (item.Top + item.Bottom) / 2;
    if (screenX < item.Left || screenX >= item.Right ||
        screenY < item.Top || screenY >= item.Bottom) return null;
    var point = new ScreenPoint {
      X = screenX,
      Y = screenY
    };
    if (!operations.ScreenToClient(popup, ref point)) return null;
    ScreenPoint before, at;
    if (!operations.GetCursorPos(out before))
      throw new InvalidOperationException(String.Format("GetCursorPos before popup click failed: Win32Error={0}", Marshal.GetLastWin32Error()));
    RequireOwnedPopupForeground(popup, owner, expectedProcessId);
    if (!operations.SetCursorPos(screenX, screenY))
      throw new InvalidOperationException(String.Format("SetCursorPos for popup click failed: Win32Error={0}", Marshal.GetLastWin32Error()));
    if (!operations.GetCursorPos(out at))
      throw new InvalidOperationException(String.Format("GetCursorPos after popup move failed: Win32Error={0}", Marshal.GetLastWin32Error()));
    if (at.X != screenX || at.Y != screenY)
      throw new InvalidOperationException(String.Format("Popup cursor landed at ({0},{1}), expected ({2},{3})", at.X, at.Y, screenX, screenY));
    operations.SendMessage(popup, 0x0200, UIntPtr.Zero, operations.MouseLParam(point.X, point.Y));
    bool hilite = false;
    for (int attempt = 0; attempt < 50 && !hilite; attempt++) {
      hilite = (operations.GetMenuState(menu, (uint)position, 0x0400) & 0x0080) != 0;
      if (!hilite) operations.Sleep(10);
    }
    bool selectItemFallback = false;
    if (!hilite) {
      operations.SendMessage(popup, 0x01E5, (UIntPtr)position, IntPtr.Zero);
      selectItemFallback = true;
      for (int attempt = 0; attempt < 50 && !hilite; attempt++) {
        hilite = (operations.GetMenuState(menu, (uint)position, 0x0400) & 0x0080) != 0;
        if (!hilite) operations.Sleep(10);
      }
    }
    if (!hilite)
      throw new InvalidOperationException("Popup item did not acknowledge hover before click");
    var inputs = new[] {
      new Input { Type = 0, Mouse = new MouseInput { Flags = 0x0002 } },
      new Input { Type = 0, Mouse = new MouseInput { Flags = 0x0004 } }
    };
    ScreenPoint cursorBeforeInput;
    if (!operations.GetCursorPos(out cursorBeforeInput) || cursorBeforeInput.X != screenX || cursorBeforeInput.Y != screenY)
      throw new InvalidOperationException("Popup input cursor changed; no mouse input was injected");
    uint inputOwnerProcessId = operations.WindowProcessId(owner);
    if (inputOwnerProcessId != expectedProcessId || !operations.IsRetainedProcessAlive(expectedProcessId))
      throw new InvalidOperationException("Popup input ownership changed; no mouse input was injected");
    IntPtr foregroundBeforeInput = operations.GetForegroundWindow();
    IntPtr inputPointWindow = operations.WindowFromPoint(cursorBeforeInput);
    if (!IsOwnedPopupInput(
      owner, popup, inputOwnerProcessId, operations.WindowProcessId(popup),
      operations.WindowProcessId(foregroundBeforeInput), operations.GetAncestor(foregroundBeforeInput, 2),
      operations.WindowProcessId(inputPointWindow), operations.GetAncestor(inputPointWindow, 2), operations.IsWindowVisible(popup)))
      throw new InvalidOperationException("Popup input ownership changed; no mouse input was injected");
    uint sent = operations.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(Input)));
    if (sent != inputs.Length)
      throw new InvalidOperationException(String.Format("SendInput injected {0} of {1} popup mouse events: Win32Error={2}", sent, inputs.Length, Marshal.GetLastWin32Error()));
    for (int attempt = 0; attempt < 20 && operations.IsWindowVisible(popup); attempt++) operations.Sleep(10);
    bool keyboardFallback = false;
    bool hiliteAtEnterFallback = false;
    bool hiliteBeforeEnter = false;
    if (operations.IsWindowVisible(popup)) {
      // Injected clicks can be dropped (or held) by the desktop's input stack,
      // and the menu can lose its hover hilite meanwhile. Enter with no hilited
      // item ends TrackPopupMenu with command 0: the popup closes exactly as if
      // the item had been chosen, but no command reaches the shell. Re-assert
      // the intended item and prove its hilite immediately before Enter.
      hiliteAtEnterFallback = (operations.GetMenuState(menu, (uint)position, 0x0400) & 0x0080) != 0;
      operations.SendMessage(popup, 0x01E5, (UIntPtr)position, IntPtr.Zero);
      hiliteBeforeEnter = (operations.GetMenuState(menu, (uint)position, 0x0400) & 0x0080) != 0;
    }
    if (operations.IsWindowVisible(popup)) {
      if (!hiliteBeforeEnter)
        throw new InvalidOperationException(String.Format("Popup item {0} was not hilited before the Enter fallback (hilite at fallback={1})", commandId, hiliteAtEnterFallback));
      RequireOwnedPopupForeground(popup, owner, expectedProcessId);
      keyboardFallback =
        operations.PostMessage(popup, 0x0100, (UIntPtr)0x0D, IntPtr.Zero) &&
        operations.PostMessage(popup, 0x0101, (UIntPtr)0x0D, IntPtr.Zero);
      if (!keyboardFallback)
        throw new InvalidOperationException(String.Format("Popup Enter fallback was rejected: Win32Error={0}", Marshal.GetLastWin32Error()));
    }
    return new PopupItemHit {
      Position = position, ItemId = commandId, Left = item.Left, Top = item.Top,
      Right = item.Right, Bottom = item.Bottom,
      ScreenX = screenX, ScreenY = screenY, ClientX = point.X, ClientY = point.Y,
      CursorBeforeX = before.X, CursorBeforeY = before.Y,
      CursorAtX = at.X, CursorAtY = at.Y, Hilite = hilite,
      UsedKeyboardFallback = keyboardFallback,
      UsedSelectItemFallback = selectItemFallback,
      HiliteAtEnterFallback = hiliteAtEnterFallback,
      HiliteBeforeEnter = hiliteBeforeEnter
    };
  }
}
}
