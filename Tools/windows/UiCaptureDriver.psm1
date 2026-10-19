# Same A/cap lineage, FSL-1.1-MIT (repository LICENSE).
# CaptureWorker.psm1 SHA256 B35472CFD934B542F4A8867D8698F6C0688931AACA9D7DB96854E8290979B592.
# Native ownership/PrintWindow ancestry: capture-prompts.ps1
# SHA256 13F2FB63BE761F6E8549CD1ABF936CBD24D64BCF3A15BCB20644BA66DB7E81F6.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:CapPendingLaunches = [Collections.Generic.List[object]]::new()
$script:CapExcludedDescendants = [Collections.Generic.List[object]]::new()
$script:CapLastRollbackReceipt = $null
$script:CapTracePath = $null
$script:CapTraceFailures = [Collections.Generic.List[object]]::new()

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing

# Only the required FindTopLevel/PostCommand fragments, not the executable live gate.
# Tools/windows/uia-live-gate.ps1, first Add-Type, FSL-1.1-MIT:
# SHA256 7455148BDCB64A03914812DC415B39EB300293D8970502C1BDFD110044C30795.
# Extracted GraphCodeUiaGateState.cs:
# SHA256 C2514CECBC2637202D6DAE639DF33C77901EB69ADBEDD8CB795C37C8BF92B162.
$helperSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class GraphCodeUiaGateState {
  [DllImport("user32.dll", SetLastError = true)]
  private static extern bool PostMessage(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam);
  private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
  [DllImport("user32.dll")]
  private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
  [DllImport("user32.dll")]
  private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  private static extern int GetClassName(IntPtr window, StringBuilder className, int capacity);
  public static IntPtr FindTopLevel(string className, uint processId) {
    IntPtr result = IntPtr.Zero;
    EnumWindows(delegate(IntPtr window, IntPtr parameter) {
      uint owner;
      GetWindowThreadProcessId(window, out owner);
      if (owner != processId) return true;
      var actualClass = new StringBuilder(256);
      GetClassName(window, actualClass, actualClass.Capacity);
      if (!String.Equals(actualClass.ToString(), className, StringComparison.Ordinal)) return true;
      result = window;
      return false;
    }, IntPtr.Zero);
    return result;
  }
  public static bool PostCommand(IntPtr window, uint command) {
    return PostMessage(window, 0x0111, (UIntPtr)command, IntPtr.Zero);
  }
  public static bool PostHover(IntPtr window, int x, int y) {
    return PostMessage(window, 0x0200, UIntPtr.Zero, (IntPtr)((y << 16) | (x & 0xffff)));
  }
}
'@
if (-not ('GraphCodeUiaGateState' -as [type])) {
    Add-Type -TypeDefinition $helperSource
}

$nativeSource = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

public sealed class CapProcessSnapshot {
  public int ProcessId { get; set; }
  public long CreationFileTimeUtc { get; set; }
  public long ExitFileTimeUtc { get; set; }
  public string ImagePath { get; set; }
  public bool IsExited { get; set; }
}

public sealed class CapWindowSnapshot {
  public int[] OuterBounds { get; set; }
  public int[] ClientBounds { get; set; }
  public uint Dpi { get; set; }
}

public sealed class CapCaptureResult {
  public int Width { get; set; }
  public int Height { get; set; }
  public int SampledColors { get; set; }
  public int NonMagentaSamples { get; set; }
  public uint Dpi { get; set; }
}

public static class CapNative {
  private const uint WAIT_OBJECT_0 = 0;
  private const uint WAIT_TIMEOUT = 0x102;
  private const uint WAIT_FAILED = 0xFFFFFFFF;

  [StructLayout(LayoutKind.Sequential)]
  private struct NativeRect { public int Left, Top, Right, Bottom; }

  [StructLayout(LayoutKind.Sequential)]
  private struct NativeFileTime { public uint Low, High; }

  [StructLayout(LayoutKind.Sequential)]
  private struct ProcessBasicInformation {
    public IntPtr ExitStatus, PebBaseAddress, AffinityMask, BasePriority, ProcessId, ParentProcessId;
  }

  [DllImport("ntdll.dll")]
  private static extern int NtQueryInformationProcess(IntPtr process, int info, out ProcessBasicInformation value, uint size, out uint length);
  [DllImport("ntdll.dll")]
  private static extern int NtQueryInformationProcess(IntPtr process, int info, out uint value, uint size, out uint length);
  [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern IntPtr CommandLineToArgvW(string command, out int count);
  [DllImport("kernel32.dll", SetLastError=true)]
  private static extern IntPtr LocalFree(IntPtr memory);
  [DllImport("kernel32.dll", SetLastError=true)]
  private static extern uint GetProcessId(IntPtr process);
  [DllImport("kernel32.dll", SetLastError=true)]
  private static extern bool GetProcessTimes(IntPtr process, out NativeFileTime creation, out NativeFileTime exit, out NativeFileTime kernel, out NativeFileTime user);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder image, ref uint size);
  [DllImport("kernel32.dll", SetLastError=true)]
  private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
  [DllImport("kernel32.dll", SetLastError=true)]
  private static extern bool TerminateProcess(IntPtr process, uint exitCode);
  [DllImport("user32.dll", SetLastError=true)]
  private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
  [DllImport("user32.dll", SetLastError=true)]
  private static extern bool GetWindowRect(IntPtr window, out NativeRect rect);
  [DllImport("user32.dll", SetLastError=true)]
  private static extern bool GetClientRect(IntPtr window, out NativeRect rect);
  [DllImport("user32.dll")]
  private static extern uint GetDpiForWindow(IntPtr window);
  [DllImport("user32.dll", SetLastError=true)]
  private static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern bool WaitNamedPipeW(string name, uint timeout);

  private static long FileTime(NativeFileTime value) {
    return ((long)value.High << 32) | value.Low;
  }

  public static int ParentProcessId(IntPtr handle, int expectedPid) {
    if (handle == IntPtr.Zero || GetProcessId(handle) != (uint)expectedPid)
      throw new InvalidOperationException("Process handle/PID mismatch.");
    ProcessBasicInformation value;
    uint length;
    int status = NtQueryInformationProcess(handle, 0, out value,
      (uint)Marshal.SizeOf<ProcessBasicInformation>(), out length);
    if (status != 0 || length != Marshal.SizeOf<ProcessBasicInformation>() ||
        value.ProcessId.ToInt64() != expectedPid)
      throw new InvalidOperationException("Native parent query failed for held PID " + expectedPid + ": " + status);
    return checked((int)value.ParentProcessId.ToInt64());
  }

  public static int SessionId(IntPtr handle, int expectedPid) {
    if (handle == IntPtr.Zero || GetProcessId(handle) != (uint)expectedPid)
      throw new InvalidOperationException("Process handle/PID mismatch.");
    uint value, length;
    int status = NtQueryInformationProcess(handle, 24, out value, sizeof(uint), out length);
    if (status != 0 || length != sizeof(uint))
      throw new InvalidOperationException("Native session query failed for held PID " + expectedPid + ": " + status);
    return checked((int)value);
  }

  public static string[] CommandArguments(string command) {
    if (String.IsNullOrWhiteSpace(command)) throw new ArgumentException("Empty process command line.");
    int count;
    IntPtr memory = CommandLineToArgvW(command, out count);
    if (memory == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
    try {
      var result = new string[count];
      for (int i = 0; i < count; i++)
        result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory, i * IntPtr.Size));
      return result;
    } finally {
      if (LocalFree(memory) != IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
    }
  }

  public static CapProcessSnapshot Snapshot(IntPtr handle, int expectedPid) {
    if (handle == IntPtr.Zero) throw new ArgumentNullException("handle");
    uint pid = GetProcessId(handle);
    if (pid == 0 || pid != (uint)expectedPid) throw new InvalidOperationException("Process handle/PID mismatch.");
    NativeFileTime creation, exit, kernel, user;
    if (!GetProcessTimes(handle, out creation, out exit, out kernel, out user))
      throw new InvalidOperationException("GetProcessTimes failed: " + Marshal.GetLastWin32Error());
    uint wait = WaitForSingleObject(handle, 0);
    if (wait == WAIT_FAILED) throw new InvalidOperationException("WaitForSingleObject failed: " + Marshal.GetLastWin32Error());
    bool exited = wait == WAIT_OBJECT_0;
    string path = "";
    uint size = 32768;
    var buffer = new StringBuilder((int)size);
    if (QueryFullProcessImageNameW(handle, 0, buffer, ref size)) path = buffer.ToString();
    else if (!exited) throw new InvalidOperationException("QueryFullProcessImageName failed for live PID " + pid + ": " + Marshal.GetLastWin32Error());
    return new CapProcessSnapshot {
      ProcessId = (int)pid,
      CreationFileTimeUtc = FileTime(creation),
      ExitFileTimeUtc = exited ? FileTime(exit) : 0,
      ImagePath = path,
      IsExited = exited
    };
  }

  public static int WindowProcessId(IntPtr window) {
    uint processId;
    if (window == IntPtr.Zero || GetWindowThreadProcessId(window, out processId) == 0 || processId == 0)
      throw new InvalidOperationException("GetWindowThreadProcessId failed: " + Marshal.GetLastWin32Error());
    return (int)processId;
  }

  public static bool IsExited(IntPtr handle, int pid) {
    uint wait = WaitForSingleObject(handle, 0);
    if (wait == WAIT_OBJECT_0) return true;
    if (wait == WAIT_TIMEOUT) return false;
    throw new InvalidOperationException("Kernel wait failed for PID " + pid + ": " + Marshal.GetLastWin32Error());
  }

  public static bool Terminate(IntPtr handle, int pid, uint exitCode, int timeoutMilliseconds) {
    if (IsExited(handle, pid)) return false;
    bool terminated = TerminateProcess(handle, exitCode);
    int terminateError = terminated ? 0 : Marshal.GetLastWin32Error();
    uint wait = WaitForSingleObject(handle, (uint)timeoutMilliseconds);
    if (wait == WAIT_OBJECT_0) return terminated;
    throw new InvalidOperationException("Guarded process did not exit within " + timeoutMilliseconds +
      " ms; TerminateProcess=" + terminated + " error=" + terminateError + " wait=" + wait);
  }

  public static bool SetWindowPosition(IntPtr window, int x, int y, int width, int height) {
    return SetWindowPos(window, IntPtr.Zero, x, y, width, height, 0x0014);
  }

  public static CapWindowSnapshot WindowSnapshot(IntPtr window, int expectedPid) {
    uint owner;
    if (window == IntPtr.Zero || GetWindowThreadProcessId(window, out owner) == 0 || owner != (uint)expectedPid)
      throw new InvalidOperationException("Window ownership mismatch.");
    NativeRect outer, client;
    if (!GetWindowRect(window, out outer) || !GetClientRect(window, out client))
      throw new InvalidOperationException("Window geometry query failed: " + Marshal.GetLastWin32Error());
    return new CapWindowSnapshot {
      OuterBounds = new[] { outer.Left, outer.Top, outer.Right, outer.Bottom },
      ClientBounds = new[] { client.Left, client.Top, client.Right, client.Bottom },
      Dpi = GetDpiForWindow(window)
    };
  }

  public static CapCaptureResult CaptureWindow(IntPtr window, int expectedPid, string path) {
    uint owner;
    NativeRect rect;
    if (window == IntPtr.Zero || GetWindowThreadProcessId(window, out owner) == 0 || owner != (uint)expectedPid ||
        !GetWindowRect(window, out rect) || rect.Right <= rect.Left || rect.Bottom <= rect.Top)
      throw new InvalidOperationException("Capture ownership/geometry mismatch.");
    int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
    using (var bitmap = new Bitmap(width, height, PixelFormat.Format24bppRgb))
    using (var graphics = Graphics.FromImage(bitmap)) {
      graphics.Clear(Color.Magenta);
      IntPtr dc = graphics.GetHdc();
      bool ok;
      try { ok = PrintWindow(window, dc, 2); }
      finally { graphics.ReleaseHdc(dc); }
      if (!ok) throw new InvalidOperationException("PrintWindow(flag=2) failed.");
      var colors = new System.Collections.Generic.HashSet<int>();
      int nonMagenta = 0;
      for (int y = 4; y < bitmap.Height; y += 12) {
        for (int x = 4; x < bitmap.Width; x += 12) {
          int color = bitmap.GetPixel(x, y).ToArgb();
          colors.Add(color);
          if (color != Color.Magenta.ToArgb()) nonMagenta++;
        }
      }
      if (colors.Count < 4 || nonMagenta < 20)
        throw new InvalidOperationException("PrintWindow pixel check failed: distinct=" + colors.Count + " painted=" + nonMagenta);
      bitmap.Save(path, ImageFormat.Png);
      return new CapCaptureResult {
        Width = width,
        Height = height,
        SampledColors = colors.Count,
        NonMagentaSamples = nonMagenta,
        Dpi = GetDpiForWindow(window)
      };
    }
  }

  public static int ProbePipe(string pipeName, uint timeoutMilliseconds) {
    if (String.IsNullOrWhiteSpace(pipeName) || pipeName.Contains("\\") || pipeName.Contains("/"))
      throw new ArgumentException("PipeName must be an unqualified unique pipe name.", "pipeName");
    string path = @"\\.\pipe\" + pipeName;
    if (WaitNamedPipeW(path, timeoutMilliseconds)) return 0;
    return Marshal.GetLastWin32Error();
  }

  [DllImport("user32.dll", SetLastError=true)]
  private static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
}
'@

if (-not ('CapNative' -as [type])) {
    Add-Type -TypeDefinition $nativeSource -ReferencedAssemblies @(
        [System.Drawing.Bitmap].Assembly.Location,
        [System.Drawing.Graphics].Assembly.Location,
        [System.Drawing.Color].Assembly.Location,
        (Join-Path $PSHOME 'System.Private.Windows.Core.dll'),
        (Join-Path $PSHOME 'System.Private.Windows.GdiPlus.dll'),
        'System.Collections.dll',
        'System.ComponentModel.Primitives.dll',
        'Microsoft.Win32.Primitives.dll'
    )
}

function Set-CapTracePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $script:CapTracePath = [IO.Path]::GetFullPath($Path)
}

$jobSource = @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
// Adapted from this repository's Packaging.Standalone.Tests.ps1 StandaloneProcessJob.
public static class CapProcessJob {
  [StructLayout(LayoutKind.Sequential)]
  struct BasicLimits { public long ProcessTime, JobTime; public uint Flags; public UIntPtr Min, Max; public uint Active; public UIntPtr Affinity; public uint Priority, Scheduling; }
  [StructLayout(LayoutKind.Sequential)]
  struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
  [StructLayout(LayoutKind.Sequential)]
  struct Limits { public BasicLimits Basic; public IoCounters Io; public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory; }
  [StructLayout(LayoutKind.Sequential)]
  struct Accounting { public long User, Kernel, PeriodUser, PeriodKernel; public uint Faults, Total, Active, Terminated; }
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateJobObjectW(IntPtr attributes, IntPtr name);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int info, ref Limits limits, uint size);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int info, out Accounting value, uint size, IntPtr length);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int info, IntPtr buffer, uint size, IntPtr length);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, uint code);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr GetStdHandle(int number);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
  public static void ClearStandardHandleInheritance() {
    foreach (int number in new[] { -10, -11, -12 }) {
      IntPtr handle = GetStdHandle(number);
      if (handle == IntPtr.Zero || handle == new IntPtr(-1))
        throw new InvalidOperationException("Invalid own STD handle: " + number);
      if (!SetHandleInformation(handle, 1, 0)) throw new Win32Exception();
    }
  }
  public static IntPtr Create() {
    IntPtr job = CreateJobObjectW(IntPtr.Zero, IntPtr.Zero);
    if (job == IntPtr.Zero) throw new Win32Exception();
    var limits = new Limits();
    limits.Basic.Flags = 0x2000; // KILL_ON_JOB_CLOSE; no escape flags.
    if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<Limits>())) {
      var error = new Win32Exception();
      if (!CloseHandle(job)) throw new InvalidOperationException("Job configuration and handle close both failed.", error);
      throw error;
    }
    return job;
  }
  public static bool Contains(IntPtr job, IntPtr process) {
    bool result;
    if (!IsProcessInJob(process, job, out result)) throw new Win32Exception();
    return result;
  }
  public static void Assign(IntPtr job, IntPtr process) {
    if (!AssignProcessToJobObject(job, process)) throw new Win32Exception();
    if (!Contains(job, process)) throw new InvalidOperationException("Assigned launcher is not a job member.");
  }
  public static uint Active(IntPtr job) {
    Accounting value;
    if (!QueryInformationJobObject(job, 1, out value, (uint)Marshal.SizeOf<Accounting>(), IntPtr.Zero)) throw new Win32Exception();
    return value.Active;
  }
  public static int[] Members(IntPtr job) {
    const int capacity = 4096;
    int size = 8 + capacity * IntPtr.Size;
    IntPtr buffer = Marshal.AllocHGlobal(size);
    try {
      if (!QueryInformationJobObject(job, 3, buffer, (uint)size, IntPtr.Zero)) throw new Win32Exception();
      int assigned = Marshal.ReadInt32(buffer, 0), count = Marshal.ReadInt32(buffer, 4);
      if (count < 0 || count > capacity || assigned != count)
        throw new InvalidOperationException("Incomplete job member census.");
      var result = new int[count];
      for (int i = 0; i < count; i++)
        result[i] = checked((int)Marshal.ReadIntPtr(buffer, 8 + i * IntPtr.Size).ToInt64());
      return result;
    } finally { Marshal.FreeHGlobal(buffer); }
  }
  public static void Terminate(IntPtr job) {
    if (!TerminateJobObject(job, 125)) throw new Win32Exception();
  }
  public static void WaitForEmpty(IntPtr job, int milliseconds) {
    var clock = Stopwatch.StartNew();
    while (Active(job) != 0) {
      if (clock.ElapsedMilliseconds >= milliseconds) throw new TimeoutException("Owned capture job still has active processes.");
      System.Threading.Thread.Sleep(10);
    }
  }
  public static void Close(IntPtr job) {
    if (!CloseHandle(job)) throw new Win32Exception();
  }
}
'@
if (-not ('CapProcessJob' -as [type])) {
    Add-Type -TypeDefinition $jobSource -ReferencedAssemblies @(
        'System.Runtime.dll','System.Runtime.InteropServices.dll','System.ComponentModel.Primitives.dll',
        'Microsoft.Win32.Primitives.dll','System.Diagnostics.Process.dll','System.Threading.Thread.dll'
    )
}

# Embedded in the bound module: the child cannot spawn a target until its private
# stdin gate is released after assignment and immutable launcher registration.
$jobLauncherSource = @'
$ErrorActionPreference = 'Stop'
$specBytes = [IO.File]::ReadAllBytes($specPath)
if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($specBytes)) -cne $specHash) {
    throw 'Contained launcher specification bytes changed.'
}
$spec = [Text.UTF8Encoding]::new($false, $true).GetString($specBytes) | ConvertFrom-Json -DateKind String
if ((Get-FileHash -LiteralPath $spec.modulePath -Algorithm SHA256).Hash -cne $spec.moduleSha256) {
    throw 'Contained launcher source binding changed.'
}
Import-Module $spec.modulePath -Force -WarningAction SilentlyContinue
[CapProcessJob]::ClearStandardHandleInheritance()
$gate = [Console]::In.ReadLineAsync()
if (-not $gate.Wait(30000) -or $gate.Result -cne $specHash) { throw 'Contained launcher gate was not authorized.' }
foreach ($path in @($spec.stdoutPath, $spec.stderrPath, $spec.targetReceiptPath, $spec.exitReceiptPath)) {
    $null = Assert-CapArtifactPath -Root $spec.root -Path $path
}
$stdout = [IO.FileStream]::new($spec.stdoutPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::Read, 1, $true)
$stderr = $null
$process = $null
try {
    $stderr = [IO.FileStream]::new($spec.stderrPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::Read, 1, $true)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $spec.filePath
    $info.WorkingDirectory = $spec.workingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    foreach ($argument in $spec.arguments) { $info.ArgumentList.Add([string]$argument) }
    foreach ($key in @($info.Environment.Keys)) {
        if ($key -like 'GRAPHCODE_*' -or $key -like 'ZMX_*') { $null = $info.Environment.Remove($key) }
    }
    foreach ($property in $spec.environment.PSObject.Properties) { $info.Environment[$property.Name] = [string]$property.Value }
    $process = [Diagnostics.Process]::Start($info)
    if ($null -eq $process) { throw 'Contained normal Process.Start returned null.' }
    $access = Read-CapProcessAccess -Process $process -Role 'contained-target' -CallSite 'JobLauncher.InitialSnapshot'
    $snapshot = [CapNative]::Snapshot($access.Handle, $access.Pid)
    if (-not $snapshot.IsExited -and $snapshot.ImagePath -ine $spec.filePath) { throw 'Contained target image differs.' }
    $outPump = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
    $errPump = $process.StandardError.BaseStream.CopyToAsync($stderr)
    $process.StandardInput.Close()
    $null = Write-CapImmutableJson -Root $spec.root -Path $spec.targetReceiptPath -Value ([pscustomobject]@{
        jobId = $spec.jobId; specSha256 = $specHash; pid = [long]$access.Pid
        creationFileTimeUtc = [long]$snapshot.CreationFileTimeUtc
        expectedImagePath = $spec.filePath; arguments = @($spec.arguments)
        attestation = 'NORMAL_START_RETAINED_HANDLE_NOT_PREEXECUTION_IDENTITY'
    })
    while (-not $process.WaitForExit(100)) {}
    $access = Read-CapProcessAccess -Process $process -Role 'contained-target' `
        -CallSite 'JobLauncher.ExitSnapshot' -ExpectedPid $snapshot.ProcessId
    $exit = [CapNative]::Snapshot($access.Handle, $access.Pid)
    if (-not $exit.IsExited) { throw 'Contained target exit lacks a signalled original handle.' }
    $null = Write-CapImmutableJson -Root $spec.root -Path $spec.exitReceiptPath -Value ([pscustomobject]@{
        jobId = $spec.jobId; specSha256 = $specHash; pid = [long]$access.Pid
        creationFileTimeUtc = [long]$snapshot.CreationFileTimeUtc; exitCode = [long]$process.ExitCode; kernelExited = $true
    })
    # The job owner may terminate this host while daemon descendants still hold
    # these private target pipes. Files are not labelled pipe EOF in that case.
    [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outPump, $errPump))
    $stdout.Flush($true); $stderr.Flush($true)
} finally {
    if ($null -ne $process) { $process.Dispose() }
    if ($null -ne $stderr) { $stderr.Dispose() }
    $stdout.Dispose()
}
'@

function Start-CapJobLauncher {
    [CmdletBinding()]
    param([string]$Root, [string]$OutputDirectory, [string]$FilePath,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$ArgumentList, [string]$WorkingDirectory,
        [string]$Role, [hashtable]$Environment = @{})
    $directory = Assert-CapArtifactPath -Root $Root -Path $OutputDirectory
    $filePath = [IO.Path]::GetFullPath($FilePath)
    if (-not [IO.Path]::IsPathFullyQualified($FilePath) -or -not [IO.File]::Exists($filePath)) {
        throw 'Contained target requires an existing absolute executable path.'
    }
    $jobId = [guid]::NewGuid().ToString('N')
    $specPath = Join-Path $directory "$jobId-launch.json"
    $stdoutPath = Join-Path $directory "$jobId-stdout.log"
    $stderrPath = Join-Path $directory "$jobId-stderr.log"
    $spec = [pscustomobject]@{
        root = $Root; jobId = $jobId; modulePath = (Join-Path $PSScriptRoot 'UiCaptureDriver.psm1')
        moduleSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'UiCaptureDriver.psm1') -Algorithm SHA256).Hash
        filePath = $filePath; arguments = @($ArgumentList); workingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
        environment = [pscustomobject]$Environment; stdoutPath = $stdoutPath; stderrPath = $stderrPath
        targetReceiptPath = (Join-Path $directory "$jobId-target.json")
        exitReceiptPath = (Join-Path $directory "$jobId-exit.json")
    }
    $pins = [Collections.Generic.List[IO.Stream]]::new()
    $job = [IntPtr]::Zero
    $run = $null
    try {
        foreach ($path in @($stdoutPath, $stderrPath)) {
            $created = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $created.Dispose()
            $pins.Add([IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite))
        }
        $specReference = Write-CapImmutableJson -Root $Root -Path $specPath -Value $spec
        $job = [CapProcessJob]::Create()
        $prefix = '$specPath = ' + "'" + $specPath.Replace("'", "''") + "'`n" +
            '$specHash = ' + "'" + $specReference.sha256 + "'`n"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($prefix + $jobLauncherSource))
        $run = Start-CapManagedProcess -FilePath (Join-Path $PSHOME 'pwsh.exe') `
            -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) `
            -WorkingDirectory $WorkingDirectory -Role $Role -HoldStdin
        [CapProcessJob]::Assign($job, $run.Identity.Process.Handle)
        $run.Identity | Add-Member -NotePropertyName JobId -NotePropertyValue $jobId
        $run | Add-Member -NotePropertyMembers @{
            Job = $job; JobId = $jobId; Root = $Root; SpecSha256 = $specReference.sha256
            TargetReceiptPath = $spec.targetReceiptPath; ExitReceiptPath = $spec.exitReceiptPath
            TargetReceipt = $null; TargetExit = $null; OutputPaths = @($stdoutPath,$stderrPath)
            OutputPins = $pins; ClosedOutputPins = [Collections.Generic.List[IO.Stream]]::new()
            Members = [Collections.Generic.List[object]]::new(); GateReleased = $false
            CleanupComplete = $false; OutputProof = $null
        }
        return $run
    } catch {
        $primary = $_
        $cleanup = [Collections.Generic.List[string]]::new()
        if ($job -ne [IntPtr]::Zero) {
            try {
                [CapProcessJob]::Terminate($job)
                [CapProcessJob]::WaitForEmpty($job, 5000)
                if ([CapProcessJob]::Active($job) -ne 0) { throw 'Job not empty before close.' }
                [CapProcessJob]::Close($job)
            } catch { $cleanup.Add($_.Exception.ToString()) }
        }
        if ($run) {
            try {
                $null = Stop-CapManagedProcess -Identity $run.Identity
                if (-not $run.StdoutTask.Wait(2000) -or -not $run.StderrTask.Wait(2000)) { throw 'Unreleased launcher raw EOF unproved.' }
                $run.Identity.Process.Dispose()
            } catch { $cleanup.Add($_.Exception.ToString()) }
        }
        foreach ($pin in $pins) { $pin.Dispose() }
        if ($cleanup.Count) { throw "Contained launch failed: $($primary.Exception.Message); CLEANUP_UNPROVEN: $($cleanup -join '; ')" }
        throw $primary
    }
}

function Release-CapJobLauncher {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Run, [Parameter(Mandatory)]$JournalState)
    if ($Run.GateReleased -or $Run.CleanupComplete -or
        -not [CapProcessJob]::Contains($Run.Job, $Run.Identity.Process.Handle)) { throw 'Invalid contained launcher gate state.' }
    if ($JournalState.Sequence -lt 1) { throw 'Launcher requires an immutable journal publication before gate release.' }
    $snapshot = Read-CapJournalObject $JournalState $JournalState.Sequence (New-CapJournalTransaction $JournalState)
    $entries = @($snapshot.Payload.data.entries | Where-Object {
        $_.pid -eq $Run.Identity.Pid -and $_.creationFileTimeUtc -eq $Run.Identity.CreationFileTimeUtc -and
        $_.PSObject.Properties['jobId'] -and $_.jobId -ceq $Run.JobId
    })
    if ($entries.Count -ne 1) { throw 'Publication does not bind the assigned launcher generation/job.' }
    $Run.Identity.Process.StandardInput.WriteLine($Run.SpecSha256)
    $Run.Identity.Process.StandardInput.Flush()
    $Run.Identity.Process.StandardInput.Close()
    $Run.GateReleased = $true
    $Run.TargetReceipt = Read-CapJobTargetRecord -Run $Run -Path $Run.TargetReceiptPath `
        -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(10))
    return $Run.TargetReceipt
}

function Read-CapJobTargetRecord {
    param($Run, [string]$Path, [DateTime]$DeadlineUtc)
    $observation = 'NotPublished'
    $nativeError = $null
    $attempt = 0
    while ([DateTime]::UtcNow -lt $DeadlineUtc) {
        $attempt++
        $bytes = $null
        try {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try {
                $memory = [IO.MemoryStream]::new()
                try { $stream.CopyTo($memory); $bytes = $memory.ToArray() } finally { $memory.Dispose() }
            } finally { $stream.Dispose() }
        } catch [IO.IOException] {
            $nativeError = Get-CapJournalNativeError $_.Exception
            if ($nativeError -notin @('80070002','80070003','80070020')) { throw }
            $observation = if ($nativeError -eq '80070020') { 'SharingViolation' } else { 'NotPublished' }
            if ($nativeError -ne '80070020' -and
                [CapNative]::IsExited($Run.Identity.Process.Handle, $Run.Identity.Pid)) {
                throw "Contained launcher exited without target receipt: $Path"
            }
        }
        if ($null -ne $bytes) {
            if ([DateTime]::UtcNow -ge $DeadlineUtc) { break }
            $record = $null
            try { $record = ConvertFrom-CapJournalBytes $bytes }
            catch [IO.IOException] {
                $class = $null
                for ($exception = $_.Exception; $null -ne $exception; $exception = $exception.InnerException) {
                    if ($exception.Data.Contains('CapJournalFailure')) { $class = $exception.Data['CapJournalFailure']; break }
                }
                if ($class -notin @('JournalEncoding','JournalParse')) { throw }
                $observation = 'MalformedReceiptJson'
            }
            $fields = @{ jobId = [string]; specSha256 = [string]; pid = [long]; creationFileTimeUtc = [long] }
            if ($Path -ieq $Run.ExitReceiptPath) { $fields.exitCode = [long]; $fields.kernelExited = [bool] }
            $complete = $record -is [pscustomobject]
            if ($complete) {
                foreach ($name in $fields.Keys) {
                    $property = $record.PSObject.Properties[$name]
                    if ($null -eq $property -or $null -eq $property.Value -or
                        -not $fields[$name].IsInstanceOfType($property.Value)) { $complete = $false; break }
                }
            }
            if ($complete) {
                if ($record.jobId -cne $Run.JobId -or $record.specSha256 -cne $Run.SpecSha256 -or
                    $record.pid -le 0 -or $record.creationFileTimeUtc -le 0 -or
                    ($null -ne $Run.TargetReceipt -and ($record.pid -ne $Run.TargetReceipt.pid -or
                        $record.creationFileTimeUtc -ne $Run.TargetReceipt.creationFileTimeUtc))) {
                    $failure = [IO.InvalidDataException]::new('ReceiptIdentityMismatch: contained target receipt binding differs.')
                    $failure.Data['CapCaptureCode'] = 'ReceiptIdentityMismatch'
                    throw $failure
                }
                if ([DateTime]::UtcNow -ge $DeadlineUtc) { break }
                return $record
            }
            $observation = 'MalformedReceiptJson'
        }
        Write-CapTrace -Command 'CapReceiptReadRetry' -Parameters @{
            Path = $Path; Attempt = $attempt; Observation = $observation; NativeHresult = $nativeError
        }
        $remaining = ($DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds
        if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Min(20, [Math]::Ceiling($remaining))) }
    }
    $failure = [TimeoutException]::new("Contained target deadline reached: $Path; ReceiptDeadlineExceeded, last=$observation.")
    $failure.Data['CapCaptureCode'] = 'ReceiptDeadlineExceeded'
    $failure.Data['LastReceiptObservation'] = $observation
    $failure.Data['LastNativeHresult'] = $nativeError
    throw $failure
}

function Wait-CapJobTarget {
    [CmdletBinding()]
    param($Run, [DateTime]$DeadlineUtc)
    $record = Read-CapJobTargetRecord -Run $Run -Path $Run.ExitReceiptPath -DeadlineUtc $DeadlineUtc
    Assert-CapDataRecord $record @{ exitCode = [long]; kernelExited = [bool] } 'Contained target exit'
    if (-not $record.kernelExited -or $record.pid -ne $Run.TargetReceipt.pid -or
        $record.creationFileTimeUtc -ne $Run.TargetReceipt.creationFileTimeUtc) { throw 'Contained target exit generation differs.' }
    $Run.TargetExit = $record
    return $record
}

function Get-CapJobMembers {
    [CmdletBinding()]
    param($Run)
    $members = [Collections.Generic.List[object]]::new()
    foreach ($memberPid in [CapProcessJob]::Members($Run.Job)) {
        if ($memberPid -eq $Run.Identity.Pid) { continue }
        $process = $null
        try { $process = [Diagnostics.Process]::GetProcessById($memberPid) }
        catch [ArgumentException] {
            if ($memberPid -in [CapProcessJob]::Members($Run.Job)) { throw 'Job member identity unavailable while still listed.' }
            continue
        }
        $retained = $false
        try {
            $access = Read-CapProcessAccess -Process $process -Role 'job-member' `
                -CallSite 'Get-CapJobMembers.Snapshot' -ExpectedPid $memberPid
            if (-not [CapProcessJob]::Contains($Run.Job, $access.Handle)) {
                throw 'Census PID does not identify a held job-member generation.'
            }
            $snapshot = [CapNative]::Snapshot($access.Handle, $access.Pid)
            if ($snapshot.IsExited) { continue }
            $existing = @($Run.Members | Where-Object { $_.Pid -eq $memberPid -and
                $_.CreationFileTimeUtc -eq $snapshot.CreationFileTimeUtc })
            if ($existing.Count -eq 1) { $members.Add($existing[0]); continue }
            $identity = Get-CapProcessIdentity -Process $process -ExpectedImagePath $snapshot.ImagePath -Role 'job-member'
            $identity | Add-Member -NotePropertyName JobId -NotePropertyValue $Run.JobId
            $Run.Members.Add($identity); $members.Add($identity); $retained = $true
        } finally { if (-not $retained) { $process.Dispose() } }
    }
    return @($members.ToArray())
}

