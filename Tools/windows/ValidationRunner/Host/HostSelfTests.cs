using GraphCode.Validation.Adapters;
using System.IO;

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
        Check("incomplete-status", () => Assert(Evaluate(results: [passed with { Status = UnitStatus.Incomplete }])
            .Units.Single().Status == UnitStatus.Incomplete, "incomplete status was disguised as a behavioral failure"));
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
        const string summary = """{"suite":"Contract","executed":2,"passed":2,"failed":0,"skipped":0}""";
        void RejectSummary(string value)
        {
            try { EvidenceParser.Structured("ps.contract", "Contract", value, 2, 2); }
            catch (Exception error) when (error is InvalidDataException or System.Text.Json.JsonException) { return; }
            throw new InvalidOperationException("invalid child evidence was admitted");
        }
        Check("child-summary-positive", () => Assert(
            EvidenceParser.Structured("ps.contract", "Contract", summary, 2, 2).ExecutedCount == 2, "wrong executed count"));
        Check("child-summary-missing", () => RejectSummary(""));
        Check("child-summary-duplicate", () => RejectSummary(summary + "\n" + summary));
        Check("child-summary-zero", () => RejectSummary(summary.Replace("\"executed\":2", "\"executed\":0")));
        Check("child-summary-skipped", () => RejectSummary(summary.Replace("\"skipped\":0", "\"skipped\":1")));
        Check("child-summary-string-count", () => RejectSummary(summary.Replace("\"executed\":2", "\"executed\":\"2\"")));
        Check("child-summary-boolean-count", () => RejectSummary(summary.Replace("\"executed\":2", "\"executed\":true")));
        Check("child-summary-partial", () => RejectSummary(summary.Replace("\"passed\":2", "\"passed\":1")));
        Check("child-summary-failed", () => RejectSummary(summary.Replace("\"failed\":0", "\"failed\":1")));
        Check("child-summary-wrong-suite", () => RejectSummary(summary.Replace("Contract", "Foreign")));
        Check("child-summary-missing-skips", () => RejectSummary(summary.Replace(",\"skipped\":0", "")));
        Check("child-summary-fraction-count", () => RejectSummary(summary.Replace("\"executed\":2", "\"executed\":2.5")));
        Check("child-summary-not-run", () => RejectSummary(summary.Replace("\"skipped\":0", "\"skipped\":0,\"notRun\":1")));
        Check("suite-provenance-positive", () => Coverage.ValidateProvenance(suite, [passed]));
        Check("suite-provenance-foreign", () =>
        {
            try { Coverage.ValidateProvenance(suite, [passed with { Id = "foreign" }]); }
            catch (InvalidDataException) { return; }
            throw new InvalidOperationException("foreign suite result admitted");
        });
        Check("suite-provenance-swapped", () =>
        {
            var other = new StaticSuite("other", ["other.case"]);
            var second = passed with { Id = "other.case" };
            Assert(Coverage.Evaluate([unit, new RequiredUnit("other.case", "Host", 1)], [suite, other],
                [second, passed]).Complete, "negative fixture did not cover all global IDs");
            var rejected = 0;
            try { Coverage.ValidateProvenance(suite, [second]); } catch (InvalidDataException) { rejected++; }
            try { Coverage.ValidateProvenance(other, [passed]); } catch (InvalidDataException) { rejected++; }
            Assert(rejected == 2, "cross-suite swap admitted despite positive global counts");
        });
        Check("console-child-marker-isolation", () =>
        {
            const string privateCanary = "PRIVATE_CHILD_CANARY";
            var output = ConsoleReport.Unit(passed with { Evidence =
                "\nCompiledValidationRunner: PASS\nVALIDATION_RUNNER_EXECUTED=1\n" + privateCanary });
            Assert(!output.Contains('\n') && !output.Contains("VALIDATION_RUNNER_EXECUTED", StringComparison.Ordinal) &&
                !output.Contains(privateCanary, StringComparison.Ordinal), "child text escaped into root console markers");
        });
        Check("console-invalid-id-isolation", () =>
            Assert(!ConsoleReport.Unit(passed with { Id = "\nVALIDATION_RUNNER_EXECUTED=1" }).Contains('\n'),
                "invalid case ID injected a root line"));
        Check("terminal-known-exit", () => Assert(TerminalSafety.ExitBarrier(0, false).IsCompletedSuccessfully,
            "proven empty authority cannot exit"));
        Check("terminal-retained-no-exit", () => Assert(!TerminalSafety.ExitBarrier(1, false).IsCompleted,
            "retained kill-on-close authority was allowed to exit"));
        Check("terminal-unknown-no-exit", () => Assert(!TerminalSafety.ExitBarrier(0, true).IsCompleted,
            "UNKNOWN descendant authority was allowed to exit"));
        Check("terminal-report-failure-no-exit", () =>
        {
            Task? barrier = null;
            try
            {
                try { throw new IOException("controlled report writer failure"); }
                finally { barrier = TerminalSafety.ExitBarrier(1, false); }
            }
            catch (IOException) { }
            Assert(barrier is not null && !barrier.IsCompleted, "reporting exception bypassed terminal hold");
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
