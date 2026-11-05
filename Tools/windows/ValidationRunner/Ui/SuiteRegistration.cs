using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace GraphCode.Validation.Ui;

public static class SuiteRegistration
{
    public static IReadOnlyList<IValidationSuite> CreateSuites() => new IValidationSuite[]
    {
        new ActivationSuite(), new ManagedUiSuite(), new CardsAcceptanceControlsSuite(), new NativeUiSuite(), new ControlClickTopologySuite()
    }.Concat(UiAdapterCases.CreateSuites()).ToArray();
}

public sealed class ActivationSuite : IValidationSuite
{
    public string Id => "ui.activation";
    public IReadOnlyList<string> UnitIds { get; } = new[]
    {
        "ui.activation.foreground-refused",
        "ui.activation.foreground-acquired",
        "ui.activation.ownership-refused",
        "ui.activation.invalid-window-refused"
    };

    public Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken)
    {
        Action[] cases = { ActivationCases.ForegroundRefused, ActivationCases.ForegroundAcquired,
            ActivationCases.OwnershipRefused, ActivationCases.InvalidWindowRefused };
        var results = new List<UnitResult>();
        for (int i = 0; i < cases.Length; i++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                cases[i]();
                results.Add(new UnitResult(UnitIds[i], UnitStatus.Passed, 1,
                    "Actual shared UiaWindowActivation algorithm; typed test-only operations; nativeCalls=0"));
            }
            catch (InvalidOperationException failure)
            {
                results.Add(new UnitResult(UnitIds[i], UnitStatus.Failed, 1, failure.ToString()));
            }
        }
        return Task.FromResult<IReadOnlyList<UnitResult>>(results);
    }
}
