using System;
using GraphCode.Validation.Ui.Fixtures;
using GraphCode.Windows;

namespace GraphCode.Validation.Ui;

public static class ActivationCases
{
    public static void ForegroundRefused() => ObserveAcquisition(false);
    public static void ForegroundAcquired() => ObserveAcquisition(true);

    private static void ObserveAcquisition(bool acquire)
    {
        var probe = new UiaWindowActivationFixture();
        probe.Reset(acquire, true);
        bool observed = probe.ActivateWindow(new IntPtr(10));
        Require(probe.GlobalKeys == 0 && probe.Attachments == 0,
            "UIA_ACTIVATION_RED: actual activation emitted global key events or input-queue attachments");
        Require(observed == acquire, "UIA activation did not verify acquired foreground");
        string expectedCalls = "pid,owner,restore,bring,set,foreground" + (acquire ? ",pid,owner" : "");
        string expectedDiagnostic = acquire
            ? "BringWindowToTop=True GetLastError=0 SetForegroundWindow=True GetLastError=0 observedOwnedForeground=True; no synthetic keys or input-queue attachment"
            : "BringWindowToTop=False GetLastError=1400 SetForegroundWindow=False GetLastError=5 observedOwnedForeground=False; no synthetic keys or input-queue attachment";
        Require(probe.Calls == expectedCalls && probe.Mutations == 3 &&
            probe.OwnershipChecks == (acquire ? 2 : 1) && probe.LastActivationDiagnostic == expectedDiagnostic,
            "UIA activation changed ownership/restore ordering or native return/error diagnostics");
        Require(typeof(IUiaWindowActivationOperations).Assembly ==
            probe.GetType().GetInterface(typeof(IUiaWindowActivationOperations).FullName!)!.Assembly,
            "Activation fixture does not implement the current production component interface");
    }

    public static void OwnershipRefused()
    {
        var probe = new UiaWindowActivationFixture();
        probe.Reset(true, false);
        Require(!probe.ActivateWindow(new IntPtr(10)) && probe.Mutations == 0 &&
            probe.Calls == "pid,owner" && probe.OwnershipChecks == 1 &&
            probe.GlobalKeys == 0 && probe.Attachments == 0 &&
            probe.LastActivationDiagnostic == "invalid target HWND or no retained live launch identity",
            "UIA activation changed a window without retained process authority");
    }

    public static void InvalidWindowRefused()
    {
        var probe = new UiaWindowActivationFixture();
        probe.Reset(true, true);
        Require(!probe.ActivateWindow(IntPtr.Zero) && probe.Mutations == 0 &&
            probe.Calls == "pid" && probe.OwnershipChecks == 0 &&
            probe.GlobalKeys == 0 && probe.Attachments == 0 &&
            probe.LastActivationDiagnostic == "invalid target HWND or no retained live launch identity",
            "UIA activation accepted an invalid window");
    }

    internal static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
