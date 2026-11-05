using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using GraphCode.Validation.Ui.Fixtures;
using GraphCode.Windows;

namespace GraphCode.Validation.Ui;

internal sealed record UiCase(string Id, Action Run, string Source);

public sealed class ManagedUiSuite : IValidationSuite
{
    private readonly IReadOnlyList<UiCase> cases = CreateCases();
    public string Id => "ui.managed";
    public IReadOnlyList<string> UnitIds => cases.Select(test => test.Id).ToArray();

    public Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken)
    {
        var results = new List<UnitResult>();
        foreach (var test in cases)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                test.Run();
                results.Add(new UnitResult(test.Id, UnitStatus.Passed, 1, $"{test.Source}; nativeCalls=0"));
            }
            catch (Exception failure)
            {
                results.Add(new UnitResult(test.Id, UnitStatus.Failed, 1, failure.ToString()));
            }
        }
        return Task.FromResult<IReadOnlyList<UnitResult>>(results);
    }

    private sealed record InputCase(string Name, string Operation, int Expected,
        Action<InputFixture>? Configure = null, int? Moves = null, bool? Refuse = null);

    private static IReadOnlyList<UiCase> CreateCases()
    {
        var cases = new List<UiCase>();
        InputCase[] inputCases =
        {
            new("owned-key", "key", 1),
            new("foreign-foreground", "key", 0, p => p.Foreground = false),
            new("foreign-focus", "key", 0, p => p.Focus = new IntPtr(99)),
            new("sibling-focus", "key", 0, p => p.Focus = new IntPtr(21)),
            new("missing-focus", "key", 0, p => p.Focus = IntPtr.Zero),
            new("dead-retained-process", "key", 0, p => p.Alive = false),
            new("hidden-window", "key", 0, p => p.Visible = false),
            new("disabled-window", "key", 0, p => p.Enabled = false),
            new("owned-unicode", "unicode", 1),
            new("unicode-foreign-focus", "unicode", 0, p => p.Focus = new IntPtr(99)),
            new("owned-mouse", "mouse", 1),
            new("mouse-hit-loss", "mouse", 0, p => p.HitLoss = true),
            new("mouse-cursor-loss", "mouse", 0, p => p.CursorLoss = true),
            new("mouse-foreign-foreground", "mouse", 0, p => p.Foreground = false),
            new("owned-edit", "edit", 2),
            new("edit-focus-loss-after-select", "edit", 0, p => p.FocusOnSelect = true),
            new("edit-focus-loss-after-read", "edit", 1, p => p.FocusOnRead = true, Refuse: true),
            new("owned-submenu-hover", "hover", 0, Moves: 1, Refuse: false),
            new("submenu-foreign-foreground", "hover", 0, p => p.Foreground = false, Moves: 0),
            new("submenu-unretained-process", "hover", 0, p => p.Alive = false, Moves: 0),
            new("submenu-covered-point", "hover", 0, p => p.Covered = true, Moves: 0)
        };
        ActivationCases.Require(inputCases.Length == 21, "UIA input fixtures require exactly twenty-one cases");
        foreach (var test in inputCases)
            cases.Add(new UiCase($"ui.input.{test.Name}", () => RunInput(test), "ValidationRunner.Tests.ps1:758-890"));

        (string Name, long Owner, long Popup, uint Expected, uint PopupPid, uint ForegroundPid,
            long ForegroundRoot, uint PointPid, long PointRoot, bool Visible, bool Accepted)[] predicates =
        {
            ("owned-shell", 42,43,4242,4242,4242,42,4242,43,true,true),
            ("owned-popup", 42,43,4242,4242,4242,43,4242,43,true,true),
            ("foreign-foreground", 42,43,4242,4242,7777,42,4242,43,true,false),
            ("foreign-foreground-root", 42,43,4242,4242,4242,99,4242,43,true,false),
            ("foreign-hit", 42,43,4242,4242,4242,42,7777,43,true,false),
            ("underlying-shell-hit", 42,43,4242,4242,4242,42,4242,42,true,false),
            ("hidden-popup", 42,43,4242,4242,4242,42,4242,43,false,false),
            ("unknown-owner", 42,43,0,0,0,42,0,43,true,false),
            ("foreign-popup", 42,43,4242,7777,4242,42,4242,43,true,false),
            ("absent-popup", 42,0,4242,4242,4242,42,4242,0,true,false)
        };
        ActivationCases.Require(predicates.Length == 10, "Popup ownership requires ten managed combinations");
        foreach (var test in predicates)
            cases.Add(new UiCase($"ui.popup.predicate.{test.Name}", () =>
            {
                bool accepted = UiaInputSafety.IsOwnedPopupInput(new IntPtr(test.Owner), new IntPtr(test.Popup),
                    test.Expected, test.PopupPid, test.ForegroundPid, new IntPtr(test.ForegroundRoot),
                    test.PointPid, new IntPtr(test.PointRoot), test.Visible);
                ActivationCases.Require(accepted == test.Accepted, $"Popup ownership predicate: {test.Name} differs");
            }, "ValidationRunner.Tests.ps1:1221-1255"));

        string[] effects = { "owned", "owned-enter", "foreign-foreground", "foreign-after-hover",
            "foreign-before-enter", "foreign-owner-all", "foreign-hit", "underlying-shell-hit",
            "hidden-popup", "cursor-changed", "cursor-unreadable" };
        ActivationCases.Require(effects.Length == 11, "Popup effect contract requires eleven scenarios");
        foreach (string name in effects)
            cases.Add(new UiCase($"ui.popup.effect.{name}", () => RunPopupEffect(name),
                "ValidationRunner.Tests.ps1:1256-1328"));

        cases.Add(new UiCase("ui.geometry.seven-pixel-band", () =>
        {
            int[][] remainder = GraphCodeUiaGateState.SubtractCoveredRectangles(
                new[] { 667, 698, 763, 728 }, new[] { new[] { 84, 699, 763, 721 } });
            ActivationCases.Require(remainder.Length == 2 && remainder[0].SequenceEqual(new[] { 667, 721, 763, 728 }),
                "RED: node sheet rectangle subtraction misses the real seven-pixel uncovered Create band");
        }, "ValidationRunner.Tests.ps1:7626-7634"));
        cases.Add(new UiCase("ui.geometry.multiple-covers", () =>
        {
            int[][] remainder = GraphCodeUiaGateState.SubtractCoveredRectangles(
                new[] { 667, 698, 763, 728 }, new[] { new[] { 84, 699, 763, 721 }, new[] { 667, 721, 715, 728 } });
            ActivationCases.Require(remainder.Length == 2 && remainder[0].SequenceEqual(new[] { 715, 721, 763, 728 }),
                "RED: node sheet rectangle subtraction does not handle more than one covering control");
        }, "ValidationRunner.Tests.ps1:7635-7643"));
        cases.Add(new UiCase("ui.gate-state.activation-reference", () =>
        {
            var field = typeof(GraphCodeUiaGateState).GetField("ActivationOperations",
                System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static);
            ActivationCases.Require(field is not null &&
                field.FieldType == typeof(IUiaWindowActivationOperations) &&
                field.FieldType.Assembly == typeof(UiaWindowActivation).Assembly,
                "Full UIA gate helper does not use the activation contracts' production type identity");
        }, "ValidationRunner.Tests.ps1:7408-7430"));
        cases.Add(new UiCase("ui.gate-state.input-reference", () =>
        {
            var field = typeof(GraphCodeUiaGateState).GetField("InputSafety",
                System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static);
            ActivationCases.Require(field is not null && field.FieldType == typeof(UiaInputSafety),
                "Full UIA gate helper must use the tested shared input safety component");
        }, "Compiled migration shared production linkage"));
        return cases;
    }

    private static void RunInput(InputCase test)
    {
        var probe = new InputFixture();
        probe.Reset();
        test.Configure?.Invoke(probe);
        var input = new UiaInputSafety(probe);
        Exception? failure = null;
        try
        {
            switch (test.Operation)
            {
                case "key": input.SendKeyInput(new IntPtr(10), 123, new IntPtr(20), 46, 1); break;
                case "unicode": input.SendUnicodeInput(new IntPtr(10), 123, new IntPtr(20), "test"); break;
                case "mouse": input.ClickOwnedScreenRectangle(new IntPtr(10), 0, 0, 10, 10, false); break;
                case "edit": input.TypeEditTextById(new IntPtr(10), 1, "test"); break;
                case "hover": probe.Hover = true; input.HoverPopupMenuItem(new IntPtr(10), new IntPtr(11), 0); break;
                default: throw new InvalidOperationException($"Unknown input operation {test.Operation}");
            }
        }
        catch (InvalidOperationException error) { failure = error; }
        bool mustRefuse = test.Refuse ?? test.Expected == 0;
        ActivationCases.Require(probe.Injected == test.Expected && (failure is not null) == mustRefuse &&
            (test.Moves is null || probe.Moves == test.Moves),
            $"UIA_INPUT_RED: {test.Name} injected={probe.Injected} expected={test.Expected} refusal={failure is not null}; {failure?.Message}");
        if (test.Name == "owned-key") CheckControlModifier();
    }

    private static void CheckControlModifier()
    {
        var method = typeof(UiaInputSafety).GetMethod(nameof(UiaInputSafety.SendKeyInput),
            new[] { typeof(IntPtr), typeof(uint), typeof(IntPtr), typeof(ushort), typeof(int), typeof(bool) });
        ActivationCases.Require(method is not null, "Guarded optional-Control input contract is missing");
        Exception? Send(InputFixture probe, bool modifier)
        {
            try
            {
                var result = method!.Invoke(new UiaInputSafety(probe),
                    new object[] { new IntPtr(10), 123u, new IntPtr(20), (ushort)0x4C, 1, modifier });
                ActivationCases.Require(result is int count && count == 1, "Complete key batch lost its return count");
                return null;
            }
            catch (System.Reflection.TargetInvocationException error) when (error.InnerException is not null) { return error.InnerException; }
        }
        var normal = new InputFixture(); normal.Reset();
        ActivationCases.Require(Send(normal, false) is null && normal.KeyBatches.Count == 1 &&
            normal.KeyBatches[0].Length == 2 && normal.KeyBatches[0][0].Key.VirtualKey == 0x4C &&
            normal.KeyBatches[0][0].Key.Flags == 0 && normal.KeyBatches[0][1].Key.Flags == 2 &&
            normal.PressedKeys.Count == 0, "Default input is no longer the original two-event batch");
        var original = new InputFixture(); original.Reset();
        var originalInput = new UiaInputSafety(original);
        ActivationCases.Require(originalInput.SendKeyInput(new IntPtr(10), 123, new IntPtr(20), 0x4C, 0) == 0 &&
            original.KeyBatches.Count == 0 &&
            originalInput.SendKeyInput(new IntPtr(10), 123, new IntPtr(20), 0x4C, 2) == 2 &&
            original.KeyBatches.Count == 1 && original.KeyBatches[0].Length == 4 &&
            original.KeyBatches[0].Select(record => record.Key.VirtualKey).SequenceEqual(new ushort[] { 0x4C, 0x4C, 0x4C, 0x4C }) &&
            original.KeyBatches[0].Select(record => record.Key.Flags).SequenceEqual(new uint[] { 0, 2, 0, 2 }) &&
            original.PressedKeys.Count == 0, "Original five-argument zero/repeated-key behavior changed");
        for (uint sent = 0; sent <= 4; sent++)
        {
            var probe = new InputFixture(); probe.Reset(); probe.KeyReturns.Enqueue(sent);
            probe.AfterFirstKeyInput = p => p.Focus = new IntPtr(21);
            var error = Send(probe, true);
            var batch = probe.KeyBatches[0];
            ActivationCases.Require(batch.Length == 4 &&
                batch.Select(record => record.Key.VirtualKey).SequenceEqual(new ushort[] { 0x11, 0x4C, 0x4C, 0x11 }) &&
                batch.Select(record => record.Key.Flags).SequenceEqual(new uint[] { 0, 0, 2, 2 }) &&
                batch.All(record => record.Type == 1) && probe.PressedKeys.Count == 0 &&
                (sent == 4 ? error is null : error is InvalidOperationException) &&
                probe.KeyBatches.Count == (sent is 1 or 2 or 3 ? 2 : 1) &&
                probe.KeyBatches.Skip(1).SelectMany(records => records).All(record => record.Key.Flags == 2),
                $"Control batch return {sent} changed order, failed to release keys, replayed keydowns or hid failure: {error}");
        }
        foreach (Action<InputFixture> invalidate in new Action<InputFixture>[] {
            p => p.Foreground = false, p => p.Focus = new IntPtr(99),
            p => p.Focus = new IntPtr(21), p => p.Focus = new IntPtr(30), p => p.Focus = IntPtr.Zero,
            p => p.Alive = false, p => p.ForeignOwner = true,
            p => p.ForegroundOverride = new IntPtr(30), p => p.Visible = false, p => p.Enabled = false })
        {
            var probe = new InputFixture(); probe.Reset(); invalidate(probe);
            ActivationCases.Require(Send(probe, true) is InvalidOperationException &&
                probe.KeyBatches.Count == 0, "Control modifier bypassed an original pre-input guard");
        }
        for (uint released = 0; released <= 2; released++)
        {
            var probe = new InputFixture(); probe.Reset();
            probe.KeyReturns.Enqueue(2); probe.KeyReturns.Enqueue(released);
            var error = Send(probe, true);
            ActivationCases.Require(probe.KeyBatches.Count == 2 &&
                probe.KeyBatches[1].Select(record => record.Key.VirtualKey).SequenceEqual(new ushort[] { 0x4C, 0x11 }) &&
                probe.KeyBatches[1].All(record => record.Key.Flags == 2) &&
                (released == 2 ? error is InvalidOperationException && probe.PressedKeys.Count == 0 :
                    error is AggregateException aggregate && aggregate.InnerExceptions.Count == 2 &&
                    probe.PressedKeys.Contains(0x11)),
                $"Short key-up cleanup {released}/2 hid failure, replayed keydowns or claimed key release");
        }
        foreach (Action<InputFixture> invalidateCleanup in new Action<InputFixture>[] {
            p => p.Foreground = false, p => p.Focus = new IntPtr(99), p => p.Focus = IntPtr.Zero,
            p => p.Focus = new IntPtr(30), p => p.Alive = false, p => p.ForeignOwner = true,
            p => p.ForegroundOverride = new IntPtr(30), p => p.Visible = false, p => p.Enabled = false })
        {
            var probe = new InputFixture(); probe.Reset();
            probe.KeyReturns.Enqueue(2); probe.KeyReturns.Enqueue(0);
            probe.AfterFirstKeyInput = invalidateCleanup;
            var error = Send(probe, true);
            ActivationCases.Require(error is AggregateException aggregate && aggregate.InnerExceptions.Count == 2 &&
                aggregate.InnerExceptions[0] is InvalidOperationException primary &&
                primary.Message.StartsWith("SendInput injected 2 of 4 key events", StringComparison.Ordinal) &&
                aggregate.InnerExceptions[1] is InvalidOperationException &&
                probe.KeyBatches.Count == 1 &&
                probe.KeyBatches.Skip(1).SelectMany(records => records).All(record => record.Key.Flags == 2) &&
                probe.PressedKeys.Contains(0x11),
                "Unproved modifier cleanup lost its primary/separate error, bypassed ownership or hid held Ctrl");
        }
        foreach (var cleanup in new Exception[] { new InvalidOperationException("Fixture cleanup refused"),
            new System.ComponentModel.Win32Exception(5) })
        {
            var probe = new InputFixture(); probe.Reset();
            probe.KeyReturns.Enqueue(2); probe.KeyCleanupFailure = cleanup;
            ActivationCases.Require(Send(probe, true) is AggregateException aggregate &&
                aggregate.InnerExceptions.Count == 2 && ReferenceEquals(aggregate.InnerExceptions[1], cleanup) &&
                probe.PressedKeys.Contains(0x11), "Native cleanup exception replaced the primary failure or hid held Ctrl");
        }
    }

    private static void RunPopupEffect(string name)
    {
        var probe = new PopupEffectFixture();
        probe.Reset(name);
        var input = new UiaInputSafety(probe);
        UiaInputSafety.PopupItemHit? hit = null;
        Exception? failure = null;
        try { hit = input.ClickPopupMenuItem(new IntPtr(43), new IntPtr(42), 0, 5103, 4242); }
        catch (InvalidOperationException error) { failure = error; }
        bool expected = name is "owned" or "owned-enter";
        bool passed = (hit is not null) == expected &&
            probe.MouseCalls == (expected || name == "foreign-before-enter" ? 1 : 0) &&
            probe.KeyCalls == (name == "owned-enter" ? 2 : 0) &&
            probe.CursorMoves == (name is "foreign-foreground" or "foreign-owner-all" or "hidden-popup" ? 0 : 1);
        if (!expected)
        {
            string diagnostic = name is "cursor-changed" or "cursor-unreadable"
                ? "Popup input cursor changed; no mouse input was injected"
                : name is "foreign-foreground" or "foreign-before-enter" or "foreign-owner-all" or "hidden-popup"
                    ? "Popup input ownership changed; no further input was injected"
                    : "Popup input ownership changed; no mouse input was injected";
            passed &= failure is not null && failure.Message.Contains(diagnostic, StringComparison.Ordinal);
        }
        ActivationCases.Require(passed, $"Actual popup input effect contract: {name} differs; {failure?.Message}");
    }
}