function Close-CapJobLauncher {
    [CmdletBinding()]
    param($Run)
    if ($Run.CleanupComplete) { return $Run.OutputProof }
    $censusFailure = $null
    try { $null = Get-CapJobMembers -Run $Run }
    catch { $censusFailure = $_ }
    if ($null -ne $Run.TargetExit) { $null = $Run.Identity.Process.WaitForExit(250) }
    [CapProcessJob]::Terminate($Run.Job)
    [CapProcessJob]::WaitForEmpty($Run.Job, 5000)
    $active = [CapProcessJob]::Active($Run.Job)
    if ($active -ne 0) { throw 'Contained job Active=0 was not observed before handle close.' }
    if (-not $Run.StdoutTask.Wait(2000) -or -not $Run.StderrTask.Wait(2000)) {
        throw 'Contained launcher raw stdout/stderr EOF was not reached.'
    }
    $files = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $Run.OutputPaths.Count; $index++) {
        $path = $Run.OutputPaths[$index]
        $exclusive = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $Run.ClosedOutputPins.Add($exclusive)
        $pin = $Run.OutputPins[$index]
        $pin.Position = 0; $exclusive.Position = 0
        $pinHash = (Get-FileHash -InputStream $pin -Algorithm SHA256).Hash
        $hash = (Get-FileHash -InputStream $exclusive -Algorithm SHA256).Hash
        if ($pin.Length -ne $exclusive.Length -or $pinHash -cne $hash) { throw 'Pinned owned output bytes differ.' }
        $files.Add([pscustomobject]@{ path = $path; length = [long]$exclusive.Length; sha256 = $hash })
    }
    $Run.OutputProof = [pscustomobject]@{
        kind = 'OWNED_FILES_JOB'; jobId = $Run.JobId; state = 'CLOSED'
        jobActive0 = $true; activeProcesses = [long]$active
        launcherPid = [long]$Run.Identity.Pid; launcherCreationFileTimeUtc = [long]$Run.Identity.CreationFileTimeUtc
        launcherStdoutEof = $true; launcherStderrEof = $true
        files = @($files.ToArray()); memberCount = [long]$Run.Members.Count
        censusProven = $null -eq $censusFailure
        transport = 'PRIVATE_TARGET_PIPE_PUMPS_TO_OWNED_FILES'
        targetPipeEofClaimed = $false
    }
    [CapProcessJob]::Close($Run.Job)
    $Run.Job = [IntPtr]::Zero
    $Run.CleanupComplete = $true
    if ($censusFailure) { throw "Contained job is empty but member census was unproved: $($censusFailure.Exception.Message)" }
    return $Run.OutputProof
}

function Assert-CapJobOutputProof {
    [CmdletBinding()]
    param([string]$Root, $Proof, [switch]$RetainStreams)
    Assert-CapDataRecord $Proof @{ kind = [string]; jobId = [string]; state = [string]
        jobActive0 = [bool]; activeProcesses = [long]; files = [array]
        launcherStdoutEof = [bool]; launcherStderrEof = [bool]; censusProven = [bool]
        launcherPid = [long]; launcherCreationFileTimeUtc = [long] } 'Job output proof'
    $null = [guid]::Parse($Proof.jobId)
    if ($Proof.kind -cne 'OWNED_FILES_JOB' -or $Proof.state -cne 'CLOSED' -or -not $Proof.jobActive0 -or
        $Proof.activeProcesses -ne 0 -or -not $Proof.launcherStdoutEof -or
        -not $Proof.launcherStderrEof -or -not $Proof.censusProven -or
        $Proof.launcherPid -le 0 -or $Proof.launcherCreationFileTimeUtc -le 0 -or
        $Proof.files.Count -ne 2) { throw 'Job output closure is unproved.' }
    $held = [Collections.Generic.List[IO.Stream]]::new()
    $keep = $false
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($file in $Proof.files) {
            Assert-CapDataRecord $file @{ path = [string]; length = [long]; sha256 = [string] } 'Owned output bytes'
            $path = Assert-CapArtifactPath -Root $Root -Path $file.path
            if (-not $paths.Add($path) -or $file.length -lt 0 -or $file.sha256 -cnotmatch '\A[A-F0-9]{64}\z') {
                throw 'Invalid or duplicate owned output bytes.'
            }
            $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $held.Add($stream)
            if ($stream.Length -ne $file.length -or (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash -cne $file.sha256) {
                throw 'Owned output bytes changed after closure.'
            }
        }
        if ($RetainStreams) { $keep = $true; return @($held.ToArray()) }
    } finally { if (-not $keep) { foreach ($stream in $held) { $stream.Dispose() } } }
}

function Write-CapTrace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [System.Collections.IDictionary]$Parameters = @{}
    )
    if (-not $script:CapTracePath) { return }
    $values = [ordered]@{}
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        $values[$key] = if ($null -eq $value -or $value -is [string] -or $value -is [ValueType] -or
            $value -is [string[]]) { $value }
        elseif ($value.PSObject.Properties['Pid'] -and $value.PSObject.Properties['CreationFileTimeUtc'] -and
            $value.PSObject.Properties['ExpectedImagePath'] -and $value.PSObject.Properties['Role']) {
            [ordered]@{ pid = $value.Pid; creationFileTimeUtc = $value.CreationFileTimeUtc
                expectedImagePath = $value.ExpectedImagePath; role = $value.Role }
        } else { $value.GetType().FullName }
    }
    $stack = @(Get-PSCallStack | Select-Object -Skip 1 -First 2 | ForEach-Object {
        [ordered]@{ command = $_.Command; file = $_.ScriptName; line = $_.ScriptLineNumber }
    })
    $line = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); callerPid = $PID; callsites = $stack
        command = $Command; parameters = $values } | ConvertTo-Json -Depth 8 -Compress
    try {
        [IO.File]::AppendAllText($script:CapTracePath, $line + "`n", [Text.UTF8Encoding]::new($false))
    } catch [IO.IOException], [UnauthorizedAccessException] {
        if (-not @($script:CapTraceFailures | Where-Object command -CEQ $Command).Count) {
            $script:CapTraceFailures.Add([pscustomobject]@{
                command = $Command; path = $script:CapTracePath; failure = $_.Exception.ToString()
            })
            [Console]::Error.WriteLine("CAP_TRACE_FAILURE command=$Command path=$($script:CapTracePath): $($_.Exception.Message)")
        }
    }
}

function Get-CapTraceFailures {
    [CmdletBinding()]
    param()
    return @($script:CapTraceFailures.ToArray())
}

function Assert-CapArtifactPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    foreach ($candidate in @($Root, $Path)) {
        if (-not [IO.Path]::IsPathFullyQualified($candidate) -or $candidate -notmatch '^[A-Za-z]:\\' -or
            $candidate.Substring(2).Contains(':') -or $candidate -match '(^|\\)\.\.?($|\\)') {
            throw 'Capture artifacts require explicit local absolute paths without traversal or device syntax.'
        }
        $ancestor = [IO.Path]::GetFullPath($candidate)
        while ($ancestor) {
            if (Test-Path -LiteralPath $ancestor) {
                $item = Get-Item -LiteralPath $ancestor -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Capture artifact path has a reparse-point ancestor: $ancestor"
                }
            }
            $ancestor = Split-Path -Parent $ancestor
        }
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($rootFull -ieq [IO.Path]::GetPathRoot($rootFull).TrimEnd('\') -or
        $rootFull -match '^C:\\gcs\\(?:cap|ia|ib|ic|id|ie)(?:\\|$)') {
        throw 'Capture output must use a dedicated caller-owned root, not a drive or preserved lane root.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Capture artifact escaped the explicit owned root: $full"
    }
    return $full
}

function Assert-CapZmxLeasePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ZmxDir,
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][string]$Sid
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters @{
        ZmxDir = $ZmxDir; SessionName = $SessionName; SidLength = $Sid.Length
    }
    if (-not [IO.Path]::IsPathFullyQualified($ZmxDir) -or
        [string]::IsNullOrWhiteSpace($Sid) -or [string]::IsNullOrWhiteSpace($SessionName)) {
        throw [ArgumentException]::new('Zmx lease validation requires an absolute state directory, SID and session.')
    }
    $directory = [IO.Path]::GetFullPath($ZmxDir).TrimEnd('\')
    $sessionBytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($SessionName)
    $sessionHex = [Convert]::ToHexString($sessionBytes).ToLowerInvariant()
    $length = ('{0}\ipc\{1}\{2}.endpoint.lease' -f $directory, $Sid, $sessionHex).Length
    if ($length -gt 240) {
        $failure = [IO.PathTooLongException]::new(
            "ZmxLeasePathTooLong: rendezvous lease requires $length characters; maximum is 240.")
        $failure.Data['CapCaptureCode'] = 'ZmxLeasePathTooLong'
        $failure.Data['LeasePathLength'] = $length
        $failure.Data['MaximumLeasePathLength'] = 240
        throw $failure
    }
    return [pscustomobject]@{
        ZmxDir = $directory; LeasePathLength = $length; MaximumLeasePathLength = 240
        SidLength = $Sid.Length; SessionUtf8Bytes = $sessionBytes.Length; SessionHexLength = $sessionHex.Length
    }
}

function Get-CapActionSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('actual-size', 'open-project', 'overview-destination', 'open-loop', 'file-exit',
            'quick-chats-destination','open-quick-chat','workspace-show-graph','workspace-toggle-panel',
            'workspace-restart-session','workspace-new-tab','workspace-split-right','workspace-select-tab','workspace-close-tab')][string]$Action,
        [string]$Name,
        [string]$SubjectId
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    switch ($Action) {
        'actual-size' { return [pscustomobject]@{ AutomationId = 'actual-size'; AutomationIdPrefix = $null; Name = 'Actual size'; CommandId = $null } }
        'open-project' {
            if ([string]::IsNullOrWhiteSpace($Name)) { throw 'open-project requires a project name.' }
            return [pscustomobject]@{ AutomationId = $null; AutomationIdPrefix = 'open-project-'; Name = $Name; CommandId = $null }
        }
        'overview-destination' { return [pscustomobject]@{ AutomationId = 'overview-destination'; AutomationIdPrefix = $null; Name = 'Graph'; CommandId = $null } }
        'quick-chats-destination' { return [pscustomobject]@{AutomationId='quick-chats-destination';AutomationIdPrefix=$null;Name='Quick Chats';CommandId=$null} }
        'open-quick-chat' {
            if ($Name -cnotin @('Quick Chat capture fixture','Quick Chat history fixture')) { throw 'Unknown D fixture chat target.' }
            return [pscustomobject]@{AutomationId=$null;AutomationIdPrefix='quick-chat-card-';Name=$Name;CommandId=$null}
        }
        'workspace-show-graph' { return [pscustomobject]@{AutomationId=$null;AutomationIdPrefix='workspace-show-graph-';Name='Show in Graph';CommandId=$null} }
        'workspace-toggle-panel' {
            if ($Name -cnotin @('Expand loop panel','Collapse loop panel')) { throw 'Normal panel action requires its exact current state.' }
            return [pscustomobject]@{AutomationId=$null;AutomationIdPrefix='workspace-toggle-panel-';Name=$Name;CommandId=$null}
        }
        'workspace-restart-session' {
            if ($SubjectId -cne '11111111-1111-4111-8111-000000000001') {throw 'Matched Restart requires its exact declared loop owner.'}
            return [pscustomobject]@{AutomationId=(Get-CapMatchedAutomationId "workspace-restart-session:$SubjectId")
                AutomationIdPrefix=$null;Name='Restart session';CommandId=$null}
        }
        'workspace-new-tab' {return [pscustomobject]@{AutomationId=(Get-CapMatchedAutomationId 'workspace-new-tab:control')
            AutomationIdPrefix=$null;Name='New Tab';CommandId=$null}}
        'workspace-split-right' {return [pscustomobject]@{AutomationId=(Get-CapMatchedAutomationId 'workspace-split-right:control')
            AutomationIdPrefix=$null;Name='Split Right';CommandId=$null}}
        'workspace-select-tab' {
            if ($SubjectId -cnotmatch '^(?:[0-9]|1[01])$' -or [string]::IsNullOrWhiteSpace($Name)) {throw 'Matched tab selection requires its bounded index and actual name.'}
            return [pscustomobject]@{AutomationId=(Get-CapMatchedAutomationId "workspace-tab:$SubjectId")
                AutomationIdPrefix=$null;Name=$Name;CommandId=$null}
        }
        'workspace-close-tab' {
            if ($SubjectId -cnotmatch '^(?:[0-9]|1[01])$') {throw 'Matched tab close requires its bounded index.'}
            return [pscustomobject]@{AutomationId=(Get-CapMatchedAutomationId "workspace-tab-close:$SubjectId")
                AutomationIdPrefix=$null;Name='Close tab';CommandId=$null}
        }
        'open-loop' {
            if ([string]::IsNullOrWhiteSpace($Name)) { throw 'open-loop requires a loop name.' }
            return [pscustomobject]@{ AutomationId = $null; AutomationIdPrefix = 'canvas-card-'; Name = $Name; CommandId = $null }
        }
        'file-exit' { return [pscustomobject]@{ AutomationId = $null; AutomationIdPrefix = $null; Name = $null; CommandId = 4104 } }
    }
}

function Assert-CapFixtureMapping {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$FixturePath,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$MappingPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedMappingSha256,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSourceSha256,
        [Parameter(Mandatory)][string]$OriginalRoot,
        [ValidateSet('B_FIVE_SCENES_V1','D_QUICK_CHAT_V1','S_MATCHED_V12_V1')][string]$SceneAdapter = 'B_FIVE_SCENES_V1',
        [string]$ExpectedPeerSha256
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    $FixturePath = Assert-CapArtifactPath -Root $Root -Path $FixturePath
    $SourcePath = Assert-CapArtifactPath -Root $Root -Path $SourcePath
    $MappingPath = Assert-CapArtifactPath -Root $Root -Path $MappingPath
    $mappingHash = (Get-FileHash -LiteralPath $MappingPath -Algorithm SHA256).Hash
    $sourceHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash
    $fixtureHash = (Get-FileHash -LiteralPath $FixturePath -Algorithm SHA256).Hash
    if ($mappingHash -ne $ExpectedMappingSha256 -or $sourceHash -ne $ExpectedSourceSha256) {
        throw 'Fixture mapping/source does not match its exact trusted hashes.'
    }
    $mapping = Get-Content -LiteralPath $MappingPath -Raw | ConvertFrom-Json -DateKind String
    $isD = $SceneAdapter -ceq 'D_QUICK_CHAT_V1'
    $isS = $SceneAdapter -ceq 'S_MATCHED_V12_V1'
    $graphCount = if ($isD -or $isS) {1} else {2}
    $nodeCount = if ($isS) {8} elseif ($isD) {2} else {10}
    if ($mapping.sourcePath -cne (Join-Path $OriginalRoot 'fixture.json') -or
        $mapping.sourceSha256 -ne $ExpectedSourceSha256 -or
        $mapping.copiedSourcePath -cne $SourcePath -or $mapping.rewrittenFixturePath -cne $FixturePath -or
        $mapping.rewrittenFixtureSha256 -ne $fixtureHash -or
        $mapping.pathPrefixMap.from -cne $OriginalRoot -or
        $mapping.pathPrefixMap.to -cne (Join-Path $Root 'fixtures\projects') -or
        $mapping.graphs -ne $graphCount -or $mapping.topLevelNodes -ne $nodeCount -or $mapping.pathsRewritten -ne $true) {
        throw 'Fixture mapping does not bind the exact source and rewritten owned-root fixture.'
    }
    $source = Get-Content -LiteralPath $SourcePath -Raw | ConvertFrom-Json -DateKind String
    $fixture = Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json -DateKind String
    if ($source.graphs.Count -ne $graphCount -or $fixture.graphs.Count -ne $graphCount -or
        ($source.graphs | ForEach-Object { $_.nodes.Count } | Measure-Object -Sum).Sum -ne $nodeCount -or
        ($fixture.graphs | ForEach-Object { $_.nodes.Count } | Measure-Object -Sum).Sum -ne $nodeCount) {
        throw 'Fixture mapping changed the two-graph/ten-node capture contract.'
    }
    foreach ($index in 0..($graphCount-1)) {
        $sourceProject = $source.graphs[$index].project
        $mappedProject = $fixture.graphs[$index].project
        if ($sourceProject.path -cne (Join-Path $OriginalRoot $sourceProject.name) -or
            $mappedProject.name -cne $sourceProject.name -or
            $mappedProject.path -cne (Join-Path (Join-Path $Root 'fixtures\projects') $sourceProject.name) -or
            $fixture.graphs[$index].nodes.Count -ne $source.graphs[$index].nodes.Count) {
            throw "Fixture mapping changed graph identity, owned project path, or node count at index $index."
        }
    }
    $projectsRoot = Join-Path $Root 'fixtures\projects'
    $visit = {
        param($Value)
        if ($Value -is [string]) {
            if ($Value -match '^[A-Za-z]:[\\/]') {
                $path = [IO.Path]::GetFullPath($Value)
                if ($path -ine $projectsRoot -and
                    -not $path.StartsWith($projectsRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Fixture contains a foreign or unrewritten embedded path.'
                }
                $null = Assert-CapArtifactPath -Root $Root -Path $Value
            }
        } elseif ($Value -is [array]) {
            foreach ($item in $Value) { & $visit $item }
        } elseif ($Value -is [pscustomobject]) {
            foreach ($property in $Value.PSObject.Properties) { & $visit $property.Value }
        }
    }
    & $visit $fixture
    $originalEscaped = ($OriginalRoot | ConvertTo-Json -Compress).Trim('"')
    $ownedEscaped = ($projectsRoot | ConvertTo-Json -Compress).Trim('"')
    $expectedFixture = [IO.File]::ReadAllText($SourcePath).Replace($originalEscaped, $ownedEscaped) |
        ConvertFrom-Json -DateKind String | ConvertTo-Json -Depth 40 -Compress
    if (($fixture | ConvertTo-Json -Depth 40 -Compress) -cne $expectedFixture) {
        throw 'Rewritten fixture differs from the source beyond the complete owned-prefix substitution.'
    }
    if ($isD) {
        if ($mapping.quickChats -ne 2 -or $mapping.layouts -ne 3) { throw 'D fixture mapping requires two chats and three layouts.' }
        Assert-CapDFixture -Fixture $fixture -ProjectRoot $projectsRoot
    }
    if ($isS) {$null=Assert-CapMatchedFixture -Fixture $fixture -ProjectRoot $projectsRoot}
    $peerPath = Assert-CapArtifactPath -Root $Root -Path (Join-Path $Root 'inputs\offline-peer-source.ps1')
    $peerBytes = [IO.File]::ReadAllBytes($peerPath)
    $canonicalPeer = [Text.UTF8Encoding]::new($false).GetBytes($(if ($isD) {Get-CapDPeerSource} else {Get-CapBPeerSource}))
    if ($ExpectedPeerSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($peerBytes)) -ne $ExpectedPeerSha256 -or
        -not [Linq.Enumerable]::SequenceEqual[byte]($peerBytes,$canonicalPeer)) {
        $lane = if ($isD) {'D'} else {'B'}
        throw "$lane peer bytes differ from the hash-bound same-module fixture peer."
    }
    return [pscustomobject]@{ FixtureSha256 = $fixtureHash; SourceSha256 = $sourceHash; MappingSha256 = $mappingHash }
}

function Assert-CapUiaProcessIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ExpectedProcessId,
        [Parameter(Mandatory)][int[]]$ObservedProcessIds
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    foreach ($observedProcessId in $ObservedProcessIds) {
        if ($observedProcessId -le 0 -or $observedProcessId -ne $ExpectedProcessId) {
            throw "UIA subtree process $observedProcessId does not match owned PID $ExpectedProcessId."
        }
    }
    return $true
}

function Write-CapSelectorRefusal {
    param($Candidates, [bool]$CandidatesObserved, [Nullable[int]]$ExpectedProcessId, [string]$Name,
        [string]$AutomationId, [string]$AutomationIdPrefix, [bool]$AllowOffscreen,
        [Management.Automation.ErrorRecord]$Refusal, $Context, $TerminalObservation)
    if (-not $script:CapTracePath) { return }
    try {
        $propertyReadStartedUtc = [DateTime]::UtcNow.ToString('o')
        function Limit-RefusalString {
            param([string]$Value, [int]$Limit = 512)
            $length = $Value.Length
            $take = [Math]::Min($length, $Limit)
            if ($take -gt 0 -and $take -lt $length -and [char]::IsHighSurrogate($Value[$take - 1])) { $take-- }
            $text = [Text.StringBuilder]::new($take)
            $replaced = $false
            for ($i = 0; $i -lt $take; $i++) {
                $character = $Value[$i]
                if ([char]::IsHighSurrogate($character) -and $i + 1 -lt $take -and [char]::IsLowSurrogate($Value[$i + 1])) {
                    $null = $text.Append($character).Append($Value[++$i])
                } elseif ([char]::IsSurrogate($character)) {
                    $null = $text.Append([char]0xfffd)
                    $replaced = $true
                } else { $null = $text.Append($character) }
            }
            return [ordered]@{ value = $text.ToString(); originalLength = $length; truncated = ($take -lt $length)
                invalidSurrogatesReplaced = $replaced }
        }
        function Read-RefusalField {
            param($Object, [string]$Property, [string]$Kind = 'String', [int]$Limit = 512)
            $record = [ordered]@{ status = 'Missing'; value = $null; propertyReadSucceeded = $null }
            $raw = $null
            try {
                if ($null -ne $Object -and $Object.PSObject.Properties[$Property]) {
                    $raw = $Object.PSObject.Properties[$Property].get_Value()
                    $record.propertyReadSucceeded = $true
                    if ($null -eq $raw) { $record.status = 'Null' }
                    else {
                        $record.status = 'Value'
                        switch ($Kind) {
                            'Current' { }
                            'Int' {
                                if (($raw -isnot [int] -and $raw -isnot [long]) -or
                                    $raw -lt [int]::MinValue -or $raw -gt [int]::MaxValue) { throw 'Not an Int32 primitive.' }
                                $record.value = [int]$raw
                            }
                            'Long' {
                                if ($raw -isnot [int] -and $raw -isnot [long]) { throw 'Not an Int64 primitive.' }
                                $record.value = [long]$raw
                            }
                            'Bool' {
                                if ($raw -isnot [bool]) { throw 'Not a Boolean primitive.' }
                                $record.value = $raw
                            }
                            'Rectangle' {
                                $rectangle = [ordered]@{}
                                $numbers = [ordered]@{}
                                foreach ($part in @('Left','Top','Width','Height')) {
                                    $partProperty = $raw.PSObject.Properties[$part]
                                    if ($null -eq $partProperty) { throw "Rectangle property '$part' is missing." }
                                    $number = [double]$partProperty.get_Value()
                                    $numbers[$part] = $number
                                    $rectangle[$part] = if ([double]::IsNaN($number)) {
                                        [ordered]@{ numberKind = 'NaN' }
                                    } elseif ([double]::IsPositiveInfinity($number)) {
                                        [ordered]@{ numberKind = 'PositiveInfinity' }
                                    } elseif ([double]::IsNegativeInfinity($number)) {
                                        [ordered]@{ numberKind = 'NegativeInfinity' }
                                    } else { $number }
                                }
                                $record.value = $rectangle
                                $record.rectangleKind = if ([double]::IsPositiveInfinity($numbers.Left) -and
                                    [double]::IsPositiveInfinity($numbers.Top) -and
                                    [double]::IsNegativeInfinity($numbers.Width) -and
                                    [double]::IsNegativeInfinity($numbers.Height)) { 'Empty' } else { 'Rectangle' }
                            }
                            default {
                                $text = if ($Kind -ceq 'ControlType' -and $raw -isnot [string]) {
                                    [string]$raw.ProgrammaticName
                                } else { [string]$raw }
                                $bounded = Limit-RefusalString $text $Limit
                                $record.value = $bounded.value
                                $record.originalLength = $bounded.originalLength
                                $record.truncated = $bounded.truncated
                                $record.invalidSurrogatesReplaced = $bounded.invalidSurrogatesReplaced
                            }
                        }
                    }
                }
            } catch {
                $record.status = 'ReadError'
                $record.value = $null
                $record.propertyReadSucceeded = $false
                $record.error = Limit-RefusalString $_.Exception.Message 256
                $record.errorType = (Limit-RefusalString $_.Exception.GetType().FullName 128).value
            }
            return [pscustomobject]@{ Raw = $raw; Record = $record }
        }
        $counts = [ordered]@{ total = $null; processOwned = $null; nameMatch = $null; automationIdMatch = $null
            prefixMatch = $null; visible = $null; bounds = $null }
        $stageErrors = [ordered]@{ processOwned = 0; nameMatch = 0; automationIdMatch = 0; prefixMatch = 0; visible = 0; bounds = 0 }
        $sample = [Collections.Generic.List[object]]::new()
        $pids = [Collections.Generic.HashSet[int]]::new()
        $pidSample = [Collections.Generic.List[int]]::new()
        $rawPidCount = 0
        $pidUnavailableCount = 0
        if ($CandidatesObserved) {
            foreach ($key in @($counts.Keys)) { $counts[$key] = 0 }
            $index = 0
            foreach ($candidate in $Candidates) {
                $counts.total++
                $current = $candidate
                $currentStatus = 'Value'
                $currentRecord = [ordered]@{ status = 'DirectCandidate'; propertyReadSucceeded = $null }
                if ($null -eq $candidate) { $currentStatus = 'Null' }
                elseif ($candidate.PSObject.Properties['Current']) {
                    $reading = Read-RefusalField $candidate 'Current' 'Current'
                    $current = $reading.Raw
                    $currentRecord = $reading.Record
                    $currentStatus = $reading.Record.status
                }
                $fields = [ordered]@{}
                foreach ($spec in @(
                    @('Name','String',512), @('AutomationId','String',512), @('ProcessId','Int',512),
                    @('IsOffscreen','Bool',512), @('BoundingRectangle','Rectangle',512), @('ControlType','ControlType',128)
                )) {
                    $field = Read-RefusalField $current $spec[0] $spec[1] $spec[2]
                    if ($currentStatus -ceq 'ReadError') {
                        $field.Record.status = 'ReadError'
                        $field.Record.propertyReadSucceeded = $false
                        $field.Record.error = $currentRecord.error
                        $field.Record.errorType = $currentRecord.errorType
                    }
                    $fields[$spec[0]] = $field
                }
                $pidField = $fields.ProcessId
                if ($pidField.Record.status -ceq 'Value') {
                    $rawPidCount++
                    if ($pids.Add([int]$pidField.Raw) -and $pidSample.Count -lt 64) { $pidSample.Add([int]$pidField.Raw) }
                } else { $pidUnavailableCount++ }
                $eligible = $true
                $rank = 0
                foreach ($stage in @('processOwned','nameMatch','automationIdMatch','prefixMatch','visible','bounds')) {
                    if (-not $eligible) { break }
                    $fieldName = switch ($stage) {
                        'processOwned' { 'ProcessId' }
                        'nameMatch' { 'Name' }
                        'automationIdMatch' { 'AutomationId' }
                        'prefixMatch' { 'AutomationId' }
                        'visible' { 'IsOffscreen' }
                        'bounds' { 'BoundingRectangle' }
                    }
                    $inactive = ($stage -ceq 'automationIdMatch' -and -not $AutomationId) -or
                        ($stage -ceq 'prefixMatch' -and -not $AutomationIdPrefix) -or
                        ($stage -ceq 'visible' -and $AllowOffscreen)
                    $field = $fields[$fieldName]
                    if (-not $inactive -and $field.Record.status -in @('Missing','ReadError')) {
                        $stageErrors[$stage]++
                        $eligible = $false
                        break
                    }
                    $eligible = $inactive -or $(switch ($stage) {
                        'processOwned' { $field.Record.status -ceq 'Value' -and [int]$field.Raw -eq $ExpectedProcessId -and [int]$field.Raw -gt 0 }
                        'nameMatch' { [string]$field.Raw -ceq $Name }
                        'automationIdMatch' { [string]$field.Raw -ceq $AutomationId }
                        'prefixMatch' { ([string]$field.Raw).StartsWith($AutomationIdPrefix, [StringComparison]::Ordinal) }
                        'visible' { -not [bool]$field.Raw }
                        'bounds' { -not ($null -eq $field.Raw -or $field.Raw.Width -le 0 -or $field.Raw.Height -le 0) }
                    })
                    if ($eligible) { $counts[$stage]++; $rank++ }
                }
                $row = [ordered]@{ sourceIndex = $index; passedStages = $rank; currentStatus = $currentStatus
                    current = $currentRecord }
                foreach ($key in $fields.Keys) { $row[$key] = $fields[$key].Record }
                $sample.Add([pscustomobject]$row)
                if ($sample.Count -gt 16) {
                    $worst = 0
                    for ($i = 1; $i -lt $sample.Count; $i++) {
                        if ($sample[$i].passedStages -lt $sample[$worst].passedStages -or
                            ($sample[$i].passedStages -eq $sample[$worst].passedStages -and
                                $sample[$i].sourceIndex -gt $sample[$worst].sourceIndex)) { $worst = $i }
                    }
                    $sample.RemoveAt($worst)
                }
                $index++
            }
        }
        $held = [ordered]@{ status = 'NotObserved' }
        if ($null -ne $Context) {
            $held = [ordered]@{ status = 'Observed'; rootHandle = $null; rootProcessId = $Context.RootProcessId
                rootProcessIdStatus = if ($null -eq $Context.RootProcessId) { 'NotObserved' } else { 'Observed' }
                parameterSet = [string]$Context.ParameterSet; scope = [string]$Context.Scope
                identity = [ordered]@{} }
            if ($null -ne $Context.RootHandle) { $held.rootHandle = $Context.RootHandle.ToInt64() }
            foreach ($property in @('Pid','CreationFileTimeUtc','ExpectedImagePath','Role')) {
                $kind = if ($property -ceq 'Pid') { 'Int' } elseif ($property -ceq 'CreationFileTimeUtc') { 'Long' } else { 'String' }
                $held.identity[$property] = (Read-RefusalField $Context.ProcessIdentity $property $kind).Record
            }
        }
        $complete = $CandidatesObserved
        foreach ($key in $stageErrors.Keys) { if ($stageErrors[$key] -gt 0) { $complete = $false } }
        $diagnostic = [ordered]@{
            schema = 'CapSelectorRefusal/1'
            evidenceKind = if ($null -ne $TerminalObservation) { 'TERMINAL_LAST_POLL_SNAPSHOT' } else { 'DIRECT_SELECTOR_REFUSAL' }
            terminalObservation = $TerminalObservation
            propertyReadStartedUtc = $propertyReadStartedUtc
            selector = [ordered]@{ Name = Limit-RefusalString $Name; AutomationId = Limit-RefusalString $AutomationId
                AutomationIdPrefix = Limit-RefusalString $AutomationIdPrefix; allowOffscreen = $AllowOffscreen }
            expectedProcessId = $ExpectedProcessId; heldContext = $held
            refusal = [ordered]@{ type = $Refusal.Exception.GetType().FullName
                message = (Limit-RefusalString $Refusal.Exception.Message 1024).value
                messageLength = $Refusal.Exception.Message.Length; messageTruncated = ($Refusal.Exception.Message.Length -gt 1024) }
            candidatesObserved = $CandidatesObserved; stageCounts = $counts; stageReadErrors = $stageErrors
            stageCountsComplete = $complete
            samplePolicy = 'deepest-passed-stage-then-source-index'; candidateLimit = 16
            candidateSampleCount = $sample.Count
            candidatesOmitted = if ($CandidatesObserved) { $counts.total - $sample.Count } else { $null }
            candidates = @($sample | Sort-Object @{ Expression = 'passedStages'; Descending = $true }, sourceIndex)
            observedProcessIds = @($pidSample.ToArray()); observedProcessIdLimit = 64
            observedProcessIdRawCount = $rawPidCount; observedProcessIdDistinctCount = $pids.Count
            observedProcessIdSampleCount = $pidSample.Count; observedProcessIdsTruncated = ($pids.Count -gt 64)
            observedProcessIdsComplete = ($CandidatesObserved -and $pidUnavailableCount -eq 0 -and $pids.Count -le 64)
            observedProcessIdUnavailableCount = $pidUnavailableCount
        }
        $json = ConvertTo-Json -InputObject $diagnostic -Depth 16 -Compress
        Write-CapTrace -Command 'CapSelectorRefusal' -Parameters @{ diagnosticJson = $json }
    } catch {
        if (-not @($script:CapTraceFailures | Where-Object command -CEQ 'CapSelectorRefusal').Count) {
            $script:CapTraceFailures.Add([pscustomobject]@{
                command = 'CapSelectorRefusal'; path = $script:CapTracePath; failure = $_.Exception.ToString()
            })
            [Console]::Error.WriteLine("CAP_TRACE_FAILURE command=CapSelectorRefusal: $($_.Exception.Message)")
        }
    }
}

