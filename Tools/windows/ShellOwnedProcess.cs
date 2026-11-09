#nullable disable
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;

public sealed class ShellOwnedLaunch {
  [DllImport("kernel32.dll")]
  static extern uint GetOEMCP();
  public static int OemCodePage() { return checked((int)GetOEMCP()); }

  public static string SelectWorkingDirectory(ProcessStartInfo info) {
    return String.IsNullOrEmpty(info.WorkingDirectory) ? null : info.WorkingDirectory;
  }
  [StructLayout(LayoutKind.Sequential)]
  struct Security { public int Length; public IntPtr Descriptor; public int Inherit; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct Startup {
    public int Size;
    public string Reserved, Desktop, Title;
    public int X, Y, Width, Height, XChars, YChars, Fill, Flags;
    public short Show, ReservedSize;
    public IntPtr ReservedBytes, Input, Output, Error, Attributes;
  }
  [StructLayout(LayoutKind.Sequential)]
  struct ProcessInfo { public IntPtr Process, Thread; public int Pid, Tid; }
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool CreatePipe(out IntPtr read, out IntPtr write, ref Security security, int size);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern IntPtr CreateFileW(string name, uint access, uint share, ref Security security,
    uint disposition, uint flags, IntPtr template);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute,
    IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
  [DllImport("kernel32.dll")]
  static extern void DeleteProcThreadAttributeList(IntPtr list);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern bool CreateProcessW(string file, StringBuilder command, IntPtr processSecurity,
    IntPtr threadSecurity, bool inherit, uint flags, IntPtr environment, string directory,
    ref Startup startup, out ProcessInfo process);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool TerminateProcess(IntPtr process, uint code);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern uint WaitForSingleObject(IntPtr handle, uint timeout);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool GetProcessTimes(IntPtr process, out long created, out long exited,
    out long kernel, out long user);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool CloseHandle(IntPtr handle);

  public Process Process { get; private set; }
  public IntPtr Handle { get; private set; }
  public Task<string> Output { get; private set; }
  public Task<string> Error { get; private set; }
  IntPtr thread;
  StreamReader outputReader, errorReader;
  OutputCapture outputCapture, errorCapture;

  sealed class OutputCapture {
    readonly TextReader reader;
    readonly TextWriter forward;
    readonly object gate = new object();
    StringBuilder captured = new StringBuilder();
    int forwarded;
    public Task<string> Completion { get; private set; }
    public OutputCapture(TextReader reader) : this(reader, null) {}
    public OutputCapture(TextReader reader, TextWriter forward) {
      this.reader = reader;
      this.forward = forward;
      Completion = Pump();
    }
    async Task<string> Pump() {
      var buffer = new char[4096];
      char? pendingHigh = null;
      int count;
      while ((count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) != 0) {
        lock (gate) captured.Append(buffer, 0, count);
        if (forward != null) {
          char[] chunk = buffer;
          int length = count;
          if (pendingHigh.HasValue) {
            chunk = new char[count + 1];
            chunk[0] = pendingHigh.Value;
            Array.Copy(buffer, 0, chunk, 1, count);
            length++;
            pendingHigh = null;
          }
          if (Char.IsHighSurrogate(chunk[length - 1])) {
            pendingHigh = chunk[length - 1];
            length--;
          }
          if (length > 0) {
            forward.Write(chunk, 0, length);
            forward.Flush();
          }
        }
      }
      if (forward != null && pendingHigh.HasValue) {
        forward.Write(new[] { pendingHigh.Value }, 0, 1);
        forward.Flush();
      }
      lock (gate) return captured.ToString();
    }
    public string Take(int maximumCharacters) {
      if (maximumCharacters < 2 || maximumCharacters > 65536)
        throw new ArgumentOutOfRangeException(nameof(maximumCharacters));
      if (Completion.IsFaulted || Completion.IsCanceled) Completion.GetAwaiter().GetResult();
      lock (gate) {
        if (captured == null) throw new ObjectDisposedException(nameof(OutputCapture));
        int count = Math.Min(maximumCharacters, captured.Length - forwarded);
        if (count > 0 && Char.IsHighSurrogate(captured[forwarded + count - 1])) count--;
        string result = captured.ToString(forwarded, count);
        forwarded += count;
        return result;
      }
    }
    public void Release() { lock (gate) captured = null; }
  }

  static TextWriter ForwardWriter(bool redirected, TextWriter writer) {
    if (!redirected && writer == null) throw new ArgumentNullException(nameof(writer));
    return redirected ? null : writer;
  }

  static string Quote(string value) {
    var result = new StringBuilder("\"");
    int slashes = 0;
    foreach (char c in value) {
      if (c == '\\') { slashes++; continue; }
      result.Append('\\', c == '"' ? slashes * 2 + 1 : slashes);
      result.Append(c);
      slashes = 0;
    }
    return result.Append('\\', slashes * 2).Append('"').ToString();
  }

