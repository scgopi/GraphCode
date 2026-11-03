using GraphCode.Validation.Adapters;
using System.IO;
using System.Text.Json;

namespace GraphCode.Validation.Host;

public static class HostSelfTests
{
    public static IValidationSuite CreateSuite() => new AdmissionSuite();

    public static int Run(Action<int, int>? completed = null)
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
        Check("normal-full-mode", () => Assert(Coverage.ForInvocation(Evaluate(), []).Complete &&
            Coverage.ForInvocation(Evaluate(), []).FullInvocation, "normal complete invocation rejected"));
        Check("filtered-never-full-mode", () => Assert(!Coverage.ForInvocation(Evaluate(), ["test"]).Complete &&
            !Coverage.ForInvocation(Evaluate(), ["test"]).FullInvocation,
            "a selected invocation was admitted as canonical proof even with every unit passed"));
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
            var output = ConsoleReport.Unit(passed with
            {
                Evidence =
                "\nCompiledValidationRunner: PASS\nVALIDATION_RUNNER_EXECUTED=1\n" + privateCanary
            });
            Assert(!output.Contains('\n') && !output.Contains("VALIDATION_RUNNER_EXECUTED", StringComparison.Ordinal) &&
                !output.Contains(privateCanary, StringComparison.Ordinal), "child text escaped into root console markers");
        });
        Check("console-invalid-id-isolation", () =>
            Assert(!ConsoleReport.Unit(passed with { Id = "\nVALIDATION_RUNNER_EXECUTED=1" }).Contains('\n'),
                "invalid case ID injected a root line"));
        Check("console-safe-failure-classification", () =>
        {
            var safe = ConsoleReport.SuiteFailure("test.suite", "System.InvalidOperationException");
            Assert(safe.Contains("id=test.suite exception=System.InvalidOperationException", StringComparison.Ordinal),
                "safe suite/type classification was lost");
            var injected = ConsoleReport.SuiteFailure("test\nPRIVATE_CANARY", "type\nVALIDATION_RUNNER_EXECUTED=1");
            Assert(!injected.Contains('\n') && !injected.Contains("PRIVATE_CANARY", StringComparison.Ordinal) &&
                !injected.Contains("VALIDATION_RUNNER_EXECUTED", StringComparison.Ordinal), "failure classification leaked raw payload");
            foreach (var newline in new[] { "\n", "\r", "\r\n" })
            {
                var terminal = ConsoleReport.SuiteFailure("test.suite" + newline, "System.Exception" + newline);
                Assert(!terminal.Contains('\n') && !terminal.Contains('\r') &&
                    !ConsoleReport.ValidId("test.suite" + newline), "terminal newline bypassed failure classification");
            }
        });
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
        Check("capture-expected-negative-diagnostics", () =>
        {
            const string root = "D:\\owned\\suite";
            const string selector = "CAP_TRACE_FAILURE command=CapSelectorRefusal: Cannot find an overload for \"ToInt64\" and the argument count: \"0\".";
            var journal = "JournalObservationFailure while reporting JournalUnavailable: JournalObservationFailure: " +
                "Exception calling \"Open\" with \"4\" argument(s): \"Access to the path 'D:\\owned\\suite\\manifest-creation-budget\\snapshots' is denied.\"";
            var text = selector + "\n" + selector + "\n" + journal + "\n";
            Assert(EvidenceParser.CaptureDiagnostics(text, root), "known controlled refusals were rejected");
            Assert(!EvidenceParser.CaptureDiagnostics(text + "unexpected error\n", root), "unexpected diagnostic was admitted");
            Assert(!EvidenceParser.CaptureDiagnostics(text.Replace("D:\\owned", "D:\\foreign"), root), "foreign-path diagnostic was admitted");
        });
        Check("registry-positive", () => Assert(Coverage.RegistryErrors([unit], [suite]).Count == 0,
            "valid registry rejected before execution"));
        Check("registry-duplicate-preflight", () => Assert(Coverage.RegistryErrors([unit], [suite, suite]).Count > 0,
            "duplicate executors not rejected before execution"));
        var compositeDirectory = Path.Combine(Path.GetTempPath(), "gc-composite-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(compositeDirectory);
        var mapPath = Path.Combine(compositeDirectory, "map.json");
        try
        {
            var aggregate = new RequiredUnit("test.aggregate", "Host", 1, ["group"], 1,
                ["test.case"], 1, "map.json");
            var template = new CompositeTemplate("source-1", ["test.case"], 1);
            CoverageReport Composite(IReadOnlyList<UnitResult>? observations = null, RequiredUnit? declaration = null,
                IReadOnlyList<CompositeTemplate>? templates = null, IReadOnlyList<IValidationSuite>? registry = null)
            {
                File.WriteAllText(mapPath, JsonSerializer.Serialize(new CompositeSourceMap(templates ?? [template]), Coverage.JsonOptions));
                return Coverage.Evaluate([unit, declaration ?? aggregate], registry ?? [suite],
                    observations ?? [passed with { Groups = ["group"] }], sourceDirectory: compositeDirectory);
            }
            Check("composite-positive", () => Assert(Composite().Complete, "complete independently mapped proof rejected"));
            Check("composite-not-double-counted", () =>
            {
                var report = Composite();
                Assert(report.ActualExecutedCount == 1 && report.DerivedProofCount == 1,
                    "derived composite proof was counted again as actual test execution");
            });
            Check("composite-missing", () => Assert(!Composite(observations: []).Complete, "missing dependency admitted"));
            Check("composite-duplicate", () => Assert(!Composite(observations: [passed, passed]).Complete, "duplicate dependency admitted"));
            Check("composite-skipped", () => Assert(!Composite(observations: [passed with { Status = UnitStatus.Skipped }]).Complete, "skipped dependency admitted"));
            Check("composite-zero", () => Assert(!Composite(observations: [passed with { ExecutedCount = 0 }]).Complete, "zero dependency admitted"));
            Check("composite-unimplemented", () => Assert(!Composite(registry: []).Complete, "unimplemented dependency admitted"));
            Check("composite-source-count", () => Assert(!Composite(declaration: aggregate with { SourceTemplateCount = 2 }).Complete, "missing original source template admitted"));
            Check("composite-map-duplicate", () => Assert(!Composite(declaration: aggregate with { SourceTemplateCount = 2 },
                templates: [template, template]).Complete, "duplicate source mapping admitted"));
            Check("composite-expanded-count", () => Assert(!Composite(templates: [template with { ExpectedCount = 2 }]).Complete, "wrong expanded original count admitted"));
            Check("composite-unknown-dependency", () => Assert(!Composite(declaration: aggregate with { CompositeOf = ["missing"] }).Complete, "unknown dependency admitted"));
            Check("composite-submitted-proof", () => Assert(!Composite(observations: [passed, passed with { Id = "test.aggregate" }]).Complete, "caller-submitted composite admitted"));
            Check("composite-groups", () => Assert(!Composite(observations: [passed]).Complete, "missing measured group admitted"));
            Check("composite-map-escape", () => Assert(!Composite(declaration: aggregate with { SourceMap = "..\\outside.json" }).Complete, "escaped source map admitted"));
        }
        finally
        {
            File.Delete(mapPath);
            Directory.Delete(compositeDirectory, false);
        }
        foreach (var error in errors) Console.Error.WriteLine(error);
        Console.WriteLine($"HOST_SELF_TESTS executed={executed} passed={executed - errors.Count} failed={errors.Count} skipped=0");
        completed?.Invoke(executed, errors.Count);
        return errors.Count == 0 ? 0 : 1;
    }

    private sealed class AdmissionSuite : IValidationSuite
    {
        public string Id => "host.admission-guards";
        public IReadOnlyList<string> UnitIds => [Id];
        public Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var executed = 0;
            var failed = 0;
            var exitCode = Run((count, failures) => { executed = count; failed = failures; });
            IReadOnlyList<UnitResult> results = [new UnitResult(Id,
                exitCode == 0 ? UnitStatus.Passed : UnitStatus.Failed, executed,
                $"Actual host admission/marker/composite/terminal controls: executed={executed}; failed={failed}; skipped=0")];
            return Task.FromResult(results);
        }
    }

    private sealed class StaticSuite(string id, IReadOnlyList<string> unitIds) : IValidationSuite
    {
        public string Id => id;
        public IReadOnlyList<string> UnitIds => unitIds;
        public Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken) =>
            throw new NotSupportedException("Coverage self-tests do not execute synthetic suites");
    }
}