function Write-CapTerminalSelectorRefusal {
    [CmdletBinding()]
    param($Snapshot, [Management.Automation.ErrorRecord]$Refusal, [Nullable[DateTime]]$PollUtc,
        [DateTime]$DeadlineUtc, [IntPtr]$Window, $ProcessIdentity, [string]$Name,
        [string]$AutomationId, [string]$AutomationIdPrefix, [switch]$AllowOffscreen)
    if (-not $script:CapTracePath) { return }
    if ($null -ne $Snapshot) {
        if ($Snapshot.EmissionAttempted) { return }
        $Snapshot.EmissionAttempted = $true
    } else {
        $Snapshot = @{ Candidates = $null; CandidatesObserved = $false
            ExpectedProcessId = $null; Name = $Name; AutomationId = $AutomationId
            AutomationIdPrefix = $AutomationIdPrefix; AllowOffscreen = $AllowOffscreen.IsPresent
            Context = @{ RootHandle = $Window; RootProcessId = $null; ProcessIdentity = $ProcessIdentity
                Scope = 'Descendants'; ParameterSet = 'Window' } }
    }
    Write-CapSelectorRefusal -Candidates $Snapshot.Candidates -CandidatesObserved $Snapshot.CandidatesObserved `
        -ExpectedProcessId $Snapshot.ExpectedProcessId -Name $Snapshot.Name -AutomationId $Snapshot.AutomationId `
        -AutomationIdPrefix $Snapshot.AutomationIdPrefix -AllowOffscreen $Snapshot.AllowOffscreen `
        -Refusal $Refusal -Context $Snapshot.Context -TerminalObservation ([ordered]@{
            lastPollUtc = if ($null -ne $PollUtc) { $PollUtc.ToString('o') } else { $null }
            waitDeadlineUtc = $DeadlineUtc.ToString('o'); failureObservedUtc = [DateTime]::UtcNow.ToString('o')
            meaning = 'Last poll references; property values are read after terminal failure, not frozen at poll time.'
        })
}

function Wait-CapAutomationElement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IntPtr]$Window,
        [Parameter(Mandatory)]$ProcessIdentity,
        [Parameter(Mandatory)][string]$Name,
        [string]$AutomationId,
        [string]$AutomationIdPrefix,
        [switch]$AllowOffscreen,
        [Parameter(Mandatory)][DateTime]$DeadlineUtc,
        [Parameter(Mandatory)][scriptblock]$FindElement,
        [scriptblock]$BeforePoll
    )
    $lastSnapshot = $null
    $lastPollUtc = $null
    try {
        while ([DateTime]::UtcNow -lt $DeadlineUtc) {
            if ($BeforePoll) { & $BeforePoll }
            $lastPollUtc = [DateTime]::UtcNow
            try {
                return & $FindElement ([ref]$lastSnapshot)
            } catch {
                if ($_.Exception.Message -notmatch 'found=0\.') { throw }
                Start-Sleep -Milliseconds 100
            }
        }
        throw "UIA element '$Name' did not become available before the reserved deadline."
    } catch {
        Write-CapTerminalSelectorRefusal -Snapshot $lastSnapshot -Refusal $_ -PollUtc $lastPollUtc `
            -DeadlineUtc $DeadlineUtc -Window $Window -ProcessIdentity $ProcessIdentity `
            -Name $Name -AutomationId $AutomationId -AutomationIdPrefix $AutomationIdPrefix -AllowOffscreen:$AllowOffscreen
        throw
    }
}

function Resolve-CapAutomationCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Candidates,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ExpectedProcessId,
        [Parameter(Mandatory)][string]$Name,
        [string]$AutomationId,
        [string]$AutomationIdPrefix,
        [switch]$AllowOffscreen,
        [System.Collections.IDictionary]$RefusalContext,
        [ref]$RefusalSnapshot
    )
    $traceParameters = [ordered]@{}
    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -cnotin @('RefusalContext','RefusalSnapshot')) { $traceParameters[$key] = $PSBoundParameters[$key] }
    }
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $traceParameters

    try {
    $found = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $Candidates) {
        if ($null -eq $candidate) { throw 'UIA resolver returned a null candidate.' }
        $current = if ($candidate.PSObject.Properties['Current']) { $candidate.Current } else { $candidate }
        $null = Assert-CapUiaProcessIds -ExpectedProcessId $ExpectedProcessId -ObservedProcessIds @([int]$current.ProcessId)
        if ([string]$current.Name -cne $Name) { continue }
        if ($AutomationId -and [string]$current.AutomationId -cne $AutomationId) { continue }
        if ($AutomationIdPrefix -and -not ([string]$current.AutomationId).StartsWith($AutomationIdPrefix, [StringComparison]::Ordinal)) { continue }
        if (-not $AllowOffscreen -and [bool]$current.IsOffscreen) { continue }
        $rect = $current.BoundingRectangle
        if ($null -eq $rect -or $rect.Width -le 0 -or $rect.Height -le 0) { continue }
        $found.Add($candidate)
    }
    if ($found.Count -ne 1) {
        throw "Expected exactly one visible UIA element Name='$Name' id='$AutomationId' prefix='$AutomationIdPrefix'; found=$($found.Count)."
    }
    return $found[0]
    } catch {
        if ($script:CapTracePath) {
            if ($null -ne $RefusalSnapshot) {
                $RefusalSnapshot.Value = @{ Candidates = $Candidates; CandidatesObserved = $true; ExpectedProcessId = $ExpectedProcessId
                    Name = $Name; AutomationId = $AutomationId; AutomationIdPrefix = $AutomationIdPrefix
                    AllowOffscreen = $AllowOffscreen.IsPresent; Context = $RefusalContext; EmissionAttempted = $false }
            } else {
                Write-CapSelectorRefusal -Candidates $Candidates -CandidatesObserved $true -ExpectedProcessId $ExpectedProcessId `
                    -Name $Name -AutomationId $AutomationId -AutomationIdPrefix $AutomationIdPrefix `
                    -AllowOffscreen $AllowOffscreen.IsPresent -Refusal $_ -Context $RefusalContext
            }
        }
        throw
    }
}

function Find-CapAutomationElement {
    [CmdletBinding(DefaultParameterSetName = 'Window')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Window')][IntPtr]$RootHandle,
        [Parameter(Mandatory)][object]$ProcessIdentity,
        [Parameter(Mandatory, ParameterSetName = 'Element')][System.Windows.Automation.AutomationElement]$Parent,
        [int]$ExpectedProcessId = 0,
        [Parameter(Mandatory)][string]$Name,
        [string]$AutomationId,
        [string]$AutomationIdPrefix,
        [System.Windows.Automation.TreeScope]$Scope = [System.Windows.Automation.TreeScope]::Descendants,
        [switch]$AllowOffscreen,
        [ref]$RefusalSnapshot
    )
    $traceParameters = [ordered]@{}
    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -cne 'RefusalSnapshot') { $traceParameters[$key] = $PSBoundParameters[$key] }
    }
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $traceParameters


    $resolving = $false
    $rootProcessId = $null
    try {
    $rootElement = if ($PSCmdlet.ParameterSetName -eq 'Window') {
        [System.Windows.Automation.AutomationElement]::FromHandle($RootHandle)
    } else {
        $Parent
    }
    if ($null -eq $rootElement) { throw 'UIA root is unavailable.' }
    if ($PSCmdlet.ParameterSetName -eq 'Window') {
        $null = Assert-CapRootProcess -RootHandle $RootHandle -ProcessIdentity $ProcessIdentity
    } else {
        $verified = Assert-CapProcessIdentity -Identity $ProcessIdentity
        if ($verified.State -ne 'Live') { throw "UIA parent process PID $($ProcessIdentity.Pid) is no longer live." }
    }
    $rootProcessId = [int]$rootElement.Current.ProcessId
    if ($ExpectedProcessId -le 0) { $ExpectedProcessId = [int]$ProcessIdentity.Pid }
    if ($ExpectedProcessId -ne [int]$ProcessIdentity.Pid) {
        throw "Expected UIA PID $ExpectedProcessId does not match held window generation PID $($ProcessIdentity.Pid)."
    }
    $null = Assert-CapUiaProcessIds -ExpectedProcessId $ExpectedProcessId -ObservedProcessIds @($rootProcessId)
    $elements = $rootElement.FindAll($Scope, [System.Windows.Automation.Condition]::TrueCondition)
    $optionalParameters = @{}
    if ($PSBoundParameters.ContainsKey('RefusalSnapshot')) {
        $optionalParameters.RefusalSnapshot = $RefusalSnapshot
    }
    $resolving = $true
    return Resolve-CapAutomationCandidate -Candidates @($elements) -ExpectedProcessId $ExpectedProcessId `
        -Name $Name -AutomationId $AutomationId -AutomationIdPrefix $AutomationIdPrefix -AllowOffscreen:$AllowOffscreen `
        @optionalParameters -RefusalContext $(if ($script:CapTracePath) {
            @{ RootHandle = if ($PSCmdlet.ParameterSetName -eq 'Window') { $RootHandle } else { $null }
                ProcessIdentity = $ProcessIdentity; RootProcessId = $rootProcessId; Scope = $Scope; ParameterSet = $PSCmdlet.ParameterSetName }
        } else { $null })
    } catch {
        if (-not $resolving -and $script:CapTracePath) {
            $context = @{
                    RootHandle = if ($PSCmdlet.ParameterSetName -eq 'Window') { $RootHandle } else { $null }
                    ProcessIdentity = $ProcessIdentity; RootProcessId = $rootProcessId; Scope = $Scope; ParameterSet = $PSCmdlet.ParameterSetName }
            if ($null -ne $RefusalSnapshot) {
                $RefusalSnapshot.Value = @{ Candidates = $null; CandidatesObserved = $false; ExpectedProcessId = $ExpectedProcessId
                    Name = $Name; AutomationId = $AutomationId; AutomationIdPrefix = $AutomationIdPrefix
                    AllowOffscreen = $AllowOffscreen.IsPresent; Context = $context; EmissionAttempted = $false }
            } else {
                Write-CapSelectorRefusal -Candidates $null -CandidatesObserved $false -ExpectedProcessId $ExpectedProcessId `
                    -Name $Name -AutomationId $AutomationId -AutomationIdPrefix $AutomationIdPrefix `
                    -AllowOffscreen $AllowOffscreen.IsPresent -Refusal $_ -Context $context
            }
        }
        throw
    }
}

function Get-CapDirectChildren {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Windows.Automation.AutomationElement]$Parent)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $children = $Parent.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.Condition]::TrueCondition
    )
    return @($children)
}

function Get-CapActionObservations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Parent,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ExpectedProcessId,
        [Parameter(Mandatory)][string[]]$RequiredNames,
        [scriptblock]$ChildrenResolver
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $children = if ($ChildrenResolver) { @(& $ChildrenResolver $Parent) } else { @(Get-CapDirectChildren -Parent $Parent) }
    $observations = [Collections.Generic.List[object]]::new()
    foreach ($child in $children) {
        $current = if ($child.PSObject.Properties['Current']) { $child.Current } else { $child }
        $null = Assert-CapUiaProcessIds -ExpectedProcessId $ExpectedProcessId -ObservedProcessIds @([int]$current.ProcessId)
        if ($current.Name -notin $RequiredNames) { continue }
        $bounds = $current.BoundingRectangle
        if ($current.IsOffscreen -or $bounds.Width -le 0 -or $bounds.Height -le 0) {
            throw "Action observation '$($current.Name)' is not visibly bounded."
        }
        $observations.Add([pscustomobject]@{
            Name = [string]$current.Name
            AutomationId = [string]$current.AutomationId
            ProcessId = [int]$current.ProcessId
            IsEnabled = [bool]$current.IsEnabled
            Bounds = [pscustomobject]@{ Left = $bounds.Left; Top = $bounds.Top; Width = $bounds.Width; Height = $bounds.Height }
        })
    }
    foreach ($name in $RequiredNames) {
        $count = @($observations | Where-Object Name -CEQ $name).Count
        if ($count -ne 1) { throw "Expected one visible direct action observation '$name'; found=$count." }
    }
    return @($observations)
}

function Get-CapGraphActionObservations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IntPtr]$RootHandle,
        [Parameter(Mandatory)]$ProcessIdentity,
        [Parameter(Mandatory)][string[]]$RequiredNames,
        [scriptblock]$GraphResolver,
        [scriptblock]$ChildrenResolver,
        [scriptblock]$WindowProcessResolver
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    if (($GraphResolver -or $ChildrenResolver -or $WindowProcessResolver) -and
        (-not $GraphResolver -or -not $ChildrenResolver -or -not $WindowProcessResolver)) {
        throw 'Graph/action observation mocks must supply all three resolver seams.'
    }
    $null = Assert-CapRootProcess -RootHandle $RootHandle -ProcessIdentity $ProcessIdentity `
        -WindowProcessResolver $WindowProcessResolver
    $graph = if ($GraphResolver) {
        & $GraphResolver $RootHandle $ProcessIdentity
    } else {
        Find-CapAutomationElement -RootHandle $RootHandle -ProcessIdentity $ProcessIdentity `
            -ExpectedProcessId $ProcessIdentity.Pid -Name 'Graph' -AutomationId 'graph'
    }
    if ($null -eq $graph) { throw 'The owned Graph UIA element is unavailable.' }
    $current = if ($graph.PSObject.Properties['Current']) { $graph.Current } else { $graph }
    $null = Assert-CapUiaProcessIds -ExpectedProcessId $ProcessIdentity.Pid -ObservedProcessIds @([int]$current.ProcessId)
    return Get-CapActionObservations -Parent $graph -ExpectedProcessId $ProcessIdentity.Pid `
        -RequiredNames $RequiredNames -ChildrenResolver $ChildrenResolver
}

function Assert-CapRootProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IntPtr]$RootHandle,
        [Parameter(Mandatory)]$ProcessIdentity,
        [scriptblock]$WindowProcessResolver
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $verified = Assert-CapProcessIdentity -Identity $ProcessIdentity
    if ($verified.State -ne 'Live') { throw "Root process PID $($ProcessIdentity.Pid) is no longer live." }
    $windowProcessId = if ($WindowProcessResolver) {
        [int](& $WindowProcessResolver $RootHandle)
    } else {
        [CapNative]::WindowProcessId($RootHandle)
    }
    if ($windowProcessId -ne [int]$ProcessIdentity.Pid) {
        throw "Root HWND belongs to PID $windowProcessId, not held generation PID $($ProcessIdentity.Pid)."
    }
    return $verified
}

function Invoke-CapAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][IntPtr]$RootHandle,
        [Parameter(Mandatory)]$ProcessIdentity,
        [string]$Name,
        [string]$SubjectId,
        [scriptblock]$Invoker,
        [scriptblock]$WindowProcessResolver,
        [scriptblock]$ElementResolver,
        [DateTime]$DeadlineUtc,
        [scriptblock]$BeforeElementPoll
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    if ($Action -in @('reply', 'reclaim', 'keep')) { throw "Mutating graph action '$Action' is prohibited by the capture contract." }
    if ($Action -notin @('actual-size', 'open-project', 'overview-destination', 'open-loop', 'file-exit',
        'quick-chats-destination','open-quick-chat','workspace-show-graph','workspace-toggle-panel',
        'workspace-restart-session','workspace-new-tab','workspace-split-right','workspace-select-tab','workspace-close-tab')) {
        throw "Unsupported capture action '$Action'."
    }
    if ($WindowProcessResolver -and -not $Invoker) { throw 'A custom HWND resolver is allowed only with the action mock.' }
    if ($ElementResolver -and -not $Invoker) { throw 'A custom UIA candidate resolver is allowed only with the action mock.' }
    if ($Invoker -and $Action -notin @('file-exit') -and -not $ElementResolver) {
        throw 'UIA action mocks must exercise the production candidate resolver.'
    }
    $null = Assert-CapRootProcess -RootHandle $RootHandle -ProcessIdentity $ProcessIdentity -WindowProcessResolver $WindowProcessResolver
    $spec = Get-CapActionSpec -Action $Action -Name $Name -SubjectId $SubjectId
    if ($Action -eq 'file-exit') {
        if ($Invoker) { return & $Invoker $spec }
        $null = Assert-CapRootProcess -RootHandle $RootHandle -ProcessIdentity $ProcessIdentity -WindowProcessResolver $WindowProcessResolver
        if (-not [GraphCodeUiaGateState]::PostCommand($RootHandle, [uint32]$spec.CommandId)) {
            throw 'Posting the native File > Exit command failed.'
        }
        return [pscustomobject]@{ Action = $Action; CommandId = $spec.CommandId; Invoked = $true }
    }
    $element = if ($ElementResolver) {
        $candidates = @(& $ElementResolver $RootHandle $ProcessIdentity $spec)
        Resolve-CapAutomationCandidate -Candidates $candidates -ExpectedProcessId $ProcessIdentity.Pid `
            -Name $spec.Name -AutomationId $spec.AutomationId -AutomationIdPrefix $spec.AutomationIdPrefix
    } elseif ($PSBoundParameters.ContainsKey('DeadlineUtc')) {
        Wait-CapAutomationElement -Window $RootHandle -ProcessIdentity $ProcessIdentity `
            -Name $spec.Name -AutomationId $spec.AutomationId -AutomationIdPrefix $spec.AutomationIdPrefix `
            -DeadlineUtc $DeadlineUtc -BeforePoll $BeforeElementPoll -FindElement {
                param([ref]$Snapshot)
                Find-CapAutomationElement -RootHandle $RootHandle -ProcessIdentity $ProcessIdentity `
                    -ExpectedProcessId $ProcessIdentity.Pid -Name $spec.Name -AutomationId $spec.AutomationId `
                    -AutomationIdPrefix $spec.AutomationIdPrefix -RefusalSnapshot $Snapshot
            }
    } else {
        Find-CapAutomationElement -RootHandle $RootHandle -ProcessIdentity $ProcessIdentity `
            -ExpectedProcessId $ProcessIdentity.Pid -Name $spec.Name -AutomationId $spec.AutomationId `
            -AutomationIdPrefix $spec.AutomationIdPrefix
    }
    $current = if ($element.PSObject.Properties['Current']) { $element.Current } else { $element }
    $null = Assert-CapRootProcess -RootHandle $RootHandle -ProcessIdentity $ProcessIdentity -WindowProcessResolver $WindowProcessResolver
    $null = Assert-CapUiaProcessIds -ExpectedProcessId $ProcessIdentity.Pid -ObservedProcessIds @([int]$current.ProcessId)
    if ($Action -in @('quick-chats-destination','open-quick-chat','workspace-show-graph','workspace-toggle-panel',
        'workspace-restart-session','workspace-new-tab','workspace-split-right','workspace-select-tab','workspace-close-tab')) {
        if (-not $current.IsEnabled) { throw 'D action target is disabled.' }
        if ($current.ControlType -ne [System.Windows.Automation.ControlType]::Button -and
            $current.ControlType -ne [System.Windows.Automation.ControlType]::ListItem) { throw 'D action target has an unexpected control type.' }
        if ($Invoker -and (-not $element.PSObject.Properties['HasInvokePattern'] -or -not $element.HasInvokePattern)) {
            throw 'D component action target does not support InvokePattern.'
        }
        if ($Action -ceq 'workspace-toggle-panel' -and $SubjectId -cne 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA') {
            throw 'D panel action requires the normal-loop subject.'
        }
    }
    if ($Invoker) { return & $Invoker $spec $element }
    $invoke = $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $invoke.Invoke()
    return [pscustomobject]@{
        Action = $Action
        Name = $spec.Name
        AutomationId = $element.Current.AutomationId
        Invoked = $true
    }
}

function Measure-CapZoom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Windows.Automation.AutomationElement]$Element,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$NaturalWidth
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $current = $Element.Current
    $rect = $current.BoundingRectangle
    if ($current.IsOffscreen -or $rect.Width -le 0 -or $rect.Height -le 0) {
        throw "Zoom probe '$($current.Name)' is not visibly bounded."
    }
    $percent = [Math]::Round(($rect.Width / $NaturalWidth) * 100, 2)
    if ($percent -lt 99 -or $percent -gt 101) { throw "Actual-size zoom measured $percent%, expected 100%." }
    return [pscustomobject]@{
        Name = $current.Name
        AutomationId = $current.AutomationId
        Bounds = [pscustomobject]@{ Left = $rect.Left; Top = $rect.Top; Width = $rect.Width; Height = $rect.Height }
        NaturalWidth = $NaturalWidth
        MeasuredWidth = $rect.Width
        ZoomPercent = $percent
    }
}

function Get-CapWindowMetrics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IntPtr]$Window,
        [Parameter(Mandatory)]$ProcessIdentity
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $null = Assert-CapRootProcess -RootHandle $Window -ProcessIdentity $ProcessIdentity
    return [CapNative]::WindowSnapshot($Window, [int]$ProcessIdentity.Pid)
}

function Set-CapWindowPosition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IntPtr]$Window,
        [Parameter(Mandatory)]$ProcessIdentity,
        [int]$X = 30,
        [int]$Y = 30,
        [int]$Width = 1456,
        [int]$Height = 959
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $null = Assert-CapRootProcess -RootHandle $Window -ProcessIdentity $ProcessIdentity
    if (-not [CapNative]::SetWindowPosition($Window, $X, $Y, $Width, $Height)) {
        throw "SetWindowPos failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
}

function Find-CapTopLevelWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ProcessIdentity,
        [ValidateSet('GraphCodeWindowsShell')][string]$ClassName = 'GraphCodeWindowsShell',
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30,
        [DateTime]$DeadlineUtc = [DateTime]::MaxValue
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds -and [DateTime]::UtcNow -lt $DeadlineUtc) {
        $verified = Assert-CapProcessIdentity -Identity $ProcessIdentity
        if ($verified.State -ne 'Live') { throw "Owned app PID $($ProcessIdentity.Pid) exited before its window appeared." }
        $window = [GraphCodeUiaGateState]::FindTopLevel($ClassName, [uint32]$ProcessIdentity.Pid)
        if ($window -ne [IntPtr]::Zero) {
            $null = Assert-CapRootProcess -RootHandle $window -ProcessIdentity $ProcessIdentity
            return $window
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Owned window '$ClassName' did not appear within its remaining bounded wait."
}

function Capture-CapWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IntPtr]$Window,
        [Parameter(Mandatory)]$ProcessIdentity,
        [Parameter(Mandatory)][string]$Path
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Capture directory missing: $parent" }
    $null = Assert-CapRootProcess -RootHandle $Window -ProcessIdentity $ProcessIdentity
    $result = [CapNative]::CaptureWindow($Window, [int]$ProcessIdentity.Pid, $Path)
    return [pscustomobject]@{
        Path = $Path
        Width = $result.Width
        Height = $result.Height
        SampledColors = $result.SampledColors
        NonMagentaSamples = $result.NonMagentaSamples
        Dpi = $result.Dpi
        Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
    }
}

function ConvertTo-CapImagePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $value = $Path.Trim()
    if ($value.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        $value = '\\' + $value.Substring(8)
    } elseif ($value.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase) -or
        $value.StartsWith('\??\', [StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring(4)
    }
    return [IO.Path]::GetFullPath($value)
}

function Read-CapProcessAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$CallSite,
        [Nullable[int]]$ExpectedPid = $null
    )
    $handle = $null
    $processId = $null
    $handleState = $null
    $idState = $null
    $failures = [Collections.Generic.List[Exception]]::new()
    # Explicit accessors preserve failures that PowerShell's adapted properties
    # otherwise turn into null before the native method binder sees them.
    try { $handle = $Process.get_Handle() }
    catch [Management.Automation.MethodInvocationException], [InvalidOperationException], [ComponentModel.Win32Exception] {
        $handleState = 'GetterException'
        $failures.Add($_.Exception)
    }
    try { $processId = $Process.get_Id() }
    catch [Management.Automation.MethodInvocationException], [InvalidOperationException], [ComponentModel.Win32Exception] {
        $idState = 'GetterException'
        $failures.Add($_.Exception)
    }
    if ($null -eq $handleState) {
        $handleState = if ($null -eq $handle) { 'Null' }
            elseif ($handle -isnot [IntPtr] -or $handle -eq [IntPtr]::Zero -or $handle -eq [IntPtr]::new(-1)) { 'Invalid' }
            else { 'Available' }
    }
    if ($null -eq $idState) {
        $idState = if ($null -eq $processId) { 'Null' }
            elseif ($processId -isnot [int] -or $processId -le 0) { 'Invalid' }
            else { 'Available' }
    }
    if ($handleState -cne 'Available' -or $idState -cne 'Available') {
        $inner = if ($failures.Count -eq 1) { $failures[0] }
            elseif ($failures.Count -gt 1) { [AggregateException]::new('Process accessor failures.', $failures.ToArray()) }
            else { $null }
        $failure = [InvalidOperationException]::new(
            "ProcessIdentityUnavailable: $Role at $CallSite; Handle=$handleState; Id=$idState; kernel exit and EOF are UNPROVEN.", $inner)
        $failure.Data['CapCaptureCode'] = 'ProcessIdentityUnavailable'
        $failure.Data['Role'] = $Role
        $failure.Data['CallSite'] = $CallSite
        $failure.Data['HandleState'] = $handleState
        $failure.Data['IdState'] = $idState
        $failure.Data['AcquiredPid'] = if ($idState -ceq 'Available') { $processId } else { $null }
        $failure.Data['ExpectedPid'] = $ExpectedPid
        throw $failure
    }
    if ($null -ne $ExpectedPid -and $processId -ne $ExpectedPid) {
        $failure = [InvalidOperationException]::new("Tracked PID changed for $Role at $CallSite; acquired=$processId expected=$ExpectedPid.")
        $failure.Data['CapCaptureCode'] = 'ProcessIdentityMismatch'
        $failure.Data['AcquiredPid'] = $processId
        $failure.Data['ExpectedPid'] = $ExpectedPid
        throw $failure
    }
    return [pscustomobject]@{ Handle = $handle; Pid = $processId }
}

function Get-CapProcessIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][string]$ExpectedImagePath,
        [Parameter(Mandatory)][string]$Role,
        [int]$ExpectedParentPid = -1,
        [int]$ExpectedSessionId = -1
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $access = Read-CapProcessAccess -Process $Process -Role $Role -CallSite 'Get-CapProcessIdentity.InitialSnapshot'
    $snapshot = [CapNative]::Snapshot($access.Handle, $access.Pid)
    if ($snapshot.ProcessId -ne $access.Pid) { throw "Kernel PID changed while tracking $Role." }
    $expected = ConvertTo-CapImagePath -Path $ExpectedImagePath
    if (-not $snapshot.IsExited -and (ConvertTo-CapImagePath -Path $snapshot.ImagePath) -ine $expected) {
        throw "Live $Role executable mismatch: $($snapshot.ImagePath) != $expected."
    }
    $metadata = $null
    # Observability (records the ACTUAL terminal classification and whether the
    # conclusion was governed by a retained kernel exit; never a mere alias of the
    # metadata-observed flag).
    $terminalState = if ($snapshot.IsExited) { 'KernelExitedBeforeQuery' } else { $null }
    $concludedGoneByKernelExit = [bool]$snapshot.IsExited
    if (-not $snapshot.IsExited) {
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            $state = Read-CapProcessMetadataState -Pid $access.Pid
            # The retained kernel handle governs an Absent/Incomplete reading. EOF is
            # proven later by the launch caller, so the loop passes BothStreamsEofReached
            # = $false and treats either exited disposition as "break and defer the EOF
            # gate to the caller".
            $access = Read-CapProcessAccess -Process $Process -Role $Role `
                -CallSite 'Get-CapProcessIdentity.MetadataSnapshot' -ExpectedPid $snapshot.ProcessId
            $snapshot = [CapNative]::Snapshot($access.Handle, $access.Pid)
            $disposition = Resolve-CapAttestationDisposition -State $state.State `
                -KernelExited ([bool]$snapshot.IsExited) -BothStreamsEofReached $false
            $terminalState = if ($snapshot.IsExited) { "KernelExitedWith$($state.State)" } else { $state.State }
            if ($disposition -eq 'UseMetadata') { $metadata = $state.Metadata; break }
            if ($disposition -eq 'GoneByKernelExit' -or $disposition -eq 'RequireBothEofBeforeGone') {
                $concludedGoneByKernelExit = $true; break
            }
            if ($disposition -eq 'RefuseLiveIncomplete') {
                # A torn-down row on a still-live owned child is refused outright,
                # exactly as main did; it is never retried into a passing outcome.
                throw "Live $Role PID $($access.Pid) has incomplete current CIM metadata; refusing ownership inference."
            }
            # RetryAbsent: not yet listed on a live child -> bounded startup re-poll.
            Start-Sleep -Milliseconds 50
        }
        if ($null -eq $metadata -and -not $concludedGoneByKernelExit -and -not $snapshot.IsExited -and
            ($ExpectedParentPid -lt 0 -or $ExpectedSessionId -lt 0)) {
            throw "Live $Role PID $($access.Pid) has no current CIM metadata."
        }
    }
    $expectedMetadataMatches = if ($metadata) {
        ($ExpectedParentPid -lt 0 -or $metadata.ParentPid -eq $ExpectedParentPid) -and
        ($ExpectedSessionId -lt 0 -or $metadata.SessionId -eq $ExpectedSessionId)
    } else { $null }
    $identity = [pscustomobject]@{
        Process = $Process
        Pid = $snapshot.ProcessId
        CreationFileTimeUtc = $snapshot.CreationFileTimeUtc
        ImagePath = if ($snapshot.ImagePath) { ConvertTo-CapImagePath -Path $snapshot.ImagePath } else { $expected }
        ExpectedImagePath = $expected
        Role = $Role
        ParentPid = if ($ExpectedParentPid -ge 0) { $ExpectedParentPid } elseif ($metadata) { $metadata.ParentPid } else { $null }
        SessionId = if ($ExpectedSessionId -ge 0) { $ExpectedSessionId } elseif ($metadata) { $metadata.SessionId } else { $null }
        InitialMetadataObserved = $null -ne $metadata
        InitialMetadataMatchesExpected = $expectedMetadataMatches
        AttestationTerminalState = $terminalState
        ConcludedGoneByKernelExit = $concludedGoneByKernelExit
    }
    if ($metadata) { $null = Assert-CapMetadataRecord -Identity $identity -Metadata $metadata }
    return $identity
}

function Convert-CapCimCreationTime {
    param([Parameter(Mandatory)]$Value)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    if ($Value -is [DateTime]) { $date = $Value.ToUniversalTime() }
    elseif ($Value -is [string]) { $date = [Management.ManagementDateTimeConverter]::ToDateTime($Value).ToUniversalTime() }
    else { throw "Unsupported CIM CreationDate type: $($Value.GetType().FullName)" }
    return $date.ToFileTimeUtc()
}

function Assert-CapDescendantLifetime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][long]$ParentCreationFileTimeUtc,
        [Parameter(Mandatory)][long]$ChildCreationFileTimeUtc,
        [long]$ParentExitFileTimeUtc = 0
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    if ($ChildCreationFileTimeUtc -lt $ParentCreationFileTimeUtc -or
        ($ParentExitFileTimeUtc -gt 0 -and $ChildCreationFileTimeUtc -gt $ParentExitFileTimeUtc)) {
        throw "Child generation $ChildCreationFileTimeUtc is outside parent lifetime $ParentCreationFileTimeUtc..$ParentExitFileTimeUtc."
    }
    return $true
}

function Test-CapGraphAppRootRole {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Role)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    return $Role -match '^graphcode-app-(before|after)-(normal|actions)$'
}

function Read-CapProcessMetadataState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Pid)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    # Classify the current Win32_Process reading without inferring liveness:
    #   Absent     - no single matching row (the PID is not currently listed)
    #   Incomplete - a row exists but a required field is torn down/unreadable
    #   Complete    - a fully populated owned-process row
    # The caller decides what Absent/Incomplete means by consulting the retained
    # kernel handle; this function never treats a missing field as proof of death.
    $rows = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $Pid" -ErrorAction Stop)
    if ($rows.Count -ne 1) { return [pscustomobject]@{ State = 'Absent'; Metadata = $null } }
    $row = $rows[0]
    if ($null -eq $row.CreationDate -or [string]::IsNullOrWhiteSpace([string]$row.ExecutablePath) -or
        [string]::IsNullOrWhiteSpace([string]$row.CommandLine) -or $null -eq $row.ParentProcessId) {
        return [pscustomobject]@{ State = 'Incomplete'; Metadata = $null }
    }
    return [pscustomobject]@{
        State = 'Complete'
        Metadata = [pscustomobject]@{
            Pid = [int]$row.ProcessId
            ParentPid = [int]$row.ParentProcessId
            SessionId = [int]$row.SessionId
            CreationFileTimeUtc = Convert-CapCimCreationTime $row.CreationDate
            ImagePath = ConvertTo-CapImagePath -Path ([string]$row.ExecutablePath)
            CommandLine = [string]$row.CommandLine
        }
    }
}

function Resolve-CapAttestationDisposition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Complete', 'Incomplete', 'Absent')][string]$State,
        [Parameter(Mandatory)][bool]$KernelExited,
        [Parameter(Mandatory)][bool]$BothStreamsEofReached
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    # Pure decision rule bound to the (observed CIM classification x retained-kernel
    # exit x both-stream EOF) matrix. No process, I/O or timing. It encodes two
    # invariants: the retained kernel handle governs an Absent/Incomplete reading,
    # and a genuinely-gone conclusion requires both redirected streams to have
    # reached bounded EOF - a kernel exit alone never suffices.
    #   UseMetadata              - live child, complete row; attest with it.
    #   RefuseLiveIncomplete     - live child, torn-down row; refuse immediately.
    #   RetryAbsent              - live child, not yet listed; bounded startup re-poll.
    #   GoneByKernelExit         - kernel exited AND both streams reached EOF; gone.
    #   RequireBothEofBeforeGone - kernel exited but EOF not yet proven; not gone.
    if (-not $KernelExited) {
        switch ($State) {
            'Complete' { return 'UseMetadata' }
            'Incomplete' { return 'RefuseLiveIncomplete' }
            'Absent' { return 'RetryAbsent' }
        }
    }
    if ($BothStreamsEofReached) { return 'GoneByKernelExit' }
    return 'RequireBothEofBeforeGone'
}

function Get-CapCurrentMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Pid)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    # Strict contract (unchanged): a complete reading returns the metadata record,
    # an absent reading returns $null, and an incomplete reading is refused. Callers
    # that must distinguish incomplete from absent use Read-CapProcessMetadataState.
    $state = Read-CapProcessMetadataState -Pid $Pid
    if ($state.State -eq 'Incomplete') {
        throw "Live PID $Pid has incomplete current CIM metadata; refusing ownership inference."
    }
    return $state.Metadata
}

function Assert-CapMetadataRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Identity,
        [AllowNull()]$Metadata
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    if ($null -eq $Metadata) { throw "Current CIM metadata is missing for live PID $($Identity.Pid); refusing." }
    if ([string]::IsNullOrWhiteSpace([string]$Metadata.CommandLine) -or
        [string]::IsNullOrWhiteSpace([string]$Metadata.ImagePath) -or
        $null -eq $Metadata.CreationFileTimeUtc -or $null -eq $Metadata.ParentPid -or
        $null -eq $Metadata.SessionId) {
        throw "Current CIM metadata is incomplete for live PID $($Identity.Pid); refusing."
    }
    $tolerance = [TimeSpan]::FromMilliseconds(100).Ticks
    if ([int]$Metadata.Pid -ne [int]$Identity.Pid -or
        [Math]::Abs([double]([long]$Metadata.CreationFileTimeUtc - [long]$Identity.CreationFileTimeUtc)) -gt $tolerance -or
        (ConvertTo-CapImagePath -Path ([string]$Metadata.ImagePath)) -ine
        (ConvertTo-CapImagePath -Path ([string]$Identity.ExpectedImagePath)) -or
        [int]$Metadata.ParentPid -ne [int]$Identity.ParentPid -or
        [int]$Metadata.SessionId -ne [int]$Identity.SessionId) {
        throw "Current CIM metadata no longer identifies owned PID $($Identity.Pid); refusing."
    }
    return $true
}

function Assert-CapProcessIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Identity)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $access = Read-CapProcessAccess -Process $Identity.Process -Role $Identity.Role `
        -CallSite 'Assert-CapProcessIdentity.Snapshot' -ExpectedPid $Identity.Pid
    $snapshot = [CapNative]::Snapshot($access.Handle, $access.Pid)
    if ($snapshot.IsExited) { return [pscustomobject]@{ State = 'Exited'; Snapshot = $snapshot; Metadata = $null } }
    if ($snapshot.ProcessId -ne $Identity.Pid -or
        $snapshot.CreationFileTimeUtc -ne [long]$Identity.CreationFileTimeUtc -or
        (ConvertTo-CapImagePath -Path $snapshot.ImagePath) -ine
        (ConvertTo-CapImagePath -Path $Identity.ExpectedImagePath)) {
        throw "Kernel process identity changed for live PID $($Identity.Pid); refusing."
    }
    $state = Read-CapProcessMetadataState -Pid $Identity.Pid
    if ($state.State -ne 'Complete') {
        # A missing or incomplete reading is governed by the retained kernel handle,
        # never treated as proof of death on its own. If the owned generation has
        # exited, report it exited; if it is still live, an incomplete/absent row
        # is a refusal, not a silent pass.
        $access = Read-CapProcessAccess -Process $Identity.Process -Role $Identity.Role `
            -CallSite 'Assert-CapProcessIdentity.MetadataExit' -ExpectedPid $Identity.Pid
        if ([CapNative]::IsExited($access.Handle, $access.Pid)) { return [pscustomobject]@{ State = 'Exited'; Snapshot = $snapshot; Metadata = $null } }
        throw "Live PID $($Identity.Pid) has no complete current CIM row; refusing."
    }
    $metadata = $state.Metadata
    $null = Assert-CapMetadataRecord -Identity $Identity -Metadata $metadata
    return [pscustomobject]@{ State = 'Live'; Snapshot = $snapshot; Metadata = $metadata }
}

function Stop-CapManagedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Identity,
        [uint32]$ExitCode = 125,
        [ValidateRange(1, 30000)][int]$TimeoutMilliseconds = 5000
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $verified = Assert-CapProcessIdentity -Identity $Identity
    if ($verified.State -eq 'Exited') {
        return [pscustomobject]@{ Pid = $Identity.Pid; Role = $Identity.Role; Result = 'SKIP_GENUINELY_EXITED_KERNEL' }
    }
    $access = Read-CapProcessAccess -Process $Identity.Process -Role $Identity.Role `
        -CallSite 'Stop-CapManagedProcess.Terminate' -ExpectedPid $Identity.Pid
    $terminated = [CapNative]::Terminate($access.Handle, $access.Pid, $ExitCode, $TimeoutMilliseconds)
    if (-not [CapNative]::IsExited($access.Handle, $access.Pid)) { throw "Owned process PID $($Identity.Pid) remains live after guarded termination." }
    return [pscustomobject]@{ Pid = $Identity.Pid; Role = $Identity.Role
        Result = if ($terminated) { 'TERMINATED_GUARDED_HANDLE' } else { 'EXITED_DURING_GUARDED_STOP' } }
}

function Wait-CapManagedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][DateTime]$DeadlineUtc,
        [ValidateRange(10, 1000)][int]$PollMilliseconds = 100
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $process = $Run.Identity.Process
    $null = Read-CapProcessAccess -Process $process -Role $Run.Identity.Role `
        -CallSite 'Wait-CapManagedProcess.Wait' -ExpectedPid $Run.Identity.Pid
    while ([DateTime]::UtcNow -lt $DeadlineUtc) {
        $remaining = [int][Math]::Max(1, [Math]::Min(
            $PollMilliseconds,
            [Math]::Ceiling(($DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds)
        ))
        if ($process.WaitForExit($remaining)) {
            return [pscustomobject]@{
                State = 'Exited'
                ExitCode = $process.ExitCode
                CompletedUtc = [DateTime]::UtcNow
            }
        }
    }
    return [pscustomobject]@{ State = 'TimedOut'; ExitCode = $null; CompletedUtc = [DateTime]::UtcNow }
}

function Invoke-CapLaunchRollback {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$LaunchRecord)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $process = $LaunchRecord.Process
    $access = Read-CapProcessAccess -Process $process -Role $LaunchRecord.Role `
        -CallSite 'Invoke-CapLaunchRollback.InitialSnapshot' -ExpectedPid $LaunchRecord.AcquiredPid
    $LaunchRecord.AcquiredPid = $access.Pid
    $snapshot = [CapNative]::Snapshot($access.Handle, $access.Pid)
    $result = $null
    if ($snapshot.IsExited) {
        $result = 'SKIP_GENUINELY_EXITED_KERNEL'
    } else {
        $metadata = $null
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            $metadata = Get-CapCurrentMetadata -Pid $access.Pid
            if ($metadata) { break }
            $access = Read-CapProcessAccess -Process $process -Role $LaunchRecord.Role `
                -CallSite 'Invoke-CapLaunchRollback.MetadataSnapshot' -ExpectedPid $snapshot.ProcessId
            $snapshot = [CapNative]::Snapshot($access.Handle, $access.Pid)
            if ($snapshot.IsExited) { break }
            Start-Sleep -Milliseconds 50
        }
        if ($snapshot.IsExited) {
            $result = 'SKIP_GENUINELY_EXITED_KERNEL'
        } elseif ($null -eq $metadata) {
            throw "Rollback refused for live PID $($access.Pid): current process metadata is unavailable."
        } else {
            $expectedPath = ConvertTo-CapImagePath -Path $LaunchRecord.ExpectedImagePath
            if ($metadata.Pid -ne $access.Pid -or
                [Math]::Abs([double]([long]$metadata.CreationFileTimeUtc - [long]$snapshot.CreationFileTimeUtc)) -gt
                [TimeSpan]::FromMilliseconds(100).Ticks -or
                $metadata.ImagePath -ine $expectedPath -or
                $metadata.ParentPid -ne $LaunchRecord.ExpectedParentPid -or
                $metadata.SessionId -ne $LaunchRecord.ExpectedSessionId) {
                throw "Rollback refused for live PID $($access.Pid): current kernel/CIM identity differs from the held launch record."
            }
            $identity = [pscustomobject]@{
                Process = $process
                Pid = $access.Pid
                CreationFileTimeUtc = $snapshot.CreationFileTimeUtc
                ImagePath = $expectedPath
                ExpectedImagePath = $expectedPath
                Role = $LaunchRecord.Role
                ParentPid = $LaunchRecord.ExpectedParentPid
                SessionId = $LaunchRecord.ExpectedSessionId
                InitialMetadataObserved = $true
                InitialMetadataMatchesExpected = $true
            }
            $null = Assert-CapMetadataRecord -Identity $identity -Metadata $metadata
            $stop = Stop-CapManagedProcess -Identity $identity -TimeoutMilliseconds 5000
            $result = $stop.Result
        }
    }
    if ($null -eq $LaunchRecord.StdoutTask) { $LaunchRecord.StdoutTask = $process.StandardOutput.ReadToEndAsync() }
    if ($null -eq $LaunchRecord.StderrTask) { $LaunchRecord.StderrTask = $process.StandardError.ReadToEndAsync() }
    if (-not $LaunchRecord.StdoutTask.Wait(2000)) { throw "Rollback stdout reader did not reach bounded EOF for PID $($access.Pid)." }
    if (-not $LaunchRecord.StderrTask.Wait(2000)) { throw "Rollback stderr reader did not reach bounded EOF for PID $($access.Pid)." }
    $stdout = [string]$LaunchRecord.StdoutTask.Result
    $stderr = [string]$LaunchRecord.StderrTask.Result
    $access = Read-CapProcessAccess -Process $process -Role $LaunchRecord.Role `
        -CallSite 'Invoke-CapLaunchRollback.FinalExit' -ExpectedPid $snapshot.ProcessId
    if (-not [CapNative]::IsExited($access.Handle, $access.Pid)) { throw "Rollback left live PID $($access.Pid)." }
    return [pscustomobject]@{
        Pid = $access.Pid
        Role = $LaunchRecord.Role
        ExpectedPath = $LaunchRecord.ExpectedImagePath
        CreationFileTimeUtc = $snapshot.CreationFileTimeUtc
        Result = $result
        KernelExited = $true
        StdoutEof = $true
        StderrEof = $true
        StdoutBytes = [Text.Encoding]::UTF8.GetByteCount($stdout)
        StderrBytes = [Text.Encoding]::UTF8.GetByteCount($stderr)
    }
}

