using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace GraphCode.Validation.Ownership;

public sealed record OwnedCleanupProof(bool RootExited, bool JobEmpty, bool StdoutEof, bool StderrEof, bool ResourcesClosed)
{
    public bool CanRelease => RootExited && JobEmpty && StdoutEof && StderrEof;
}
public sealed record OwnedChildResult(int ExitCode, string StandardOutput, string StandardError, OwnedCleanupProof Cleanup);
public sealed record OwnedChildObservation(bool RootExited, uint ActiveJobProcesses, bool StdoutCompleted, bool StderrCompleted);

public sealed class OwnedChildSupervisor
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Security { public int Length; public IntPtr Descriptor; public int Inherit; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Startup
    {
        public int Size;
        public string? Reserved, Desktop, Title;
        public int X, Y, Width, Height, XChars, YChars, Fill, Flags;
        public short Show, ReservedSize;
        public IntPtr ReservedBytes, Input, Output, Error, Attributes;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInfo { public IntPtr Process, Thread; public uint Pid, Tid; }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CreatePipe(out IntPtr read, out IntPtr write, ref Security security, int size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateFileW(string name, uint access, uint share, ref Security security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessW(string file, StringBuilder command, IntPtr processSecurity, IntPtr threadSecurity,
        bool inherit, uint flags, IntPtr environment, string? directory, ref Startup startup, out ProcessInfo process);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint timeout);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessTimes(IntPtr process, out long created, out long exited, out long kernel, out long user);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetProcessId(IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    // Unknown leases stay reachable: a finalizer must not close a kill-on-close job.
    private static readonly ConcurrentBag<OwnedChildSupervisor> retained = new();
    private static readonly Task lifetimeHold = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously).Task;
    private readonly Deadline deadline;
    private readonly string artifactRoot;
    private readonly object retentionGate = new();
    private readonly CancellationTokenSource retentionCancellation = new();
    private bool descendantUnknown, retentionRegistered;
    private IntPtr root, thread, job;
    private bool assigned, resumed, completed;
    private StreamReader? stdoutReader, stderrReader;
    private Task<string>? stdout, stderr;
    private long creationFileTime;
    public uint ProcessId { get; private set; }
    public long CreationFileTime => creationFileTime;
    public Task<string> StandardOutput => stdout ?? throw new InvalidOperationException("stdout capture unavailable.");
    public Task<string> StandardError => stderr ?? throw new InvalidOperationException("stderr capture unavailable.");
    public static int RetainedLeaseCount => retained.Count;
    public static bool RequiresLifetimeHold => RetainedLeaseCount != 0;

    // The host must await this in its outermost finally, including reporting failures.
    // Returning from Main would close kill-on-close jobs despite the retained references.
    public static Task HoldRetainedResourcesAsync() => RequiresLifetimeHold ? lifetimeHold : Task.CompletedTask;

    private void ObserveDescendantUnknown()
    {
        lock (retentionGate)
        {
            if (descendantUnknown) return;
            descendantUnknown = true;
            RegisterRetention();
            retentionCancellation.Cancel();
        }
    }

    private void RegisterRetention()
    {
        lock (retentionGate)
        {
            if (retentionRegistered) return;
            retained.Add(this);
            retentionRegistered = true;
        }
    }

    public OwnedChildObservation Observe() => new(RootExited(), StandaloneProcessJob.Active(job),
        StandardOutput.IsCompleted, StandardError.IsCompleted);

    private OwnedChildSupervisor(TimeSpan timeout, string artifactRoot)
    {
        deadline = new Deadline(timeout);
        this.artifactRoot = Path.GetFullPath(artifactRoot);
        if (!Directory.Exists(this.artifactRoot)) throw new DirectoryNotFoundException(this.artifactRoot);
    }

    public static OwnedChildSupervisor Start(ProcessStartInfo start, TimeSpan timeout, string artifactRoot)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Owned native jobs require Windows.");
        if (start.UseShellExecute || !string.IsNullOrEmpty(start.Arguments) || start.RedirectStandardInput)
            throw new ArgumentException("Owned launch requires ArgumentList, UseShellExecute=false and closed stdin.", nameof(start));
        if (!Path.IsPathFullyQualified(start.FileName) || !File.Exists(start.FileName))
            throw new ArgumentException("Owned executable must be an existing absolute path.", nameof(start));
        var run = new OwnedChildSupervisor(timeout, artifactRoot);
        try
        {
            run.Launch(start);
            return run;
        }
        catch (Exception primary)
        {
            // Synchronous launch has no consumer yet, but uses the same bounded cleanup.
            run.CleanupAsync(primary).GetAwaiter().GetResult();
            throw;
        }
    }

    public static async Task<OwnedChildResult> RunAsync(ProcessStartInfo start, TimeSpan timeout, string artifactRoot,
        CancellationToken cancellationToken = default)
    {
        var child = Start(start, timeout, artifactRoot);
        return await child.CompleteAsync(cancellationToken).ConfigureAwait(false);
    }

    private void Launch(ProcessStartInfo info)
    {
        var security = new Security { Length = Marshal.SizeOf<Security>(), Inherit = 1 };
        IntPtr outRead = IntPtr.Zero, outWrite = IntPtr.Zero, errRead = IntPtr.Zero, errWrite = IntPtr.Zero;
        IntPtr input = IntPtr.Zero, attributes = IntPtr.Zero, handles = IntPtr.Zero, environment = IntPtr.Zero;
        bool initialized = false;
        Exception? primary = null;
        try
        {
            job = StandaloneProcessJob.Create();
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
            // Even an empty environment requires two terminators.
            if (block.Length == 0) block.Append('\0');
            block.Append('\0');
            environment = Marshal.StringToHGlobalUni(block.ToString());
            var command = new StringBuilder(QuoteArgument(info.FileName));
            foreach (string argument in info.ArgumentList) command.Append(' ').Append(QuoteArgument(argument));
            var startup = new Startup
            {
                Size = Marshal.SizeOf<Startup>(), Flags = 0x101, Input = input, Output = outWrite, Error = errWrite,
                Show = (short)(info.WindowStyle == ProcessWindowStyle.Hidden ? 0 :
                    info.WindowStyle == ProcessWindowStyle.Minimized ? 2 : info.WindowStyle == ProcessWindowStyle.Maximized ? 3 : 1),
                Attributes = attributes
            };
            uint flags = 0x4 | 0x400 | 0x80000;
            if (info.CreateNoWindow) flags |= 0x08000000;
            if (!CreateProcessW(info.FileName, command, IntPtr.Zero, IntPtr.Zero, true, flags, environment,
                string.IsNullOrEmpty(info.WorkingDirectory) ? null : info.WorkingDirectory, ref startup, out ProcessInfo created))
                throw new Win32Exception();
            root = created.Process;
            thread = created.Thread;
            ProcessId = created.Pid;
            if (!GetProcessTimes(root, out creationFileTime, out _, out _, out _)) throw new Win32Exception();
            VerifyRoot();
            StandaloneProcessJob.Assign(job, root);
            assigned = true;
            UiaOwnedStreamCapture.RequireJobMember(root, job);
            stdoutReader = MakeReader(ref outRead, info.StandardOutputEncoding);
            stderrReader = MakeReader(ref errRead, info.StandardErrorEncoding);
            string stem = $"owned-{ProcessId}-{creationFileTime}";
            stdout = UiaOwnedStreamCapture.Read(stdoutReader, Path.Combine(artifactRoot, stem + "-stdout.log"),
                new RetentionSignalObserver(ObserveDescendantUnknown));
            stderr = UiaOwnedStreamCapture.Read(stderrReader, Path.Combine(artifactRoot, stem + "-stderr.log"),
                new RetentionSignalObserver(ObserveDescendantUnknown));
            if (deadline.Expired) throw new TimeoutException("Owned launch original deadline exceeded before resume.");
            uint previous = ResumeThread(thread);
            if (previous == uint.MaxValue) throw new Win32Exception();
            if (previous != 1) throw new InvalidOperationException("Owned launch suspension count changed.");
            resumed = true;
            Close(ref thread);
        }
        catch (Exception failure)
        {
            primary = failure;
            throw;
        }
        finally
        {
            var failures = new List<Exception>();
            foreach (IntPtr handle in new[] { outRead, outWrite, errRead, errWrite, input })
                if (handle != IntPtr.Zero && handle != new IntPtr(-1) && !CloseHandle(handle))
                    failures.Add(new Win32Exception());
            if (initialized) DeleteProcThreadAttributeList(attributes);
            foreach (IntPtr allocation in new[] { attributes, handles, environment })
                if (allocation != IntPtr.Zero) Marshal.FreeHGlobal(allocation);
            if (failures.Count != 0)
            {
                var cleanup = new AggregateException("Owned launch temporary handle cleanup failed.", failures);
                if (primary != null) primary.Data["OwnedLaunchTemporaryCleanup"] = cleanup;
                else throw cleanup;
            }
        }
    }

    private static StreamReader MakeReader(ref IntPtr handle, Encoding? encoding)
    {
        var safe = new SafeFileHandle(handle, true);
        handle = IntPtr.Zero;
        try { return new StreamReader(new FileStream(safe, FileAccess.Read), encoding ?? new UTF8Encoding(false, true), true); }
        catch { safe.Dispose(); throw; }
    }

    public static string QuoteArgument(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (value.Contains('\0')) throw new ArgumentException("Command argument contains NUL.", nameof(value));
        var result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in value)
        {
            if (c == '\\') { slashes++; continue; }
            result.Append('\\', c == '"' ? slashes * 2 + 1 : slashes).Append(c);
            slashes = 0;
        }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }

    private void VerifyRoot()
    {
        if (root == IntPtr.Zero || GetProcessId(root) != ProcessId ||
            !GetProcessTimes(root, out long observed, out _, out _, out _) || observed != creationFileTime)
            throw new InvalidOperationException("Held root identity could not be verified.");
    }

    private bool RootExited()
    {
        VerifyRoot();
        uint state = WaitForSingleObject(root, 0);
        if (state == 0) return true;
        if (state == 258) return false;
        throw new Win32Exception();
    }

    public async Task<OwnedChildResult> CompleteAsync(CancellationToken cancellationToken = default)
    {
        if (completed) throw new InvalidOperationException("Owned child completion already consumed.");
        completed = true;
        Exception? primary = null;
        int exitCode = -1;
        string output = "", error = "";
        using var waiting = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, retentionCancellation.Token);
        try
        {
            while (!RootExited())
            {
                waiting.Token.ThrowIfCancellationRequested();
                if (deadline.Expired) throw new TimeoutException("OWNED_CAPTURE_EXIT: original deadline exceeded.");
                await Task.Delay(Math.Min(10, deadline.RemainingMilliseconds), waiting.Token).ConfigureAwait(false);
            }
            await RequireDrainAsync([StandardOutput, StandardError], deadline, waiting.Token).ConfigureAwait(false);
            waiting.Token.ThrowIfCancellationRequested();
            if (!GetExitCodeProcess(root, out uint code)) throw new Win32Exception();
            exitCode = unchecked((int)code);
            output = await StandardOutput.ConfigureAwait(false);
            error = await StandardError.ConfigureAwait(false);
        }
        catch (Exception failure) { primary = failure; }
        OwnedCleanupProof proof = await CleanupAsync(primary).ConfigureAwait(false);
        if (primary != null) ExceptionDispatchInfo.Capture(primary).Throw();
        return new OwnedChildResult(exitCode, output, error, proof);
    }

    public Task<OwnedCleanupProof> StopAsync(Exception? primary = null)
    {
        if (completed) throw new InvalidOperationException("Owned child completion already consumed.");
        completed = true;
        return CleanupAsync(primary);
    }

    public static async Task RequireDrainAsync(IReadOnlyList<Task<string>> streams, Deadline limit,
        CancellationToken cancellationToken = default)
    {
        var failures = new List<Exception>();
        foreach (Task<string> stream in streams)
        {
            try
            {
                await stream.WaitAsync(limit.Remaining, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception failure) { failures.Add(failure); }
        }
        if (failures.Count != 0)
            throw new AggregateException("OWNED_CAPTURE_DRAIN: independent readers did not all reach successful EOF.", failures);
    }

    private Task<OwnedCleanupProof> CleanupAsync(Exception? primary) =>
        OwnedCleanupCoordinator.CompleteAsync(new NativeCleanupAuthority(this), primary, TimeSpan.FromSeconds(5));

    private sealed class NativeCleanupAuthority(OwnedChildSupervisor owner) : IOwnedCleanupAuthority
    {
        public string Identity => $"pid={owner.ProcessId}; creation={owner.creationFileTime}; job={owner.job}";
        public bool OwnershipUnproven { get { lock (owner.retentionGate) return owner.descendantUnknown; } }
        public Task<string>? StandardOutput => owner.stdout;
        public Task<string>? StandardError => owner.stderr;
        public IReadOnlyList<Action> CloseActions =>
        [
            () => CloseOwned(() => owner.stdoutReader?.Dispose()), () => CloseOwned(() => owner.stderrReader?.Dispose()),
            () => CloseOwned(() => Close(ref owner.thread)),
            () => CloseOwned(() => { if (owner.job != IntPtr.Zero) { StandaloneProcessJob.Close(owner.job); owner.job = IntPtr.Zero; } }),
            () => CloseOwned(() => Close(ref owner.root)), () => CloseOwned(owner.retentionCancellation.Dispose)
        ];

        public void Terminate()
        {
            lock (owner.retentionGate)
            {
                if (owner.descendantUnknown) throw new InvalidOperationException("UNKNOWN descendant ownership; termination withheld.");
                if (owner.assigned) StandaloneProcessJob.Terminate(owner.job);
                else if (owner.root != IntPtr.Zero)
                {
                    if (owner.resumed) throw new InvalidOperationException("Unassigned root was unexpectedly resumed.");
                    if (WaitForSingleObject(owner.root, 0) != 0 && !TerminateProcess(owner.root, 124))
                        throw new Win32Exception();
                }
            }
        }

        private void CloseOwned(Action action)
        {
            lock (owner.retentionGate)
            {
                if (owner.descendantUnknown) throw new InvalidOperationException("UNKNOWN descendant ownership; close withheld.");
                action();
            }
        }

        public async Task<bool> WaitForJobEmptyAsync(Deadline deadline)
        {
            if (owner.job == IntPtr.Zero) return true;
            while (StandaloneProcessJob.Active(owner.job) != 0)
            {
                if (OwnershipUnproven) throw new InvalidOperationException("UNKNOWN descendant ownership; job wait withheld.");
                if (deadline.Expired) throw new TimeoutException("Owned job still has active processes.");
                await Task.Delay(Math.Min(10, deadline.RemainingMilliseconds)).ConfigureAwait(false);
            }
            return true;
        }

        public async Task<bool> WaitForRootExitAsync(Deadline deadline)
        {
            while (owner.root != IntPtr.Zero && !owner.RootExited())
            {
                if (OwnershipUnproven) throw new InvalidOperationException("UNKNOWN descendant ownership; root wait withheld.");
                if (deadline.Expired) throw new TimeoutException("Held root exit unproved.");
                await Task.Delay(Math.Min(10, deadline.RemainingMilliseconds)).ConfigureAwait(false);
            }
            return true;
        }

        public void Retain(Exception failure)
        {
            owner.RegisterRetention();
            OwnershipRetention.Tag(failure, owner.artifactRoot);
            failure.Data["OwnedRetainedLease"] = owner;
        }
    }

    private static void Close(ref IntPtr handle)
    {
        if (handle == IntPtr.Zero) return;
        if (!CloseHandle(handle)) throw new Win32Exception();
        handle = IntPtr.Zero;
    }
}
