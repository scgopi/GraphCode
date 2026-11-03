using System.IO;
using GraphCode.Validation.Adapters;

namespace GraphCode.Validation.Host.RootContracts;

public static class ResidualScopeRegistration
{
    public static IReadOnlyList<IValidationSuite> CreateSuites() => [new ResidualSuite()];

    private static readonly string[] Cases =
    [
        "source.packaging.signing", "control.packaging.signing.missing-call",
        "source.packaging.rollback", "control.packaging.rollback.missing-call",
        "source.packaging.standalone", "control.packaging.standalone.missing-call",
        "source.packaging.script_signing", "control.packaging.script_signing.missing-call",
        "source.packaging.scheduler", "control.packaging.scheduler.missing-call",
        "source.packaging.uninstall", "control.packaging.uninstall.missing-call",
        "source.packaging.real-input-order", "control.packaging.real-missing-initialization",
        "control.packaging.wrong-part-guard", "control.packaging.comment-is-not-invocation"
    ];

    private sealed class ResidualSuite : IValidationSuite
    {
        public string Id => "host.root-source-scope-mock-environment-error-streams";
        public IReadOnlyList<string> UnitIds => [Id];

        public async Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken)
        {
            var suite = new StandaloneSuites.CaseScriptSuite(Id,
                "Tools\\windows\\ValidationRunner\\Host\\CiContracts\\ResidualScope.ps1", "HOST_CASE_RESULT=", [Id]);
            var results = await suite.RunAsync(context, cancellationToken);
            if (results.Count != 1 || results[0].Id != Id)
                throw new InvalidDataException("Residual root scope requires exactly one matching unit result");
            var row = results[0];
            if (row.ExecutedCount != Cases.Length || (row.Status == UnitStatus.Passed &&
                (row.Groups is null || row.Groups.Count != Cases.Length ||
                 !row.Groups.Order(StringComparer.Ordinal).SequenceEqual(Cases.Order(StringComparer.Ordinal), StringComparer.Ordinal))))
                row = row with { Status = UnitStatus.Failed, Evidence = row.Evidence + "; exact residual case inventory/count mismatch" };
            return [row];
        }
    }
}