function Complete-CapFailedLaunch {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$LaunchRecord, [Parameter(Mandatory)][Exception]$StartFailure)
    $LaunchRecord.StartFailure = $StartFailure.Message
    $LaunchRecord.StartFailureException = $StartFailure
    if ($null -eq $LaunchRecord.AcquiredPid -and $StartFailure.Data['AcquiredPid'] -is [int]) {
        $LaunchRecord.AcquiredPid = $StartFailure.Data['AcquiredPid']
    }
    $pidText = if ($null -ne $LaunchRecord.AcquiredPid) { [string]$LaunchRecord.AcquiredPid } else { 'UNAVAILABLE' }
    try {
        $rollback = Invoke-CapLaunchRollback -LaunchRecord $LaunchRecord
        $script:CapLastRollbackReceipt = $rollback
        $null = $script:CapPendingLaunches.Remove($LaunchRecord)
        $LaunchRecord.Process.Dispose()
    } catch {
        $LaunchRecord.RollbackFailure = $_.Exception.Message
        $LaunchRecord.RollbackFailureException = $_.Exception
        $script:CapLastRollbackReceipt = [pscustomobject]@{
            Pid = $LaunchRecord.AcquiredPid
            Role = $LaunchRecord.Role
            ExpectedPath = $LaunchRecord.ExpectedImagePath
            CreationFileTimeUtc = if ($LaunchRecord.Snapshot) { $LaunchRecord.Snapshot.CreationFileTimeUtc } else { $null }
            KernelExited = if ($LaunchRecord.Snapshot) { [bool]$LaunchRecord.Snapshot.IsExited } else { $null }
            RollbackFailure = $LaunchRecord.RollbackFailure
            RefusedUnsafeTermination = $true
        }
        $failure = [InvalidOperationException]::new(
            "Process.Start identity attestation failed for $($LaunchRecord.Role) PID ${pidText}: $($StartFailure.Message); guarded rollback also failed: $($LaunchRecord.RollbackFailure).",
            [AggregateException]::new('Primary attestation and guarded rollback failures.',
                [Exception[]]@($StartFailure, $LaunchRecord.RollbackFailureException)))
        foreach ($key in $StartFailure.Data.Keys) { $failure.Data[$key] = $StartFailure.Data[$key] }
        throw $failure
    }
    $failure = [InvalidOperationException]::new(
        "Process.Start identity attestation failed for $($LaunchRecord.Role) PID ${pidText}: $($StartFailure.Message); guarded rollback=$($rollback.Result), stdoutEOF=$($rollback.StdoutEof), stderrEOF=$($rollback.StderrEof).",
        $StartFailure)
    foreach ($key in $StartFailure.Data.Keys) { $failure.Data[$key] = $StartFailure.Data[$key] }
    throw $failure
}

function Start-CapManagedProcessCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$Role,
        [hashtable]$Environment = @{},
        [switch]$CloseStdin,
        [switch]$HoldStdin,
        [scriptblock]$AttestationOverride
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $fullPath = [IO.Path]::GetFullPath($FilePath)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Executable missing: $fullPath" }
    $parentMetadata = Get-CapCurrentMetadata -Pid $PID
    if ($null -eq $parentMetadata) { throw "Cannot establish current metadata for launcher PID $PID." }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $fullPath
    $startInfo.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($CloseStdin -and $HoldStdin) { throw 'Cannot both close and hold the launch stdin gate.' }
    $startInfo.RedirectStandardInput = [bool]($CloseStdin -or $HoldStdin)
    foreach ($argument in $ArgumentList) { $startInfo.ArgumentList.Add($argument) }
    foreach ($key in @($startInfo.Environment.Keys)) {
        if ([string]$key -like 'GRAPHCODE_*' -or [string]$key -like 'ZMX_*') {
            $null = $startInfo.Environment.Remove([string]$key)
        }
    }
    foreach ($key in $Environment.Keys) { $startInfo.Environment[[string]$key] = [string]$Environment[$key] }
    $process = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) { throw "Process.Start returned null for $Role." }
    $launchRecord = [pscustomobject]@{
        Process = $process
        ExpectedImagePath = $fullPath
        ExpectedParentPid = $PID
        ExpectedSessionId = $parentMetadata.SessionId
        Role = $Role
        StartInfo = $startInfo
        Snapshot = $null
        AcquiredPid = $null
        StdoutTask = $null
        StderrTask = $null
        Identity = $null
        StartFailure = $null
        RollbackFailure = $null
        StartFailureException = $null
        RollbackFailureException = $null
    }
    $script:CapPendingLaunches.Add($launchRecord)
    try {
        $access = Read-CapProcessAccess -Process $process -Role $Role -CallSite 'Start-CapManagedProcessCore.InitialSnapshot'
        $launchRecord.AcquiredPid = $access.Pid
        $launchRecord.Snapshot = [CapNative]::Snapshot($access.Handle, $access.Pid)
        $launchRecord.StdoutTask = $process.StandardOutput.ReadToEndAsync()
        $launchRecord.StderrTask = $process.StandardError.ReadToEndAsync()
        Write-CapTrace -Command 'Process.Start' -Parameters @{
            FilePath = $fullPath; ArgumentList = $ArgumentList; Role = $Role
            Pid = $access.Pid; CreationFileTimeUtc = $launchRecord.Snapshot.CreationFileTimeUtc
            HeldKernelHandle = $access.Handle.ToInt64(); ExpectedParentPid = $PID
            ExpectedSessionId = $parentMetadata.SessionId
        }
        if (-not $launchRecord.Snapshot.IsExited -and
            (ConvertTo-CapImagePath -Path $launchRecord.Snapshot.ImagePath) -ine $fullPath) {
            throw "Kernel image path mismatch after Process.Start for $Role."
        }
        $identity = if ($AttestationOverride) {
            & $AttestationOverride $process $fullPath $Role $PID $parentMetadata.SessionId
        } else {
            Get-CapProcessIdentity -Process $process -ExpectedImagePath $fullPath -Role $Role `
                -ExpectedParentPid $PID -ExpectedSessionId $parentMetadata.SessionId
        }
        if ($identity.Pid -ne $launchRecord.AcquiredPid -or $identity.CreationFileTimeUtc -ne $launchRecord.Snapshot.CreationFileTimeUtc) {
            throw "Identity attestor returned a different kernel generation for $Role."
        }
        $access = Read-CapProcessAccess -Process $process -Role $Role `
            -CallSite 'Start-CapManagedProcessCore.AttestationExit' -ExpectedPid $launchRecord.AcquiredPid
        $exitedDuringAttestation = [CapNative]::IsExited($access.Handle, $access.Pid)
        if (-not $exitedDuringAttestation) {
            if (-not $identity.InitialMetadataObserved -or -not $identity.InitialMetadataMatchesExpected) {
                throw "Live $Role PID $($launchRecord.AcquiredPid) lacks a complete expected-parent/session attestation."
            }
            # Consume the verification result: the child can exit during this final
            # assertion, and that exit must also be routed through the shared EOF gate
            # rather than silently accepted.
            $verified = Assert-CapProcessIdentity -Identity $identity
            if ($verified.State -eq 'Exited') { $exitedDuringAttestation = $true }
        }
        if ($exitedDuringAttestation) {
            # The owned generation exited during attestation. Route the final gone
            # decision through the same pure decision seam: a retained kernel exit is
            # accepted as genuinely gone ONLY when both redirected streams have reached
            # bounded EOF, never from a missing or incomplete CIM reading alone. Every
            # attestation-time exit, including one discovered inside the final assertion,
            # passes through this one gate.
            $bothEof = $launchRecord.StdoutTask.Wait(2000) -and $launchRecord.StderrTask.Wait(2000)
            $final = Resolve-CapAttestationDisposition -State 'Absent' -KernelExited $true -BothStreamsEofReached $bothEof
            if ($final -cne 'GoneByKernelExit') {
                throw "Exited $Role PID $($launchRecord.AcquiredPid) did not reach bounded stdout/stderr EOF; cannot attest it genuinely gone."
            }
        }
        $launchRecord.Identity = $identity
        if ($CloseStdin) { $process.StandardInput.Close() }
        $null = $script:CapPendingLaunches.Remove($launchRecord)
    } catch {
        Complete-CapFailedLaunch -LaunchRecord $launchRecord -StartFailure $_.Exception
    }
    return [pscustomobject]@{
        Identity = $identity
        StdoutTask = $launchRecord.StdoutTask
        StderrTask = $launchRecord.StderrTask
        StartInfo = $startInfo
        StdinClosed = [bool]$CloseStdin
        StartedUtc = [DateTime]::UtcNow
    }
}

function Start-CapManagedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$Role,
        [hashtable]$Environment = @{},
        [switch]$CloseStdin,
        [switch]$HoldStdin
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    if ($script:CapTraceFailures.Count -gt 0) { throw 'Capture tracing failed; refusing a new process launch.' }

    return Start-CapManagedProcessCore @PSBoundParameters
}

function Test-CapManagedProcessRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProcessPath,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    New-Item -ItemType Directory -Path $WorkingDirectory -Force | Out-Null
    $script:CapLastRollbackReceipt = $null
    $injectFailure = {
        param($Process, $ExpectedPath, $Role, $ParentPid, $SessionId)
        $identity = Get-CapProcessIdentity -Process $Process -ExpectedImagePath $ExpectedPath -Role $Role `
            -ExpectedParentPid $ParentPid -ExpectedSessionId $SessionId
        if (-not $identity.InitialMetadataObserved -or -not $identity.InitialMetadataMatchesExpected) {
            throw 'Failure injection could not first establish the child identity.'
        }
        throw 'INJECTED_IDENTITY_ATTESTATION_FAILURE'
    }.GetNewClosure()
    try {
        $null = Start-CapManagedProcessCore -FilePath $ProcessPath -ArgumentList @(
            '-NoProfile', '-Command', 'Start-Sleep -Seconds 10'
        ) `
            -WorkingDirectory $WorkingDirectory -Role 'rollback-failure-injection' -AttestationOverride $injectFailure
        throw 'Identity attestation failure injection unexpectedly returned a child.'
    } catch {
        if ($_.Exception.Message -like 'Identity attestation failure injection unexpectedly returned*') { throw }
        if ($_.Exception.Message -notlike '*INJECTED_IDENTITY_ATTESTATION_FAILURE*') { throw }
    }
    if ($script:CapPendingLaunches.Count -ne 0) { throw "Unreturned child launch records remain: $($script:CapPendingLaunches.Count)." }
    if ($null -eq $script:CapLastRollbackReceipt -or
        -not $script:CapLastRollbackReceipt.KernelExited -or
        -not $script:CapLastRollbackReceipt.StdoutEof -or
        -not $script:CapLastRollbackReceipt.StderrEof) {
        throw 'Failure-injected child rollback did not prove kernel exit and both bounded EOF readers.'
    }
    return $script:CapLastRollbackReceipt
}

function Get-CapPendingLaunches {
    [CmdletBinding()]
    param()
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    return @($script:CapPendingLaunches | ForEach-Object {
        $record = $_
        $kernelExited = $null
        $kernelProbeFailure = $null
        $kernelProbeFailureDetails = $null
        try {
            $access = Read-CapProcessAccess -Process $record.Process -Role $record.Role `
                -CallSite 'Get-CapPendingLaunches.KernelProbe' -ExpectedPid $record.AcquiredPid
            $kernelExited = [CapNative]::IsExited($access.Handle, $access.Pid)
        }
        catch [InvalidOperationException], [ComponentModel.Win32Exception] {
            $kernelProbeFailure = $_.Exception.ToString()
            $kernelProbeFailureDetails = $_.Exception.Data
        }
        [pscustomobject]@{
            Pid = $record.AcquiredPid
            Role = $record.Role
            ExpectedPath = $record.ExpectedImagePath
            CreationFileTimeUtc = if ($record.Snapshot) { $record.Snapshot.CreationFileTimeUtc } else { $null }
            ExpectedParentPid = $record.ExpectedParentPid
            ExpectedSessionId = $record.ExpectedSessionId
            StartFailure = $record.StartFailure
            RollbackFailure = $record.RollbackFailure
            StartFailureDetails = if ($record.StartFailureException) { $record.StartFailureException.Data } else { $null }
            RollbackFailureDetails = if ($record.RollbackFailureException) { $record.RollbackFailureException.Data } else { $null }
            KernelExited = $kernelExited
            KernelProbeFailure = $kernelProbeFailure
            KernelProbeFailureDetails = $kernelProbeFailureDetails
        }
    })
}

function Get-CapExcludedDescendants {
    [CmdletBinding()]
    param()
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    return @($script:CapExcludedDescendants.ToArray())
}

function Resolve-CapPendingLaunches {
    [CmdletBinding()]
    param()
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $results = [Collections.Generic.List[object]]::new()
    $failures = [Collections.Generic.List[string]]::new()
    $exceptions = [Collections.Generic.List[Exception]]::new()
    foreach ($record in $script:CapPendingLaunches.ToArray()) {
        try {
            $receipt = Invoke-CapLaunchRollback -LaunchRecord $record
            $results.Add($receipt)
            $null = $script:CapPendingLaunches.Remove($record)
            $record.Process.Dispose()
        } catch {
            $pidText = if ($null -ne $record.AcquiredPid) { [string]$record.AcquiredPid } else { 'UNAVAILABLE' }
            $failures.Add("PID $pidText role=$($record.Role): $($_.Exception.Message)")
            $exceptions.Add($_.Exception)
        }
    }
    if ($failures.Count) {
        throw [InvalidOperationException]::new("Pending launch rollback refused or failed: $($failures -join '; ')",
            [AggregateException]::new('Pending launch rollback failures.', $exceptions.ToArray()))
    }
    return @($results)
}

function Test-CapAppZmxCommand {
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [Parameter(Mandatory)][string]$ZmxPath,
        [Parameter(Mandatory)][string]$SessionPrefix,
        [string[]]$ExactSessionNames = @()
    )
    $arguments = [CapNative]::CommandArguments($CommandLine)
    if ($arguments.Count -lt 2 -or
        (ConvertTo-CapImagePath $arguments[0]) -ine (ConvertTo-CapImagePath $ZmxPath)) { return $false }
    if ($arguments.Count -eq 2 -and $arguments[1] -ceq 'ls') { return $true }
    $sessions = @()
    switch -CaseSensitive ($arguments[1]) {
        'attach' {
            if ($arguments.Count -ne 5 -or $arguments[3] -cne '--size' -or
                $arguments[4] -cnotmatch '^[1-9][0-9]*x[1-9][0-9]*$') { return $false }
            $sessions = @($arguments[2])
        }
        'resize' {
            if ($arguments.Count -ne 4 -or $arguments[3] -cnotmatch '^[1-9][0-9]*x[1-9][0-9]*$') { return $false }
            $sessions = @($arguments[2])
        }
        'kill' {
            if ($arguments.Count -lt 4 -or $arguments[-1] -cne '--force') { return $false }
            $sessions = @($arguments[2..($arguments.Count - 2)])
        }
        default { return $false }
    }
    if ($ExactSessionNames.Count -gt 0) {
        # Retain the D adapter's exact declared-session contract.
        $null = Test-CapDSessionCommand -CommandLine $CommandLine -SessionNames $ExactSessionNames
    }
    foreach ($session in $sessions) {
        if ($ExactSessionNames.Count -gt 0) {
            if ($session -cnotin $ExactSessionNames) { return $false }
        } elseif ($session -cne 'graphcode-11111111-1111-4111-8111-000000000001' -and
            $session -cnotmatch ('^graphcode-' + [regex]::Escape($SessionPrefix) +
                '-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')) {
            return $false
        }
    }
    return $true
}

function Get-CapAdvisoryOlderExclusion {
    param($Parent, $Context, [Management.Automation.ErrorRecord]$NativeFailure)
    $errorData = $NativeFailure.Exception.Data
    if ($errorData['CapCaptureCode'] -cne 'ProcessIdentityUnavailable' -or
        $errorData['CallSite'] -cne 'Get-CapOwnedDescendants.InitialSnapshot' -or
        $errorData['HandleState'] -cne 'GetterException' -or $errorData['IdState'] -cne 'Available' -or
        $errorData['AcquiredPid'] -isnot [int] -or
        $errorData['AcquiredPid'] -ne $Context.RawRow.ProcessId -or
        $errorData['ExpectedPid'] -ne $Context.RawRow.ProcessId) { return $null }
    $nativeError = $NativeFailure.Exception
    while ($null -ne $nativeError -and $nativeError -isnot [ComponentModel.Win32Exception]) {
        $nativeError = $nativeError.InnerException
    }
    if ($null -eq $nativeError -or $nativeError.NativeErrorCode -ne 5) { return $null }

    $parentAccess = Read-CapProcessAccess -Process $Parent.Process -Role $Parent.Role `
        -CallSite 'Get-CapOwnedDescendants.AdvisoryParentSnapshot' -ExpectedPid $Parent.Pid
    $parentSnapshot = [CapNative]::Snapshot($parentAccess.Handle, $parentAccess.Pid)
    $Context.ParentNativeSnapshot = $parentSnapshot
    if ($Context.ParentCreationFileTimeUtc -isnot [long] -or $Context.ParentCreationFileTimeUtc -le 0 -or
        $parentSnapshot.CreationFileTimeUtc -le 0 -or
        $parentSnapshot.CreationFileTimeUtc -ne $Context.ParentCreationFileTimeUtc -or
        [string]::IsNullOrWhiteSpace($parentSnapshot.ImagePath) -or
        (ConvertTo-CapImagePath $parentSnapshot.ImagePath) -ine (ConvertTo-CapImagePath $Parent.ExpectedImagePath)) {
        throw "Advisory exclusion requires the saved held parent native generation for PID $($Parent.Pid); refusing."
    }
    $value = $Context.RawRow.CreationDate
    if ($value -is [DateTime] -and $value.Kind -ne [DateTimeKind]::Unspecified) {
        $creation = $value.ToFileTimeUtc()
    } elseif ($value -is [DateTimeOffset]) {
        $creation = $value.UtcDateTime.ToFileTimeUtc()
    } elseif ($value -is [string] -and $value -cmatch '^\d{14}\.\d{6}[+-]\d{3}$') {
        $creation = Convert-CapCimCreationTime $value
    } else {
        throw "Advisory candidate creation time is missing, unparseable or lacks an explicit time zone for PID $($Context.RawRow.ProcessId); refusing."
    }
    if ($creation -le 0) { throw "Advisory candidate creation time is nonpositive for PID $($Context.RawRow.ProcessId); refusing." }
    if ($creation -ge $parentSnapshot.CreationFileTimeUtc) { return $null }
    return [pscustomobject]@{
        Pid = [int]$Context.RawRow.ProcessId
        ParentPid = $Parent.Pid
        ParentCreationFileTimeUtc = $parentSnapshot.CreationFileTimeUtc
        ParentExitFileTimeUtc = $parentSnapshot.ExitFileTimeUtc
        CandidateCreationFileTimeUtc = $creation
        CandidateCreationSource = 'ADVISORY_CIM_NOT_NATIVE'
        ParentCreationSource = 'HELD_NATIVE_SNAPSHOT'
        RawCimRow = $Context.RawRow
        ParentNativeSnapshot = $parentSnapshot
        NativeWin32Error = $nativeError.NativeErrorCode
        NativeFailure = $NativeFailure.Exception.ToString()
        OriginalErrorRecord = $NativeFailure
        Reason = 'predates held parent generation (advisory, native unavailable)'
        Disposition = 'EXCLUDED_ADVISORY_PREDATES_NATIVE_PARENT_NATIVE_UNAVAILABLE'
    }
}

function Get-CapOwnedDescendants {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Roots,
        [Parameter(Mandatory)][string]$ZmxPath,
        [Parameter(Mandatory)][string]$CmdPath,
        [Parameter(Mandatory)][string]$ConhostPath,
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][string]$CommandMarker,
        [switch]$AllowGraphCodeRoot,
        [switch]$AllowUnmarkedCmd,
        [string[]]$ExactSessionNames = @(),
        [Collections.Generic.List[object]]$OwnedDescendants
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $known = [Collections.Generic.Dictionary[int, object]]::new()
    foreach ($root in $Roots) { $known[$root.Pid] = $root }
    if ($null -eq $OwnedDescendants) { $OwnedDescendants = [Collections.Generic.List[object]]::new() }
    foreach ($child in $OwnedDescendants) { $known.Add($child.Pid, $child) }
    for ($pass = 0; $pass -lt 8; $pass++) {
        $changed = $false
        $filter = (@($known.Keys | ForEach-Object { "ParentProcessId = $_" }) -join ' OR ')
        $rows = @(Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction Stop)
        foreach ($row in $rows) {
            $pid = [int]$row.ProcessId
            if ($known.ContainsKey($pid) -or -not $known.ContainsKey([int]$row.ParentProcessId)) { continue }
            $parent = $known[[int]$row.ParentProcessId]
            $process = $null
            $retained = $false
            $rawRow = [ordered]@{}
            foreach ($name in @('ProcessId','ParentProcessId','SessionId','CreationDate','ExecutablePath','CommandLine')) {
                $property = $row.PSObject.Properties[$name]
                $rawRow[$name] = if ($null -ne $property) { $property.Value } else { $null }
            }
            $parentCreation = $parent.PSObject.Properties['CreationFileTimeUtc']
            $context = [pscustomobject]@{
                ObservedUtc = [DateTimeOffset]::UtcNow.ToString('o')
                RawRow = [pscustomobject]$rawRow
                ParentPid = $parent.Pid
                ParentCreationFileTimeUtc = if ($null -ne $parentCreation) { $parentCreation.Value } else { $null }
                NativeSnapshot = $null
                ParentNativeSnapshot = $null
                InitialNativeFailure = $null
                ErrorRecord = $null
            }
            $failureCode = 'DescendantNativeIdentityUnavailable'
            try {
                $process = [Diagnostics.Process]::GetProcessById($pid)
                try {
                    $access = Read-CapProcessAccess -Process $process -Role 'descendant' `
                        -CallSite 'Get-CapOwnedDescendants.InitialSnapshot' -ExpectedPid $pid
                } catch {
                    $context.InitialNativeFailure = $_
                    $exclusion = Get-CapAdvisoryOlderExclusion -Parent $parent -Context $context -NativeFailure $_
                    if ($null -eq $exclusion) { throw }
                    $alreadyRecorded = @($script:CapExcludedDescendants | Where-Object {
                        $_.Pid -eq $pid -and $_.ParentPid -eq $parent.Pid -and
                        $_.CandidateCreationFileTimeUtc -eq $exclusion.CandidateCreationFileTimeUtc -and
                        $_.Disposition -ceq $exclusion.Disposition
                    }).Count -gt 0
                    if (-not $alreadyRecorded) {
                        $script:CapExcludedDescendants.Add($exclusion)
                        Write-CapTrace -Command 'CapDescendantAdvisoryExcluded' -Parameters @{
                            diagnosticJson = ($exclusion | ConvertTo-Json -Depth 12 -Compress)
                        }
                    }
                    continue
                }
                $context.NativeSnapshot = [CapNative]::Snapshot($access.Handle, $access.Pid)
                if ($context.NativeSnapshot.IsExited) {
                    Write-CapTrace -Command 'CapDescendantExited' -Parameters @{
                        diagnosticJson = ($context | ConvertTo-Json -Depth 10 -Compress)
                    }
                    continue
                }
                # A reused advisory parent PID can select an older, unrelated image.
                $failureCode = 'DescendantIdentityMismatch'
                $parentAccess = Read-CapProcessAccess -Process $parent.Process -Role $parent.Role `
                    -CallSite 'Get-CapOwnedDescendants.ParentSnapshot' -ExpectedPid $parent.Pid
                $parentSnapshot = [CapNative]::Snapshot($parentAccess.Handle, $parentAccess.Pid)
                $context.ParentNativeSnapshot = $parentSnapshot
                $childCreationFileTimeUtc = $context.NativeSnapshot.CreationFileTimeUtc
                $savedParentCreationFileTimeUtc = $context.ParentCreationFileTimeUtc
                if ($childCreationFileTimeUtc -le 0 -or $savedParentCreationFileTimeUtc -isnot [long] -or
                    $savedParentCreationFileTimeUtc -le 0 -or $parentSnapshot.CreationFileTimeUtc -le 0) {
                    throw "Unprovable descendant or held parent creation time for PID $pid; refusing."
                }
                if ($parentSnapshot.CreationFileTimeUtc -ne $savedParentCreationFileTimeUtc -or
                    ($parentSnapshot.ImagePath -and (ConvertTo-CapImagePath $parentSnapshot.ImagePath) -ine
                        (ConvertTo-CapImagePath $parent.ExpectedImagePath))) {
                    throw "Held parent generation changed for PID $($parent.Pid); refusing."
                }
                $parentExitFileTimeUtc = $parentSnapshot.ExitFileTimeUtc
                if ($parentExitFileTimeUtc -lt 0 -or
                    ($parentSnapshot.IsExited -and $parentExitFileTimeUtc -le 0) -or
                    ($parentExitFileTimeUtc -gt 0 -and $parentExitFileTimeUtc -lt $savedParentCreationFileTimeUtc)) {
                    throw "Unprovable held parent exit time for PID $($parent.Pid); refusing."
                }
                $outsideParentLifetime =
                    ($childCreationFileTimeUtc -lt $savedParentCreationFileTimeUtc) -or
                    ($parentExitFileTimeUtc -gt 0 -and $childCreationFileTimeUtc -gt $parentExitFileTimeUtc)
                if ($outsideParentLifetime) {
                    $alreadyRecorded = @($script:CapExcludedDescendants | Where-Object {
                        $_.Pid -eq $pid -and $_.ParentPid -eq $parent.Pid -and
                        $_.CandidateCreationFileTimeUtc -eq $childCreationFileTimeUtc
                    }).Count -gt 0
                    if (-not $alreadyRecorded) {
                        $script:CapExcludedDescendants.Add([pscustomobject]@{
                            Pid = $pid
                            ParentPid = $parent.Pid
                            ParentCreationFileTimeUtc = $savedParentCreationFileTimeUtc
                            ParentExitFileTimeUtc = $parentExitFileTimeUtc
                            CandidateCreationFileTimeUtc = $childCreationFileTimeUtc
                            CandidateImagePath = $context.NativeSnapshot.ImagePath
                            CandidateCommandLineSha256 = if ($rawRow.CommandLine -is [string]) {
                                [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                                    [Text.Encoding]::UTF8.GetBytes($rawRow.CommandLine)))
                            } else { $null }
                            RawCimRow = $context.RawRow
                            NativeSnapshot = $context.NativeSnapshot
                            ParentNativeSnapshot = $parentSnapshot
                            Disposition = 'REJECTED_PARENT_PID_REUSE_NOT_TERMINATED'
                        })
                    }
                    continue
                }
                $nativePath = ConvertTo-CapImagePath $context.NativeSnapshot.ImagePath
                $failureCode = 'DescendantUnrecognizedImage'
                if ($nativePath -ine (ConvertTo-CapImagePath $ZmxPath) -and
                    $nativePath -ine (ConvertTo-CapImagePath $CmdPath) -and
                    $nativePath -ine (ConvertTo-CapImagePath $ConhostPath)) {
                    throw "Unknown live descendant PID $pid image='$nativePath'; refusing."
                }
                $failureCode = 'DescendantMetadataIncomplete'
                if ([string]::IsNullOrWhiteSpace([string]$rawRow.ExecutablePath) -or
                    [string]::IsNullOrWhiteSpace([string]$rawRow.CommandLine) -or
                    $null -eq $rawRow.CreationDate -or $null -eq $rawRow.ParentProcessId -or
                    $null -eq $rawRow.SessionId) {
                    throw "Live descendant PID $pid has incomplete candidate CIM metadata; refusing."
                }
                $failureCode = 'DescendantMetadataMismatch'
                if ((ConvertTo-CapImagePath ([string]$rawRow.ExecutablePath)) -ine $nativePath) {
                    throw "Candidate CIM image differs from held native image for PID $pid; refusing."
                }
                $failureCode = 'DescendantMetadataIncomplete'
                $identity = Get-CapProcessIdentity -Process $process -ExpectedImagePath $nativePath `
                    -Role 'descendant' -ExpectedParentPid $parent.Pid -ExpectedSessionId $parent.SessionId
                $verified = Assert-CapProcessIdentity -Identity $identity
                if ($verified.State -eq 'Exited') { continue }
                $failureCode = 'DescendantIdentityMismatch'
                $meta = $verified.Metadata
                if ($verified.Snapshot.CreationFileTimeUtc -ne $childCreationFileTimeUtc) {
                    throw "Held descendant generation changed for PID $pid; refusing."
                }
                $null = Assert-CapDescendantLifetime `
                    -ParentCreationFileTimeUtc ([long]$parent.CreationFileTimeUtc) `
                    -ChildCreationFileTimeUtc $childCreationFileTimeUtc `
                    -ParentExitFileTimeUtc $parentExitFileTimeUtc
                # CIM selects candidates; held native generations establish ancestry.
                $childAccess = Read-CapProcessAccess -Process $process -Role $identity.Role `
                    -CallSite 'Get-CapOwnedDescendants.ChildParent' -ExpectedPid $identity.Pid
                if ([CapNative]::ParentProcessId($childAccess.Handle, $childAccess.Pid) -ne $parent.Pid -or
                    [CapNative]::SessionId($childAccess.Handle, $childAccess.Pid) -ne $parent.SessionId -or
                    $meta.ParentPid -ne $parent.Pid -or
                    $meta.SessionId -ne $parent.SessionId) {
                    throw "Descendant PID $pid does not match the saved parent generation/session; refusing."
                }
                $imagePath = ConvertTo-CapImagePath -Path ([string]$meta.ImagePath)
                $failureCode = 'DescendantUnrecognizedCommand'
                if ($imagePath -ieq (ConvertTo-CapImagePath -Path $ZmxPath)) {
                    $appClient = $AllowGraphCodeRoot -and (Test-CapGraphAppRootRole -Role $parent.Role)
                    $validParentRole = $parent.Role -eq 'zmx-seed' -or $appClient
                    $sessionMatches = if ($appClient) {
                        Test-CapAppZmxCommand -CommandLine $meta.CommandLine -ZmxPath $ZmxPath `
                            -SessionPrefix $SessionName -ExactSessionNames $ExactSessionNames
                    } elseif ($ExactSessionNames.Count -gt 0) {
                        Test-CapDSessionCommand -CommandLine $meta.CommandLine -SessionNames $ExactSessionNames
                    } else { $meta.CommandLine -like "*$SessionName*" }
                    if (-not $validParentRole -or -not $sessionMatches) {
                        throw "Unrecognized live zmx child PID $pid; refusing."
                    }
                    $identity.Role = if ($appClient) { 'zmx-client' } else { 'zmx-daemon' }
                } elseif ($imagePath -ieq (ConvertTo-CapImagePath -Path $CmdPath)) {
                    $dSeed = $SessionName -cin @('graphcode-33333333-3333-4333-8333-333333333333','graphcode-44444444-4444-4444-8444-444444444444')
                    $expectedMarker = if ($dSeed -or $ExactSessionNames.Count -gt 0) {'D_OFFLINE_QUICKCHAT_FIXTURE'} else {$CommandMarker}
                    $commandMatches = $expectedMarker -and $meta.CommandLine -like "*$expectedMarker*"
                    if ($parent.Role -notin @('zmx-daemon', 'offline-cmd-peer') -or
                        (-not $commandMatches -and (-not $AllowUnmarkedCmd -or $dSeed -or $ExactSessionNames.Count -gt 0))) {
                        throw "Unrecognized live cmd child PID $pid; refusing."
                    }
                    $identity.Role = 'offline-cmd-peer'
                } elseif ($imagePath -ieq (ConvertTo-CapImagePath -Path $ConhostPath)) {
                    $commandLine = $meta.CommandLine.Trim()
                    if ($commandLine.StartsWith('\??\', [StringComparison]::OrdinalIgnoreCase)) {
                        $commandLine = $commandLine.Substring(4)
                    } elseif ($commandLine.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
                        $commandLine = $commandLine.Substring(4)
                    }
                    $commandParts = @($commandLine -split '\s+')
                    $knownConhostCommand = $false
                    if ($commandParts.Count -eq 2) {
                        $knownConhostCommand =
                            ((ConvertTo-CapImagePath -Path $commandParts[0]) -ieq (ConvertTo-CapImagePath -Path $ConhostPath)) -and
                            ($commandParts[1] -match '^0x[0-9a-fA-F]+$')
                    } elseif ($commandParts.Count -eq 10) {
                        $knownConhostCommand =
                            ((ConvertTo-CapImagePath -Path $commandParts[0]) -ieq (ConvertTo-CapImagePath -Path $ConhostPath)) -and
                            ($commandParts[1] -ceq '--headless') -and
                            ($commandParts[2] -ceq '--width') -and
                            ($commandParts[3] -match '^[1-9][0-9]*$') -and
                            ($commandParts[4] -ceq '--height') -and
                            ($commandParts[5] -match '^[1-9][0-9]*$') -and
                            ($commandParts[6] -ceq '--signal') -and
                            ($commandParts[7] -match '^0x[0-9a-fA-F]+$') -and
                            ($commandParts[8] -ceq '--server') -and
                            ($commandParts[9] -match '^0x[0-9a-fA-F]+$')
                    }
                    $validConhostParent = $parent.Role -in @('zmx-daemon', 'zmx-client') -or
                        ($AllowUnmarkedCmd -and $parent.Role -eq 'offline-cmd-peer')
                    if (-not $validConhostParent -or -not $knownConhostCommand) {
                        throw "Unrecognized live ConPTY conhost child PID $pid; refusing."
                    }
                    $identity.Role = 'conpty-conhost'
                } else {
                    throw "Unknown live descendant PID $pid image='$($meta.ImagePath)'; refusing."
                }
                $known[$pid] = $identity
                $OwnedDescendants.Add($identity)
                $retained = $true
                $changed = $true
            } catch {
                $context.ErrorRecord = [pscustomobject]@{
                    Type = $_.Exception.GetType().FullName
                    Message = $_.Exception.Message
                    Raw = $_.Exception.ToString()
                    FullyQualifiedErrorId = $_.FullyQualifiedErrorId
                    Category = [string]$_.CategoryInfo
                    ScriptStackTrace = $_.ScriptStackTrace
                    ObservedUtc = [DateTimeOffset]::UtcNow.ToString('o')
                }
                $failure = [InvalidOperationException]::new("${failureCode}: $($_.Exception.Message)", $_.Exception)
                $failure.Data['CapCaptureCode'] = $failureCode
                $failure.Data['CandidateContext'] = $context
                $failure.Data['OriginalErrorRecord'] = $_
                $failure.Data['RawCimRow'] = $row
                Write-CapTrace -Command 'CapDescendantRefusal' -Parameters @{
                    diagnosticJson = ($context | ConvertTo-Json -Depth 10 -Compress)
                }
                throw $failure
            } finally {
                if (-not $retained -and $null -ne $process) { $process.Dispose() }
            }
        }
        if (-not $changed) { break }
    }
    return @($OwnedDescendants.ToArray())
}

function Test-CapPipeUnserved {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PipeName)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $errorCode = [CapNative]::ProbePipe($PipeName, 200)
    if ($errorCode -eq 2) { return [pscustomobject]@{ PipeName = $PipeName; Unserved = $true; Win32Error = $errorCode } }
    if ($errorCode -eq 0) { throw "Unique pipe '$PipeName' unexpectedly has a server." }
    throw "Pipe '$PipeName' probe is ambiguous or failed with Win32 error $errorCode."
}

