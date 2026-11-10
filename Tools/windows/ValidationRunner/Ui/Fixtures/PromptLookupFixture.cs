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
  private static readonly WindowProc editProcedure = EditWindowProc;
  private static IntPtr crossProcessEdit;
  private static int editChanges;
  private static string changedBuffer;
  [StructLayout(LayoutKind.Sequential)]
  private struct Message {
    public IntPtr Window;
    public uint Id;
    public UIntPtr WParam;
    public IntPtr LParam;
    public uint Time;
    public int X, Y;
    public uint Private;
  }
  [DllImport("user32.dll", EntryPoint = "GetMessageW")]
  private static extern int GetMessage(out Message message, IntPtr window, uint first, uint last);
  [DllImport("user32.dll")]
  private static extern bool TranslateMessage(ref Message message);
  [DllImport("user32.dll", EntryPoint = "DispatchMessageW")]
  private static extern IntPtr DispatchMessage(ref Message message);
  [DllImport("user32.dll")]
  private static extern void PostQuitMessage(int exitCode);
  [DllImport("user32.dll", EntryPoint = "SetWindowTextW", CharSet = CharSet.Unicode)]
  public static extern bool SetCaptionForRegression(IntPtr window, string text);
  private static IntPtr EditWindowProc(IntPtr window, uint message, UIntPtr wparam, IntPtr lparam) {
    if (message == 0x0111 && (wparam.ToUInt64() >> 16) == 0x0300 && lparam == crossProcessEdit) {
      editChanges++;
      changedBuffer = GraphCodeUiaGateState.EditTextById(window, 9904);
    }
    if (message == 0x0010) {
      PostQuitMessage(0);
      return IntPtr.Zero;
    }
    return DefWindowProc(window, message, wparam, lparam);
  }
  public static int RunEditBufferChild(string root) {
    if (!System.IO.Path.IsPathFullyQualified(root) || !System.IO.Directory.Exists(root))
      throw new ArgumentException("Existing absolute owned fixture root required.");
    var cls = new WindowClass { Name = "GraphCodeEditBufferFixture", Instance = GetModuleHandle(null),
      Procedure = Marshal.GetFunctionPointerForDelegate(editProcedure) };
    if (RegisterClass(ref cls) == 0)
      throw new InvalidOperationException("Edit fixture registration failed: " + Marshal.GetLastWin32Error());
    IntPtr parent = Create(cls.Name, IntPtr.Zero, 0);
    Exception primary = null;
    try {
      crossProcessEdit = Create("EDIT", parent, 9904);
      if (!GraphCodeUiaGateState.SetEditTextById(parent, 9904, "UIA loop B"))
        throw new InvalidOperationException("Initial child edit buffer write failed.");
      editChanges = 0;
      changedBuffer = null;
      using (var file = new System.IO.FileStream(System.IO.Path.Combine(root, "ready.json"),
          System.IO.FileMode.CreateNew, System.IO.FileAccess.Write, System.IO.FileShare.None))
        System.Text.Json.JsonSerializer.Serialize(file, new { pid = Environment.ProcessId, window = parent.ToInt64() });
      using (System.IO.File.Open(System.IO.Path.Combine(root, "published"), System.IO.FileMode.CreateNew)) { }
      int status;
      while ((status = GetMessage(out var message, IntPtr.Zero, 0, 0)) > 0) {
        TranslateMessage(ref message);
        DispatchMessage(ref message);
      }
      if (status < 0) throw new InvalidOperationException("Edit fixture message pump failed.");
      Console.WriteLine("EDIT_BUFFER_CHILD=" + System.Text.Json.JsonSerializer.Serialize(new {
        pid = Environment.ProcessId, buffer = GraphCodeUiaGateState.EditTextById(parent, 9904),
        changes = editChanges, observed = changedBuffer
      }));
      return 0;
    } catch (Exception failure) {
      primary = failure;
      throw;
    } finally {
      if (!DestroyWindow(parent)) {
        var failure = new InvalidOperationException("Edit fixture window cleanup failed.");
        if (primary == null) throw failure;
        throw new AggregateException("Edit fixture execution and window cleanup failed.", primary, failure);
      }
    }
  }
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
