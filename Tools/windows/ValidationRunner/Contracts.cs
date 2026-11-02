namespace GraphCode.Validation;

public interface IValidationSuite
{
    string Id { get; }
    IReadOnlyList<string> UnitIds { get; }
    Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken);
}

public sealed record ValidationContext(string RepositoryRoot, string ArtifactRoot);

public enum UnitStatus { Passed, Failed, Skipped, Incomplete }

public sealed record UnitResult(
    string Id,
    UnitStatus Status,
    int ExecutedCount,
    string Evidence,
    IReadOnlyList<string>? Groups = null);