function Get-CapNativeBindingDeclarations {
    $types = @([CapNative], [GraphCodeUiaGateState], [CapProcessJob])
    $declarations = [Collections.Generic.List[object]]::new()
    foreach ($type in $types) {
        foreach ($method in $type.GetMethods([Reflection.BindingFlags]'Static,Public,NonPublic')) {
            $import = $method.GetCustomAttributes([Runtime.InteropServices.DllImportAttribute], $false) |
                Select-Object -First 1
            if ($null -eq $import) { continue }
            $parameters = @($method.GetParameters() | ForEach-Object { $_.ParameterType.FullName })
            $declarations.Add([pscustomobject]@{
                Name = "$($type.FullName).$($method.Name)($($parameters -join ','))"
                Method = $method
                Import = $import
            })
        }
    }
    return @($declarations.ToArray())
}

function Get-CapRequiredNativeBindingNames {
    [CmdletBinding()]
    param()
    foreach ($declaration in Get-CapNativeBindingDeclarations) { $declaration.Name }
}

function Test-CapNativeBindings {
    [CmdletBinding()]
    param()
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters

    $bindings = [Collections.Generic.List[object]]::new()
    foreach ($declaration in Get-CapNativeBindingDeclarations) {
        $method = $declaration.Method
        $import = $declaration.Import
        $libraryHandle = [IntPtr]::Zero
        try {
            $libraryHandle = [Runtime.InteropServices.NativeLibrary]::Load($import.Value)
            $entryPoint = if ([string]::IsNullOrWhiteSpace($import.EntryPoint)) { $method.Name } else { $import.EntryPoint }
            $candidates = [Collections.Generic.List[string]]::new()
            if (-not $import.ExactSpelling) {
                switch ($import.CharSet) {
                    ([Runtime.InteropServices.CharSet]::Unicode) { $candidates.Add($entryPoint + 'W') }
                    ([Runtime.InteropServices.CharSet]::Auto) { $candidates.Add($entryPoint + 'W') }
                    default { $candidates.Add($entryPoint + 'A') }
                }
            }
            $candidates.Add($entryPoint)
            $resolvedEntryPoint = $null
            foreach ($candidate in $candidates) {
                $address = [IntPtr]::Zero
                if ([Runtime.InteropServices.NativeLibrary]::TryGetExport($libraryHandle, $candidate, [ref]$address) -and
                    $address -ne [IntPtr]::Zero) {
                    $resolvedEntryPoint = $candidate
                    break
                }
            }
            if ($null -eq $resolvedEntryPoint) {
                throw "Native export '$entryPoint' (candidates=$($candidates -join ', ')) is missing from '$($import.Value)' for $($method.DeclaringType.FullName)."
            }
            $bindings.Add([pscustomobject]@{ Name = $declaration.Name; Type = $method.DeclaringType.FullName
                Method = $method.Name; Library = $import.Value; EntryPoint = $resolvedEntryPoint })
        } finally {
            if ($libraryHandle -ne [IntPtr]::Zero) { [Runtime.InteropServices.NativeLibrary]::Free($libraryHandle) }
        }
    }
    if ($bindings.Count -eq 0) { throw 'No native P/Invoke bindings were inspected.' }
    return @($bindings)
}

function Test-CapFixtureIsolation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$Namespace
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $phaseRoots = @()
    foreach ($phase in @('before', 'after')) {
        $phaseRoot = Join-Path $rootFull "preflight\$Namespace\phases\$phase"
        $phaseRoots += [IO.Path]::GetFullPath($phaseRoot)
        foreach ($name in @('support', 'local', 'temp', 'tmp', 'profile', 'zmx')) {
            $path = Join-Path $phaseRoot $name
            $full = [IO.Path]::GetFullPath($path)
            if (-not $full.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Fixture path escapes cap root: $full" }
            if ($full -match '\\(ia|ib|ic|id|ie)(\\|$)' -or $full -match '\\gcia(\\|$)') { throw "Foreign lane/runtime path found: $full" }
            New-Item -ItemType Directory -Path $full -Force | Out-Null
        }
    }
    if ($phaseRoots[0] -ieq $phaseRoots[1]) { throw 'Before/after fixture roots are not isolated.' }
    $supportBefore = Join-Path $phaseRoots[0] 'support'
    $supportAfter = Join-Path $phaseRoots[1] 'support'
    [IO.File]::WriteAllText((Join-Path $supportBefore 'onboarding-seen'), '1', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $supportAfter 'onboarding-seen'), '1', [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{
        Root = $rootFull
        BeforeRoot = $phaseRoots[0]
        AfterRoot = $phaseRoots[1]
        BeforeSupport = $supportBefore
        AfterSupport = $supportAfter
        SupportFilesDistinct = ((Join-Path $supportBefore 'onboarding-seen') -ine (Join-Path $supportAfter 'onboarding-seen'))
        SharedFixturePath = Join-Path $rootFull 'fixtures\fixture.json'
        SharedFixtureSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $rootFull 'fixtures\fixture.json')).Hash
    }
}

function Assert-CapDataRecord {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][hashtable]$Fields,
        [Parameter(Mandatory)][string]$Label)
    if ($Value -isnot [pscustomobject]) { throw "$Label must be a complete typed object." }
    foreach ($name in $Fields.Keys) {
        $property = $Value.PSObject.Properties[$name]
        if ($null -eq $property -or $null -eq $property.Value -or
            -not $Fields[$name].IsInstanceOfType($property.Value) -or
            ($property.Value -is [string] -and [string]::IsNullOrWhiteSpace($property.Value))) {
            throw "$Label requires a non-null $($Fields[$name].Name) field '$name'."
        }
    }
}

function Get-CapMatchedSceneNames {
    return @('s-goal-unwired-selected','s-goal-unwired-unselected','s-main-cycle-selected','s-main-cycle-unselected',
        's-main-stopped-reclaim','s-goal-done-reclaim','s-tabs-goal-needs-you','s-tabs-loop-running',
        's-tabs-backend-idle','s-tabs-agent-unknown','s-tabs-two-agent-selected','s-tabs-two-shell-selected',
        's-tabs-split-right-focused','s-tabs-many-first','s-tabs-overflow-last','s-tabs-hover-close',
        's-tabs-last-guard','s-restart-confirmed')
}

function Assert-CapMatchedFixture {
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)][string]$ProjectRoot)
    Assert-CapDataRecord $Fixture @{schemaVersion=[long];sceneAdapter=[string];macSource=[string]
        fixtureUtc=[string];graphs=[array];states=[array];worktrees=[array]} 'Matched fixture'
    $canonicalPath=Join-Path $PSScriptRoot 'fixtures\matched-v12.json'
    $canonical=[IO.File]::ReadAllText($canonicalPath).Replace('C:\\fixture',
        (($ProjectRoot | ConvertTo-Json -Compress).Trim('"')))
    if (-not [Text.Json.Nodes.JsonNode]::DeepEquals(
        [Text.Json.Nodes.JsonNode]::Parse(($Fixture | ConvertTo-Json -Depth 40 -Compress)),
        [Text.Json.Nodes.JsonNode]::Parse($canonical))) {
        throw 'Matched fixture identity, type, wiring, selection, attention reason, resolution or worktree facts differ.'
    }
    $utc=ConvertTo-CapUtcInstant $Fixture.fixtureUtc 'Matched fixture UTC'
    $referenceSeconds=($utc-[DateTime]::new(2001,1,1,0,0,0,[DateTimeKind]::Utc)).TotalSeconds
    $graph=$Fixture.graphs[0]
    if ($graph.project.lastOpenedAt -isnot [ValueType] -or
        [Math]::Abs([double]$graph.project.lastOpenedAt-$referenceSeconds) -gt 0.001) {
        throw 'Matched fixture ProjectRef must preserve numeric Swift-reference lastOpenedAt.'
    }
    foreach ($state in $Fixture.states) {
        $incoming=@($graph.edges | Where-Object {$_.to -ceq $state.nodeId -and $_.blocksTarget})
        $outgoing=@($graph.edges | Where-Object {$_.from -ceq $state.nodeId -and $_.blocksTarget})
        $touching=@($graph.edges | Where-Object {$_.to -ceq $state.nodeId -or $_.from -ceq $state.nodeId})
        $valid=switch ($state.wiring) {
            'unwired' {$touching.Count -eq 0}
            'entry' {$incoming.Count -eq 0 -and $outgoing.Count -gt 0}
            'interior' {$incoming.Count -gt 0}
            'closed-handoff-cycle' {$incoming.Count -eq 1 -and $outgoing.Count -eq 1 -and
                $incoming[0].from -ceq $outgoing[0].to}
            default {$false}
        }
        if (-not $valid) {throw "Matched fixture topology does not establish declared wiring for $($state.scene)."}
    }
    return [pscustomobject]@{states=@($Fixture.states);nodes=$Fixture.graphs[0].nodes.Count
        macSource=$Fixture.macSource;mode='TYPED_WIRE_FIXTURE_NOT_RENDERED_PARITY'
        g11='ASSESSABLE_SOURCE_CAPABILITY_NOT_RUNTIME_VALIDATED'}
}

function Get-CapMatchedAutomationId {
    param([Parameter(Mandatory)][string]$Identity)
    $kind=($Identity -split ':',2)[0]
    [bigint]$hash=1469598103934665603
    foreach ($value in [Text.Encoding]::UTF8.GetBytes($Identity)) {
        $hash=(($hash -bxor [bigint]$value)*1099511628211) -band [bigint]::Parse('18446744073709551615')
    }
    $prefix=if ($kind -cin @('project-card','overview-card')) {'canvas-card'} else {$kind}
    $rowKey=($hash -band [bigint]::Parse('1152921504606846975')) -bor [bigint]::Parse('1152921504606846976')
    return "$prefix-$rowKey"
}

function Get-CapMatchedBackendSource {
    return @'
#include <windows.h>
#include <stdio.h>
int main(void) {
    puts("GraphCode offline capture fixture; not an AI agent");
    fflush(stdout);
    Sleep(INFINITE);
    return 0;
}
'@
}

function Get-CapMatchedTabObservation {
    param([Parameter(Mandatory)][object[]]$Rows,[Parameter(Mandatory)][int]$ExpectedProcessId,
        [Parameter(Mandatory)][int]$TotalTabs,[Parameter(Mandatory)][int]$SelectedTab,
        [Parameter(Mandatory)][string]$AgentTitle,[Parameter(Mandatory)][int[]]$VisibleIndexes)
    if ($TotalTabs -lt 1 -or $SelectedTab -lt 0 -or $SelectedTab -ge $TotalTabs -or
        $VisibleIndexes.Count -lt 1 -or $SelectedTab -notin $VisibleIndexes -or
        @($VisibleIndexes | Sort-Object -Unique).Count -ne $VisibleIndexes.Count) {throw 'Matched tabs invalid declared topology.'}
    foreach ($row in $Rows) {
        if ($row.ProcessId -isnot [long] -or $row.ProcessId -ne $ExpectedProcessId -or
            $row.ParentAutomationId -cne 'graph' -or $row.IsOffscreen -isnot [bool] -or $row.IsOffscreen -or
            $row.Bounds -isnot [array] -or $row.Bounds.Count -ne 4 -or
            $row.Bounds[2] -le $row.Bounds[0] -or $row.Bounds[3] -le $row.Bounds[1]) {
            throw 'Matched tabs require bounded direct children of the owned Graph fragment.'
        }
    }
    $expected=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $observed=[Collections.Generic.List[object]]::new()
    foreach ($index in $VisibleIndexes) {
        $id=Get-CapMatchedAutomationId "workspace-tab:$index"
        $closeId=Get-CapMatchedAutomationId "workspace-tab-close:$index"
        $null=$expected.Add($id);$null=$expected.Add($closeId)
        $tabs=@($Rows | Where-Object AutomationId -CEQ $id)
        $closes=@($Rows | Where-Object AutomationId -CEQ $closeId)
        $title=if ($index -eq 0) {$AgentTitle} else {'Shell'}
        if ($tabs.Count -ne 1 -or $closes.Count -ne 1 -or $tabs[0].Name -cne $title -or
            $tabs[0].Selected -isnot [bool] -or $tabs[0].Selected -ne ($index -eq $SelectedTab) -or
            $closes[0].Name -cne 'Close tab' -or $closes[0].IsEnabled -isnot [bool] -or
            $closes[0].IsEnabled -ne ($TotalTabs -gt 1)) {throw 'Matched tabs identity, name, selection or last-tab guard differs.'}
        $tab=$tabs[0].Bounds;$close=$closes[0].Bounds
        if ($close[0] -lt $tab[0] -or $close[1] -ne $tab[1] -or $close[2] -ne $tab[2] -or
            $close[3] -ne $tab[3] -or $close[2]-$close[0] -ne 24) {throw 'Matched tabs close bounds escape their exact tab.'}
        $observed.Add([pscustomobject]@{index=$index;automationId=$id;name=$title;selected=$tabs[0].Selected
            bounds=$tab;closeBounds=$close;closeEnabled=$closes[0].IsEnabled
            shortcut=if ($index -lt 9) {"Ctrl+$($index+1)"} else {$null}})
    }
    $tabRows=@($Rows | Where-Object {$_.AutomationId -cmatch '^workspace-tab(?:-close)?-'})
    if ($tabRows.Count -ne $expected.Count -or @($tabRows | Where-Object {-not $expected.Contains($_.AutomationId)}).Count) {
        throw 'Matched tabs roster contains hidden, duplicate or foreign tab identities.'
    }
    $ordered=@($observed | Sort-Object index)
    for ($i=1;$i -lt $ordered.Count;$i++) {
        if ($ordered[$i].bounds[0] -le $ordered[$i-1].bounds[2]) {throw 'Matched tabs overlap or are out of order.'}
    }
    return [pscustomobject]@{total=$TotalTabs;selected=$SelectedTab;visible=@($observed)
        evidenceMode='OWNED_UIA_STATE_NOT_GLYPHS_OR_VISUAL_PARITY';hover='VISUAL_ONLY_NOT_EXPOSED_BY_UIA'}
}

function Assert-CapRestartEvidence {
    param([Parameter(Mandatory)]$Evidence,[Parameter(Mandatory)][string]$ExpectedDaemonSha256)
    $fail={param($Reason) throw "Restart evidence: $Reason"}
    foreach ($field in @('projectPath','nodeId','connection','counter','rows','beforeAttach','afterAttach','daemon')) {
        if (-not $Evidence.PSObject.Properties[$field]) {& $fail "missing $field"}
    }
    $daemon=$Evidence.daemon;$before=$Evidence.beforeAttach;$after=$Evidence.afterAttach
    foreach ($pair in @(@($daemon,'held'),@($daemon,'jobOwned'),@($before,'retired'),
        @($after,'held'),@($after,'jobOwned'),@($after,'daemonSessionReady'),@($after,'uiaPaneOwned'),@($after,'oldBackendExited'))) {
        if ($pair[0].($pair[1]) -isnot [bool] -or -not $pair[0].($pair[1])) {& $fail 'typed native ownership/retirement flag is unproved'}
    }
    if ($daemon.pid -isnot [long] -or $daemon.pid -le 0 -or $daemon.creationFileTimeUtc -isnot [long] -or
        $daemon.creationFileTimeUtc -le 0 -or $daemon.held -cne $true -or $daemon.jobOwned -cne $true -or
        $daemon.imageSha256 -ne $ExpectedDaemonSha256 -or $Evidence.connection -isnot [long] -or
        $Evidence.connection -le 0 -or $Evidence.counter -isnot [long] -or $Evidence.counter -lt 0 -or
        $Evidence.rows -isnot [array] -or $Evidence.rows.Count -lt 5) {& $fail 'invalid held daemon or transcript authority'}
    $session="graphcode-$($Evidence.nodeId)"
    if ($before.retired -cne $true -or $before.pid -isnot [long] -or $before.pid -le 0 -or
        $before.creationFileTimeUtc -isnot [long] -or $before.creationFileTimeUtc -le 0 -or
        $before.session -cne $session -or $after.session -cne $session -or $after.held -cne $true -or
        $after.jobOwned -cne $true -or $after.daemonSessionReady -cne $true -or $after.uiaPaneOwned -cne $true -or
        $after.pid -isnot [long] -or $after.pid -le 0 -or $after.creationFileTimeUtc -isnot [long] -or
        $after.creationFileTimeUtc -le $before.creationFileTimeUtc -or
        ($after.pid -eq $before.pid -and $after.creationFileTimeUtc -eq $before.creationFileTimeUtc)) {
        & $fail 'old attachment retirement or new owned daemon-session attachment is unproved'
    }
    if ($after.oldBackendPid -isnot [long] -or $after.oldBackendPid -le 0 -or
        $after.backendPid -isnot [long] -or $after.backendPid -le 0 -or
        $after.oldBackendCreationFileTimeUtc -isnot [long] -or $after.oldBackendCreationFileTimeUtc -le 0 -or
        $after.backendCreationFileTimeUtc -isnot [long] -or
        $after.backendCreationFileTimeUtc -le $after.oldBackendCreationFileTimeUtc) {& $fail 'offline backend generation was not replaced'}
    $restart=$null;$restartResponse=$null;$advance=$null;$resume=$null;$resumeResponse=$null;$baseline=$false
    $ordinal=0L;$elapsed=0L
    foreach ($row in $Evidence.rows) {
        if ($row.ordinal -isnot [long] -or $row.ordinal -le $ordinal -or $row.elapsedMs -isnot [long] -or
            $row.elapsedMs -lt $elapsed -or $row.connection -ne $Evidence.connection -or
            $row.direction -cnotin @('shell','daemon')) {& $fail 'connection, ordering, duplicate or clock mismatch'}
        $ordinal=$row.ordinal;$elapsed=$row.elapsedMs;$frame=$row.frame
        if ($row.direction -ceq 'daemon' -and $frame.kind -ceq 'error') {& $fail 'daemon error envelope is not confirmation'}
        if ($frame.kind -ceq 'request' -and $row.direction -ceq 'shell') {
            if (-not $frame.command.PSObject.Properties['graphCommand']) {continue}
            $graphCommand=$frame.command.graphCommand
            if ($graphCommand.command.PSObject.Properties['stopNode']) {& $fail 'Stop is not Restart'}
            foreach ($action in @('restartNode','resumeSession')) {
                if (-not $graphCommand.command.PSObject.Properties[$action]) {continue}
                if ($action -ceq 'resumeSession' -and -not $restart) {continue}
                $requestId=[guid]::Empty
                if ($graphCommand.projectPath -cne $Evidence.projectPath -or $graphCommand.command.$action._0 -cne $Evidence.nodeId -or
                    $frame.requestID -isnot [string] -or -not [guid]::TryParseExact($frame.requestID,'D',[ref]$requestId)) {& $fail 'request owner or UUID differs'}
                if ($action -ceq 'restartNode') {
                    if ($null -ne $restart -or -not $baseline) {& $fail 'duplicate restart or missing prior owner counter'}
                    $restart=$row
                } else {
                    if ($null -eq $advance -or $null -ne $resume) {& $fail 'resume precedes counter confirmation or is duplicated'}
                    $resume=$row
                }
            }
        }
        if ($frame.kind -ceq 'response' -and $row.direction -ceq 'daemon') {
            if ($restart -and $frame.requestID -ieq $restart.frame.requestID) {
                if (($frame.PSObject.Properties['success'] -and $frame.success -cne $true) -or
                    (-not $frame.PSObject.Properties['event'] -and -not $frame.PSObject.Properties['success']) -or
                    $restartResponse) {& $fail 'restart response failed or duplicated'}
                $restartResponse=$row
            }
            if ($resume -and $frame.requestID -ieq $resume.frame.requestID) {
                if (($frame.PSObject.Properties['success'] -and $frame.success -cne $true) -or
                    (-not $frame.PSObject.Properties['event'] -and -not $frame.PSObject.Properties['success']) -or
                    $resumeResponse) {& $fail 'resume response failed or duplicated'}
                $resumeResponse=$row
            }
        }
        if ($row.direction -cne 'daemon' -or -not $frame.PSObject.Properties['event']) {continue}
        if ($frame.event.PSObject.Properties['errorOccurred']) {& $fail 'daemon error is not confirmation'}
        $graph=$null;$path=$null
        if ($frame.event.PSObject.Properties['graphChanged']) {$graph=$frame.event.graphChanged;$path=$graph.project.path}
        elseif ($frame.event.PSObject.Properties['nodesChanged']) {$graph=$frame.event.nodesChanged;$path=$graph.projectPath}
        if ($null -eq $graph -or $path -cne $Evidence.projectPath) {continue}
        $nodes=@($graph.nodes | Where-Object id -CEQ $Evidence.nodeId)
        if ($nodes.Count -gt 1) {& $fail 'ambiguous owner'}
        if ($nodes.Count -ne 1) {continue}
        $counter=$nodes[0].sessionRestarts
        if ($counter -isnot [long] -or $counter -lt 0) {& $fail 'malformed owner counter'}
        if (-not $restart -and $counter -eq $Evidence.counter) {$baseline=$true}
        if ($restart -and $counter -gt $Evidence.counter) {
            if ($row.elapsedMs-$restart.elapsedMs -gt 30000 -or
                $nodes[0].state -cnotin @('idle','running','awaitingInput','blocked','waiting')) {& $fail 'counter confirmation timed out or loop is not unresolved'}
            if (-not $advance) {$advance=$row}
        }
    }
    if (-not $restart -or -not $restartResponse -or -not $advance -or -not $resume -or -not $resumeResponse -or
        $after.observedAfterOrdinal -isnot [long] -or $after.observedAfterOrdinal -lt $resumeResponse.ordinal) {
        & $fail 'complete correlated restart, counter advance, checked resume and subsequent attach required'
    }
    return [pscustomobject]@{restartRequestId=$restart.frame.requestID;resumeRequestId=$resume.frame.requestID
        connection=$Evidence.connection;counterBefore=$Evidence.counter;counterAfter=($advance.frame.event.PSObject.Properties |
            Where-Object {$_.Name -cin @('graphChanged','nodesChanged')} | ForEach-Object {$_.Value.nodes |
                Where-Object id -CEQ $Evidence.nodeId | ForEach-Object sessionRestarts})
        status='CONFIRMED_DAEMON_ROUNDTRIP_AND_OWNED_REATTACH';backend='OFFLINE_FIXTURE_NOT_AUTHENTICATED_AGENT'}
}

function Initialize-CapMatchedProxy {
    if ('CapMatchedProxy' -as [type]) {return}
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public sealed class CapMatchedProxy : IDisposable {
    readonly string listen, upstream, log;
    readonly CancellationTokenSource cancel;
    readonly object gate = new object();
    readonly System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();
    long ordinal;
    public Task Completion { get; private set; }
    public CapMatchedProxy(string listen, string upstream, string log, int milliseconds) {
        this.listen=listen; this.upstream=upstream; this.log=log;
        using (File.Open(log,FileMode.CreateNew,FileAccess.Write,FileShare.Read)) {}
        cancel=new CancellationTokenSource(milliseconds);
        Completion=Task.Run(Run);
    }
    async Task<byte[]> Read(Stream stream,int count,CancellationToken token) {
        byte[] bytes=new byte[count];int offset=0;
        while(offset<count) {
            int n=await stream.ReadAsync(bytes,offset,count-offset,token).ConfigureAwait(false);
            if(n==0) {if(offset==0)return null;throw new InvalidDataException("Truncated proxy frame");}
            offset+=n;
        }
        return bytes;
    }
    async Task Pump(Stream from,Stream to,string direction,int connection,CancellationToken token) {
        while(true) {
            byte[] header=await Read(from,4,token).ConfigureAwait(false);if(header==null)return;
            int count=(header[0]<<24)|(header[1]<<16)|(header[2]<<8)|header[3];
            if(count<1||count>2097152)throw new InvalidDataException("Invalid proxy frame length");
            byte[] body=await Read(from,count,token).ConfigureAwait(false);
            if(body==null)throw new InvalidDataException("Missing proxy frame body");
            lock(gate) {
                string line="{\"ordinal\":"+(++ordinal)+",\"connection\":"+connection+
                    ",\"elapsedMs\":"+clock.ElapsedMilliseconds+",\"direction\":\""+direction+
                    "\",\"frameBase64\":\""+Convert.ToBase64String(body)+"\"}\n";
                File.AppendAllText(log,line,new UTF8Encoding(false));
            }
            await to.WriteAsync(header,0,4,token).ConfigureAwait(false);
            await to.WriteAsync(body,0,body.Length,token).ConfigureAwait(false);
            await to.FlushAsync(token).ConfigureAwait(false);
        }
    }
    async Task Run() {
        int connection=0;
        try {
            while(!cancel.IsCancellationRequested) {
                using(var server=new NamedPipeServerStream(listen,PipeDirection.InOut,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous|PipeOptions.CurrentUserOnly))
                using(var client=new NamedPipeClientStream(".",upstream,PipeDirection.InOut,PipeOptions.Asynchronous)) {
                    await server.WaitForConnectionAsync(cancel.Token).ConfigureAwait(false);
                    await client.ConnectAsync(5000,cancel.Token).ConfigureAwait(false);
                    connection++;
                    using(var pair=CancellationTokenSource.CreateLinkedTokenSource(cancel.Token)) {
                        var a=Pump(server,client,"shell",connection,pair.Token);
                        var b=Pump(client,server,"daemon",connection,pair.Token);
                        var first=await Task.WhenAny(a,b).ConfigureAwait(false);
                        pair.Cancel();
                        try {await Task.WhenAll(a,b).ConfigureAwait(false);}
                        catch(OperationCanceledException) {if(first.IsFaulted)await first.ConfigureAwait(false);}
                        catch(IOException) {if(first.IsFaulted)await first.ConfigureAwait(false);}
                    }
                }
            }
        } catch(OperationCanceledException) {if(!cancel.IsCancellationRequested)throw;}
    }
    public void Dispose() {
        cancel.Cancel();
        if(!Completion.Wait(5000))throw new TimeoutException("Proxy did not stop");
        cancel.Dispose();
    }
}
'@
}

function Read-CapRestartTranscript {
    param([Parameter(Mandatory)][string]$Path)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        if ($stream.Length -gt 16MB) {throw 'Restart evidence: bounded transcript exceeded 16 MiB'}
        $reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true))
        try {$text=$reader.ReadToEnd()} finally {$reader.Dispose()}
    } finally {$stream.Dispose()}
    if (-not $text.EndsWith("`n",[StringComparison]::Ordinal)) {
        $failure=[IO.InvalidDataException]::new('Restart evidence: transcript publication pending')
        $failure.Data['CapCaptureCode']='RestartTranscriptPending'
        throw $failure
    }
    return @($text -split "`n" | Where-Object {$_} | ForEach-Object {
        $row=$_ | ConvertFrom-Json -DateKind String
        $frame=[Text.UTF8Encoding]::new($false,$true).GetString([Convert]::FromBase64String($row.frameBase64)) |
            ConvertFrom-Json -DateKind String
        [pscustomobject]@{ordinal=$row.ordinal;connection=$row.connection;elapsedMs=$row.elapsedMs;direction=$row.direction;frame=$frame}
    })
}

function Assert-CapMatchedManifest {
    param([Parameter(Mandatory)]$Manifest,[Parameter(Mandatory)]$Job)
    $expected=@(foreach ($phase in @('before','after')) {foreach ($scene in Get-CapMatchedSceneNames) {"${phase}:$scene"}})
    $actual=@($Manifest.images | ForEach-Object {"$($_.phase):$($_.scene)"})
    if ($Manifest.sceneAdapter -cne 'S_MATCHED_V12_V1' -or $Manifest.lane -cne 'S' -or
        $Manifest.status -cne 'COMPLETE' -or $Manifest.executionMode -cne 'LIVE_CAPTURE' -or
        $actual.Count -ne 36 -or @($actual | Sort-Object -Unique).Count -ne 36 -or
        (($actual | Sort-Object) -join ',') -cne (($expected | Sort-Object) -join ',') -or
        $Manifest.g11Qualification -cne 'ASSESSABLE_SOURCE_CAPABILITY_NOT_RUNTIME_VALIDATED' -or
        $Manifest.backendTurns -ne 0 -or $Manifest.realRestarts.Count -ne 2) {throw 'Matched manifest inventory or evidence qualification differs.'}
    foreach ($phase in @('before','after')) {
        $restarts=@($Manifest.realRestarts | Where-Object phase -CEQ $phase)
        if ($restarts.Count -ne 1) {throw 'Matched manifest must retain one real restart per phase.'}
        $null=Assert-CapRestartEvidence -Evidence $restarts[0].evidence -ExpectedDaemonSha256 $Job.binaries.daemon.sha256
    }
    foreach ($image in $Manifest.images) {
        if ($image.captureMode -cne 'PRINTWINDOW' -or $image.observedState.readSucceeded -cne $true -or
            $image.observedState.evidenceMode -cne 'OWNED_UIA_READ_NOT_VISUAL_PARITY') {
            throw 'Matched manifest requires actual images with owned state observations.'
        }
    }
}

