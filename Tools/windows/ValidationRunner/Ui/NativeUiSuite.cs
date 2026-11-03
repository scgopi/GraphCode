using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using GraphCode.Validation.Ui.Fixtures;

namespace GraphCode.Validation.Ui;

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
        "ui.host-info.current-session"
    };

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
            void Check(string id, Action assertion)
            {
                cancellationToken.ThrowIfCancellationRequested();
                try
                {
                    assertion();
                    results.Add(new UnitResult(id, UnitStatus.Passed, 1,
                        "Actual compiled helper and hidden owned Win32 fixture; ValidationRunner.Tests.ps1:7431-7624"));
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
