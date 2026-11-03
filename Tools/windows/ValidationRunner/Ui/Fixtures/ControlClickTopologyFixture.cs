using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace GraphCode.Validation.Ui.Fixtures;

internal sealed class ControlClickTopologyFixture : IDisposable
{
    internal const string HostTitle = "Owned control click fixture";
    private readonly Thread thread;
    private readonly ManualResetEventSlim ready = new(false);
    private Exception? startupFailure;
    private Form? window;
    private Form? unrelated;
    private Panel? content;
    private Panel? sibling;
    private Button? target;
    private readonly ManualResetEventSlim clicked = new(false);
    internal IntPtr Root { get; private set; }
    internal IntPtr Parent { get; private set; }
    internal IntPtr Target { get; private set; }
    internal IntPtr Sibling { get; private set; }
    internal IntPtr Unrelated { get; private set; }
    internal int[] Bounds { get; private set; } = Array.Empty<int>();
    internal int ClickCount;

    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] internal static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out NativePoint point);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [StructLayout(LayoutKind.Sequential)] private struct NativePoint { public int X, Y; }
    private NativePoint initialCursor;
    private bool cursorSaved;

    internal ControlClickTopologyFixture(bool nested)
    {
        thread = new Thread(() =>
        {
            try
            {
                window = new Form { Text = HostTitle, StartPosition = FormStartPosition.Manual,
                    Left = 120, Top = 120, Width = 480, Height = 360, ShowInTaskbar = false };
                unrelated = new Form { Text = "Unrelated owned root fixture", StartPosition = FormStartPosition.Manual,
                    Left = 650, Top = 120, Width = 160, Height = 120, ShowInTaskbar = false };
                content = new Panel { Left = 20, Top = 25, Width = 400, Height = 250 };
                sibling = new Panel { Left = 350, Top = 280, Width = 30, Height = 20 };
                target = new Button { Left = 40, Top = 45, Width = 160, Height = 60, Text = "Owned target" };
                if (nested)
                {
                    var viewport = new Panel { Dock = DockStyle.Fill };
                    window.Controls.Add(viewport);
                    viewport.Controls.Add(content);
                    content.Controls.Add(target);
                }
                else window.Controls.Add(target);
                window.Controls.Add(sibling);
                target.MouseDown += (_, _) => { Interlocked.Increment(ref ClickCount); clicked.Set(); };
                window.Shown += (_, _) =>
                {
                    Root = window.Handle;
                    Parent = target.Parent!.Handle;
                    Target = target.Handle;
                    Sibling = sibling.Handle;
                    Unrelated = unrelated.Handle;
                    var rectangle = target.RectangleToScreen(target.ClientRectangle);
                    Bounds = new[] { rectangle.Left, rectangle.Top, rectangle.Right, rectangle.Bottom };
                    ready.Set();
                };
                Application.Run(window);
            }
            catch (Exception failure) { startupFailure = failure; ready.Set(); }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        if (!ready.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException("Owned control fixture did not create its windows");
        if (startupFailure is not null) throw new InvalidOperationException("Owned control fixture startup failed", startupFailure);
        GraphCodeUiaGateState.RetainProcess(Process.GetCurrentProcess());
    }

    internal T Run<T>(Func<T> action) => (T)window!.Invoke(action);

    internal void Foreground()
    {
        Run(() => GraphCodeUiaGateState.ActivateWindow(Root));
        if (GetForegroundWindow() != Root)
            throw new InvalidOperationException($"Owned fixture could not acquire exact foreground; {GraphCodeUiaGateState.LastActivationDiagnostic}");
    }

    internal void BeginInput()
    {
        if (!GetCursorPos(out initialCursor)) throw new InvalidOperationException("Could not retain the fixture's original cursor position");
        cursorSaved = true;
    }

    internal void ExpectClick()
    {
        if (!clicked.Wait(TimeSpan.FromSeconds(3)) || Volatile.Read(ref ClickCount) != 1)
            throw new InvalidOperationException($"Owned fixture expected exactly one physical target click; actual={ClickCount}");
    }

    public void Dispose()
    {
        if (window is not null && !window.IsDisposed)
            window.Invoke(() => { unrelated?.Dispose(); window.Close(); });
        if (!thread.Join(TimeSpan.FromSeconds(10))) throw new TimeoutException("Owned control fixture UI thread did not exit");
        if (cursorSaved && !SetCursorPos(initialCursor.X, initialCursor.Y))
            throw new InvalidOperationException("Could not restore the fixture's original cursor position");
        clicked.Dispose();
        ready.Dispose();
    }
}