function Assert-CapSceneContract {
    param([Parameter(Mandatory)]$Job)
    if ($Job.lane -ceq 'S' -and $Job.sceneAdapter -ceq 'S_MATCHED_V12_V1') {
        Assert-CapDataRecord $Job @{authority=[pscustomobject];captureContract=[pscustomobject];scenes=[array]
            fixture=[pscustomobject];binaries=[pscustomobject]} 'Matched scene'
        Assert-CapDataRecord $Job.authority @{centralCaptureLeaseGrantedByThisArtifact=[bool];sWorkerMayLaunchGui=[bool]} 'Matched scene authority'
        $contract=$Job.captureContract
        Assert-CapDataRecord $contract @{phases=[array];sceneCountPerPhase=[long];windowOuterXYWH=[array]
            expectedClientWH=[array];dpi=[long];canvasZoomPercent=[long];cleanupReserveSeconds=[long];estimatedSeconds=[long]} 'Matched scene geometry'
        Assert-CapDataRecord $Job.binaries.backendFixture @{sha256=[string];sourceSha256=[string];networkAllowed=[bool]} 'Matched scene backend fixture'
        if ($Job.authority.centralCaptureLeaseGrantedByThisArtifact -cne $false -or
            $Job.authority.sWorkerMayLaunchGui -cne $false -or
            ($contract.phases -join ',') -cne 'before,after' -or $contract.sceneCountPerPhase -ne 18 -or
            ($contract.windowOuterXYWH -join ',') -cne '30,30,1456,959' -or
            ($contract.expectedClientWH -join ',') -cne '1440,900' -or $contract.dpi -ne 96 -or
            $contract.canvasZoomPercent -ne 100 -or $contract.cleanupReserveSeconds -ne 90 -or
            $contract.estimatedSeconds -lt 1 -or $contract.estimatedSeconds -gt 1710 -or
            ($Job.scenes.name -join ',') -cne ((Get-CapMatchedSceneNames) -join ',')) {throw 'Matched scene inventory, geometry or non-authority differs.'}
        foreach ($scene in $Job.scenes) {
            Assert-CapDataRecord $scene @{name=[string];naturalWidthBeforeAfter=[array]} 'Matched scene width'
            if ($scene.naturalWidthBeforeAfter.Count -ne 2 -or
                @($scene.naturalWidthBeforeAfter | Where-Object {$_ -isnot [long] -or $_ -ne 250}).Count) {throw 'Matched scene requires exact 250px source widths.'}
        }
        foreach ($binary in @('daemon','backendFixture')) {
            if ($Job.binaries.$binary.sha256 -cnotmatch '^[A-Fa-f0-9]{64}$') {throw 'Matched scene requires hash-bound real daemon and offline backend fixture.'}
        }
        if ($Job.binaries.backendFixture.networkAllowed -cne $false) {throw 'Matched scene backend fixture must prohibit network.'}
        $seed=@('run','graphcode-11111111-1111-4111-8111-000000000001','-d','cmd.exe','/Q','/K','echo Offline card fixture - no backend')
        if (($Job.binaries.offlineZmx.seedArgumentOrder -join [char]0) -cne ($seed -join [char]0)) {throw 'Matched scene requires the exact cmd-only seed vector.'}
        $sourceHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.UTF8Encoding]::new($false).GetBytes((Get-CapMatchedBackendSource))))
        if ($Job.binaries.backendFixture.sourceSha256 -ne $sourceHash) {throw 'Matched scene requires its canonical harmless backend source hash.'}
        return
    }
    if ($Job.lane -ceq 'D' -and $Job.sceneAdapter -ceq 'D_QUICK_CHAT_V1') {
        Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
        Assert-CapDataRecord $Job @{authority=[pscustomobject];captureContract=[pscustomobject];scenes=[array];fixture=[pscustomobject]} 'D scene job'
        Assert-CapDataRecord $Job.authority @{centralCaptureLeaseGrantedByThisArtifact=[bool];dWorkerMayLaunchGui=[bool]} 'D non-authority'
        $contract=$Job.captureContract
        Assert-CapDataRecord $contract @{phases=[array];sceneCountPerPhase=[long];expectedClientWH=[array];dpi=[long]
            canvasZoomPercent=[long];placement=[string];estimatedSeconds=[long];cleanupReserveSeconds=[long]
            requireLiveMissingChat=[bool];requireLiveSavedAgentSplit=[bool]} 'D scene contract'
        if ($Job.authority.centralCaptureLeaseGrantedByThisArtifact -or $Job.authority.dWorkerMayLaunchGui -or
            ($contract.phases -join ',') -cne 'before,after' -or $contract.sceneCountPerPhase -ne 10 -or
            ($contract.expectedClientWH -join ',') -cne '1440,952' -or $contract.dpi -ne 96 -or
            $contract.canvasZoomPercent -ne 100 -or $contract.placement -cne 'MEASURED_FIT_WORKAREA' -or
            $contract.estimatedSeconds -le 0 -or $contract.estimatedSeconds -gt 1710 -or $contract.cleanupReserveSeconds -ne 90 -or
            $Job.scenes.Count -ne 10 -or (($Job.scenes | ForEach-Object name) -join ',') -cne ((Get-CapDSceneNames) -join ',')) {
            throw 'D scene, geometry, budget or non-authority contract differs from the closed adapter.'
        }
        if ($contract.requireLiveMissingChat -or $contract.requireLiveSavedAgentSplit) {
            throw 'D live missing-chat and saved Agent/Split obligations are NotExecuted; required-live requests refuse.'
        }
        if ($contract.PSObject.Properties['requireRuntimeDpiAwareness'] -and $contract.requireRuntimeDpiAwareness) {
            throw 'Runtime DPI awareness is unverified; a required-runtime-awareness job refuses.'
        }
        foreach ($scene in $Job.scenes) {
            Assert-CapDataRecord $scene @{name=[string];naturalWidthBeforeAfter=[array]} 'D scene'
            if ($scene.naturalWidthBeforeAfter.Count -ne 2 -or
                @($scene.naturalWidthBeforeAfter | Where-Object {$_ -isnot [long] -or $_ -lt 1 -or $_ -gt 1000}).Count -ne 0) {
                throw 'D canvas widths must bind both frozen source phases.'
            }
        }
        Assert-CapDataRecord $Job.fixture @{sha256=[string];mappingSha256=[string];originalRoot=[string];offlinePeerReference=[pscustomobject]} 'D fixture'
        Assert-CapDataRecord $Job.fixture.offlinePeerReference @{sha256=[string]} 'D peer'
        Assert-CapDataRecord $Job.binaries.offlineZmx @{sha256=[string];seedCommand=[array]} 'D seed'
        if (($Job.binaries.offlineZmx.seedCommand -join [char]0) -cne (@('/Q','/K','echo D_OFFLINE_QUICKCHAT_FIXTURE') -join [char]0)) {
            throw 'D requires the exact cmd-only seed command.'
        }
        foreach ($digest in @($Job.fixture.sha256,$Job.fixture.mappingSha256,$Job.fixture.offlinePeerReference.sha256,$Job.binaries.offlineZmx.sha256)) {
            if ($digest -notmatch '^[A-Fa-f0-9]{64}$') { throw 'D scene input digest is missing or invalid.' }
        }
        return
    }
    if ($Job.lane -cne 'B' -or $Job.sceneAdapter -cne 'B_FIVE_SCENES_V1') {
        throw 'Unsupported scene adapter; generic identity does not implement C/D/E scene execution.'
    }
    Assert-CapDataRecord $Job @{ authority = [pscustomobject]; captureContract = [pscustomobject]
        scenes = [array]; fixture = [pscustomobject] } 'B scene job'
    Assert-CapDataRecord $Job.authority @{ centralCaptureLeaseGrantedByThisArtifact = [bool]
        bWorkerMayLaunchGui = [bool] } 'Job non-authority'
    Assert-CapDataRecord $Job.captureContract @{ phases = [array]; sceneCountPerPhase = [long]
        windowOuterXYWH = [array]; expectedClientWH = [array]; dpi = [long]; canvasZoomPercent = [long] } 'B geometry'
    Assert-CapDataRecord $Job.fixture @{ sha256 = [string]; mappingSha256 = [string]
        originalRoot = [string]; offlinePeerReference = [pscustomobject] } 'B fixture'
    Assert-CapDataRecord $Job.fixture.offlinePeerReference @{ sha256 = [string] } 'Offline peer'
    Assert-CapDataRecord $Job.binaries.offlineZmx @{ sha256 = [string]; seedArgumentOrder = [array] } 'Offline seed'
    if ($Job.authority.centralCaptureLeaseGrantedByThisArtifact -or $Job.authority.bWorkerMayLaunchGui -or
        ($Job.captureContract.phases -join ',') -cne 'before,after' -or
        $Job.captureContract.sceneCountPerPhase -ne 5 -or
        ($Job.captureContract.windowOuterXYWH -join ',') -cne '30,30,1456,959' -or
        ($Job.captureContract.expectedClientWH -join ',') -cne '1440,900' -or
        $Job.captureContract.dpi -ne 96 -or $Job.captureContract.canvasZoomPercent -ne 100 -or
        $Job.scenes.Count -ne 5 -or
        (($Job.scenes | ForEach-Object name) -join ',') -cne 'project-alpha,project-beta,overview,workspace,actions') {
        throw 'B scene, geometry, zoom or non-authority contract differs from the implemented adapter.'
    }
    $seed = @('run', 'graphcode-11111111-1111-4111-8111-000000000001', '-d',
        'cmd.exe', '/Q', '/K', 'echo Offline card fixture - no backend')
    if (($Job.binaries.offlineZmx.seedArgumentOrder -join [char]0) -cne ($seed -join [char]0)) {
        throw 'B scene adapter requires the exact offline cmd-only seed vector.'
    }
    foreach ($digest in @($Job.fixture.sha256, $Job.fixture.mappingSha256,
        $Job.fixture.offlinePeerReference.sha256, $Job.binaries.offlineZmx.sha256)) {
        if ($digest -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Scene input SHA256 digest is missing or invalid.' }
    }
}

function Get-CapDSceneNames {
    return @('d-quick-chats-canvas','d-chat-primary-shell','d-chat-history-roles','d-chat-show-graph-destination',
        'd-neighbor-sidebar','d-neighbor-overview','d-neighbor-project','d-normal-panel-expanded',
        'd-normal-panel-collapsed','d-normal-route-away-project')
}

function Assert-CapDFixture {
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)][string]$ProjectRoot)
    Assert-CapDataRecord $Fixture @{schemaVersion=[long];sceneAdapter=[string];fixtureUtc=[string];graphs=[array];chats=[array];layouts=[array]} 'D fixture data'
    $utc=ConvertTo-CapUtcInstant -Value $Fixture.fixtureUtc -Field 'fixtureUtc'
    $seconds=($utc-[DateTime]::new(2001,1,1,0,0,0,[DateTimeKind]::Utc)).TotalSeconds
    if ($Fixture.schemaVersion -ne 1 -or $Fixture.sceneAdapter -cne 'D_QUICK_CHAT_V1' -or
        $Fixture.createdAt -isnot [ValueType] -or [Math]::Abs([double]$Fixture.createdAt-$seconds) -gt 0.001 -or
        $seconds -le 10800 -or $Fixture.graphs.Count -ne 1 -or $Fixture.chats.Count -ne 2 -or $Fixture.layouts.Count -ne 3) {
        throw 'D fixture schema, frozen Swift-reference date or inventory differs.'
    }
    $graph=$Fixture.graphs[0]
    $project=Join-Path $ProjectRoot 'D Offline Capture Fixture'
    if ($graph.id -cne 'd-capture-graph' -or $graph.project.name -cne 'D Offline Capture Fixture' -or
        $graph.project.path -cne $project -or $graph.nodes.Count -ne 2 -or $graph.edges.Count -ne 0) { throw 'D graph identity differs.' }
    $ids=@('33333333-3333-4333-8333-333333333333','44444444-4444-4444-8444-444444444444',
        'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA','BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB')
    foreach ($i in 0..1) {
        $chat=$Fixture.chats[$i]
        if ($chat.id -cne $ids[$i] -or $chat.title -cne @('Quick Chat capture fixture','Quick Chat history fixture')[$i] -or
            $chat.backend -cne @('claudeCode','copilot')[$i] -or $chat.createdAt -isnot [ValueType] -or
            [Math]::Abs([double]$chat.createdAt-($seconds-@(2100,10800)[$i])) -gt 0.001 -or $null -ne $chat.activity) {
            throw 'D chat identity, backend or frozen date differs.'
        }
        $node=$graph.nodes[$i]
        if ($node.id -cne $ids[$i+2] -or $node.title -cne @('Loop workspace fixture','Secondary loop fixture')[$i] -or
            $node.loopType -cne 'turnBased' -or $node.state -cne @('running','idle')[$i] -or
            $node.createdAt -isnot [ValueType] -or [double]$node.createdAt -le 0) { throw 'D normal-loop identity or date differs.' }
    }
    $metric=$graph.nodes[0].metricHistory
    if ($metric -isnot [array] -or $metric.Count -ne 2 -or $metric[0].value -isnot [ValueType] -or
        $metric[1].value -isnot [ValueType] -or $metric[0].value -ne 3 -or $metric[1].value -ne 2 -or
        $graph.nodes[0].inputTokens -ne 256 -or $graph.nodes[0].outputTokens -ne 128) {
        throw 'D normal-loop metric requires two numeric object samples and declared synthetic tokens.'
    }
    foreach ($i in 0..2) {
        $layout=$Fixture.layouts[$i]
        $expectedProject=if ($i -lt 2) {'graphcode://quick-chats'} else {$project}
        if ($layout.schemaVersion -ne 2 -or $layout.project -cne $expectedProject -or $layout.loop -cne $ids[$i] -or
            $layout.selectedTab -ne 0 -or $layout.tabs.Count -ne 1 -or $layout.tabs[0].id -ne ($i+1) -or
            $layout.tabs[0].direction -cne 'horizontal' -or $layout.tabs[0].focused -ne 0 -or
            $layout.tabs[0].panes.Count -ne 1 -or $layout.tabs[0].panes[0].id -cne $ids[$i] -or
            $layout.tabs[0].panes[0].agent -isnot [bool] -or $layout.tabs[0].panes[0].agent -ne ($i -eq 2)) {
            throw 'D layout binding, topology or role differs from the two-seed restored-Shell contract.'
        }
    }
}

function Get-CapDLayoutPath {
    param([Parameter(Mandatory)][string]$LayoutBase,[Parameter(Mandatory)][string]$ProjectKey,[Parameter(Mandatory)][string]$LoopId)
    $suffixFor={param([string]$Text)
        $bytes=[Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))
        [Convert]::ToHexString([byte[]]$bytes[7..0]).ToLowerInvariant()
    }
    $base=if ($LayoutBase.EndsWith('.json',[StringComparison]::Ordinal)) {$LayoutBase.Substring(0,$LayoutBase.Length-5)} else {$LayoutBase}
    $projectPath="$base.$(& $suffixFor $ProjectKey).json"
    $file=if ($LoopId -cmatch '^[A-Za-z0-9_-]{1,128}$') {"$LoopId.json"} else {"loop-$(& $suffixFor $LoopId).json"}
    return [pscustomobject]@{ProjectPath=$projectPath;LoopPath=(Join-Path (Split-Path -Parent $projectPath) $file)}
}

function Test-CapDSessionCommand {
    param([Parameter(Mandatory)][string]$CommandLine,[Parameter(Mandatory)][string[]]$SessionNames)
    $expected=@('graphcode-33333333-3333-4333-8333-333333333333','graphcode-44444444-4444-4444-8444-444444444444')
    if (($SessionNames -join ',') -cne ($expected -join ',')) { throw 'D session recovery requires the two exact declared chat sessions.' }
    foreach ($name in $SessionNames) {
        if ($CommandLine -cmatch ('(?:^|\s|")'+[regex]::Escape($name)+'(?=$|\s|")')) { return $true }
    }
    return $false
}

function Get-CapDGeometry {
    param([Parameter(Mandatory)]$Metrics,[Parameter(Mandatory)][int[]]$WorkArea)
    if ($Metrics.Dpi -ne 96 -or $WorkArea.Count -ne 4 -or $Metrics.ClientBounds.Count -ne 4 -or
        $Metrics.OuterBounds.Count -ne 4) { throw 'D geometry requires measured 96 DPI and ordered rectangles.' }
    $outer=$Metrics.OuterBounds;$client=$Metrics.ClientBounds
    $width=1440+($outer[2]-$outer[0])-($client[2]-$client[0])
    $height=952+($outer[3]-$outer[1])-($client[3]-$client[1])
    if ($width -lt 1440 -or $height -lt 952 -or $WorkArea[2]-$WorkArea[0] -lt $width -or $WorkArea[3]-$WorkArea[1] -lt $height) {
        throw 'D requested client and measured frame do not fit the work area.'
    }
    return [pscustomobject]@{x=$WorkArea[0];y=$WorkArea[1];width=$width;height=$height
        outerBounds=@($WorkArea[0],$WorkArea[1],($WorkArea[0]+$width),($WorkArea[1]+$height))}
}

function Get-CapDObservation {
    param([Parameter(Mandatory)][object[]]$Candidates,[Parameter(Mandatory)][int]$ExpectedProcessId,
        [Parameter(Mandatory)][ValidateSet('chats','primary','history','project','overview','expanded','collapsed','missing','roles-component')][string]$State,
        [Parameter(Mandatory)][ValidateSet('before','after')][string]$Phase)
    $rows=@($Candidates | ForEach-Object {if ($_.PSObject.Properties['Current']) {$_.Current} else {$_}})
    foreach ($row in $rows) {$null=Assert-CapUiaProcessIds -ExpectedProcessId $ExpectedProcessId -ObservedProcessIds @([int]$row.ProcessId)}
    $root=@($rows | Where-Object AutomationId -CEQ 'graphcode-root')
    $graph=@($rows | Where-Object AutomationId -CEQ 'graph')
    if ($root.Count -ne 1 -or $graph.Count -ne 1 -or $root[0].IsOffscreen -or $graph[0].IsOffscreen -or
        $root[0].BoundingRectangle.Width -le 0 -or $graph[0].BoundingRectangle.Width -le 0) { throw 'D observation requires one healthy owned root and Graph.' }
    $required=[Collections.Generic.List[object]]::new()
    $require={param([string]$Prefix,[string]$Name)
        $found=@($rows | Where-Object {([string]$_.AutomationId).StartsWith($Prefix,[StringComparison]::Ordinal) -and $_.Name -ceq $Name})
        if ($found.Count -ne 1 -or $found[0].IsOffscreen -or $found[0].BoundingRectangle.Width -le 0 -or
            $found[0].BoundingRectangle.Height -le 0) { throw "D observation requires one bounded $Prefix/$Name; found=$($found.Count)." }
        $required.Add([pscustomobject]@{name=$found[0].Name;automationId=$found[0].AutomationId;bounds=$found[0].BoundingRectangle})
    }
    switch ($State) {
        'chats' {& $require 'quick-chat-card-' 'Quick Chat capture fixture'; & $require 'quick-chat-card-' 'Quick Chat history fixture'}
        {$_ -in @('primary','history')} {
            if ($Phase -ceq 'after') {
                & $require 'workspace-quick-chat-bar-' $(if ($State -ceq 'primary') {'Quick Chat capture fixture'} else {'Quick Chat history fixture'})
                & $require 'workspace-tab-' 'Shell tab'
                & $require 'workspace-restart-session-' 'Restart session'
                & $require 'workspace-show-graph-' 'Show in Graph'
                if (@($rows | Where-Object {$_.AutomationId -match '^workspace-(toggle-panel|detail-|stop-)'}).Count -ne 0) { throw 'D chat workspace exposes normal-loop details or actions.' }
            } else {
                $tabs=@($rows | Where-Object {$_.AutomationId -match '^workspace-tab-[0-9]+$'})
                if ($tabs.Count -ne 1) { throw 'Baseline D chat requires its actual single restored tab.' }
                & $require 'workspace-tab-' $tabs[0].Name
            }
        }
        {$_ -in @('project','overview')} {
            & $require 'canvas-card-' 'Loop workspace fixture'; & $require 'canvas-card-' 'Secondary loop fixture'
            if (@($rows | Where-Object {$_.AutomationId -match '^workspace-(tab-|quick-chat-bar-|loop-bar-|detail-|toggle-panel-)'}).Count -ne 0) { throw 'D route-away still exposes workspace chrome.' }
        }
        'expanded' {
            & $require 'workspace-loop-bar-' 'Selected loop workspace'; & $require 'workspace-toggle-panel-' 'Collapse loop panel'
            & $require 'workspace-detail-sparkline-' 'Metric sparkline'; & $require 'workspace-detail-start-' 'Start time'
            & $require 'workspace-detail-usage-' '384 tokens'; & $require 'workspace-tab-' 'Agent tab'
        }
        'collapsed' {
            & $require 'workspace-loop-bar-' 'Selected loop workspace'; & $require 'workspace-toggle-panel-' 'Expand loop panel'
            & $require 'workspace-tab-' 'Agent tab'
            if (@($rows | Where-Object AutomationId -Like 'workspace-detail-*').Count -ne 0) { throw 'Collapsed D panel still exposes details.' }
        }
        'missing' {
            & $require 'workspace-tab-' 'Shell tab'
            if (@($rows | Where-Object {$_.AutomationId -match '^workspace-(quick-chat-bar-|restart-session-|show-graph-)'}).Count -ne 0) { throw 'Missing-bound-chat component still exposes chat controls.' }
        }
        'roles-component' {& $require 'workspace-tab-' 'Shell tab'; & $require 'workspace-tab-' 'Agent tab'; & $require 'workspace-tab-' 'Split tab'}
    }
    return [pscustomobject]@{state=$State;phase=$Phase;readSucceeded=$true;healthyRoot=$true;observations=@($required)
        evidenceMode='DATA_PREDICATE_NOT_LIVE_OBSERVATION';backendAgentAttach=$false;restartInvoked=$false}
}

function Get-CapDPeerFrames {
    param([Parameter(Mandatory)]$Frame,[Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)][ref]$Sequence)
    $project=$Fixture.graphs[0].project
    if ($Frame.kind -ceq 'hello') {
        if ($Frame.version -ne 2) { throw 'D peer requires protocol 2.' }
        return [ordered]@{version=2;kind='hello';supportedVersions=@(1,2);selectedVersion=2}
    }
    Assert-CapDataRecord $Frame @{version=[long];kind=[string];requestID=[string];command=[pscustomobject]} 'D peer request'
    if ($Frame.version -ne 2 -or $Frame.kind -cne 'request' -or @($Frame.command.PSObject.Properties).Count -ne 1) { throw 'D peer refuses malformed command.' }
    $verb=@($Frame.command.PSObject.Properties)[0].Name
    $payload=$Frame.command.$verb
    if ($payload -isnot [pscustomobject]) { throw 'D peer refuses malformed payload.' }
    $keys=@($payload.PSObject.Properties | ForEach-Object Name)
    $response=[ordered]@{version=2;kind='response';requestID=$Frame.requestID;success=$true}
    switch -CaseSensitive ($verb) {
        'listRecentProjects' {
            if ($keys.Count -ne 0) { throw 'D peer refuses extra payload.' }
            $response.Remove('success');$response.event=@{recentProjectsListed=@(@{path=$project.path;name=$project.name;remote=$false;lastOpenedAt=0})}
            $Sequence.Value++
            return @($response,@{version=2;kind='event';sequence=$Sequence.Value;event=@{graphChanged=$Fixture.graphs[0]}})
        }
        'listQuickChats' {
            if ($keys.Count -ne 0) { throw 'D peer refuses extra payload.' }
            $response.Remove('success');$response.event=@{quickChatsListed=@($Fixture.chats)}
        }
        'openQuickChat' {
            if (($keys -join ',') -cne 'id' -or $payload.id -cnotin @($Fixture.chats | ForEach-Object id)) { throw 'D peer refuses unknown chat.' }
            $chat=@($Fixture.chats | Where-Object id -CEQ $payload.id);$Sequence.Value++
            return @($response,@{version=2;kind='event';sequence=$Sequence.Value;event=@{quickChatChanged=$chat[0]}})
        }
        {$_ -cin @('openProject','readProjectGraph')} {
            if (($keys -join ',') -cne 'path' -or $payload.path -cne $project.path) { throw 'D peer refuses foreign project.' }
            $response.Remove('success');$response.event=@{graphChanged=$Fixture.graphs[0]}
        }
        'graphCommand' {
            if ((($keys | Sort-Object) -join ',') -cne 'command,projectPath' -or $payload.projectPath -cne $project.path -or
                $payload.command -isnot [pscustomobject] -or @($payload.command.PSObject.Properties).Count -ne 1 -or
                @($payload.command.PSObject.Properties)[0].Name -cne 'resumeSession' -or
                $payload.command.resumeSession -isnot [pscustomobject] -or
                (@($payload.command.resumeSession.PSObject.Properties | ForEach-Object Name) -join ',') -cne '_0' -or
                $payload.command.resumeSession._0 -cne 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA') { throw 'D peer refuses all but exact metadata-only resumeSession.' }
        }
        {$_ -cin @('restoreOpenProjects','openGlobalGraph')} {if ($keys.Count -ne 0) { throw 'D peer refuses extra payload.' }}
        default { throw "D peer refuses unapproved command '$verb'." }
    }
    return $response
}

function Get-CapBPeerSource {
    return @'
param([Parameter(Mandatory)][string] $PipeName, [Parameter(Mandatory)][string] $FixturePath)
$ErrorActionPreference = "Stop"
$fixture = Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json -AsHashtable
function Read-Bytes($stream, [int] $length) {
    $bytes = [byte[]]::new($length)
    $offset = 0
    while ($offset -lt $length) {
        $count = $stream.Read($bytes, $offset, $length - $offset)
        if ($count -eq 0) {
            if ($offset -ne 0) { throw [IO.InvalidDataException]::new("Truncated fixture peer frame.") }
            return $null
        }
        $offset += $count
    }
    return ,$bytes
}
function Send-Frame($stream, $frame) {
    $data = [Text.Encoding]::UTF8.GetBytes(($frame | ConvertTo-Json -Depth 32 -Compress))
    $length = [uint32]$data.Length
    $header = [byte[]]@((($length -shr 24) -band 255), (($length -shr 16) -band 255), (($length -shr 8) -band 255), ($length -band 255))
    $stream.Write($header, 0, 4)
    $stream.Write($data, 0, $data.Length)
    $stream.Flush()
}
$null = @{ version = 2; kind = "hello"; supportedVersions = @(1,2); selectedVersion = 2 } |
    ConvertTo-Json -Depth 32 -Compress | ConvertFrom-Json -AsHashtable
[Console]::Out.WriteLine("CAP_PEER_READY:$([DateTime]::UtcNow.ToString('o')):$([Diagnostics.Stopwatch]::GetTimestamp())")
$sequence = 0
while ($true) {
    $server = [IO.Pipes.NamedPipeServerStream]::new($PipeName, [IO.Pipes.PipeDirection]::InOut, 1)
    try {
        $server.WaitForConnection()
        $published = $false
        while ($server.IsConnected) {
            $header = Read-Bytes $server 4
            if ($null -eq $header) { break }
            $length = ([int]$header[0] -shl 24) -bor ([int]$header[1] -shl 16) -bor ([int]$header[2] -shl 8) -bor $header[3]
            if ($length -le 0 -or $length -gt 2097152) { throw [IO.InvalidDataException]::new("Invalid frame length $length") }
            $bytes = Read-Bytes $server $length
            if ($null -eq $bytes) { throw [IO.InvalidDataException]::new("Missing fixture peer frame body.") }
            try {
                $frame = [Text.UTF8Encoding]::new($false,$true).GetString($bytes) | ConvertFrom-Json -AsHashtable
            } catch [ArgumentException] { throw [IO.InvalidDataException]::new("Invalid fixture peer JSON.",$_.Exception) }
            if ($frame -isnot [Collections.IDictionary]) { throw [IO.InvalidDataException]::new("Invalid fixture peer envelope.") }
            if ($frame.kind -eq "hello") {
                Send-Frame $server @{ version = 2; kind = "hello"; supportedVersions = @(1,2); selectedVersion = 2 }
                continue
            }
            if ($frame.kind -ne "request") { throw [IO.InvalidDataException]::new("Unexpected frame kind") }
            if ($frame.command -isnot [Collections.IDictionary] -or $frame.command.Count -eq 0) {
                throw [IO.InvalidDataException]::new("Invalid fixture peer command.")
            }
            $command = @($frame.command.Keys)[0]
            $response = @{ version = 2; kind = "response"; requestID = $frame.requestID; success = $true }
            if ($command -eq "listRecentProjects") {
                $response.Remove("success")
                $response.event = @{ recentProjectsListed = @($fixture.graphs | ForEach-Object { $_.project }) }
            } elseif ($command -eq "listQuickChats") {
                $response.Remove("success")
                $response.event = @{ quickChatsListed = @() }
            }
            Send-Frame $server $response
            if (-not $published -and $command -eq "listRecentProjects") {
                foreach ($graph in $fixture.graphs) {
                    $sequence++
                    Send-Frame $server @{ version = 2; kind = "event"; sequence = $sequence; event = @{ graphChanged = $graph } }
                }
                $published = $true
            }
        }
    } catch [IO.InvalidDataException] {
        [Console]::Error.WriteLine("CAP_PEER_PROTOCOL_REFUSAL: $($_.Exception.Message)")
    } catch [IO.IOException], [ObjectDisposedException] {
    } catch {
        [Console]::Error.WriteLine("CAP_PEER_FATAL: $($_.Exception)")
        throw
    } finally { $server.Dispose() }
}
'@
}

function Get-CapDPeerSource {
    return @'
param([string]$PipeName,[string]$FixturePath,[string]$CommandLog,[string]$ModulePath,[string]$ModuleSha256)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ((Get-FileHash -LiteralPath $ModulePath -Algorithm SHA256).Hash -ne $ModuleSha256) {
    throw 'D fixture peer module hash changed.'
}
Import-Module $ModulePath -Force -WarningAction SilentlyContinue
$fixture = Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json -DateKind String
function Read-Exact([IO.Stream]$Stream,[int]$Length) {
    $bytes = [byte[]]::new($Length)
    $offset = 0
    while ($offset -lt $Length) {
        $read = $Stream.Read($bytes,$offset,$Length-$offset)
        if ($read -eq 0) {
            if ($offset -ne 0) { throw [IO.InvalidDataException]::new('Truncated fixture peer frame.') }
            return $null
        }
        $offset += $read
    }
    return ,$bytes
}
$null = @{version=2;kind='hello';supportedVersions=@(1,2);selectedVersion=2} |
    ConvertTo-Json -Depth 40 -Compress | ConvertFrom-Json -DateKind String
[Console]::Out.WriteLine("CAP_PEER_READY:$([DateTime]::UtcNow.ToString('o')):$([Diagnostics.Stopwatch]::GetTimestamp())")
$sequence = 0
while ($true) {
    $pipe = [IO.Pipes.NamedPipeServerStream]::new($PipeName,[IO.Pipes.PipeDirection]::InOut,1)
    $clientIo = $true
    try {
        $pipe.WaitForConnection()
        while ($pipe.IsConnected) {
            $header = Read-Exact $pipe 4
            if ($null -eq $header) { break }
            $length = ([int]$header[0] -shl 24) -bor ([int]$header[1] -shl 16) -bor ([int]$header[2] -shl 8) -bor $header[3]
            if ($length -le 0 -or $length -gt 2097152) { throw [IO.InvalidDataException]::new('Invalid fixture peer frame length.') }
            $bytes = Read-Exact $pipe $length
            if ($null -eq $bytes) { throw [IO.InvalidDataException]::new('Missing fixture peer frame body.') }
            try {
                $frame = [Text.UTF8Encoding]::new($false,$true).GetString($bytes) | ConvertFrom-Json -DateKind String
            } catch [ArgumentException] { throw [IO.InvalidDataException]::new('Invalid fixture peer JSON.',$_.Exception) }
            if ($frame -isnot [pscustomobject] -or -not $frame.PSObject.Properties['kind'] -or
                -not $frame.PSObject.Properties['version']) { throw [IO.InvalidDataException]::new('Invalid fixture peer envelope.') }
            $clientIo = $false
            try {
                $responses = @(Get-CapDPeerFrames -Frame $frame -Fixture $fixture -Sequence ([ref]$sequence))
            } catch {
                if ($_.Exception.Message -match '^D peer (requires|refuses|request\b)') {
                    throw [IO.InvalidDataException]::new($_.Exception.Message,$_.Exception)
                }
                throw
            }
            [IO.File]::AppendAllText($CommandLog,($frame | ConvertTo-Json -Depth 20 -Compress)+"`n",[Text.UTF8Encoding]::new($false))
            $clientIo = $true
            foreach ($response in $responses) {
                $payload = [Text.Encoding]::UTF8.GetBytes(($response | ConvertTo-Json -Depth 40 -Compress))
                $size = $payload.Length
                $prefix = [byte[]]@((($size -shr 24)-band 255),(($size -shr 16)-band 255),(($size -shr 8)-band 255),($size-band 255))
                $pipe.Write($prefix,0,4)
                $pipe.Write($payload,0,$payload.Length)
                $pipe.Flush()
            }
        }
    } catch [IO.InvalidDataException] {
        [Console]::Error.WriteLine("CAP_PEER_PROTOCOL_REFUSAL: $($_.Exception.Message)")
    } catch [IO.IOException], [ObjectDisposedException] {
        if (-not $clientIo) {
            [Console]::Error.WriteLine("CAP_PEER_FATAL: $($_.Exception)")
            throw
        }
    } catch {
        [Console]::Error.WriteLine("CAP_PEER_FATAL: $($_.Exception)")
        throw
    } finally { $pipe.Dispose() }
}
'@
}

function Read-CapBoundJson {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Reference)
    Assert-CapDataRecord $Reference @{ path = [string]; sha256 = [string] } 'Artifact reference'
    $path = Assert-CapArtifactPath -Root $Root -Path $Reference.path
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($Reference.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -ne $Reference.sha256) {
        throw "Bound artifact hash mismatch: $path"
    }
    $offset = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
    $json = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset)
    $document = [Text.Json.JsonDocument]::Parse($json)
    try {
        $visit = {
            param([Text.Json.JsonElement]$Element)
            if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($property in $Element.EnumerateObject()) {
                    if (-not $names.Add($property.Name)) { throw "Duplicate JSON field in bound artifact: $($property.Name)" }
                    & $visit $property.Value
                }
            } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                foreach ($item in $Element.EnumerateArray()) { & $visit $item }
            }
        }
        & $visit $document.RootElement
    } finally { $document.Dispose() }
    return ConvertFrom-Json -InputObject $json -DateKind String
}

