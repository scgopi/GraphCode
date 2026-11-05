#nullable disable
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class GraphCodeUiaAttribution {
  private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
  [DllImport("user32.dll")]
  private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
  [DllImport("user32.dll")]
  private static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")]
  private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern int GetClassName(IntPtr window, StringBuilder className, int capacity);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
  [DllImport("user32.dll")]
  private static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")]
  private static extern bool IsWindowEnabled(IntPtr window);
  [DllImport("user32.dll")]
  private static extern bool IsHungAppWindow(IntPtr window);
  [DllImport("user32.dll")]
  private static extern IntPtr GetWindow(IntPtr window, uint command);
  [StructLayout(LayoutKind.Sequential)]
  public struct Rect { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")]
  private static extern bool GetWindowRect(IntPtr window, out Rect rect);
  [DllImport("user32.dll")]
  public static extern bool PrintWindow(IntPtr window, IntPtr hdc, uint flags);
  public sealed class WindowRecord {
    public long Handle; public long Owner; public string ClassName; public string Title;
    public bool Visible, Enabled, Hung; public int Left, Top, Right, Bottom;
  }
  private static string ClassOf(IntPtr window) {
    var text = new StringBuilder(256);
    GetClassName(window, text, text.Capacity);
    return text.ToString();
  }
  public static long ForegroundHandle() { return GetForegroundWindow().ToInt64(); }
  public static uint ProcessOf(IntPtr window) {
    if (window == IntPtr.Zero) return 0;
    uint processId;
    GetWindowThreadProcessId(window, out processId);
    return processId;
  }
  public static string ClassName(IntPtr window) {
    return window == IntPtr.Zero ? "" : ClassOf(window);
  }
  public static Rect Bounds(IntPtr window) {
    Rect rect;
    if (window == IntPtr.Zero || !GetWindowRect(window, out rect)) return new Rect();
    return rect;
  }
  // Titles are read only for windows owned by processId (the gate's own shell).
  public static WindowRecord[] ProcessWindows(uint processId) {
    var results = new List<WindowRecord>();
    EnumWindows(delegate(IntPtr window, IntPtr parameter) {
      uint owner;
      GetWindowThreadProcessId(window, out owner);
      if (owner != processId) return true;
      var title = new StringBuilder(512);
      GetWindowText(window, title, title.Capacity);
      Rect rect;
      GetWindowRect(window, out rect);
      results.Add(new WindowRecord {
        Handle = window.ToInt64(), Owner = GetWindow(window, 4).ToInt64(),
        ClassName = ClassOf(window), Title = title.ToString(),
        Visible = IsWindowVisible(window), Enabled = IsWindowEnabled(window),
        Hung = IsHungAppWindow(window),
        Left = rect.Left, Top = rect.Top, Right = rect.Right, Bottom = rect.Bottom
      });
      return true;
    }, IntPtr.Zero);
    return results.ToArray();
  }
}
