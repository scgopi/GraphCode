#nullable disable
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class GraphCodeMultiProjectRenameNative {
  [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo {
    public int Size; public Rect Monitor, Work; public uint Flags;
  }
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr window, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(Point point);
  [DllImport("user32.dll")] private static extern IntPtr RealChildWindowFromPoint(IntPtr window, Point point);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string title);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="GetClassNameW")]
  private static extern int GetClassName(IntPtr window, System.Text.StringBuilder name, int capacity);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool GetClientRect(IntPtr window, out Rect rect);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool ClientToScreen(IntPtr window, ref Point point);
  [DllImport("user32.dll", SetLastError=true)] private static extern bool ScreenToClient(IntPtr window, ref Point point);
  [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
  public static int[] ClientBounds(IntPtr window) {
    Rect rect;
    if (!GetClientRect(window, out rect)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Rename GetClientRect");
    var first = new Point { X=rect.Left, Y=rect.Top };
    var last = new Point { X=rect.Right, Y=rect.Bottom };
    if (!ClientToScreen(window, ref first) || !ClientToScreen(window, ref last))
      throw new Win32Exception(Marshal.GetLastWin32Error(), "Rename ClientToScreen");
    return new[] { first.X, first.Y, last.X, last.Y };
  }
  public static int[] WorkBounds(IntPtr window) {
    var info = new MonitorInfo { Size=Marshal.SizeOf(typeof(MonitorInfo)) };
    if (!GetMonitorInfo(MonitorFromWindow(window, 2), ref info))
      throw new Win32Exception(Marshal.GetLastWin32Error(), "Rename GetMonitorInfo");
    return new[] { info.Work.Left, info.Work.Top, info.Work.Right, info.Work.Bottom };
  }
  private static bool ContainsScreenPoint(IntPtr window, int x, int y) {
    Rect rect;
    if (!GetClientRect(window, out rect)) return false;
    var first = new Point { X=rect.Left, Y=rect.Top };
    var last = new Point { X=rect.Right, Y=rect.Bottom };
    if (!ClientToScreen(window, ref first) || !ClientToScreen(window, ref last)) return false;
    return x >= first.X && x < last.X && y >= first.Y && y < last.Y;
  }
  public static IntPtr ChildAt(IntPtr window, int x, int y) {
    var point = new Point { X=x, Y=y };
    if (!ScreenToClient(window, ref point)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Rename ScreenToClient");
    IntPtr direct = RealChildWindowFromPoint(window, point);
    var rootClass = new System.Text.StringBuilder(128);
    var childClass = new System.Text.StringBuilder(128);
    GetClassName(window, rootClass, rootClass.Capacity);
    if (direct == IntPtr.Zero &&
        String.Equals(rootClass.ToString(), "GraphCodeSheetHost", StringComparison.Ordinal)) {
      IntPtr viewport = FindWindowEx(window, IntPtr.Zero, "GraphCodeSheetViewport", null);
      if (ContainsScreenPoint(viewport, x, y)) direct = viewport;
    }
    GetClassName(direct, childClass, childClass.Capacity);
    if (!String.Equals(rootClass.ToString(), "GraphCodeSheetHost", StringComparison.Ordinal) ||
        !String.Equals(childClass.ToString(), "GraphCodeSheetViewport", StringComparison.Ordinal))
      return direct;
    IntPtr content = FindWindowEx(direct, IntPtr.Zero, "GraphCodeWindowsDialogContent", null);
    if (content == IntPtr.Zero) return direct;
    var viewportPoint = new Point { X=x, Y=y };
    if (!ScreenToClient(direct, ref viewportPoint))
      throw new Win32Exception(Marshal.GetLastWin32Error(), "Rename viewport ScreenToClient");
    IntPtr viewportChild = RealChildWindowFromPoint(direct, viewportPoint);
    if (viewportChild != content &&
        !(viewportChild == IntPtr.Zero && ContainsScreenPoint(content, x, y))) return direct;
    var contentPoint = new Point { X=x, Y=y };
    if (!ScreenToClient(content, ref contentPoint))
      throw new Win32Exception(Marshal.GetLastWin32Error(), "Rename content ScreenToClient");
    IntPtr nested = RealChildWindowFromPoint(content, contentPoint);
    return nested == IntPtr.Zero ? content : nested;
  }
}