function Invoke-CapAdmissionGit {
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string[]]$Arguments)
    $output = @(& git --no-pager --no-optional-locks -c core.quotepath=false -c core.fsmonitor=false -C $Repository @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Source identity Git command failed ($($Arguments -join ' ')): $($output -join [Environment]::NewLine)" }
    return $output
}

function Assert-CapSourceArchive {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Commit, [Parameter(Mandatory)]$Receipt)
    $sourceRoot = Assert-CapArtifactPath -Root $Root -Path $Receipt.sourceRoot
    # This is archive byte validation, not a claim that compilation was observed by this process.
    $treeSpec = if ($Receipt.sourceSubdirectory -ceq '.') { "$Commit`^{tree}" }
        elseif ($Receipt.sourceSubdirectory -ceq 'graphcode-windows') { "${Commit}:graphcode-windows" }
        else { throw 'Fresh source coverage must be the full repository or graphcode-windows, not a narrowed input subset.' }
    $tree = [string](Invoke-CapAdmissionGit $Repository @('rev-parse', '--verify', $treeSpec))
    if ($tree -cne $Receipt.sourceTree) { throw 'Fresh source tree does not match the named Git object.' }
    $entries = @(Invoke-CapAdmissionGit $Repository @('ls-tree', '-r', $tree))
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $gitlinks = [Collections.Generic.List[string]]::new()
    foreach ($entry in $entries) {
        if ($entry -notmatch '^(100644|100755|160000) (blob|commit) ([a-f0-9]{40})\t([^\r\n\t"]+)$') {
            throw "Unsupported source archive entry: $entry"
        }
        $mode, $kind, $blob, $relative = $Matches[1], $Matches[2], $Matches[3], $Matches[4]
        if ($mode -eq '160000' -and $kind -eq 'commit') { $gitlinks.Add("$relative=$blob"); continue }
        if ($kind -cne 'blob' -or -not $expected.Add($relative)) { throw 'Invalid or duplicate source archive path.' }
        $file = Assert-CapArtifactPath -Root $Root -Path (Join-Path $sourceRoot $relative.Replace('/', '\'))
        $stream = [IO.File]::OpenRead($file)
        $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA1)
        try {
            $hash.AppendData([Text.Encoding]::UTF8.GetBytes("blob $($stream.Length)`0"))
            $buffer = [byte[]]::new(65536)
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) { $hash.AppendData($buffer, 0, $read) }
            $actual = [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
        } finally { $hash.Dispose(); $stream.Dispose() }
        if ($actual -cne $blob) { throw "Fresh source bytes differ from the named Git object: $relative" }
    }
    $files = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File)
    if ($expected.Count -le 0 -or $files.Count -ne $expected.Count) { throw 'Fresh source archive has missing or additional files.' }
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($sourceRoot, $file.FullName).Replace('\', '/')
        if (-not $expected.Contains($relative)) { throw "Untracked fresh source input: $relative" }
    }
    return [pscustomobject]@{ tree = $tree; files = $expected.Count; gitlinks = @($gitlinks) }
}

function Assert-CapJobIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Job,
        [Parameter(Mandatory)]$Lease, [Parameter(Mandatory)][string]$JobSha256,
        [switch]$OfflineTestData)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    Assert-CapDataRecord $Job @{ lane = [string]; head = [string]; base = [string]
        sourceRepository = [string]; admission = [pscustomobject]; binaries = [pscustomobject] } 'Job identity'
    Assert-CapDataRecord $Job.admission @{ schemaVersion = [long]; reviewedHead = [string]
        reviewAcceptance = [pscustomobject]; equivalence = [pscustomobject]; ci = [pscustomobject] } 'Job admission'
    Assert-CapDataRecord $Lease @{ lane = [string]; head = [string]; base = [string]; jobManifestSha256 = [string]
        reviewedHead = [string]; reviewAcceptanceSha256 = [string]; equivalenceSha256 = [string]
        ciInventorySha256 = [string]; ciRuns = [array]
        beforeBuildReceiptSha256 = [string]; afterBuildReceiptSha256 = [string]
        beforeBinarySha256 = [string]; afterBinarySha256 = [string] } 'Lease identity'
    if ($Job.admission.schemaVersion -ne 1 -or $Job.lane -cnotmatch '^[A-Z]$' -or
        $Lease.lane -cne $Job.lane -or $Lease.head -cne $Job.head -or $Lease.base -cne $Job.base -or
        $Lease.jobManifestSha256 -ne $JobSha256 -or $Lease.reviewedHead -cne $Job.admission.reviewedHead -or
        $Lease.reviewAcceptanceSha256 -ne $Job.admission.reviewAcceptance.sha256 -or
        $Lease.equivalenceSha256 -ne $Job.admission.equivalence.sha256 -or
        $Lease.ciInventorySha256 -ne $Job.admission.ci.sha256) {
        throw 'Lease-bound job identity differs from the separately supplied coordinator lease.'
    }
    $repository = [IO.Path]::GetFullPath($Job.sourceRepository)
    if (-not [IO.Path]::IsPathFullyQualified($Job.sourceRepository) -or
        $Job.sourceRepository -notmatch '^[A-Za-z]:\\' -or $Job.sourceRepository.Substring(2).Contains(':') -or
        $Job.sourceRepository -match '(^|\\)\.\.?($|\\)') { throw 'Source repository must be an explicit safe local path.' }
    $ancestor = $repository
    while ($ancestor) {
        if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Source repository has a reparse-point ancestor.'
        }
        $ancestor = Split-Path -Parent $ancestor
    }
    if ([string](Invoke-CapAdmissionGit $repository @('rev-parse', '--show-object-format')) -cne 'sha1') {
        throw 'Unsupported Git source object format.'
    }
    foreach ($commit in @($Job.head, $Job.base, $Job.admission.reviewedHead)) {
        if ($commit -cnotmatch '^[a-f0-9]{40}$' -or
            [string](Invoke-CapAdmissionGit $repository @('rev-parse', '--verify', "$commit`^{commit}")) -cne $commit) {
            throw 'Named source head/base/reviewed head is not an existing exact Git commit.'
        }
        $null = Invoke-CapAdmissionGit $repository @('merge-base', '--is-ancestor', $Job.base, $Job.head)
    }
    if ([string](Invoke-CapAdmissionGit $repository @('rev-parse', 'HEAD')) -cne $Job.head -or
        @(Invoke-CapAdmissionGit $repository @('status', '--porcelain', '--untracked-files=all')).Count -ne 0) {
        throw 'Named source repository is not clean at the exact job head.'
    }
    $review = Read-CapBoundJson $Root $Job.admission.reviewAcceptance
    $equivalence = Read-CapBoundJson $Root $Job.admission.equivalence
    Assert-CapDataRecord $review @{ schemaVersion = [long]; verdict = [string]; evidenceMode = [string]
        reviewedHead = [string]; reviewedBase = [string] } 'Review acceptance'
    Assert-CapDataRecord $equivalence @{ schemaVersion = [long]; reviewedHead = [string]; head = [string]
        reviewedBase = [string]; base = [string]; headDeltaPaths = [array]; baseDeltaPaths = [array] } 'Equivalence proof'
    $reviewMode = if ($OfflineTestData) { 'OFFLINE_TEST_DATA_NOT_REVIEW' } else { 'COORDINATOR_ADMITTED_REVIEW' }
    if ($review.schemaVersion -ne 1 -or $equivalence.schemaVersion -ne 1 -or
        $review.verdict -cne 'ACCEPT' -or $review.evidenceMode -cne $reviewMode -or
        $review.reviewedHead -cne $Job.admission.reviewedHead -or
        $equivalence.reviewedHead -cne $review.reviewedHead -or $equivalence.reviewedBase -cne $review.reviewedBase -or
        $equivalence.head -cne $Job.head -or $equivalence.base -cne $Job.base -or
        $review.reviewedBase -cnotmatch '^[a-f0-9]{40}$') { throw 'Reviewed reference/equivalence identity is not coordinator-bound acceptance.' }
    $null = Invoke-CapAdmissionGit $repository @('rev-parse', '--verify', "$($review.reviewedBase)`^{commit}")
    foreach ($pair in @(
        @($review.reviewedHead, $Job.head, 'headDeltaPaths'),
        @($review.reviewedBase, $Job.base, 'baseDeltaPaths')
    )) {
        $delta = @(Invoke-CapAdmissionGit $repository @('diff', '--name-only', '--no-renames', '--no-ext-diff',
            '--no-textconv', $pair[0], $pair[1], '--'))
        $declared = @($equivalence.($pair[2]))
        if (($delta -join "`0") -cne ($declared -join "`0") -or @($declared | Where-Object { $_ -isnot [string] }).Count) {
            throw 'Equivalence proof does not name the complete exact Git delta.'
        }
        foreach ($path in $delta) {
            # Docs and capture/test harnesses are not product build inputs; every other path is protected.
            $productRoot = $path -match '^(graphcode-windows|graphcode|graphcoded|graphcode-cli|GraphcodeKit|ThirdParty|Tuist)/'
            $nonProduct = -not $productRoot -and ($path -cmatch '\.md$' -or
                $path -cmatch '^(windows-tests/|Tools/[^/]+/Tests/)' -or
                $path -cmatch '^Tools/windows/(UiCaptureDriver\.psm1|Invoke-UiCapture(?:Worker)?\.ps1|fixtures/matched-v12\.json)$')
            if (-not $nonProduct) { throw "Non-equivalent product/provider/build input diff: $path" }
        }
    }
    $ci = Read-CapBoundJson $Root $Job.admission.ci
    Assert-CapDataRecord $ci @{ schemaVersion = [long]; repository = [string]; head = [string]
        evidenceMode = [string]; observedUtc = [string]; runs = [array] } 'CI inventory'
    Assert-CapDataRecord $Job.admission.ci @{ runs = [array] } 'Job CI identity'
    $ciMode = if ($OfflineTestData) { 'OFFLINE_TEST_DATA_NOT_LIVE_CI' } else { 'COORDINATOR_ADMITTED_GITHUB_API_SNAPSHOT' }
    if ($ci.schemaVersion -ne 1 -or $ci.repository -cne 'scgopi/GraphCode' -or $ci.head -cne $Job.head -or
        $ci.evidenceMode -cne $ciMode -or $ci.runs.Count -le 0 -or
        $ci.runs.Count -ne $Job.admission.ci.runs.Count -or $ci.runs.Count -ne $Lease.ciRuns.Count -or
        (ConvertTo-CapUtcInstant $ci.observedUtc 'CI observedUtc') -gt [DateTime]::UtcNow) {
        throw 'CI inventory identity, mode, observation time or run count differs from the lease-bound job.'
    }
    $runIds = [Collections.Generic.HashSet[long]]::new()
    $contextIds = [Collections.Generic.HashSet[long]]::new()
    $contextCount = 0
    for ($i = 0; $i -lt $ci.runs.Count; $i++) {
        $run = $ci.runs[$i]
        Assert-CapDataRecord $run @{ id = [long]; run_attempt = [long]; head_sha = [string]
            status = [string]; conclusion = [string]; total_count = [long]; jobs = [array] } 'CI run'
        foreach ($identity in @($Job.admission.ci.runs[$i], $Lease.ciRuns[$i])) {
            Assert-CapDataRecord $identity @{ id = [long]; attempt = [long] } 'Bound CI run identity'
            if ($identity.id -ne $run.id -or $identity.attempt -ne $run.run_attempt) { throw 'CI run identity/attempt differs from the lease.' }
        }
        if ($run.id -le 0 -or $run.run_attempt -le 0 -or -not $runIds.Add($run.id) -or
            $run.head_sha -cne $Job.head -or $run.status -cne 'completed' -or $run.conclusion -cne 'success') {
            throw 'CI run is not exact-head completed success with a unique positive identity.'
        }
        if ($run.total_count -le 0 -or $run.total_count -ne $run.jobs.Count) {
            throw 'CI inventory must contain a positive complete context count.'
        }
        foreach ($context in $run.jobs) {
            Assert-CapDataRecord $context @{ id = [long]; run_id = [long]; head_sha = [string]; name = [string]
                status = [string]; conclusion = [string]; configuredSkip = [bool] } 'CI context'
            if ($context.id -le 0 -or -not $contextIds.Add($context.id) -or $context.run_id -ne $run.id -or
                $context.head_sha -cne $Job.head -or $context.status -cne 'completed' -or
                ($context.conclusion -cne 'success' -and
                    -not ($context.conclusion -ceq 'skipped' -and $context.configuredSkip))) {
                throw 'CI context is not exact-head green or an explicitly configured skip.'
            }
            $contextCount++
        }
    }
    $builds = [ordered]@{}
    foreach ($phase in @('before', 'after')) {
        $binary = $Job.binaries.$phase
        Assert-CapDataRecord $binary @{ path = [string]; sha256 = [string]; source = [string]
            binaryBuiltAtSource = [string]; buildReceipt = [pscustomobject] } "$phase binary"
        if ($Lease."${phase}BuildReceiptSha256" -ne $binary.buildReceipt.sha256 -or
            $Lease."${phase}BinarySha256" -ne $binary.sha256) { throw 'Lease-bound build receipt/binary identity differs.' }
        $commit = if ($phase -ceq 'before') { $Job.base } else { $Job.head }
        $receipt = Read-CapBoundJson $Root $binary.buildReceipt
        Assert-CapDataRecord $receipt @{ schemaVersion = [long]; evidenceMode = [string]; sourceCommit = [string]
            sourceTree = [string]; sourceRoot = [string]; sourceSubdirectory = [string]
            binaryBuiltAtSource = [string]; archive = [pscustomobject]; log = [pscustomobject]
            rawReceipt = [pscustomobject]; executablePath = [string]; executableSha256 = [string]
            startedUtc = [string]; finishedUtc = [string]; exitCode = [long]; command = [string]; inputs = [array] } "$phase fresh build receipt"
        $buildMode = if ($OfflineTestData) { 'OFFLINE_TEST_DATA_NOT_PRODUCT_BUILD' } else { 'SEPARATE_FRESH_BUILD' }
        if ($receipt.schemaVersion -ne 1 -or $receipt.evidenceMode -cne $buildMode -or
            $binary.source -cne $commit -or $binary.binaryBuiltAtSource -cne $commit -or
            $receipt.sourceCommit -cne $commit -or $receipt.binaryBuiltAtSource -cne $commit -or
            $receipt.exitCode -ne 0 -or $receipt.executablePath -cne $binary.path -or
            $receipt.executableSha256 -ne $binary.sha256 -or $receipt.inputs.Count -le 0) {
            throw 'Fresh build provenance must name the exact phase source and actual built-at commit.'
        }
        $started = ConvertTo-CapUtcInstant $receipt.startedUtc 'Build startedUtc'
        $finished = ConvertTo-CapUtcInstant $receipt.finishedUtc 'Build finishedUtc'
        if ($finished -lt $started -or $finished -gt [DateTime]::UtcNow) { throw 'Fresh build timestamps are reversed or future-dated.' }
        $binaryPath = Assert-CapArtifactPath -Root $Root -Path $binary.path
        if ($binary.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
            (Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash -ne $binary.sha256) {
            throw "$phase binary hash mismatch against the separately produced fresh build."
        }
        $artifactPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($reference in @($receipt.archive, $receipt.log) + @($receipt.inputs)) {
            Assert-CapDataRecord $reference @{ path = [string]; sha256 = [string] } 'Build artifact'
            $path = Assert-CapArtifactPath -Root $Root -Path $reference.path
            if (-not $artifactPaths.Add($path)) { throw 'Duplicate fresh build artifact/input path.' }
            if ($reference.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $reference.sha256) {
                throw "Fresh build artifact hash mismatch: $path"
            }
        }
        $raw = Read-CapBoundJson $Root $receipt.rawReceipt
        Assert-CapDataRecord $raw @{ sourceSha = [string]; builtAtSha = [string]; sourceTree = [string]
            sourceExportSha256 = [string]; executableSha256 = [string]; exitCode = [long]
            startedUtc = [string]; finishedUtc = [string]; command = [string] } 'Original build receipt'
        if ($raw.sourceSha -cne $commit -or $raw.builtAtSha -cne $commit -or $raw.sourceTree -cne $receipt.sourceTree -or
            $raw.sourceExportSha256 -ne $receipt.archive.sha256 -or $raw.executableSha256 -ne $binary.sha256 -or
            $raw.exitCode -ne 0 -or $raw.startedUtc -cne $receipt.startedUtc -or
            $raw.finishedUtc -cne $receipt.finishedUtc -or $raw.command -cne $receipt.command) {
            throw 'Original build receipt does not agree with its relocated fresh-build artifacts.'
        }
        $source = Assert-CapSourceArchive -Root $Root -Repository $repository -Commit $commit -Receipt $receipt
        $builds[$phase] = [ordered]@{ source = $binary.source; binaryBuiltAtSource = $binary.binaryBuiltAtSource
            sha256 = $binary.sha256; receiptSha256 = $binary.buildReceipt.sha256
            sourceTree = $source.tree; sourceFiles = $source.files; gitlinks = $source.gitlinks }
    }
    return [pscustomobject]@{
        head = $Job.head; base = $Job.base; lane = $Job.lane; reviewedHead = $Job.admission.reviewedHead
        sourceRepository = $repository; ciInventorySha256 = $Job.admission.ci.sha256
        ciRuns = $ci.runs.Count; ciContexts = $contextCount
        equivalenceSha256 = $Job.admission.equivalence.sha256; builds = [pscustomobject]$builds
        attestation = 'LEASE_BOUND_ARTIFACT_VALIDATION_NOT_OBSERVED_COMPILATION_OR_LIVE_CI'
    }
}

function ConvertTo-CapUtcInstant {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Field
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    if ($Value -notmatch '(?i)(?:Z|[+-]\d{2}:\d{2})$') {
        throw "$Field must include an explicit UTC marker or numeric offset."
    }
    try {
        return [DateTimeOffset]::Parse(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None
        ).UtcDateTime
    } catch {
        throw "$Field is not a valid offset-qualified timestamp: $Value"
    }
}

function Get-CapLeaseWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GrantedUtc,
        [Parameter(Mandatory)][string]$ExpiresUtc,
        [Parameter(Mandatory)][double]$MaximumMinutes,
        [Parameter(Mandatory)][DateTime]$NowUtc
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    if ($NowUtc.Kind -ne [DateTimeKind]::Utc) {
        throw 'Lease validation clock must be an explicitly UTC DateTime.'
    }
    $granted = ConvertTo-CapUtcInstant -Value $GrantedUtc -Field 'grantedUtc'
    $expires = ConvertTo-CapUtcInstant -Value $ExpiresUtc -Field 'expiresUtc'
    $durationMinutes = ($expires - $granted).TotalMinutes
    if ($MaximumMinutes -le 0 -or $MaximumMinutes -gt 30 -or
        $durationMinutes -le 0 -or $durationMinutes -gt $MaximumMinutes -or
        $durationMinutes -gt 30 -or $granted -gt $NowUtc -or $expires -le $NowUtc) {
        throw 'Coordinator lease is expired, future-dated, or exceeds the 30-minute allocation ceiling.'
    }
    return [pscustomobject]@{
        GrantedUtc = $granted
        ExpiresUtc = $expires
        WorkerDeadlineUtc = $expires.AddSeconds(-90)
        DurationMinutes = $durationMinutes
        MaximumMinutes = $MaximumMinutes
        NowUtc = $NowUtc
    }
}

function Get-CapAuthorizedWorkerDeadline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkerDeadlineUtc,
        [Parameter(Mandatory)]$LeaseWindow,
        [Parameter(Mandatory)][DateTime]$NowUtc
    )
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters


    if ($NowUtc.Kind -ne [DateTimeKind]::Utc) {
        throw 'Worker deadline validation clock must be an explicitly UTC DateTime.'
    }
    $deadline = ConvertTo-CapUtcInstant -Value $WorkerDeadlineUtc -Field 'workerDeadlineUtc'
    if ($deadline -ne $LeaseWindow.WorkerDeadlineUtc) {
        throw 'Coordinator authorization worker deadline does not match the validated lease cleanup reserve.'
    }
    if ($deadline -le $NowUtc) {
        throw 'Coordinator-granted worker deadline has already expired.'
    }
    return $deadline
}

function New-CapJournalFailure {
    param([string]$Class, [string]$Message, [AllowNull()][Exception]$Inner = $null)
    $failure = [IO.IOException]::new("$Class`: $Message", $Inner)
    $failure.Data['CapJournalFailure'] = $Class
    return $failure
}

function Get-CapJournalNativeError {
    param([Exception]$Exception)
    for ($current = $Exception; $null -ne $current; $current = $current.InnerException) {
        if ($current -is [IO.IOException] -or $current -is [UnauthorizedAccessException]) {
            return '{0:X8}' -f ([long]$current.HResult -band 4294967295L)
        }
    }
    return '{0:X8}' -f ([long]$Exception.HResult -band 4294967295L)
}

function ConvertFrom-CapJournalBytes {
    param([byte[]]$Bytes)
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) {
        throw (New-CapJournalFailure 'JournalEncoding' 'Published JSON must be UTF-8 without BOM.')
    }
    try { $json = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes) }
    catch { throw (New-CapJournalFailure 'JournalEncoding' $_.Exception.Message $_.Exception) }
    try {
        $document = [Text.Json.JsonDocument]::Parse($json)
        try {
            $visit = {
                param([Text.Json.JsonElement]$Element)
                if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    foreach ($property in $Element.EnumerateObject()) {
                        if (-not $names.Add($property.Name)) { throw "Duplicate JSON field: $($property.Name)" }
                        & $visit $property.Value
                    }
                } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                    foreach ($item in $Element.EnumerateArray()) { & $visit $item }
                }
            }
            & $visit $document.RootElement
        } finally { $document.Dispose() }
        return ConvertFrom-Json -InputObject $json -DateKind String -Depth 60
    } catch { throw (New-CapJournalFailure 'JournalParse' $_.Exception.Message $_.Exception) }
}

function New-CapJournalBinding {
    [CmdletBinding()]
    param([string]$RunId, [string]$LeaseId, [string]$JobSha256, [string]$ModuleSha256,
        [string]$WorkerSha256, [string]$SupervisorSha256, [Parameter(Mandatory)]$Identity)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    $null = [guid]::Parse($RunId)
    $null = [guid]::Parse($LeaseId)
    foreach ($hash in @($JobSha256, $ModuleSha256, $WorkerSha256, $SupervisorSha256)) {
        if ($hash -cnotmatch '\A[A-F0-9]{64}\z') { throw 'Journal binding requires exact source digests.' }
    }
    return [pscustomobject][ordered]@{
        runId = $RunId; leaseId = $LeaseId; jobSha256 = $JobSha256
        moduleSha256 = $ModuleSha256; workerSha256 = $WorkerSha256
        supervisorSha256 = $SupervisorSha256
        workerPid = [long]$Identity.Pid
        workerCreationFileTimeUtc = [long]$Identity.CreationFileTimeUtc
        workerImagePath = [IO.Path]::GetFullPath($Identity.ExpectedImagePath).ToUpperInvariant()
        workerExecutableSha256 = (Get-FileHash -LiteralPath $Identity.ExpectedImagePath -Algorithm SHA256).Hash
        workerParentPid = [long]$Identity.ParentPid
        workerSessionId = [long]$Identity.SessionId
        workerRole = [string]$Identity.Role
    }
}

function Assert-CapJournalBinding {
    param($Actual, $Expected)
    $fields = @{
        runId = [string]; leaseId = [string]; jobSha256 = [string]; moduleSha256 = [string]
        workerSha256 = [string]; supervisorSha256 = [string]; workerPid = [long]
        workerCreationFileTimeUtc = [long]; workerImagePath = [string]
        workerExecutableSha256 = [string]; workerParentPid = [long]; workerSessionId = [long]
        workerRole = [string]
    }
    try {
        Assert-CapDataRecord $Actual $fields 'Journal binding'
        if (@($Actual.PSObject.Properties).Count -ne $fields.Count) { throw 'Unexpected journal identity field.' }
        $null = [guid]::Parse($Actual.runId)
        $null = [guid]::Parse($Actual.leaseId)
        if ($Actual.workerPid -le 0 -or $Actual.workerCreationFileTimeUtc -le 0 -or
            $Actual.workerParentPid -le 0 -or $Actual.workerSessionId -lt 0 -or
            -not [IO.Path]::IsPathFullyQualified($Actual.workerImagePath)) {
            throw 'Invalid worker generation identity.'
        }
        foreach ($name in @('jobSha256','moduleSha256','workerSha256','supervisorSha256','workerExecutableSha256')) {
            if ($Actual.$name -cnotmatch '\A[A-F0-9]{64}\z') { throw "Invalid identity digest: $name" }
        }
        foreach ($name in $fields.Keys) {
            if ($Actual.$name -cne $Expected.$name) { throw "Journal identity differs: $name" }
        }
    } catch { throw (New-CapJournalFailure 'JournalIdentity' $_.Exception.Message $_.Exception) }
}

function New-CapJournalState {
    [CmdletBinding()]
    param([string]$Root, [string]$Directory, [Parameter(Mandatory)]$Binding,
        [Parameter(Mandatory)][DateTime]$DeadlineUtc, [string]$ObservationPath = '')
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    $directoryPath = Assert-CapArtifactPath -Root $Root -Path $Directory
    if (-not ([IO.File]::GetAttributes($directoryPath) -band [IO.FileAttributes]::Directory)) {
        throw 'Journal requires an existing dedicated directory.'
    }
    if ($ObservationPath) {
        $ObservationPath = Assert-CapArtifactPath -Root $Root -Path $ObservationPath
    }
    Assert-CapJournalBinding $Binding $Binding
    return [pscustomobject]@{
        Root = [IO.Path]::GetFullPath($Root); Directory = $directoryPath; Binding = $Binding
        DeadlineUtc = $DeadlineUtc; ObservationPath = $ObservationPath
        HighestObserved = 0L; LastApplied = 0L; Sequence = 0L; PreviousHash = ('0' * 64)
        Published = [Collections.Generic.List[object]]::new()
        Accepted = [Collections.Generic.Dictionary[long,string]]::new()
        Terminal = $null; PublicationFailed = $false; FatalError = $null
    }
}

function Write-CapJournalObservation {
    param($State, [long]$Sequence, [int]$Attempt, [string]$Decision,
        [AllowNull()][string]$NativeError, $Transaction, [switch]$TerminalFailure)
    if (-not $State.ObservationPath) { return }
    $writeClock = [Diagnostics.Stopwatch]::StartNew()
    $Transaction.ObservationOrdinal++
    $ordinal = $Transaction.ObservationOrdinal
    $failureDecision = $Decision -cin @('OpenFailed','CopyFailed','FinalManifestOpenFailed','DeadlineExhausted')
    $durable = $Decision -cin @('CopyFailed','DeadlineExhausted') -or
        ($TerminalFailure -and $Decision -cin @('OpenFailed','FinalManifestOpenFailed'))
    try {
        $record = [ordered]@{
            runId = $State.Binding.runId; readerPid = $PID; sequence = $Sequence; attempt = $Attempt
            observationTransactionId = $Transaction.ObservationTransactionId
            observationOrdinal = $ordinal
            previousObservationWriteMs = $Transaction.LastCompletedObservationWriteMilliseconds
            previousObservationOrdinal = $Transaction.LastCompletedObservationOrdinal
            utc = [DateTime]::UtcNow.ToString('o')
            monotonicTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
            monotonicFrequency = [Diagnostics.Stopwatch]::Frequency
            nativeHresult = $NativeError; decision = $Decision
            deadlineUtc = $Transaction.DeadlineUtc.ToString('o'); retries = $Transaction.Retries
            openElapsedMilliseconds = $Transaction.OpenElapsedMilliseconds
            copyElapsedMilliseconds = $Transaction.CopyElapsedMilliseconds
            totalElapsedMilliseconds = $Transaction.Clock.Elapsed.TotalMilliseconds
        }
        if ($failureDecision) {
            $record.preOpenMs = if ($null -eq $Transaction.PreOpenElapsedMilliseconds) {
                $Transaction.Clock.Elapsed.TotalMilliseconds
            } else { $Transaction.PreOpenElapsedMilliseconds }
            $record.firstOpen = if ($null -eq $Transaction.PreOpenElapsedMilliseconds) { 'NOT_ATTEMPTED' } else { 'ATTEMPTED' }
        }
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
            (ConvertTo-Json -InputObject $record -Compress -Depth 8) + "`n")
        $stream = [IO.File]::Open($State.ObservationPath, [IO.FileMode]::Append,
            [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            if ($durable) { $stream.Flush($true) } else { $stream.Flush() }
        }
        finally { $stream.Dispose() }
        $writeClock.Stop()
        $Transaction.LastCompletedObservationWriteMilliseconds = $writeClock.Elapsed.TotalMilliseconds
        $Transaction.LastCompletedObservationOrdinal = $ordinal
    } catch { throw (New-CapJournalFailure 'JournalObservationFailure' $_.Exception.Message $_.Exception) }
}

function Write-CapImmutableJson {
    [CmdletBinding()]
    param([string]$Root, [string]$Path, [Parameter(Mandatory)]$Value,
        [string]$TemporaryName = ('.cap-final-' + [guid]::NewGuid().ToString('N') + '.tmp'))
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    $path = Assert-CapArtifactPath -Root $Root -Path $Path
    if ($TemporaryName -cnotmatch '\A(?:\.cap-journal-[0-9]{6}-[0-9a-f]{32}|\.cap-final-[0-9a-f]{32})\.tmp\z') {
        throw (New-CapJournalFailure 'JournalNamespace' 'Invalid unpublished staging name.')
    }
    $temporary = Join-Path (Split-Path -Parent $path) $TemporaryName
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes(
        (ConvertTo-Json -InputObject $Value -Depth 60 -Compress))
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $path)
    } catch {
        $native = Get-CapJournalNativeError $_.Exception
        $class = if ($native -in @('80070050', '800700B7')) { 'SequenceConflict' } else { 'JournalPublicationFailure' }
        throw (New-CapJournalFailure $class "$path HRESULT=$native; staging artifact retained. $($_.Exception.Message)" $_.Exception)
    }
    return [pscustomobject]@{
        name = [IO.Path]::GetFileName($path); length = [long]$bytes.Length
        sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    }
}

