namespace GraphCode.Validation.Host;

public static class HostSelfTests
{
    public static int Run()
    {
        var executed = 0;
        var errors = new List<string>();
        void Check(string id, Action body)
        {
            executed++;
            try { body(); }
            catch (Exception error) { errors.Add($"{id}: {error.Message}"); }
        }
        static void Assert(bool condition, string evidence)
        {
            if (!condition) throw new InvalidOperationException(evidence);
        }
        var unit = new RequiredUnit("test.case", "Host", 1);
        var suite = new StaticSuite("test", ["test.case"]);
        var passed = new UnitResult("test.case", UnitStatus.Passed, 1, "actual assertion ran");
        CoverageReport Evaluate(IReadOnlyList<RequiredUnit>? units = null,
            IReadOnlyList<IValidationSuite>? registry = null,
            IReadOnlyList<UnitResult>? results = null) =>
            Coverage.Evaluate(units ?? [unit], registry ?? [suite], results ?? [passed]);

        Check("positive", () => Assert(Evaluate().Complete, "positive executed case rejected"));
        Check("missing-result", () => Assert(!Evaluate(results: []).Complete, "missing result admitted"));
        Check("duplicate-result", () => Assert(!Evaluate(results: [passed, passed]).Complete, "duplicate result admitted"));
        Check("duplicate-required", () => Assert(!Evaluate(units: [unit, unit]).Complete, "duplicate manifest admitted"));
        Check("missing-executor", () => Assert(!Evaluate(registry: []).Complete, "unimplemented unit admitted"));
        Check("duplicate-executor", () => Assert(!Evaluate(registry: [suite, suite]).Complete, "duplicate executor admitted"));
        Check("zero-run", () => Assert(!Evaluate(results: [passed with { ExecutedCount = 0 }]).Complete, "zero run admitted"));
        Check("skipped", () => Assert(!Evaluate(results: [passed with { Status = UnitStatus.Skipped }]).Complete, "skip admitted"));
        Check("incomplete", () => Assert(!Evaluate(results: [passed with { Status = UnitStatus.Incomplete }]).Complete, "incomplete admitted"));
        Check("failed", () => Assert(!Evaluate(results: [passed with { Status = UnitStatus.Failed }]).Complete, "failure admitted"));
        Check("unknown-result", () => Assert(!Evaluate(results: [passed, passed with { Id = "foreign" }]).Complete, "unknown result admitted"));
        Check("unknown-executor", () => Assert(!Evaluate(registry: [suite, new StaticSuite("foreign", ["foreign"])]).Complete, "unknown executor admitted"));
        Check("empty-manifest", () => Assert(!Evaluate(units: [], registry: [], results: []).Complete, "empty run admitted"));
        Check("no-evidence", () => Assert(!Evaluate(results: [passed with { Evidence = "" }]).Complete, "empty evidence admitted"));
        Check("missing-group", () => Assert(!Evaluate(units: [unit with { RequiredGroups = ["required"] }]).Complete, "missing group admitted"));
        Check("duplicate-group", () => Assert(!Evaluate(units: [unit with { RequiredGroups = ["required"] }],
            results: [passed with { Groups = ["required", "required"] }]).Complete, "duplicate group admitted"));
        Check("positive-group", () => Assert(Evaluate(units: [unit with { RequiredGroups = ["required"] }],
            results: [passed with { Groups = ["required"] }]).Complete, "positive group rejected"));
        Check("exact-count", () => Assert(!Evaluate(units: [unit with { ExactCount = 2 }]).Complete, "wrong exact count admitted"));
        Check("minimum-count", () => Assert(!Evaluate(units: [unit with { MinimumCount = 2 }]).Complete, "insufficient count admitted"));
        Check("invalid-minimum", () => Assert(!Evaluate(units: [unit with { MinimumCount = 0 }]).Complete, "zero minimum admitted"));
        Check("execution-error", () => Assert(!Coverage.Evaluate([unit], [suite], [passed], ["child failed"]).Complete, "execution error admitted"));
        Check("missing-manifests", () =>
        {
            try { Coverage.Load(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"))); }
            catch (DirectoryNotFoundException) { return; }
            throw new InvalidOperationException("missing manifests admitted");
        });
        foreach (var error in errors) Console.Error.WriteLine(error);
        Console.WriteLine($"HOST_SELF_TESTS executed={executed} passed={executed - errors.Count} failed={errors.Count} skipped=0");
        return errors.Count == 0 ? 0 : 1;
    }

    private sealed class StaticSuite(string id, IReadOnlyList<string> unitIds) : IValidationSuite
    {
        public string Id => id;
        public IReadOnlyList<string> UnitIds => unitIds;
        public Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken) =>
            throw new NotSupportedException("Coverage self-tests do not execute synthetic suites");
    }
}
