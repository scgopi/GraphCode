using GraphCode.Validation.Ui.Fixtures;
using GraphCode.Windows;

namespace GraphCode.Validation.Ui;

public sealed class CardsAcceptanceControlsSuite : IValidationSuite
{
    public string Id => "ui.cards-acceptance-controls";
    public IReadOnlyList<string> UnitIds { get; } =
    [
        "ui.cards-controls.pointer-delivered",
        "ui.cards-controls.keyboard-refused",
        "ui.cards-controls.selection-refused",
        "ui.cards-controls.invalid-menu-refused",
        "ui.cards-controls.synthetic-hover-refused",
        "ui.cards-controls.foreign-refused",
        "ui.cards-controls.null-popup-refused",
        "ui.cards-controls.wrong-command-refused",
        "ui.cards-controls.default-fallback-preserved"
    ];

    public Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken)
    {
        var results = new List<UnitResult>();
        foreach (var id in UnitIds)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                RunCase(id);
                results.Add(new UnitResult(id, UnitStatus.Passed, 1,
                    "Existing PopupEffectFixture and compiled UiaInputSafety; nativeCalls=0"));
            }
            catch (Exception failure)
            {
                results.Add(new UnitResult(id, UnitStatus.Failed, 1, failure.ToString()));
            }
        }
        return Task.FromResult<IReadOnlyList<UnitResult>>(results);
    }

    private static void RunCase(string id)
    {
        var probe = new PopupEffectFixture();
        probe.Reset(id switch
        {
            "ui.cards-controls.pointer-delivered" => "native-hover",
            "ui.cards-controls.keyboard-refused" => "owned-enter",
            "ui.cards-controls.selection-refused" => "unhilited",
            "ui.cards-controls.invalid-menu-refused" => "invalid-state",
            "ui.cards-controls.synthetic-hover-refused" => "synthetic-hover",
            "ui.cards-controls.foreign-refused" => "foreign-foreground",
            "ui.cards-controls.default-fallback-preserved" => "owned-enter",
            _ => "owned"
        });
        var input = new UiaInputSafety(probe);
        UiaInputSafety.PopupItemHit? receipt = null;
        Exception? failure = null;
        try
        {
            if (id == "ui.cards-controls.default-fallback-preserved")
                receipt = input.ClickPopupMenuItem(new IntPtr(43), new IntPtr(42), 0, 5103, 4242);
            else
            {
                var method = typeof(UiaInputSafety).GetMethod("ClickPopupMenuItemStrict")
                    ?? throw new InvalidOperationException("Strict native pointer entry is missing");
                receipt = (UiaInputSafety.PopupItemHit?)method.Invoke(input,
                    [id == "ui.cards-controls.null-popup-refused" ? IntPtr.Zero : new IntPtr(43),
                        new IntPtr(42), 0, id == "ui.cards-controls.wrong-command-refused" ? 5122 : 5103, 4242u]);
            }
        }
        catch (Exception error) when (error is InvalidOperationException or System.Reflection.TargetInvocationException)
        {
            failure = error.InnerException ?? error;
        }
        bool accepted = id is "ui.cards-controls.pointer-delivered" or "ui.cards-controls.default-fallback-preserved";
        int mouseCalls = id is "ui.cards-controls.foreign-refused" or "ui.cards-controls.selection-refused" or "ui.cards-controls.invalid-menu-refused" or
            "ui.cards-controls.null-popup-refused" or "ui.cards-controls.wrong-command-refused" or "ui.cards-controls.synthetic-hover-refused" ? 0 : 1;
        int keyCalls = id == "ui.cards-controls.default-fallback-preserved" ? 2 : 0;
        ActivationCases.Require((receipt is not null) == accepted && (failure is null) == accepted &&
            probe.MouseCalls == mouseCalls && probe.KeyCalls == keyCalls &&
            probe.SelectItemCalls == (id == "ui.cards-controls.default-fallback-preserved" ? 1 : 0),
            $"{id}: mouse={probe.MouseCalls}, key={probe.KeyCalls}, selection={probe.SelectItemCalls}; {failure?.Message}");
        if (!accepted)
        {
            string diagnostic = id switch
            {
                "ui.cards-controls.keyboard-refused" => "Strict popup remained open after pointer input",
                "ui.cards-controls.selection-refused" => "Strict popup did not acknowledge pointer hover",
                "ui.cards-controls.invalid-menu-refused" => "Popup menu state unavailable",
                "ui.cards-controls.synthetic-hover-refused" => "Strict popup did not acknowledge pointer hover",
                "ui.cards-controls.null-popup-refused" or "ui.cards-controls.wrong-command-refused" =>
                    "Strict popup target identity or geometry is invalid",
                _ => "Popup input ownership changed"
            };
            ActivationCases.Require(failure is InvalidOperationException &&
                failure.Message.Contains(diagnostic, StringComparison.Ordinal),
                $"Expected fail-closed native route diagnostic: {diagnostic}; {failure?.Message}");
            if (id is "ui.cards-controls.selection-refused" or "ui.cards-controls.invalid-menu-refused")
                ActivationCases.Require(failure!.Data["rawMenuState"] is uint state &&
                    state == (id == "ui.cards-controls.invalid-menu-refused" ? uint.MaxValue : 0u) &&
                    failure.Data["itemRect"] is int[] rect && rect.AsSpan().SequenceEqual(new[] { 100, 100, 300, 150 }) &&
                    failure.Data["screenPoint"] is int[] point && point.AsSpan().SequenceEqual(new[] { 200, 125 }) &&
                    failure.Data["nativeErrorAvailable"] is false,
                    "Popup refusal lost original raw state or owned point/rectangle evidence");
        }
        if (receipt is not null)
            ActivationCases.Require(receipt.ItemId == 5103 &&
                receipt.UsedKeyboardFallback == (id == "ui.cards-controls.default-fallback-preserved") &&
                !receipt.UsedSelectItemFallback, "Unexpected native route receipt");
        if (id != "ui.cards-controls.default-fallback-preserved")
            ActivationCases.Require(probe.MovePosts == 0 && probe.MoveSends == 0,
                "Strict preparation coerced the native hover acknowledgement with a synthetic move message");
        if (id == "ui.cards-controls.default-fallback-preserved")
            ActivationCases.Require(probe.MovePosts == 0 && probe.MoveSends == 1, "Default valid legacy preparation changed");
        if (id == "ui.cards-controls.selection-refused")
        {
            probe.Reset("unhilited-metadata-fault");
            try
            {
                input.ClickPopupMenuItemStrict(new IntPtr(43), new IntPtr(42), 0, 5103, 4242);
                throw new InvalidOperationException("Metadata fault unexpectedly accepted popup input");
            }
            catch (InvalidOperationException error)
            {
                ActivationCases.Require(error.Message.StartsWith("Strict popup did not acknowledge pointer hover", StringComparison.Ordinal) &&
                    error.Data["rawMenuState"] is 0u &&
                    error.Data["metadataError"] is string metadataError && metadataError.Contains("Owned metadata fixture fault", StringComparison.Ordinal) &&
                    probe.MouseCalls == 0 && probe.KeyCalls == 0 && probe.SelectItemCalls == 0,
                    "Metadata failure replaced the primary popup refusal or emitted input");
            }
        }
        if (id == "ui.cards-controls.invalid-menu-refused")
        {
            probe.Reset("invalid-state");
            try
            {
                input.ClickPopupMenuItem(new IntPtr(43), new IntPtr(42), 0, 5103, 4242);
                throw new InvalidOperationException("Legacy route unexpectedly accepted invalid menu state");
            }
            catch (InvalidOperationException error)
            {
                ActivationCases.Require(error.Message.Contains("Popup menu state unavailable", StringComparison.Ordinal) &&
                    error.Data["rawMenuState"] is uint.MaxValue &&
                    probe.MouseCalls == 0 && probe.KeyCalls == 0 && probe.SelectItemCalls == 0,
                    "Invalid legacy menu state emitted input instead of refusing the native error");
            }
        }
    }
}
