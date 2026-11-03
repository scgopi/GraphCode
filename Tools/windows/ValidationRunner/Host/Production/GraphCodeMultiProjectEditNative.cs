#nullable disable
using System;
using System.Text;
using System.Diagnostics;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class GraphCodeMultiProjectEditNative {
  [StructLayout(LayoutKind.Sequential)] private struct Rect {public int Left,Top,Right,Bottom;}
  [StructLayout(LayoutKind.Sequential)] private struct GuiInfo {
    public int Size; public uint Flags; public IntPtr Active,Focus,Capture,MenuOwner,MoveSize,Caret; public Rect CaretRect;
  }
  [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", SetLastError=true)]
  private static extern IntPtr Message(IntPtr window, uint message, UIntPtr wparam, IntPtr lparam, uint flags, uint timeout, out UIntPtr result);
  [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern IntPtr TextMessage(IntPtr window, uint message, UIntPtr wparam, StringBuilder text, uint flags, uint timeout, out UIntPtr result);
  [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern IntPtr SetTextMessage(IntPtr window, uint message, UIntPtr wparam, string text, uint flags, uint timeout, out UIntPtr result);
  [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
  [DllImport("user32.dll",SetLastError=true)] private static extern bool GetGUIThreadInfo(uint thread,ref GuiInfo info);
  private static uint Remaining(int budget, Stopwatch watch) {
    long value=budget-watch.ElapsedMilliseconds;
    if(value<=0) throw new TimeoutException("N3e edit transaction deadline expired");
    return (uint)value;
  }
  private static UIntPtr ReadMessage(IntPtr window,uint message,UIntPtr first,IntPtr last,int budget,Stopwatch watch) {
    UIntPtr result;
    if(Message(window,message,first,last,0x23,Remaining(budget,watch),out result)==IntPtr.Zero)
      throw new Win32Exception(Marshal.GetLastWin32Error(),"N3e edit message unavailable/timed out");
    return result;
  }
  public static string Buffer(IntPtr edit,int budget) {
    var watch=Stopwatch.StartNew();
    int length=checked((int)ReadMessage(edit,0x000E,UIntPtr.Zero,IntPtr.Zero,budget,watch).ToUInt64());
    if(length<0 || length>65536) throw new InvalidOperationException("N3e edit buffer exceeds bound");
    var text=new StringBuilder(length+1); UIntPtr result;
    if(TextMessage(edit,0x000D,(UIntPtr)text.Capacity,text,0x23,Remaining(budget,watch),out result)==IntPtr.Zero)
      throw new Win32Exception(Marshal.GetLastWin32Error(),"N3e WM_GETTEXT unavailable/timed out");
    return text.ToString();
  }
  public static int[] Selection(IntPtr edit,int budget) {
    var watch=Stopwatch.StartNew(); IntPtr memory=Marshal.AllocHGlobal(8);
    try {
      Marshal.WriteInt32(memory,-1); Marshal.WriteInt32(memory,4,-1);
      ReadMessage(edit,0x00B0,(UIntPtr)memory.ToInt64(),IntPtr.Add(memory,4),budget,watch);
      return new[]{Marshal.ReadInt32(memory),Marshal.ReadInt32(memory,4)};
    } finally {Marshal.FreeHGlobal(memory);}
  }
  public static void SelectAll(IntPtr edit,int budget) {
    ReadMessage(edit,0x00B1,UIntPtr.Zero,new IntPtr(-1),budget,Stopwatch.StartNew());
  }
  public static void SetText(IntPtr edit,string text,int budget) {
    UIntPtr result;
    if(SetTextMessage(edit,0x000C,UIntPtr.Zero,text,0x23,(uint)budget,out result)==IntPtr.Zero)
      throw new Win32Exception(Marshal.GetLastWin32Error(),"N3e WM_SETTEXT unavailable/timed out");
  }
  public static IntPtr FocusOf(IntPtr modal) {
    uint pid; uint thread=GetWindowThreadProcessId(modal,out pid);
    var info=new GuiInfo{Size=Marshal.SizeOf(typeof(GuiInfo))};
    if(thread==0 || !GetGUIThreadInfo(thread,ref info)) throw new Win32Exception(Marshal.GetLastWin32Error(),"N3e GetGUIThreadInfo");
    return info.Focus;
  }
}
