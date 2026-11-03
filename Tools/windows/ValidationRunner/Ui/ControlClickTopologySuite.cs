using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using GraphCode.Validation.Ui.Fixtures;
using GraphCode.Windows;

namespace GraphCode.Validation.Ui;

public sealed class ControlClickTopologySuite : IValidationSuite
{
    public string Id => "ui.control-click-topology";
    public IReadOnlyList<string> UnitIds { get; } = new[]
    {
        "ui.control-click.flat-root", "ui.control-click.nested-root",
        "ui.control-click.same-pid-unrelated-root", "ui.control-click.mismatched-parent",
        "ui.control-click.foreign-root"
    };

    public Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken)
    {
        var results = new List<UnitResult>();
        MethodInfo rootMethod = typeof(GraphCodeUiaGateState).GetMethod("RequireControlClickRoot", BindingFlags.NonPublic | BindingFlags.Static)
            ?? throw new InvalidOperationException("Actual production control root validation missing");
        MethodInfo bridgeMethod = typeof(GraphCodeUiaGateState).GetMethod("ResolvesToControl", BindingFlags.NonPublic | BindingFlags.Static)
            ?? throw new InvalidOperationException("Actual production control hit bridge missing");
        string cls = "GraphCodeControlTopology" + Guid.NewGuid().ToString("N");
        PromptLookupFixture.Register(cls);
        var roots = new List<IntPtr>();
        try
        {
            GraphCodeUiaGateState.RetainProcess(Process.GetCurrentProcess());
            IntPtr root = PromptLookupFixture.Create(cls, IntPtr.Zero, 0);
            roots.Add(root);
            IntPtr unrelated = PromptLookupFixture.Create(cls, IntPtr.Zero, 0);
            roots.Add(unrelated);
            IntPtr flat = PromptLookupFixture.Create("BUTTON", root, 101);
            IntPtr viewport = PromptLookupFixture.Create("STATIC", root, 102);
            IntPtr parent = PromptLookupFixture.Create("STATIC", viewport, 103);
            IntPtr nested = PromptLookupFixture.Create("BUTTON", parent, 104);
            IntPtr sibling = PromptLookupFixture.Create("STATIC", viewport, 105);
            IntPtr ResolveRoot(IntPtr target, IntPtr owner) => (IntPtr)rootMethod.Invoke(null, new object[] { target, owner })!;
            void Check(string id, Action assertion)
            {
                cancellationToken.ThrowIfCancellationRequested();
                try
                {
                    assertion();
                    results.Add(new UnitResult(id, UnitStatus.Passed, 1,
                        "Real hidden Win32 flat/nested topology; actual production root/bridge; no activation, cursor movement or injected input"));
                }
                catch (Exception failure) { results.Add(new UnitResult(id, UnitStatus.Failed, 1, failure.ToString())); }
            }
            Check(UnitIds[0], () => ActivationCases.Require(ResolveRoot(flat, root) == root &&
                !PromptLookupFixture.IsWindowVisible(root), "Flat control did not retain its exact hidden root"));
            Check(UnitIds[1], () => ActivationCases.Require(parent != root && ResolveRoot(nested, parent) == root &&
                !PromptLookupFixture.IsWindowVisible(root), "Nested content child was mistaken for the exact root"));
            void Refuse(IntPtr owner)
            {
                bool refused = false;
                try { ResolveRoot(nested, owner); }
                catch (TargetInvocationException failure) when (failure.InnerException is InvalidOperationException error &&
                    error.Message == "Control click target lost its exact parent/root ownership; no input was injected") { refused = true; }
                var point = new UiaInputSafety.ScreenPoint { X = 5, Y = 5 };
                bool hit = (bool)bridgeMethod.Invoke(null, new object[] { nested, owner, point })!;
                ActivationCases.Require(refused && !hit, "Invalid owner reached the actual control input boundary");
            }
            Check(UnitIds[2], () => Refuse(unrelated));
            Check(UnitIds[3], () => Refuse(sibling));
            Check(UnitIds[4], () => Refuse(ControlClickTopologyFixture.GetDesktopWindow()));
        }
        finally
        {
            foreach (IntPtr root in roots)
                if (!PromptLookupFixture.DestroyWindow(root)) throw new InvalidOperationException("Owned control topology fixture cleanup failed");
        }
        return Task.FromResult<IReadOnlyList<UnitResult>>(results);
    }

    public static void RunPhysicalFixtures()
    {
        Console.WriteLine($"CONTROL_CLICK_FIXTURE_PID={Environment.ProcessId}");
        foreach (bool nested in new[] { false, true })
        {
            using var fixture = new ControlClickTopologyFixture(nested);
            fixture.Foreground();
            if (nested)
            {
                var bridge = typeof(GraphCodeUiaGateState).GetMethod("ResolvesToControl", BindingFlags.NonPublic | BindingFlags.Static)!;
                var point = new UiaInputSafety.ScreenPoint { X = (fixture.Bounds[0] + fixture.Bounds[2]) / 2,
                    Y = (fixture.Bounds[1] + fixture.Bounds[3]) / 2 };
                bool Resolve(IntPtr owner) => fixture.Run(() => (bool)bridge.Invoke(null, new object[] { fixture.Target, owner, point })!);
                ActivationCases.Require(Resolve(fixture.Parent) && Resolve(fixture.Root),
                    "Measured parent and verified exact root must resolve through the same immediate parent");
                ActivationCases.Require(!Resolve(fixture.Unrelated) && !Resolve(fixture.Sibling) &&
                    !Resolve(ControlClickTopologyFixture.GetDesktopWindow()) && fixture.ClickCount == 0,
                    "Unrelated root or mismatched parent was accepted before any input");
            }
            var result = fixture.Run(() => GraphCodeUiaGateState.ClickScreenPoint(fixture.Target));
            ActivationCases.Require(result is not null && result.HitTarget && result.SameTopLevel,
                "Actual control click did not preserve the owned target/root hit");
            fixture.ExpectClick();
            Console.WriteLine($"CONTROL_CLICK_ACTUAL_TOPOLOGY={(nested ? "nested" : "flat")} TARGET_CLICKS=1");
        }
    }
}
