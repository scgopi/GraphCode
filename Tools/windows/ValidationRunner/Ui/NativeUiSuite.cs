using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using GraphCode.Validation.Ui.Fixtures;

namespace GraphCode.Validation.Ui;

public sealed class EditBufferSuite : IValidationSuite
{
    public string Id => "ui.edit-buffer-cross-process";
    public IReadOnlyList<string> UnitIds => [Id];

    public async Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken)
    {
        string root = System.IO.Path.Combine(context.ArtifactRoot, "edit-buffer-" + Guid.NewGuid().ToString("N"));
        System.IO.Directory.CreateDirectory(root);
        string host = Environment.ProcessPath ?? throw new InvalidOperationException("Current executable unavailable.");
        var start = new ProcessStartInfo(host)
        {
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = root,
            RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = new System.Text.UTF8Encoding(false, true),
            StandardErrorEncoding = new System.Text.UTF8Encoding(false, true)
        };
        if (System.IO.Path.GetFileNameWithoutExtension(host).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
            start.ArgumentList.Add(System.Reflection.Assembly.GetEntryAssembly()!.Location);
        start.ArgumentList.Add("--edit-buffer-fixture");
        start.ArgumentList.Add(root);
        start.Environment["TEMP"] = root;
        start.Environment["TMP"] = root;
        var run = Ownership.OwnedChildSupervisor.Start(start, TimeSpan.FromSeconds(20), root);
        var completion = run.CompleteAsync(cancellationToken);
        IntPtr window = IntPtr.Zero;
        Exception? primary = null;
        Ownership.OwnedChildResult? result = null;
        int executed = 0;
        try
        {
            var readyClock = Stopwatch.StartNew();
            while (!System.IO.File.Exists(System.IO.Path.Combine(root, "published")))
            {
                if (completion.IsCompleted || readyClock.ElapsedMilliseconds >= 5000)
                    throw new TimeoutException("Owned edit fixture did not publish readiness within five seconds.");
                await Task.Delay(10, cancellationToken).ConfigureAwait(false);
            }
            using var ready = System.Text.Json.JsonDocument.Parse(
                System.IO.File.ReadAllText(System.IO.Path.Combine(root, "ready.json")));
            window = new IntPtr(ready.RootElement.GetProperty("window").GetInt64());
            ActivationCases.Require(ready.RootElement.GetProperty("pid").GetUInt32() == run.ProcessId &&
                run.ProcessId != Environment.ProcessId && !run.Observe().RootExited &&
                GraphCodeUiaGateState.WindowProcessId(window) == run.ProcessId &&
                GraphCodeUiaGateState.WindowClass(window) == "GraphCodeEditBufferFixture" &&
                !GraphCodeUiaGateState.WindowIsVisible(window),
                "Edit regression requires the hidden window of the original owned foreign process.");
            executed++;
            ActivationCases.Require(PromptLookupFixture.SetCaptionForRegression(
                GraphCodeUiaGateState.ControlById(window, 9904), "caption decoy") &&
                GraphCodeUiaGateState.EditTextById(window, 9904) == "UIA loop B",
                "Caption-only negative control unexpectedly changed the foreign EDIT buffer.");
            executed++;
            ActivationCases.Require(GraphCodeUiaGateState.SetFirstEditText(window, "UIA loop A") &&
                GraphCodeUiaGateState.EditTextById(window, 9904) == "UIA loop A",
                "SetFirstEditText did not replace the foreign EDIT buffer with query A.");
            executed++;
        }
        catch (Exception failure) { primary = failure; }
        finally
        {
            try
            {
                if (window != IntPtr.Zero && !run.Observe().RootExited &&
                    GraphCodeUiaGateState.WindowProcessId(window) == run.ProcessId &&
                    !GraphCodeUiaGateState.PostClose(window))
                    throw new InvalidOperationException("Owned edit fixture close message failed.");
            }
            catch (Exception failure)
            {
                if (primary is null) primary = failure;
                else primary.Data["EditFixtureCloseFailure"] = failure;
            }
            try { result = await completion.ConfigureAwait(false); }
            catch (Exception failure)
            {
                if (primary is null) primary = failure;
                else primary.Data["EditFixtureCompletionFailure"] = failure;
            }
            try
            {
                using var proofFile = new System.IO.FileStream(System.IO.Path.Combine(root, "proof.json"),
                    System.IO.FileMode.CreateNew, System.IO.FileAccess.Write, System.IO.FileShare.Read);
                System.Text.Json.JsonSerializer.Serialize(proofFile, new {
                    parentChecksBeforeChildReport = executed, pid = run.ProcessId, creationFileTime = run.CreationFileTime,
                    exitCode = result?.ExitCode, cleanup = result?.Cleanup,
                    retainedLeases = Ownership.OwnedChildSupervisor.RetainedLeaseCount,
                    failure = primary?.ToString()
                });
            }
            catch (Exception failure)
            {
                if (primary is null) primary = failure;
                else primary.Data["EditFixtureProofFailure"] = failure;
            }
        }
        if (primary is not null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(primary).Throw();
        if (result is null || result.ExitCode != 0 || !result.Cleanup.ResourcesClosed ||
            !result.Cleanup.CanRelease || !string.IsNullOrWhiteSpace(result.StandardError))
            throw new InvalidOperationException("Owned edit fixture failed exit/cleanup: " + result?.StandardError);
        const string prefix = "EDIT_BUFFER_CHILD=";
        string[] reports = System.Linq.Enumerable.ToArray(System.Linq.Enumerable.Where(
            result.StandardOutput.Split('\n', StringSplitOptions.RemoveEmptyEntries),
            line => line.StartsWith(prefix, StringComparison.Ordinal)));
        ActivationCases.Require(reports.Length == 1, "Expected exactly one child buffer report.");
        using var report = System.Text.Json.JsonDocument.Parse(reports[0][prefix.Length..]);
        ActivationCases.Require(report.RootElement.GetProperty("pid").GetUInt32() == run.ProcessId &&
            report.RootElement.GetProperty("buffer").GetString() == "UIA loop A" &&
            report.RootElement.GetProperty("observed").GetString() == "UIA loop A" &&
            report.RootElement.GetProperty("changes").GetInt32() > 0,
            "Foreign message pump did not observe query A through EN_CHANGE.");
        executed++;
        Console.WriteLine("EDIT_BUFFER_REGRESSION=" + System.Text.Json.JsonSerializer.Serialize(new {
            executed, cleanup = result.Cleanup, retainedLeases = Ownership.OwnedChildSupervisor.RetainedLeaseCount
        }));
        return [new UnitResult(Id, UnitStatus.Passed, executed,
            "Real hidden cross-process EDIT buffer, caption-only negative control and child EN_CHANGE; no input/focus/UIA")];
    }
}

public sealed class NativeUiSuite : IValidationSuite
{
    public string Id => "ui.native";
    public IReadOnlyList<string> UnitIds { get; } = new[]
    {
        "ui.native.lookup.named-direct-viewport", "ui.native.lookup.hidden-write-read",
        "ui.native.lookup.missing-id", "ui.native.lookup.missing-write-read",
        "ui.native.lookup.direct-precedence", "ui.native.lookup.wrong-root",
        "ui.native.lookup.wrong-viewport", "ui.native.lookup.other-sibling",
        "ui.native.lookup.no-deeper-fallback", "ui.native.lookup.direct-viewport-required",
        "ui.native.lookup.native-form", "ui.native.lookup.workspace-manager",
        "ui.native.lookup.unknown-content", "ui.native.lookup.null-parent",
        "ui.native.hit.nested-edit", "ui.native.hit.content-background",
        "ui.native.hit.wrong-root", "ui.native.hit.wrong-container",
        "ui.native.hit.no-recursion", "ui.native.hit.direct-child",
        "ui.host-info.current-session",
        "ui.native.dpi.physical-coordinates", "ui.native.dpi.exact-restore",
        "ui.native.dpi.invalid-restore", "ui.native.dpi.failed-set",
        "ui.native.dpi.foreign-thread", "ui.native.dpi.source-boundary",
        "ui.native.dpi.primary-error-preserved"
    };

    public static int RunPopupEffects()
    {
        ControlClickTopologyFixture? fixture = null;
        GraphCodeUiaGateState.ThreadDpiContext? dpi = null;
        Exception? primary = null;
        var cleanup = new List<Exception>();
        int effects = 0;
        var json = new System.Text.Json.JsonSerializerOptions { IncludeFields = true };
        void Write(string label, object value) =>
            Console.WriteLine(label + "=" + System.Text.Json.JsonSerializer.Serialize(value, json));
        void Wait(Func<bool> condition, Stopwatch clock, int budget, string label)
        {
            while (!condition())
            {
                if (clock.ElapsedMilliseconds >= budget) throw new TimeoutException(label);
                Thread.Sleep(50);
            }
        }
        try
        {
            dpi = GraphCodeUiaGateState.EnterPhysicalDpiCoordinates();
            fixture = new ControlClickTopologyFixture(false, nativePopup: true);
            var host = fixture.PopupWindow ?? throw new InvalidOperationException("Native popup window missing");
            IntPtr root = fixture.Root;
            uint pid = checked((uint)Environment.ProcessId);
            Write("NATIVE_POPUP_AWAIT", new { pid, root = root.ToInt64(), title = NativePopupEffectWindow.HostTitle,
                admissionMilliseconds = 60000, sameProcessFixture = true });
            var admission = Stopwatch.StartNew();
            string? lastAdmissionState = null;
            Wait(() =>
            {
                bool foreground = GraphCodeUiaGateState.IsForegroundWindow(root);
                uint actualPid = GraphCodeUiaGateState.WindowProcessId(root);
                bool visible = GraphCodeUiaGateState.WindowIsVisible(root);
                bool enabled = GraphCodeUiaGateState.WindowIsEnabled(root);
                string state = System.Text.Json.JsonSerializer.Serialize(new { foreground, actualPid, visible, enabled });
                if (state != lastAdmissionState)
                {
                    Write("NATIVE_POPUP_ADMISSION_STATE", new { pid, root = root.ToInt64(), foreground,
                        actualPid, visible, enabled, elapsed = admission.ElapsedMilliseconds });
                    lastAdmissionState = state;
                }
                return foreground && actualPid == pid && visible && enabled;
            },
                admission, 60000, "Owned native popup fixture foreground/health was not admitted");
            Write("NATIVE_POPUP_ADMITTED", new { pid, root = root.ToInt64(), elapsed = admission.ElapsedMilliseconds });
            fixture.BeginInput();
            foreach (string name in new[] { "first-open", "repeat-open", "cancel-reopen" })
            {
                var clock = Stopwatch.StartNew();
                IntPtr Open()
                {
                    if (host.MenuHandle != IntPtr.Zero || host.Completed != host.Opens)
                        throw new InvalidOperationException("Previous owned native popup has not completed");
                    int sequence = host.Opens + 1;
                    int[] b = fixture.Bounds;
                    int[] input = GraphCodeUiaGateState.ClickOwnedScreenRectangle(root, b[0], b[1], b[2], b[3], true);
                    ActivationCases.Require(input.Length == 8 && input[6] == 2 && input[7] == 2,
                        "Owned native popup opening did not inject exactly two right-button events");
                    IntPtr popup = IntPtr.Zero;
                    Wait(() =>
                    {
                        if (host.Failure is not null) throw host.Failure;
                        IntPtr menu = host.MenuHandle;
                        popup = menu == IntPtr.Zero ? IntPtr.Zero : GraphCodeUiaGateState.FindPopupForMenu(pid, menu);
                        return popup != IntPtr.Zero && host.Opens == sequence;
                    }, clock, 5000, "Owned native popup did not appear within original case budget");
                    Write("NATIVE_POPUP_ENTRY", new { name, sequence, pid, owner = root.ToInt64(),
                        popup = popup.ToInt64(), menu = host.MenuHandle.ToInt64(), popupBounds = GraphCodeUiaGateState.WindowBounds(popup),
                        rawState = GraphCodeUiaGateState.PopupMenuItemState(host.MenuHandle, 2),
                        callerThread = PromptLookupFixture.GetCurrentThreadId(),
                        menuDpi = PromptLookupFixture.GetDpiForWindow(popup), elapsed = clock.ElapsedMilliseconds });
                    return popup;
                }
                void Complete(int sequence)
                {
                    Wait(() => host.Completed == sequence,
                        clock, 5000, "Native TrackPopupMenu return/effect did not complete within original case budget");
                    if (host.Failure is not null) throw host.Failure;
                }
                int callbacks = host.Callbacks;
                if (name == "cancel-reopen")
                {
                    _ = Open();
                    int sequence = host.Opens;
                    GraphCodeUiaGateState.CancelPopupMenu(root);
                    Complete(sequence);
                    ActivationCases.Require(host.SelectedCommand == 0 && host.Callbacks == callbacks,
                        "Explicit native cancellation selected a command or emitted a callback");
                    Write("NATIVE_POPUP_CANCEL", new { name, sequence, selectedCommand = host.SelectedCommand,
                        callbacks = host.Callbacks, elapsed = clock.ElapsedMilliseconds });
                }
                IntPtr targetPopup = Open();
                int targetSequence = host.Opens;
                Write("NATIVE_POPUP_STRICT_BEGIN", new { name, targetSequence, elapsed = clock.ElapsedMilliseconds });
                var hit = GraphCodeUiaGateState.ClickPopupMenuItemStrict(targetPopup, root, 2,
                    checked((int)NativePopupEffectWindow.ExpectedCommand), pid);
                Write("NATIVE_POPUP_STRICT_RETURN", new { name, hit, elapsed = clock.ElapsedMilliseconds });
                Complete(targetSequence);
                ActivationCases.Require(host.SelectedCommand == NativePopupEffectWindow.ExpectedCommand &&
                    host.Callbacks == callbacks + 1 && hit.ItemId == NativePopupEffectWindow.ExpectedCommand &&
                    !hit.UsedKeyboardFallback && !hit.UsedSelectItemFallback,
                    "Strict popup receipt did not produce the actual TrackPopupMenu command/callback");
                effects++;
                Write("NATIVE_POPUP_EFFECT", new { name, selectedCommand = host.SelectedCommand,
                    callbacks = host.Callbacks, effects, elapsed = clock.ElapsedMilliseconds, sameProcessFixture = true });
            }
        }
        catch (Exception failure)
        {
            primary = failure;
            var data = new Dictionary<string, object?>();
            foreach (System.Collections.DictionaryEntry entry in failure.Data)
                data.Add((string)entry.Key, entry.Value);
            Write("NATIVE_POPUP_FIRST_FAILURE", new { error = failure.ToString(), data, effects });
        }
        finally
        {
            if (fixture is not null)
            {
                try
                {
                    if (fixture.PopupWindow is { MenuHandle: var menu } && menu != IntPtr.Zero)
                        GraphCodeUiaGateState.CancelPopupMenu(fixture.Root);
                    fixture.Dispose();
                }
                catch (Exception failure) { cleanup.Add(failure); }
            }
            if (dpi is not null)
            {
                try { GraphCodeUiaGateState.RestorePhysicalDpiCoordinates(dpi.Value); }
                catch (Exception failure) { cleanup.Add(failure); }
            }
        }
        Write("NATIVE_POPUP_TERMINAL", new { effects, requestedCases = 3, failed = primary is not null,
            cleanupFailures = cleanup.ConvertAll(error => error.ToString()), sameProcessFixture = true,
            crossProcessAppCallbackProven = false });
        return primary is null && cleanup.Count == 0 && effects == 3 ? 0 : 1;
    }

    public Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken)
    {
        var results = new List<UnitResult>();
        var roots = new List<IntPtr>();
        Exception? primary = null;
        try
        {
            foreach (string name in new[] { "GraphCodeSheetHost", "GraphCodeSheetViewport",
                "GraphCodeWindowsDialogContent", "GraphCodeNativeForm", "GraphCodeWorkspaceManager",
                "GraphCodeUnknownSheetContent" })
                PromptLookupFixture.Register(name);

            IntPtr NewRoot(string cls)
            {
                IntPtr window = PromptLookupFixture.Create(cls, IntPtr.Zero, 0);
                roots.Add(window);
                return window;
            }
            void Check(string id, Action assertion, string evidence =
                "Actual compiled helper and hidden owned Win32 fixture")
            {
                cancellationToken.ThrowIfCancellationRequested();
                try
                {
                    assertion();
                    results.Add(new UnitResult(id, UnitStatus.Passed, 1,
                        evidence));
                }
                catch (InvalidOperationException failure)
                {
                    results.Add(new UnitResult(id, UnitStatus.Failed, 1, failure.ToString()));
                }
            }
            void Lookup(string id, IntPtr parent, int controlId, IntPtr expected) =>
                Check(id, () => ActivationCases.Require(GraphCodeUiaGateState.ControlById(parent, controlId) == expected,
                    $"RED: prompt lookup {id} differs"));
            IntPtr Create(string cls, IntPtr parent, int id = 0) => PromptLookupFixture.Create(cls, parent, id);

            IntPtr prompt = NewRoot("GraphCodeSheetHost");
            IntPtr viewport = Create("GraphCodeSheetViewport", prompt);
            IntPtr content = Create("GraphCodeWindowsDialogContent", viewport);
            IntPtr edit = Create("EDIT", content, 9904);
            Lookup("ui.native.lookup.named-direct-viewport", prompt, 9904, edit);
            Check("ui.native.lookup.hidden-write-read", () => ActivationCases.Require(
                !PromptLookupFixture.IsWindowVisible(prompt) &&
                GraphCodeUiaGateState.SetEditTextById(prompt, 9904, "owned fixture") &&
                GraphCodeUiaGateState.EditTextById(prompt, 9904) == "owned fixture",
                "RED: prompt lookup hidden nested write/read did not use the same control"));
            Lookup("ui.native.lookup.missing-id", prompt, 9905, IntPtr.Zero);
            Check("ui.native.lookup.missing-write-read", () => ActivationCases.Require(
                !GraphCodeUiaGateState.SetEditTextById(prompt, 9905, "wrong") &&
                GraphCodeUiaGateState.EditTextById(prompt, 9905) is null,
                "RED: prompt lookup missing id returned successful text"));
            IntPtr direct = Create("EDIT", prompt, 9904);
            Lookup("ui.native.lookup.direct-precedence", prompt, 9904, direct);

            IntPtr wrongRoot = NewRoot("STATIC");
            IntPtr wrongRootViewport = Create("GraphCodeSheetViewport", wrongRoot);
            IntPtr wrongRootContent = Create("GraphCodeWindowsDialogContent", wrongRootViewport);
            Create("EDIT", wrongRootContent, 9904);
            Lookup("ui.native.lookup.wrong-root", wrongRoot, 9904, IntPtr.Zero);
            IntPtr wrongContainerRoot = NewRoot("GraphCodeSheetHost");
            IntPtr wrongContainer = Create("STATIC", wrongContainerRoot);
            IntPtr wrongContent = Create("GraphCodeWindowsDialogContent", wrongContainer);
            Create("EDIT", wrongContent, 9904);
            Lookup("ui.native.lookup.wrong-viewport", wrongContainerRoot, 9904, IntPtr.Zero);
            IntPtr namedViewport = Create("GraphCodeSheetViewport", wrongContainerRoot);
            IntPtr namedContent = Create("GraphCodeWindowsDialogContent", namedViewport);
            Lookup("ui.native.lookup.other-sibling", wrongContainerRoot, 9904, IntPtr.Zero);
            IntPtr deeper = Create("STATIC", namedContent);
            Create("EDIT", deeper, 9904);
            Lookup("ui.native.lookup.no-deeper-fallback", wrongContainerRoot, 9904, IntPtr.Zero);
            IntPtr deepRoot = NewRoot("GraphCodeSheetHost");
            IntPtr wrapper = Create("STATIC", deepRoot);
            IntPtr deepViewport = Create("GraphCodeSheetViewport", wrapper);
            IntPtr deepContent = Create("GraphCodeWindowsDialogContent", deepViewport);
            Create("EDIT", deepContent, 9904);
            Lookup("ui.native.lookup.direct-viewport-required", deepRoot, 9904, IntPtr.Zero);
            IntPtr nativeRoot = NewRoot("GraphCodeSheetHost");
            IntPtr nativeViewport = Create("GraphCodeSheetViewport", nativeRoot);
            IntPtr nativeContent = Create("GraphCodeNativeForm", nativeViewport);
            IntPtr nativeEdit = Create("EDIT", nativeContent, 9100);
            Lookup("ui.native.lookup.native-form", nativeRoot, 9100, nativeEdit);
            IntPtr workspaceRoot = NewRoot("GraphCodeSheetHost");
            IntPtr workspaceViewport = Create("GraphCodeSheetViewport", workspaceRoot);
            IntPtr workspaceContent = Create("GraphCodeWorkspaceManager", workspaceViewport);
            IntPtr workspaceList = Create("LISTBOX", workspaceContent, 9721);
            Lookup("ui.native.lookup.workspace-manager", workspaceRoot, 9721, workspaceList);
            IntPtr unknownRoot = NewRoot("GraphCodeSheetHost");
            IntPtr unknownViewport = Create("GraphCodeSheetViewport", unknownRoot);
            IntPtr unknownContent = Create("GraphCodeUnknownSheetContent", unknownViewport);
            Create("EDIT", unknownContent, 9100);
            Lookup("ui.native.lookup.unknown-content", unknownRoot, 9100, IntPtr.Zero);
            Lookup("ui.native.lookup.null-parent", IntPtr.Zero, 9904, IntPtr.Zero);
            ActivationCases.Require(results.Count == 14, "RED: prompt lookup case count was not 14");

            IntPtr hitRoot = NewRoot("GraphCodeSheetHost");
            IntPtr hitViewport = Create("GraphCodeSheetViewport", hitRoot);
            PromptLookupFixture.Place(hitViewport, 0, 0, 400, 300);
            IntPtr hitContent = Create("GraphCodeWindowsDialogContent", hitViewport);
            PromptLookupFixture.Place(hitContent, 15, 20, 350, 250);
            IntPtr hitEdit = Create("EDIT", hitContent, 9904);
            PromptLookupFixture.Place(hitEdit, 20, 25, 100, 24);
            int[] editBounds = GraphCodeUiaGateState.WindowBounds(hitEdit);
            Check("ui.native.hit.nested-edit", () => ActivationCases.Require(
                !PromptLookupFixture.IsWindowVisible(hitRoot) &&
                GraphCodeMultiProjectRenameNative.ChildAt(hitRoot, (editBounds[0] + editBounds[2]) / 2,
                    (editBounds[1] + editBounds[3]) / 2) == hitEdit,
                "RED: prompt hit did not resolve nested edit in hidden named viewport"));
            int[] contentBounds = GraphCodeUiaGateState.WindowBounds(hitContent);
            Check("ui.native.hit.content-background", () => ActivationCases.Require(
                GraphCodeMultiProjectRenameNative.ChildAt(hitRoot, contentBounds[2] - 10, contentBounds[3] - 10) == hitContent,
                "RED: prompt viewport background became an edit hit"));
            IntPtr plainRoot = NewRoot("STATIC");
            IntPtr plainViewport = Create("GraphCodeSheetViewport", plainRoot);
            IntPtr plainContent = Create("GraphCodeWindowsDialogContent", plainViewport);
            Create("EDIT", plainContent, 9904);
            int[] plainBounds = GraphCodeUiaGateState.WindowBounds(plainContent);
            Check("ui.native.hit.wrong-root", () => ActivationCases.Require(
                GraphCodeMultiProjectRenameNative.ChildAt(plainRoot, plainBounds[0] + 50, plainBounds[1] + 50) == plainViewport,
                "RED: prompt hit descended through wrong root class"));
            IntPtr otherRoot = NewRoot("GraphCodeSheetHost");
            IntPtr otherContent = Create("BUTTON", otherRoot);
            Create("EDIT", otherContent, 9904);
            int[] otherBounds = GraphCodeUiaGateState.WindowBounds(otherContent);
            Check("ui.native.hit.wrong-container", () => ActivationCases.Require(
                GraphCodeMultiProjectRenameNative.ChildAt(otherRoot, otherBounds[0] + 50, otherBounds[1] + 50) == otherContent,
                "RED: prompt hit descended through wrong container class"));
            IntPtr deepHitRoot = NewRoot("GraphCodeSheetHost");
            IntPtr deepHitViewport = Create("GraphCodeSheetViewport", deepHitRoot);
            PromptLookupFixture.Place(deepHitViewport, 0, 0, 400, 300);
            IntPtr deepHitContent = Create("GraphCodeWindowsDialogContent", deepHitViewport);
            IntPtr hitWrapper = Create("BUTTON", deepHitContent);
            Create("EDIT", hitWrapper, 9904);
            int[] deepBounds = GraphCodeUiaGateState.WindowBounds(hitWrapper);
            Check("ui.native.hit.no-recursion", () => ActivationCases.Require(
                GraphCodeMultiProjectRenameNative.ChildAt(deepHitRoot, deepBounds[0] + 50, deepBounds[1] + 50) == hitWrapper,
                "RED: prompt hit recursively searched deeper descendants"));
            IntPtr directRoot = NewRoot("GraphCodeSheetHost");
            IntPtr directEdit = Create("EDIT", directRoot, 9904);
            int[] directBounds = GraphCodeUiaGateState.WindowBounds(directEdit);
            Check("ui.native.hit.direct-child", () => ActivationCases.Require(
                GraphCodeMultiProjectRenameNative.ChildAt(directRoot, directBounds[0] + 50, directBounds[1] + 50) == directEdit,
                "RED: prompt hit changed existing direct-child behavior"));
            ActivationCases.Require(results.Count == 20, "RED: prompt hit case count was not 6");
            Check("ui.host-info.current-session", () => ActivationCases.Require(
                GraphCodeUiaHostInfo.CurrentSessionId() == checked((uint)Process.GetCurrentProcess().SessionId),
                "RED: UIA host context did not resolve the current Windows session"));
            Check("ui.native.dpi.physical-coordinates", () =>
            {
                IntPtr initial = PromptLookupFixture.GetThreadDpiAwarenessContext();
                ActivationCases.Require(PromptLookupFixture.SetThreadDpiAwarenessContext(new IntPtr(-1)) != IntPtr.Zero,
                    "Cannot establish unaware native coordinate control");
                try
                {
                    IntPtr unaware = PromptLookupFixture.GetThreadDpiAwarenessContext();
                    var scope = GraphCodeUiaGateState.EnterPhysicalDpiCoordinates();
                    IntPtr window;
                    int[] physical;
                    try
                    {
                        window = NewRoot("STATIC");
                        PromptLookupFixture.Place(window, 400, 300, 400, 300);
                        physical = GraphCodeUiaGateState.ClientScreenBounds(window);
                    }
                    finally { GraphCodeUiaGateState.RestorePhysicalDpiCoordinates(scope); }
                    ActivationCases.Require(PromptLookupFixture.AreDpiAwarenessContextsEqual(
                        PromptLookupFixture.GetThreadDpiAwarenessContext(), unaware),
                        "Creating the fixture did not restore the unaware caller");
                    int screenX = physical[0] + 50, screenY = physical[1] + 50;
                    ActivationCases.Require(GraphCodeUiaGateState.ScreenToClientPoint(
                        window, screenX, screenY, out int ux, out int uy),
                        "Unaware native screen-to-client control failed");
                    scope = GraphCodeUiaGateState.EnterPhysicalDpiCoordinates();
                    try
                    {
                        var uia = System.Windows.Automation.AutomationElement.FromHandle(window).Current.BoundingRectangle;
                        var native = GraphCodeUiaAttribution.Bounds(window);
                        ActivationCases.Require(
                            !PromptLookupFixture.IsWindowVisible(window) &&
                            GraphCodeUiaGateState.WindowProcessId(window) == (uint)Environment.ProcessId &&
                            uia.Left == native.Left && uia.Top == native.Top &&
                            uia.Right == native.Right && uia.Bottom == native.Bottom &&
                            GraphCodeUiaGateState.ClientScreenBounds(window).AsSpan().SequenceEqual(physical) &&
                            GraphCodeUiaGateState.ScreenToClientPoint(window, screenX, screenY, out int x, out int y) &&
                            x == 50 && y == 50 &&
                            (PromptLookupFixture.GetDpiForWindow(window) <= 96 || ux != 50 || uy != 50),
                            "Physical UIA/native coordinate scope did not preserve the fixed owned physical point");
                    }
                    finally { GraphCodeUiaGateState.RestorePhysicalDpiCoordinates(scope); }
                }
                finally
                {
                    ActivationCases.Require(PromptLookupFixture.SetThreadDpiAwarenessContext(initial) != IntPtr.Zero &&
                        PromptLookupFixture.AreDpiAwarenessContextsEqual(
                            PromptLookupFixture.GetThreadDpiAwarenessContext(), initial),
                        "Native coordinate control did not restore its initial exact context");
                }
            });
            Check("ui.native.dpi.exact-restore", () =>
            {
                IntPtr before = PromptLookupFixture.GetThreadDpiAwarenessContext();
                var scope = GraphCodeUiaGateState.EnterPhysicalDpiCoordinates();
                try
                {
                    ActivationCases.Require(scope.Context == before &&
                        scope.ThreadId == PromptLookupFixture.GetCurrentThreadId() &&
                        PromptLookupFixture.AreDpiAwarenessContextsEqual(
                            PromptLookupFixture.GetThreadDpiAwarenessContext(), new IntPtr(-4)),
                        "UIA scope did not retain the stable pre-entry token and capture thread");
                }
                finally { GraphCodeUiaGateState.RestorePhysicalDpiCoordinates(scope); }
                ActivationCases.Require(PromptLookupFixture.AreDpiAwarenessContextsEqual(
                    PromptLookupFixture.GetThreadDpiAwarenessContext(), before),
                    "UIA scope did not restore the exact pre-entry context");
            });
            void RejectRestore(GraphCodeUiaGateState.ThreadDpiContext scope, string reason)
            {
                IntPtr before = PromptLookupFixture.GetThreadDpiAwarenessContext();
                bool refused = false;
                try { GraphCodeUiaGateState.RestorePhysicalDpiCoordinates(scope); }
                catch (InvalidOperationException failure) { refused = failure.Message.Contains(reason, StringComparison.Ordinal); }
                ActivationCases.Require(refused && PromptLookupFixture.AreDpiAwarenessContextsEqual(
                    PromptLookupFixture.GetThreadDpiAwarenessContext(), before),
                    "Invalid UIA scope restoration was not refused without changing awareness: " + reason);
            }
            Check("ui.native.dpi.invalid-restore", () => RejectRestore(default, "invalid"));
            Check("ui.native.dpi.failed-set", () => RejectRestore(
                new GraphCodeUiaGateState.ThreadDpiContext(new IntPtr(-123456), PromptLookupFixture.GetCurrentThreadId()),
                "native set failed"));
            Check("ui.native.dpi.foreign-thread", () =>
            {
                var scope = GraphCodeUiaGateState.EnterPhysicalDpiCoordinates();
                Exception? failure = null;
                try
                {
                    var worker = new Thread(() =>
                    {
                        try { RejectRestore(scope, "capture thread"); }
                        catch (Exception error) { failure = error; }
                    }) { IsBackground = true };
                    worker.Start();
                    ActivationCases.Require(worker.Join(TimeSpan.FromSeconds(5)), "UIA foreign-thread refusal control timed out");
                    if (failure is not null) throw new InvalidOperationException("UIA foreign-thread refusal failed", failure);
                }
                finally { GraphCodeUiaGateState.RestorePhysicalDpiCoordinates(scope); }
            });
            string gate = System.IO.File.ReadAllText(System.IO.Path.Combine(context.RepositoryRoot,
                "Tools", "windows", "uia-live-gate.ps1")).Replace("\r\n", "\n");
            Check("ui.native.dpi.source-boundary", () =>
            {
                int enter = gate.IndexOf("$gateDpiScope = [GraphCodeUiaGateState]::EnterPhysicalDpiCoordinates()", StringComparison.Ordinal);
                int launch = gate.IndexOf("$tempRoot = if", StringComparison.Ordinal);
                int failureCapture = gate.IndexOf("Write-UiaWaitAttribution \"gate failure:", StringComparison.Ordinal);
                int cleanup = gate.IndexOf("Stop-UiaOwnedProcessTrees @", StringComparison.Ordinal);
                int restore = gate.LastIndexOf("[GraphCodeUiaGateState]::RestorePhysicalDpiCoordinates($gateDpiScope)", StringComparison.Ordinal);
                ActivationCases.Require(enter > 0 && enter < launch && failureCapture > enter &&
                    cleanup > failureCapture && restore > cleanup &&
                    gate.Contains("$gateDpiScope = $null", StringComparison.Ordinal) &&
                    gate.Contains("if ($null -ne $gateDpiScope)", StringComparison.Ordinal),
                    "UIA physical-coordinate scope must enclose queries, failure captures, owned cleanup and early returns");
            }, "UIA script source-boundary contract; nativeCalls=0");
            Check("ui.native.dpi.primary-error-preserved", () => ActivationCases.Require(
                gate.Contains("$gateFailure.Exception.Data[\"UiaDpiRestoreFailure\"] = $_.Exception", StringComparison.Ordinal) &&
                gate.Contains("$sandboxCleanupError.Exception.Data[\"UiaDpiRestoreFailure\"] = $_.Exception", StringComparison.Ordinal) &&
                gate.Contains("else { $sandboxCleanupError = $_ }", StringComparison.Ordinal) &&
                gate.Contains("UIA_DPI_RESTORE_ERROR=", StringComparison.Ordinal),
                "UIA DPI restoration must report its failure without replacing a primary gate or cleanup failure"),
                "UIA script primary-error propagation contract; nativeCalls=0");
        }
        catch (Exception failure)
        {
            primary = failure;
            throw;
        }
        finally
        {
            var cleanupFailures = new List<Exception>();
            foreach (IntPtr window in roots)
                if (!PromptLookupFixture.DestroyWindow(window))
                    cleanupFailures.Add(new InvalidOperationException($"Prompt lookup fixture cleanup failed for {window}"));
            if (cleanupFailures.Count != 0)
            {
                if (primary is not null) cleanupFailures.Insert(0, primary);
                throw new AggregateException("Native UI fixture cleanup failed", cleanupFailures);
            }
        }
        return Task.FromResult<IReadOnlyList<UnitResult>>(results);
    }
}
