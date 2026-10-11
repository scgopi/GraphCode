using System;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Diagnostics;

public class FramePump {
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool PeekNamedPipe(Microsoft.Win32.SafeHandles.SafePipeHandle h, IntPtr buf, uint size, IntPtr read, out uint avail, IntPtr left);

  public NamedPipeClientStream S;
  public bool Closed;
  public string Err;
  public FramePump(NamedPipeClientStream s) { S = s; }
  public void Start() { }

  bool Wait(int ms) {
    var sw = Stopwatch.StartNew();
    while (true) {
      uint avail;
      if (!PeekNamedPipe(S.SafePipeHandle, IntPtr.Zero, 0, IntPtr.Zero, out avail, IntPtr.Zero)) {
        Closed = true; Err = "peek failed " + Marshal.GetLastWin32Error(); return false;
      }
      if (avail > 0) return true;
      if (sw.ElapsedMilliseconds >= ms) return false;
      System.Threading.Thread.Sleep(10);
    }
  }
  bool Exact(byte[] b) {
    int o = 0;
    while (o < b.Length) {
      if (!Wait(5000)) return false;
      int r = S.Read(b, o, b.Length - o);
      if (r <= 0) { Closed = true; return false; }
      o += r;
    }
    return true;
  }
  public void Send(string s) {
    var b = Encoding.UTF8.GetBytes(s);
    int n = b.Length;
    var all = new byte[4 + n];
    all[0] = (byte)(n >> 24); all[1] = (byte)(n >> 16); all[2] = (byte)(n >> 8); all[3] = (byte)n;
    Array.Copy(b, 0, all, 4, n);
    S.Write(all, 0, all.Length);
    S.Flush();
  }
  public string Next(int ms) {
    if (!Wait(ms)) return null;
    var h = new byte[4];
    if (!Exact(h)) return null;
    int n = (h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3];
    var b = new byte[n];
    if (!Exact(b)) return null;
    return Encoding.UTF8.GetString(b);
  }
}
