#nullable disable
namespace GraphCode.Validation.Ui.Fixtures {
using System;
using System.Runtime.InteropServices;
public static class PromptLookupFixture {
  public sealed record ZipPickerResult(int Result, string SelectedPath, bool ReplacementApproved, int HResult);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Unicode)]
  private delegate int ZipPicker(IntPtr owner, [MarshalAs(UnmanagedType.Bool)] bool saving,
    string suggestedName, System.Text.StringBuilder buffer, uint capacity,
    [MarshalAs(UnmanagedType.Bool)] out bool replacement, out int error);
  public static ZipPickerResult PickZipProduction(string libraryPath, IntPtr owner, string suggestedName) {
    if (!System.IO.Path.IsPathFullyQualified(libraryPath) || owner == IntPtr.Zero ||
        string.IsNullOrWhiteSpace(suggestedName))
      throw new ArgumentException("An absolute sealed picker library, owned native owner and suggested name are required.");
    IntPtr library = NativeLibrary.Load(libraryPath);
    try {
      var pick = Marshal.GetDelegateForFunctionPointer<ZipPicker>(
        NativeLibrary.GetExport(library, "graphcode_pick_zip"));
      var buffer = new System.Text.StringBuilder(32768);
      int result = pick(owner, true, suggestedName, buffer, (uint)buffer.Capacity,
        out bool replacement, out int error);
      return new ZipPickerResult(result, buffer.ToString(), replacement, error);
    } finally { NativeLibrary.Free(library); }
  }
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
  public static extern IntPtr GetThreadDpiAwarenessContext();
  [DllImport("user32.dll", SetLastError = true)]
  public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")]
  public static extern bool AreDpiAwarenessContextsEqual(IntPtr first, IntPtr second);
  [DllImport("kernel32.dll")]
  public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")]
  public static extern uint GetDpiForWindow(IntPtr window);
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