  public static ShellOwnedLaunch Suspended(ProcessStartInfo info) {
    return Suspended(info, null, null);
  }

  public static ShellOwnedLaunch Suspended(ProcessStartInfo info, TextWriter standardOutputWriter,
      TextWriter standardErrorWriter) {
    // Supplied writers remain caller-owned until verified teardown and pipe EOF.
    if (info.UseShellExecute || !String.IsNullOrEmpty(info.Arguments))
      throw new InvalidOperationException("Owned launch requires UseShellExecute=false and ArgumentList.");
    var security = new Security { Length = Marshal.SizeOf<Security>(), Inherit = 1 };
    IntPtr outRead = IntPtr.Zero, outWrite = IntPtr.Zero, errRead = IntPtr.Zero, errWrite = IntPtr.Zero;
    IntPtr input = IntPtr.Zero, attributes = IntPtr.Zero, handles = IntPtr.Zero, environment = IntPtr.Zero;
    bool initialized = false;
    var run = new ShellOwnedLaunch();
    try {
      if (!CreatePipe(out outRead, out outWrite, ref security, 0) ||
          !CreatePipe(out errRead, out errWrite, ref security, 0) ||
          !SetHandleInformation(outRead, 1, 0) || !SetHandleInformation(errRead, 1, 0))
        throw new Win32Exception();
      input = CreateFileW("NUL", 0x80000000, 3, ref security, 3, 0, IntPtr.Zero);
      if (input == new IntPtr(-1)) throw new Win32Exception();
      IntPtr size = IntPtr.Zero;
      InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
      attributes = Marshal.AllocHGlobal(size);
      if (!InitializeProcThreadAttributeList(attributes, 1, 0, ref size)) throw new Win32Exception();
      initialized = true;
      handles = Marshal.AllocHGlobal(IntPtr.Size * 3);
      Marshal.WriteIntPtr(handles, 0, input);
      Marshal.WriteIntPtr(handles, IntPtr.Size, outWrite);
      Marshal.WriteIntPtr(handles, IntPtr.Size * 2, errWrite);
      if (!UpdateProcThreadAttribute(attributes, 0, new IntPtr(0x20002), handles,
          new IntPtr(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception();
      var block = new StringBuilder();
      foreach (var pair in info.Environment.OrderBy(p => p.Key, StringComparer.OrdinalIgnoreCase))
        block.Append(pair.Key).Append('=').Append(pair.Value).Append('\0');
      block.Append('\0');
      environment = Marshal.StringToHGlobalUni(block.ToString());
      var command = new StringBuilder(Quote(info.FileName));
      foreach (string argument in info.ArgumentList) command.Append(' ').Append(Quote(argument));
      var startup = new Startup {
        Size = Marshal.SizeOf<Startup>(), Flags = 0x101, Input = input,
        Show = (short)(info.WindowStyle == ProcessWindowStyle.Hidden ? 0 :
          info.WindowStyle == ProcessWindowStyle.Minimized ? 2 :
          info.WindowStyle == ProcessWindowStyle.Maximized ? 3 : 1),
        Output = outWrite, Error = errWrite, Attributes = attributes
      };
      ProcessInfo created;
      uint flags = 0x4 | 0x400 | 0x80000; // suspended, Unicode environment, explicit handle list
      if (info.CreateNoWindow) flags |= 0x08000000;
      if (!CreateProcessW(info.FileName, command, IntPtr.Zero, IntPtr.Zero, true, flags,
          environment, SelectWorkingDirectory(info), ref startup, out created)) throw new Win32Exception();
      run.Handle = created.Process;
      run.thread = created.Thread;
      run.Process = Process.GetProcessById(created.Pid);
      // Retain both handles before releasing the suspended target.
      var retained = run.Process.Handle;
      long nativeCreated, managedCreated, ignoredExit, ignoredKernel, ignoredUser;
      if (!GetProcessTimes(run.Handle, out nativeCreated, out ignoredExit, out ignoredKernel, out ignoredUser) ||
          !GetProcessTimes(retained, out managedCreated, out ignoredExit, out ignoredKernel, out ignoredUser))
        throw new Win32Exception();
      if (nativeCreated != managedCreated)
        throw new InvalidOperationException("Managed process generation differs from the held launch.");
      run.outputReader = new StreamReader(new FileStream(
        new Microsoft.Win32.SafeHandles.SafeFileHandle(outRead, true), FileAccess.Read));
      outRead = IntPtr.Zero;
      run.errorReader = new StreamReader(new FileStream(
        new Microsoft.Win32.SafeHandles.SafeFileHandle(errRead, true), FileAccess.Read));
      errRead = IntPtr.Zero;
      run.outputCapture = new OutputCapture(run.outputReader,
        standardOutputWriter ?? ForwardWriter(info.RedirectStandardOutput, Console.Out));
      run.errorCapture = new OutputCapture(run.errorReader,
        standardErrorWriter ?? ForwardWriter(info.RedirectStandardError, Console.Error));
      run.Output = run.outputCapture.Completion;
      run.Error = run.errorCapture.Completion;
      return run;
    } catch (Exception primary) {
      if (run.Handle != IntPtr.Zero) {
        try { run.Stop(); run.Close(); }
        catch (Exception cleanup) {
          var error = new InvalidOperationException("Owned launch failed: " + primary.Message +
            "; OWNED_CLEANUP_UNPROVEN: " + cleanup.Message, primary);
          error.Data["GraphCodeValidationRootRetentionRequired"] = true;
          throw error;
        }
      }
      throw;
    } finally {
      foreach (IntPtr handle in new[] { outRead, outWrite, errRead, errWrite, input })
        if (handle != IntPtr.Zero && handle != new IntPtr(-1)) CloseHandle(handle);
      if (initialized) DeleteProcThreadAttributeList(attributes);
      foreach (IntPtr allocation in new[] { attributes, handles, environment })
        if (allocation != IntPtr.Zero) Marshal.FreeHGlobal(allocation);
    }
  }

  public void Resume() {
    if (thread == IntPtr.Zero) throw new InvalidOperationException("Owned thread handle is unavailable.");
    uint previous = ResumeThread(thread);
    if (previous == UInt32.MaxValue) throw new Win32Exception();
    if (previous != 1) {
      var error = new InvalidOperationException("Owned launch suspension count changed before release.");
      error.Data["GraphCodeValidationRootRetentionRequired"] = true;
      throw error;
    }
    if (!CloseHandle(thread)) throw new Win32Exception();
    thread = IntPtr.Zero;
  }
  public void Stop() {
    uint state = WaitForSingleObject(Handle, 0);
    if (state == 0) return;
    if (state != 258) throw new Win32Exception();
    if (!TerminateProcess(Handle, 124) && WaitForSingleObject(Handle, 0) != 0) throw new Win32Exception();
    if (WaitForSingleObject(Handle, 5000) != 0) throw new InvalidOperationException("Owned process did not exit.");
  }
  public void RequireExited() {
    RequireExited(0);
  }
  public void RequireExited(int timeoutMilliseconds) {
    if (timeoutMilliseconds < 0) throw new ArgumentOutOfRangeException(nameof(timeoutMilliseconds));
    if (Handle == IntPtr.Zero)
      throw new InvalidOperationException("Original owned root is still live or its exit is unproved.");
    uint state = WaitForSingleObject(Handle, (uint)timeoutMilliseconds);
    if (state == 0) return;
    if (state == 258)
      throw new InvalidOperationException("Original owned root is still live or its exit is unproved.");
    throw new Win32Exception();
  }
  public string TakeOutput(int maximumCharacters) {
    if (outputCapture == null) throw new InvalidOperationException("Owned stdout capture is unavailable.");
    return outputCapture.Take(maximumCharacters);
  }
  public string TakeError(int maximumCharacters) {
    if (errorCapture == null) throw new InvalidOperationException("Owned stderr capture is unavailable.");
    return errorCapture.Take(maximumCharacters);
  }
  public void Drain() {
    foreach (var task in new[] { Output, Error })
      if (task != null && !task.Wait(5000)) throw new InvalidOperationException("Owned output EOF is unproved.");
  }
  public void Drain(int timeoutMilliseconds) {
    if (timeoutMilliseconds < 0) throw new ArgumentOutOfRangeException(nameof(timeoutMilliseconds));
    var clock = Stopwatch.StartNew();
    foreach (var task in new[] { Output, Error })
      if (task != null && !task.Wait(Math.Max(0, timeoutMilliseconds - (int)clock.ElapsedMilliseconds)))
        throw new InvalidOperationException("Owned output EOF is unproved.");
  }
  public void Close() {
    if (Handle != IntPtr.Zero) RequireExited();
    Drain();
    if (thread != IntPtr.Zero) { if (!CloseHandle(thread)) throw new Win32Exception(); thread = IntPtr.Zero; }
    if (Handle != IntPtr.Zero) { if (!CloseHandle(Handle)) throw new Win32Exception(); Handle = IntPtr.Zero; }
    if (outputReader != null) outputReader.Dispose();
    if (errorReader != null) errorReader.Dispose();
    if (outputCapture != null) outputCapture.Release();
    if (errorCapture != null) errorCapture.Release();
    if (Process != null) Process.Dispose();
  }
}