function Publish-CapJournalSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State,
        [ValidateSet('Bootstrap','Progress','Terminal')][string]$Kind,
        [Parameter(Mandatory)]$Value)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    if ($State.PublicationFailed -or $null -ne $State.Terminal) {
        throw (New-CapJournalFailure 'JournalPublicationClosed' 'No publication after failure or Terminal.')
    }
    if ([DateTime]::UtcNow -ge $State.DeadlineUtc) {
        throw (New-CapJournalFailure 'JournalExpired' 'Publication deadline reached.')
    }
    $sequence = [long]($State.Sequence + 1)
    if ($sequence -gt 999999) { throw (New-CapJournalFailure 'SequenceConflict' 'Sequence overflow.') }
    $payload = [pscustomobject][ordered]@{
        binding = $State.Binding; sequence = $sequence; previousSequence = [long]$State.Sequence
        previousSha256 = $State.PreviousHash; kind = $Kind; data = $Value
    }
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes(
        (ConvertTo-Json -InputObject $payload -Depth 55 -Compress))
    $envelope = [ordered]@{
        schemaVersion = 2L; sequence = $sequence; payloadLength = [long]$bytes.Length
        payloadSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        payloadBase64 = [Convert]::ToBase64String($bytes)
    }
    $name = $sequence.ToString('D6', [Globalization.CultureInfo]::InvariantCulture) + '.json'
    try {
        $reference = Write-CapImmutableJson -Root $State.Root -Path (Join-Path $State.Directory $name) `
            -Value $envelope -TemporaryName ('.cap-journal-' + $sequence.ToString('D6') + '-' +
                [guid]::NewGuid().ToString('N') + '.tmp')
    } catch { $State.PublicationFailed = $true; throw }
    $reference | Add-Member -NotePropertyName sequence -NotePropertyValue $sequence
    $State.Sequence = $sequence
    $State.PreviousHash = $reference.sha256
    $State.Published.Add($reference)
    if ($Kind -ceq 'Terminal') { $State.Terminal = $reference }
    return $reference
}

function Get-CapJournalNames {
    param($State, [switch]$Final)
    $numbers = [Collections.Generic.Dictionary[long,string]]::new()
    try { $paths = @([IO.Directory]::EnumerateFileSystemEntries($State.Directory)) }
    catch { throw (New-CapJournalFailure 'JournalNamespace' $_.Exception.Message $_.Exception) }
    foreach ($path in $paths) {
        $name = [IO.Path]::GetFileName($path)
        if ($name -cmatch '\A(?:\.cap-journal-[0-9]{6}-[0-9a-f]{32}|\.cap-final-[0-9a-f]{32})\.tmp\z') {
            if ($Final) { throw (New-CapJournalFailure 'ResidualJournalArtifact' $path) }
            continue
        }
        try { $attributes = [IO.File]::GetAttributes($path) }
        catch {
            $class = if ((Get-CapJournalNativeError $_.Exception) -eq '80070005') { 'JournalAccessDenied' } else { 'JournalNamespace' }
            throw (New-CapJournalFailure $class $_.Exception.Message $_.Exception)
        }
        if ($name -cnotmatch '\A[0-9]{6}\.json\z' -or
            ($attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint))) {
            throw (New-CapJournalFailure 'JournalNamespace' "Noncanonical publication: $name")
        }
        $number = [long]::Parse($name.Substring(0, 6), [Globalization.CultureInfo]::InvariantCulture)
        if ($number -lt 1 -or -not $numbers.TryAdd($number, $name)) {
            throw (New-CapJournalFailure 'SequenceConflict' "Invalid or duplicate publication: $name")
        }
    }
    return ,$numbers
}

function New-CapJournalTransaction {
    param($State, [switch]$ManifestBudget)
    $createdUtc = [DateTime]::UtcNow
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $remaining = [Math]::Max(0, [Math]::Min(1000.0, ($State.DeadlineUtc - $createdUtc).TotalMilliseconds))
    return [pscustomobject]@{
        CreatedUtc = $createdUtc
        DeadlineUtc = if ($ManifestBudget) { $createdUtc.AddMilliseconds($remaining) } else { $State.DeadlineUtc }
        Clock = $clock
        IoClock = if ($ManifestBudget) { $clock } else { $null }
        BudgetMilliseconds = if ($ManifestBudget) { $remaining } else { 1000.0 }
        PreOpenElapsedMilliseconds = $null
        ObservationState = $State
        ObservationTransactionId = [guid]::NewGuid().ToString('N')
        ObservationOrdinal = 0L
        LastCompletedObservationWriteMilliseconds = $null
        LastCompletedObservationOrdinal = $null
        Retries = 0
        Attempts = [Collections.Generic.Dictionary[long,int]]::new()
        OpenElapsedMilliseconds = $null
        CopyElapsedMilliseconds = $null
    }
}

function Format-CapJournalPhaseTiming {
    param($Transaction)
    $open = if ($null -eq $Transaction.OpenElapsedMilliseconds) { 'UNOBSERVED' }
        else { $Transaction.OpenElapsedMilliseconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture) }
    $copy = if ($null -eq $Transaction.CopyElapsedMilliseconds) { 'UNOBSERVED' }
        else { $Transaction.CopyElapsedMilliseconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture) }
    $preOpen = if ($null -eq $Transaction.PreOpenElapsedMilliseconds) { $Transaction.Clock.Elapsed.TotalMilliseconds }
        else { $Transaction.PreOpenElapsedMilliseconds }
    $firstOpen = if ($null -eq $Transaction.PreOpenElapsedMilliseconds) { 'NOT_ATTEMPTED' } else { 'ATTEMPTED' }
    $observation = if ($null -eq $Transaction.LastCompletedObservationWriteMilliseconds) { 'UNOBSERVED' }
        else { $Transaction.LastCompletedObservationWriteMilliseconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture) }
    return "preOpenMs=$($preOpen.ToString('F3', [Globalization.CultureInfo]::InvariantCulture)) firstOpen=$firstOpen openMs=$open copyMs=$copy totalMs=$($Transaction.Clock.Elapsed.TotalMilliseconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture)) previousObservationWriteMs=$observation previousObservationOrdinal=$($Transaction.LastCompletedObservationOrdinal) observationTransactionId=$($Transaction.ObservationTransactionId)"
}

function Assert-CapJournalTime {
    param($Transaction, [long]$Sequence, [AllowNull()][string]$NativeError = $null)
    if ([DateTime]::UtcNow -ge $Transaction.DeadlineUtc -or
        ($null -ne $Transaction.IoClock -and
            $Transaction.IoClock.Elapsed.TotalMilliseconds -ge $Transaction.BudgetMilliseconds)) {
        $failure = New-CapJournalFailure 'JournalUnavailable' (
            "sequence=$Sequence HRESULT=$NativeError retries=$($Transaction.Retries); deadline/exhaustion, no late success. $(Format-CapJournalPhaseTiming $Transaction)")
        try {
            $attempt = if ($Transaction.Attempts.ContainsKey($Sequence)) { $Transaction.Attempts[$Sequence] } else { 0 }
            Write-CapJournalObservation $Transaction.ObservationState $Sequence $attempt 'DeadlineExhausted' $NativeError $Transaction
        } catch {
            $failure.Data['CapJournalObservationFailure'] = $_.Exception.ToString()
            [Console]::Error.WriteLine("JournalObservationFailure while reporting JournalUnavailable: $($_.Exception.Message)")
        }
        throw $failure
    }
}

function Read-CapJournalObject {
    param($State, [long]$Sequence, $Transaction, [switch]$Advance, [switch]$RetainStream)
    $native = $null
    while ($true) {
        Assert-CapJournalTime $Transaction $Sequence $native
        if (-not $Transaction.Attempts.ContainsKey($Sequence)) { $Transaction.Attempts[$Sequence] = 0 }
        if ($Transaction.Attempts[$Sequence] -ge 8) {
            throw (New-CapJournalFailure 'JournalUnavailable' "sequence=$Sequence HRESULT=$native; eight Open attempts. $(Format-CapJournalPhaseTiming $Transaction)")
        }
        $name = $Sequence.ToString('D6', [Globalization.CultureInfo]::InvariantCulture) + '.json'
        $path = Join-Path $State.Directory $name
        $retained = $false
        Assert-CapJournalTime $Transaction $Sequence $native
        if ($null -eq $Transaction.IoClock) {
            $now = [DateTime]::UtcNow
            $Transaction.BudgetMilliseconds = [Math]::Max(0, [Math]::Min(1000.0,
                ($Transaction.DeadlineUtc - $now).TotalMilliseconds))
            $ioDeadline = $now.AddMilliseconds($Transaction.BudgetMilliseconds)
            if ($ioDeadline -lt $Transaction.DeadlineUtc) { $Transaction.DeadlineUtc = $ioDeadline }
            $Transaction.IoClock = [Diagnostics.Stopwatch]::StartNew()
        }
        Assert-CapJournalTime $Transaction $Sequence $native
        if ($null -eq $Transaction.PreOpenElapsedMilliseconds) {
            $Transaction.PreOpenElapsedMilliseconds = $Transaction.Clock.Elapsed.TotalMilliseconds
        }
        $Transaction.Attempts[$Sequence]++
        $attempt = $Transaction.Attempts[$Sequence]
        try {
            $openClock = [Diagnostics.Stopwatch]::StartNew()
            try {
                $stream = [IO.File]::Open($path, [IO.FileMode]::Open,
                    [IO.FileAccess]::Read, [IO.FileShare]::Read)
            } finally {
                $elapsed = $openClock.Elapsed.TotalMilliseconds
                $Transaction.OpenElapsedMilliseconds = if ($null -eq $Transaction.OpenElapsedMilliseconds) { $elapsed }
                    else { $Transaction.OpenElapsedMilliseconds + $elapsed }
            }
        } catch {
            $native = Get-CapJournalNativeError $_.Exception
            $terminalFailure = $native -notin @('80070002','80070003','80070020','80070021') -or
                $Transaction.Retries -ge 7
            Write-CapJournalObservation $State $Sequence $attempt 'OpenFailed' $native $Transaction `
                -TerminalFailure:$terminalFailure
            if ($native -notin @('80070002','80070003','80070020','80070021')) {
                $class = if ($native -eq '80070005') { 'JournalAccessDenied' } else { 'JournalOpenFailure' }
                throw (New-CapJournalFailure $class "sequence=$Sequence HRESULT=$native" $_.Exception)
            }
            if ($Transaction.Retries -ge 7) {
                throw (New-CapJournalFailure 'JournalUnavailable' "sequence=$Sequence HRESULT=$native; global retry limit. $(Format-CapJournalPhaseTiming $Transaction)")
            }
            $Transaction.Retries++
            Assert-CapJournalTime $Transaction $Sequence $native
            $remaining = [Math]::Min(($Transaction.DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds,
                $Transaction.BudgetMilliseconds - $Transaction.IoClock.Elapsed.TotalMilliseconds)
            if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Min(100, [Math]::Floor($remaining))) }
            Assert-CapJournalTime $Transaction $Sequence $native
            if ($Advance) {
                $names = Get-CapJournalNames $State
                foreach ($number in $names.Keys) { $State.HighestObserved = [Math]::Max($State.HighestObserved, $number) }
                $Sequence = [Math]::Max($Sequence, $State.HighestObserved)
            }
            continue
        }
        try {
            $buffer = [IO.MemoryStream]::new()
            try {
                $copyClock = [Diagnostics.Stopwatch]::StartNew()
                try { $stream.CopyTo($buffer); $bytes = $buffer.ToArray() }
                finally {
                    $elapsed = $copyClock.Elapsed.TotalMilliseconds
                    $Transaction.CopyElapsedMilliseconds = if ($null -eq $Transaction.CopyElapsedMilliseconds) { $elapsed }
                        else { $Transaction.CopyElapsedMilliseconds + $elapsed }
                }
            } catch {
                Write-CapJournalObservation $State $Sequence $attempt 'CopyFailed' (Get-CapJournalNativeError $_.Exception) $Transaction
                throw
            }
            finally { $buffer.Dispose() }
            Assert-CapJournalTime $Transaction $Sequence
            $envelope = ConvertFrom-CapJournalBytes $bytes
            try {
                Assert-CapDataRecord $envelope @{ schemaVersion = [long]; sequence = [long]
                    payloadLength = [long]; payloadSha256 = [string]; payloadBase64 = [string] } 'Journal envelope'
                if (@($envelope.PSObject.Properties).Count -ne 5 -or $envelope.schemaVersion -ne 2 -or
                    $envelope.sequence -ne $Sequence) { throw 'Envelope version/name/sequence mismatch.' }
                $payloadBytes = [Convert]::FromBase64String($envelope.payloadBase64)
                if ([Convert]::ToBase64String($payloadBytes) -cne $envelope.payloadBase64) {
                    throw 'Noncanonical payload base64.'
                }
            } catch { throw (New-CapJournalFailure 'JournalSchema' $_.Exception.Message $_.Exception) }
            if ($payloadBytes.Length -ne $envelope.payloadLength -or
                [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payloadBytes)) -cne $envelope.payloadSha256) {
                throw (New-CapJournalFailure 'JournalHash' "Payload hash/length differs at $Sequence.")
            }
            $payload = ConvertFrom-CapJournalBytes $payloadBytes
            try {
                Assert-CapDataRecord $payload @{ binding = [pscustomobject]; sequence = [long]
                    previousSequence = [long]; previousSha256 = [string]; kind = [string]; data = [pscustomobject] } 'Journal payload'
                if (@($payload.PSObject.Properties).Count -ne 6 -or
                    $payload.previousSha256 -cnotmatch '\A[A-F0-9]{64}\z' -or
                    $payload.kind -cnotin @('Bootstrap','Progress','Terminal')) { throw 'Invalid journal payload schema.' }
                Assert-CapDataRecord $payload.data @{ entries = [array] } 'Journal entries'
            } catch { throw (New-CapJournalFailure 'JournalSchema' $_.Exception.Message $_.Exception) }
            Assert-CapJournalBinding $payload.binding $State.Binding
            if ($payload.sequence -ne $Sequence -or $payload.previousSequence -ne ($Sequence - 1)) {
                throw (New-CapJournalFailure 'SequenceGap' "Predecessor/sequence mismatch at $Sequence.")
            }
            Assert-CapJournalTime $Transaction $Sequence
            $reference = [pscustomobject]@{
                sequence = $Sequence; name = $name; length = [long]$bytes.Length
                sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
            }
            Write-CapJournalObservation $State $Sequence $attempt 'ReadVerified' $null $Transaction
            Assert-CapJournalTime $Transaction $Sequence
            $result = [pscustomobject]@{ Reference = $reference; Payload = $payload; Stream = $null }
            if ($RetainStream) { $result.Stream = $stream; $retained = $true }
            return $result
        } finally { if (-not $retained) { $stream.Dispose() } }
    }
}

function Read-CapJournalSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    if ($null -ne $State.FatalError) { throw $State.FatalError }
    try {
        $transaction = New-CapJournalTransaction $State
        Assert-CapJournalTime $transaction $State.HighestObserved
        $names = Get-CapJournalNames $State
        foreach ($number in $names.Keys) { $State.HighestObserved = [Math]::Max($State.HighestObserved, $number) }
        if ($State.HighestObserved -eq 0) {
            return [pscustomobject]@{ State = 'PendingFirstPublication'; Snapshot = $null; HashChainVerified = $false }
        }
        while ($true) {
            $snapshot = Read-CapJournalObject $State $State.HighestObserved $transaction -Advance
            $names = Get-CapJournalNames $State
            foreach ($number in $names.Keys) { $State.HighestObserved = [Math]::Max($State.HighestObserved, $number) }
            if ($snapshot.Reference.sequence -lt $State.HighestObserved) { continue }
            for ($number = 1L; $number -le $snapshot.Reference.sequence; $number++) {
                if (-not $names.ContainsKey($number)) {
                    $null = Read-CapJournalObject $State $number $transaction
                }
            }
            Assert-CapJournalTime $transaction $snapshot.Reference.sequence
            if ($snapshot.Reference.sequence -lt $State.LastApplied) {
                throw (New-CapJournalFailure 'SequenceRegression' 'Cannot apply older journal state.')
            }
            if ($State.Accepted.ContainsKey($snapshot.Reference.sequence) -and
                $State.Accepted[$snapshot.Reference.sequence] -cne $snapshot.Reference.sha256) {
                throw (New-CapJournalFailure 'JournalHash' 'An accepted immutable publication changed.')
            }
            $State.Accepted[$snapshot.Reference.sequence] = $snapshot.Reference.sha256
            $State.LastApplied = $snapshot.Reference.sequence
            Write-CapJournalObservation $State $snapshot.Reference.sequence `
                $transaction.Attempts[$snapshot.Reference.sequence] 'AcceptedLiveSequenceOnly' $null $transaction
            Assert-CapJournalTime $transaction $snapshot.Reference.sequence
            return [pscustomobject]@{ State = 'Published'; Snapshot = $snapshot; HashChainVerified = $false }
        }
    } catch { $State.FatalError = $_.Exception; throw }
}

function Assert-CapJournalReference {
    param($Reference, [switch]$Numbered)
    try {
        Assert-CapDataRecord $Reference @{ name = [string]; length = [long]; sha256 = [string] } 'Journal reference'
        $expectedProperties = if ($Numbered) { 4 } else { 3 }
        if (@($Reference.PSObject.Properties).Count -ne $expectedProperties) { throw 'Unexpected byte reference field.' }
        if ($Reference.length -le 0 -or $Reference.sha256 -cnotmatch '\A[A-F0-9]{64}\z' -or
            [IO.Path]::GetFileName($Reference.name) -cne $Reference.name -or
            $Reference.name.Contains(':')) { throw 'Noncanonical byte reference.' }
        if ($Numbered) {
            Assert-CapDataRecord $Reference @{ sequence = [long] } 'Numbered reference'
            if ($Reference.sequence -lt 1 -or $Reference.sequence -gt 999999 -or
                $Reference.name -cne ($Reference.sequence.ToString('D6') + '.json')) {
                throw 'Numbered reference differs from its sequence.'
            }
        }
    } catch { throw (New-CapJournalFailure 'JournalSchema' $_.Exception.Message $_.Exception) }
}

function Format-CapJournalFinalRecord {
    [CmdletBinding()]
    param($Binding, $Manifest, $Terminal)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    Assert-CapJournalReference $Manifest
    Assert-CapJournalReference $Terminal -Numbered
    $record = [ordered]@{ schemaVersion = 2L; binding = $Binding; manifest = $Manifest; terminal = $Terminal }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
        (ConvertTo-Json -InputObject $record -Depth 15 -Compress))
    return 'CAP_JOURNAL_FINAL_V2 ' + [Convert]::ToBase64String($bytes)
}

function Read-CapJournalFinalRecord {
    [CmdletBinding()]
    param([string]$Stdout, $Binding)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    $lines = @([regex]::Split($Stdout, '\r?\n') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $records = @($lines | Where-Object { $_.StartsWith('CAP_JOURNAL_FINAL', [StringComparison]::Ordinal) })
    if ($records.Count -ne 1 -or $lines[-1] -cne $records[0] -or
        $records[0] -cnotmatch '\ACAP_JOURNAL_FINAL_V2 ([A-Za-z0-9+/]+={0,2})\z') {
        throw (New-CapJournalFailure 'JournalFinalRecord' 'Missing, duplicate, partial or nonfinal stdout binding.')
    }
    try {
        $encoded = $records[0].Substring('CAP_JOURNAL_FINAL_V2 '.Length)
        $bytes = [Convert]::FromBase64String($encoded)
        if ([Convert]::ToBase64String($bytes) -cne $encoded) { throw 'Noncanonical final base64.' }
        $record = ConvertFrom-CapJournalBytes $bytes
        Assert-CapDataRecord $record @{ schemaVersion = [long]; binding = [pscustomobject]
            manifest = [pscustomobject]; terminal = [pscustomobject] } 'Final binding'
        if ($record.schemaVersion -ne 2 -or @($record.PSObject.Properties).Count -ne 4) { throw 'Final binding schema differs.' }
        Assert-CapJournalBinding $record.binding $Binding
        Assert-CapJournalReference $record.manifest
        Assert-CapJournalReference $record.terminal -Numbered
        if ((Format-CapJournalFinalRecord $Binding $record.manifest $record.terminal) -cne $records[0]) {
            throw 'Final record is not the canonical compact encoding.'
        }
        return $record
    } catch { throw (New-CapJournalFailure 'JournalFinalRecord' $_.Exception.Message $_.Exception) }
}

function Read-CapJournalFinalProof {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [string]$OutputDirectory,
        [Parameter(Mandatory)]$Record, [switch]$RetainStreams)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    if ($null -ne $State.FatalError) { throw $State.FatalError }
    Assert-CapJournalBinding $Record.binding $State.Binding
    Assert-CapJournalReference $Record.terminal -Numbered
    Assert-CapJournalReference $Record.manifest
    if ($State.HighestObserved -gt $Record.terminal.sequence) {
        throw (New-CapJournalFailure 'PostTerminalPublication' 'Observed floor exceeds final binding.')
    }
    $transaction = New-CapJournalTransaction $State -ManifestBudget
    Assert-CapJournalTime $transaction $Record.terminal.sequence
    $manifestPath = Assert-CapArtifactPath -Root $State.Root -Path (Join-Path $OutputDirectory $Record.manifest.name)
    $stream = $null
    $held = [Collections.Generic.List[IO.Stream]]::new()
    $keepStreams = $false
    try {
        $stream = Open-CapJournalManifestStream $State $manifestPath $transaction $Record.terminal.sequence
        $held.Add($stream)
        $memory = [IO.MemoryStream]::new()
        try { $stream.CopyTo($memory); $bytes = $memory.ToArray() } finally { $memory.Dispose() }
        if ($bytes.Length -ne $Record.manifest.length -or
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $Record.manifest.sha256) {
            throw (New-CapJournalFailure 'JournalHash' 'Final manifest bytes differ.')
        }
        $manifest = ConvertFrom-CapJournalBytes $bytes
        Assert-CapDataRecord $manifest @{ journal = [pscustomobject]; status = [string]
            ownedProcesses = [array]; ownedProcessSurvivors = [array]
            pendingLaunchesRemaining = [array]; cleanupFailures = [array] } 'Final manifest'
        Assert-CapDataRecord $manifest.journal @{ protocolVersion = [long]; binding = [pscustomobject]
            terminal = [pscustomobject]; published = [array]; directory = [string] } 'Final journal inventory'
        Assert-CapJournalBinding $manifest.journal.binding $State.Binding
        if ($manifest.journal.protocolVersion -ne 2 -or $manifest.status -cnotin @('COMPLETE','FAILED') -or
            $manifest.journal.directory -ine $State.Directory -or
            (ConvertTo-Json $manifest.journal.terminal -Compress) -cne (ConvertTo-Json $Record.terminal -Compress)) {
            throw (New-CapJournalFailure 'JournalFinalBinding' 'Terminal manifest binding differs.')
        }
        Assert-CapJournalTime $transaction $Record.terminal.sequence
        $names = Get-CapJournalNames $State -Final
        $published = @($manifest.journal.published)
        if (@($names.Keys | Where-Object { $_ -gt $Record.terminal.sequence }).Count -ne 0) {
            throw (New-CapJournalFailure 'PostTerminalPublication' 'Publication above exact terminal sequence.')
        }
        if ($published.Count -ne $Record.terminal.sequence -or $names.Count -ne $published.Count) {
            throw (New-CapJournalFailure 'SequenceGap' 'Final inventory has missing or extra publications.')
        }
        $previous = '0' * 64
        $terminal = $null
        for ($index = 0; $index -lt $published.Count; $index++) {
            $reference = $published[$index]
            Assert-CapJournalReference $reference -Numbered
            $number = [long]($index + 1)
            if ($reference.sequence -ne $number -or -not $names.ContainsKey($number)) {
                throw (New-CapJournalFailure 'SequenceGap' 'Final inventory is not exactly contiguous.')
            }
            $object = Read-CapJournalObject $State $number (New-CapJournalTransaction $State) -RetainStream
            $held.Add($object.Stream)
            if ($object.Reference.sha256 -cne $reference.sha256 -or $object.Reference.length -ne $reference.length -or
                $object.Payload.previousSha256 -cne $previous) {
                throw (New-CapJournalFailure 'JournalHash' "Final predecessor chain or bytes differ at $number.")
            }
            if (($number -eq 1 -and $object.Payload.kind -cne 'Bootstrap') -or
                ($number -gt 1 -and $object.Payload.kind -ceq 'Bootstrap')) {
                throw (New-CapJournalFailure 'JournalSchema' 'Bootstrap position differs.')
            }
            if ($number -lt $Record.terminal.sequence -and $object.Payload.kind -ceq 'Terminal') {
                throw (New-CapJournalFailure 'PostTerminalPublication' 'A publication follows an earlier Terminal.')
            }
            $previous = $object.Reference.sha256
            $terminal = $object
        }
        if ($null -eq $terminal -or $terminal.Payload.kind -cne 'Terminal' -or
            $terminal.Reference.sha256 -cne $Record.terminal.sha256 -or
            $terminal.Reference.length -ne $Record.terminal.length) {
            throw (New-CapJournalFailure 'JournalFinalBinding' 'Exact Terminal snapshot missing.')
        }
        $data = $terminal.Payload.data
        Assert-CapDataRecord $data @{ entries = [array]; ownedProcesses = [array]; outcome = [string]
            ownedProcessSurvivors = [array]; pendingLaunchesRemaining = [array]; cleanupFailures = [array] } 'Terminal cleanup'
        if ($data.outcome -cne $manifest.status -or
            (ConvertTo-Json $data.ownedProcesses -Depth 15 -Compress) -cne
                (ConvertTo-Json $manifest.ownedProcesses -Depth 15 -Compress) -or
            (ConvertTo-Json $data.ownedProcessSurvivors -Depth 12 -Compress) -cne
                (ConvertTo-Json $manifest.ownedProcessSurvivors -Depth 12 -Compress) -or
            (ConvertTo-Json $data.pendingLaunchesRemaining -Depth 12 -Compress) -cne
                (ConvertTo-Json $manifest.pendingLaunchesRemaining -Depth 12 -Compress) -or
            (ConvertTo-Json $data.cleanupFailures -Depth 12 -Compress) -cne
                (ConvertTo-Json $manifest.cleanupFailures -Depth 12 -Compress)) {
            throw (New-CapJournalFailure 'JournalFinalBinding' 'Manifest and terminal cleanup differ.')
        }
        $processKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $entryKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($process in $data.ownedProcesses) {
            Assert-CapDataRecord $process @{ pid = [long]; creationFileTimeUtc = [long]; expectedImagePath = [string]
                role = [string]; parentPid = [long]; sessionId = [long]; kernelExited = [bool]
                stdoutEof = [bool]; stderrEof = [bool]; streamOwnerPid = [long]
                streamOwnerCreationFileTimeUtc = [long] } 'Owned process receipt'
            $fileOutput = $process.PSObject.Properties['outputKind'] -and $process.outputKind -ceq 'OWNED_FILES_JOB'
            if (-not $process.kernelExited -or
                (-not $fileOutput -and (-not $process.stdoutEof -or -not $process.stderrEof)) -or
                ($fileOutput -and ($process.stdoutEof -or $process.stderrEof))) {
                throw (New-CapJournalFailure 'JournalCleanupUnproven' 'Kernel exit or owning-stream EOF is unproved.')
            }
            if ($process.pid -le 0 -or $process.creationFileTimeUtc -le 0 -or $process.parentPid -le 0 -or
                $process.sessionId -lt 0 -or $process.streamOwnerPid -le 0 -or
                $process.streamOwnerCreationFileTimeUtc -le 0 -or -not [IO.Path]::IsPathFullyQualified($process.expectedImagePath)) {
                throw (New-CapJournalFailure 'JournalIdentity' 'Invalid cleanup generation identity.')
            }
            if (-not $processKeys.Add("$($process.pid):$($process.creationFileTimeUtc):$($process.role)")) {
                throw (New-CapJournalFailure 'JournalCleanupUnproven' 'Duplicate owned process receipt.')
            }
            $owners = @($data.ownedProcesses | Where-Object {
                $_.pid -eq $process.streamOwnerPid -and
                $_.creationFileTimeUtc -eq $process.streamOwnerCreationFileTimeUtc -and
                $_.streamOwnerPid -eq $_.pid
            })
            if ($owners.Count -ne 1) {
                throw (New-CapJournalFailure 'JournalCleanupUnproven' 'Owning managed-root streams are unbound.')
            }
            if ($fileOutput) {
                $owner = $owners[0]
                Assert-CapDataRecord $process @{ jobId = [string] } 'Owned job member'
                Assert-CapDataRecord $owner @{ outputProof = [pscustomobject] } 'Owned job launcher'
                $outputProof = $owner.outputProof
                if ($outputProof.jobId -cne $process.jobId -or
                    $outputProof.launcherPid -ne $owner.pid -or
                    $outputProof.launcherCreationFileTimeUtc -ne $owner.creationFileTimeUtc) {
                    throw (New-CapJournalFailure 'JournalCleanupUnproven' 'Job output owner generation differs.')
                }
                foreach ($outputStream in @(Assert-CapJobOutputProof -Root $State.Root -Proof $outputProof -RetainStreams)) {
                    $held.Add($outputStream)
                }
            }
            if ($process.PSObject.Properties['outputProof']) {
                if ($process.outputProof.launcherPid -ne $process.pid -or
                    $process.outputProof.launcherCreationFileTimeUtc -ne $process.creationFileTimeUtc -or
                    $process.streamOwnerPid -ne $process.pid -or
                    $process.streamOwnerCreationFileTimeUtc -ne $process.creationFileTimeUtc) {
                    throw (New-CapJournalFailure 'JournalCleanupUnproven' 'Output proof is not bound to its raw-pipe launcher root.')
                }
                foreach ($outputStream in @(Assert-CapJobOutputProof -Root $State.Root -Proof $process.outputProof -RetainStreams)) {
                    $held.Add($outputStream)
                }
            }
        }
        foreach ($entry in $data.entries) {
            Assert-CapDataRecord $entry @{ pid = [long]; creationFileTimeUtc = [long]; role = [string]
                expectedImagePath = [string]; expectedParentPid = [long]; expectedSessionId = [long] } 'Registered generation'
            $matches = @($data.ownedProcesses | Where-Object {
                $_.pid -eq $entry.pid -and $_.creationFileTimeUtc -eq $entry.creationFileTimeUtc -and
                $_.role -ceq $entry.role -and $_.expectedImagePath -ieq $entry.expectedImagePath -and
                $_.parentPid -eq $entry.expectedParentPid -and $_.sessionId -eq $entry.expectedSessionId
            })
            if ($matches.Count -ne 1) { throw (New-CapJournalFailure 'JournalCleanupUnproven' 'Registered generation lacks exact cleanup receipt.') }
            $null = $entryKeys.Add("$($entry.pid):$($entry.creationFileTimeUtc):$($entry.role)")
        }
        if (-not $entryKeys.SetEquals($processKeys)) {
            throw (New-CapJournalFailure 'JournalCleanupUnproven' 'Owned and registered generation inventories differ.')
        }
        $namesAfter = Get-CapJournalNames $State -Final
        if ($namesAfter.Count -ne $names.Count -or
            @($namesAfter.Keys | Where-Object { -not $names.ContainsKey($_) }).Count -ne 0) {
            throw (New-CapJournalFailure 'PostTerminalPublication' 'Namespace changed after final inventory.')
        }
        if ([DateTime]::UtcNow -ge $State.DeadlineUtc) {
            throw (New-CapJournalFailure 'JournalUnavailable' 'Final inventory exceeded cleanup hard deadline.')
        }
        $result = [pscustomobject]@{
            Manifest = $manifest; Terminal = $terminal; Record = $Record; Inventory = $published
            HeldStreams = @(); HashChainVerified = $true
        }
        if ($RetainStreams) { $result.HeldStreams = @($held.ToArray()); $keepStreams = $true }
        return $result
    } finally { if (-not $keepStreams) { foreach ($item in $held) { $item.Dispose() } } }
}

function Read-CapNumberedSeedProof {
    [CmdletBinding()]
    param([string]$Root, [Parameter(Mandatory)]$Reference, [string]$JobSha256,
        [string]$ModuleSha256, [string]$WorkerSha256, [DateTime]$DeadlineUtc)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    if ($Reference -isnot [pscustomobject] -or -not $Reference.PSObject.Properties['protocolVersion'] -or
        $Reference.protocolVersion -ne 2) {
        throw (New-CapJournalFailure 'LegacyJournalProtocol' 'Exact numbered terminal proof is required.')
    }
    Assert-CapDataRecord $Reference @{ directory = [string]; outputDirectory = [string]
        binding = [pscustomobject]; record = [pscustomobject] } 'Numbered seed proof'
    if ($Reference.directory.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase) -or
        $Reference.binding.jobSha256 -cne $JobSha256 -or
        $Reference.binding.moduleSha256 -cne $ModuleSha256 -or
        $Reference.binding.workerSha256 -cne $WorkerSha256) {
        throw (New-CapJournalFailure 'JournalIdentity' 'Seed proof layout or exact source binding differs.')
    }
    $state = New-CapJournalState -Root $Root -Directory $Reference.directory `
        -Binding $Reference.binding -DeadlineUtc $DeadlineUtc
    $proof = Read-CapJournalFinalProof -State $state -OutputDirectory $Reference.outputDirectory -Record $Reference.record
    if ($proof.Manifest.status -cne 'COMPLETE' -or $proof.Terminal.Payload.data.ownedProcessSurvivors.Count -ne 0 -or
        $proof.Terminal.Payload.data.pendingLaunchesRemaining.Count -ne 0 -or
        $proof.Terminal.Payload.data.cleanupFailures.Count -ne 0) {
        throw (New-CapJournalFailure 'JournalCleanupUnproven' 'Seed proof is not a completed clean terminal.')
    }
    return $proof
}

function Open-CapJournalManifestStream {
    param($State, [string]$Path, $Transaction, [long]$Sequence)
    $native = $null
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        Assert-CapJournalTime $Transaction $Sequence $native
        if ($null -eq $Transaction.PreOpenElapsedMilliseconds) {
            $Transaction.PreOpenElapsedMilliseconds = $Transaction.Clock.Elapsed.TotalMilliseconds
        }
        try {
            return [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        } catch {
            $native = Get-CapJournalNativeError $_.Exception
            $terminalFailure = $native -notin @('80070002','80070003','80070020','80070021') -or
                $Transaction.Retries -ge 7 -or $attempt -ge 8
            Write-CapJournalObservation $State $Sequence $attempt 'FinalManifestOpenFailed' $native $Transaction `
                -TerminalFailure:$terminalFailure
            if ($native -notin @('80070002','80070003','80070020','80070021')) {
                throw (New-CapJournalFailure 'JournalOpenFailure' "Final manifest HRESULT=$native" $_.Exception)
            }
            if ($Transaction.Retries -ge 7) { break }
            $Transaction.Retries++
            Assert-CapJournalTime $Transaction $Sequence $native
            $remaining = [Math]::Min(($Transaction.DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds,
                $Transaction.BudgetMilliseconds - $Transaction.IoClock.Elapsed.TotalMilliseconds)
            if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Min(100, [Math]::Floor($remaining))) }
        }
    }
    throw (New-CapJournalFailure 'JournalUnavailable' "Final manifest sequence=$Sequence HRESULT=$native; retry limit.")
}

function Assert-CapNoWorkerTransientArtifacts {
    [CmdletBinding()]
    param([string[]]$Directories)
    Write-CapTrace -Command $MyInvocation.MyCommand.Name -Parameters $PSBoundParameters
    if ($Directories.Count -eq 0) { throw 'Worker artifact inventory requires explicit roots.' }
    $files = [Collections.Generic.List[string]]::new()
    $pending = [Collections.Generic.Stack[string]]::new()
    foreach ($directory in $Directories) { $pending.Push($directory) }
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        if ([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint) {
            throw (New-CapJournalFailure 'JournalNamespace' "Reparse-point inventory root: $directory")
        }
        foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $attributes = [IO.File]::GetAttributes($path)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw (New-CapJournalFailure 'JournalNamespace' "Reparse-point artifact preserved: $path")
            }
            if ($attributes -band [IO.FileAttributes]::Directory) { $pending.Push($path) }
            else {
                $files.Add($path)
                if ($path.EndsWith('.tmp', [StringComparison]::OrdinalIgnoreCase) -or
                    $path.EndsWith('.partial', [StringComparison]::OrdinalIgnoreCase) -or
                    $path.EndsWith('.partial.json', [StringComparison]::OrdinalIgnoreCase)) {
                    throw (New-CapJournalFailure 'ResidualJournalArtifact' "$path retained, never deleted.")
                }
            }
        }
    }
    if ($files.Count -eq 0) { throw 'Worker artifact inventory is empty; cannot prove an executed run.' }
    return @($files.ToArray())
}

Export-ModuleMember -Function @(
    'Get-CapMatchedSceneNames','Assert-CapMatchedFixture','Get-CapMatchedAutomationId',
    'Get-CapMatchedTabObservation','Assert-CapRestartEvidence','Initialize-CapMatchedProxy',
    'Read-CapRestartTranscript','Assert-CapMatchedManifest','Get-CapMatchedBackendSource',
    'Get-CapDSceneNames',
    'Assert-CapDFixture',
    'Get-CapDLayoutPath',
    'Test-CapDSessionCommand',
    'Get-CapDGeometry',
    'Get-CapDObservation',
    'Get-CapDPeerFrames',
    'Get-CapBPeerSource', 'Get-CapDPeerSource',
    'Start-CapJobLauncher',
    'Release-CapJobLauncher',
    'Wait-CapJobTarget',
    'Get-CapJobMembers',
    'Close-CapJobLauncher',
    'Assert-CapJobOutputProof',
    'New-CapJournalBinding',
    'New-CapJournalState',
    'Publish-CapJournalSnapshot',
    'Read-CapJournalSnapshot',
    'Write-CapImmutableJson',
    'Format-CapJournalFinalRecord',
    'Read-CapJournalFinalRecord',
    'Read-CapJournalFinalProof',
    'Read-CapNumberedSeedProof',
    'Assert-CapNoWorkerTransientArtifacts',
    'Set-CapTracePath',
    'Write-CapTrace',
    'Write-CapTerminalSelectorRefusal',
    'Wait-CapAutomationElement',
    'Get-CapTraceFailures',
    'Assert-CapArtifactPath',
    'Assert-CapZmxLeasePath',
    'Assert-CapFixtureMapping',
    'Read-CapBoundJson',
    'Assert-CapDataRecord',
    'Assert-CapJobIdentity',
    'Assert-CapSceneContract',
    'Assert-CapDescendantLifetime',
    'Test-CapGraphAppRootRole',
    'Resolve-CapAutomationCandidate',
    'Get-CapActionSpec',
    'Find-CapAutomationElement',
    'Get-CapDirectChildren',
    'Get-CapActionObservations',
    'Get-CapGraphActionObservations',
    'Assert-CapRootProcess',
    'Assert-CapUiaProcessIds',
    'Invoke-CapAction',
    'Measure-CapZoom',
    'Get-CapWindowMetrics',
    'Set-CapWindowPosition',
    'Find-CapTopLevelWindow',
    'Capture-CapWindow',
    'Get-CapProcessIdentity',
    'Read-CapProcessAccess',
    'Read-CapProcessMetadataState',
    'Resolve-CapAttestationDisposition',
    'Get-CapCurrentMetadata',
    'Assert-CapMetadataRecord',
    'Assert-CapProcessIdentity',
    'Stop-CapManagedProcess',
    'Wait-CapManagedProcess',
    'Test-CapManagedProcessRollback',
    'Start-CapManagedProcess',
    'Get-CapPendingLaunches',
    'Get-CapExcludedDescendants',
    'Resolve-CapPendingLaunches',
    'Get-CapOwnedDescendants',
    'Test-CapNativeBindings',
    'Get-CapRequiredNativeBindingNames',
    'Test-CapPipeUnserved',
    'Test-CapFixtureIsolation',
    'Get-CapLeaseWindow',
    'Get-CapAuthorizedWorkerDeadline'
)
