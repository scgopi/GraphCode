#nullable disable
namespace GraphCode.Validation.Ui.Fixtures {
using System;
using System.Runtime.InteropServices;
public static class PromptLookupFixture {
  private delegate IntPtr WindowProc(IntPtr window, uint message, UIntPtr wparam, IntPtr lparam);
  private static readonly WindowProc procedure = DefWindowProc;
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  private struct WindowClass {
    public uint Style;
    public IntPtr Procedure;
    public int ClassExtra, WindowExtra;
    public IntPtr Instance, Icon, Cursor, Background;
    public string Menu, Name;
  }
  [DllImport("user32.dll", EntryPoint = "DefWindowProcW")]
  private static extern IntPtr DefWindowProc(IntPtr window, uint message, UIntPtr wparam, IntPtr lparam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "RegisterClassW")]
  private static extern ushort RegisterClass(ref WindowClass value);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
  private static extern IntPtr GetModuleHandle(string name);
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateWindowExW")]
  private static extern IntPtr CreateWindow(uint ex, string cls, string title, uint style,
    int x, int y, int width, int height, IntPtr parent, IntPtr id, IntPtr instance, IntPtr parameter);
  [DllImport("user32.dll")]
  public static extern bool DestroyWindow(IntPtr window);
  [DllImport("user32.dll")]
  public static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")]
  private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
  public static void Place(IntPtr window, int x, int y, int width, int height) {
    if (!SetWindowPos(window, IntPtr.Zero, x, y, width, height, 0x14))
      throw new InvalidOperationException("Hidden lookup fixture placement failed.");
  }
  public static void Register(string name) {
    var value = new WindowClass { Name = name, Instance = GetModuleHandle(null),
      Procedure = Marshal.GetFunctionPointerForDelegate(procedure) };
    if (RegisterClass(ref value) == 0)
      throw new InvalidOperationException("Hidden lookup fixture class registration failed: " + Marshal.GetLastWin32Error());
  }
  public static IntPtr Create(string cls, IntPtr parent, int id) {
    IntPtr result = CreateWindow(0, cls, "lookup fixture", parent == IntPtr.Zero ? 0u : 0x50000000u,
      0, 0, 400, 300, parent, new IntPtr(id), GetModuleHandle(null), IntPtr.Zero);
    if (result == IntPtr.Zero)
      throw new InvalidOperationException("Hidden lookup fixture creation failed: " + Marshal.GetLastWin32Error());
    return result;
  }
}
}
