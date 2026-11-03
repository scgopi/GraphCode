#nullable disable
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
public static class GraphCodeUiaHostInfo {
  private const int UOI_NAME = 2;
  [DllImport("user32.dll")]
  private static extern IntPtr GetProcessWindowStation();
  [DllImport("user32.dll")]
  private static extern IntPtr GetThreadDesktop(uint threadId);
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern bool GetUserObjectInformation(
    IntPtr handle, int index, StringBuilder info, uint length, out uint needed
  );
  [DllImport("kernel32.dll")]
  private static extern uint GetCurrentThreadId();
  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool ProcessIdToSessionId(uint processId, out uint sessionId);
  [DllImport("user32.dll")]
  private static extern uint GetGuiResources(IntPtr process, uint flags);
  private static string ObjectName(IntPtr handle) {
    if (handle == IntPtr.Zero) return null;
    var name = new StringBuilder(256);
    uint needed;
    if (!GetUserObjectInformation(handle, UOI_NAME, name, (uint)(name.Capacity * 2), out needed))
      return null;
    return name.ToString();
  }
  public static string CurrentWindowStationName() {
    return ObjectName(GetProcessWindowStation());
  }
  public static string CurrentDesktopName() {
    return ObjectName(GetThreadDesktop(GetCurrentThreadId()));
  }
  public static uint CurrentSessionId() {
    uint sessionId;
    if (!ProcessIdToSessionId((uint)Process.GetCurrentProcess().Id, out sessionId))
      throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    return sessionId;
  }
  public static uint GuiResourceCount(int processId, uint flags) {
    using (var process = Process.GetProcessById(processId))
      return GetGuiResources(process.Handle, flags);
  }
}
