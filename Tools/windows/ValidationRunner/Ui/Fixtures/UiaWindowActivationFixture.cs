using System;
using System.Collections.Generic;
using GraphCode.Windows;

namespace GraphCode.Validation.Ui.Fixtures {
  public sealed class UiaWindowActivationFixture : IUiaWindowActivationOperations {
    public string LastActivationDiagnostic = "not attempted";
    public int GlobalKeys, Attachments, Mutations, OwnershipChecks;
    public bool Acquire, Owned;
    public IntPtr Foreground;
    private readonly List<string> calls = new List<string>();
    public string Calls { get { return String.Join(",", calls); } }

    public void Reset(bool acquire, bool owned) {
      GlobalKeys = Attachments = Mutations = OwnershipChecks = 0;
      Acquire = acquire;
      Owned = owned;
      Foreground = new IntPtr(99);
      LastActivationDiagnostic = "not attempted";
      calls.Clear();
    }

    public bool ActivateWindow(IntPtr window) {
      return UiaWindowActivation.ActivateWindow(this, window, out LastActivationDiagnostic);
    }

    public uint WindowProcessId(IntPtr window) {
      calls.Add("pid");
      return window == new IntPtr(10) ? 123u : window == IntPtr.Zero ? 0u : 999u;
    }

    public bool IsRetainedProcessAlive(uint processId) {
      calls.Add("owner");
      OwnershipChecks++;
      return Owned && processId == 123;
    }

    public void ShowWindow(IntPtr window, int command) {
      if (window != new IntPtr(10) || command != 9) {
        throw new InvalidOperationException("Activation did not restore the expected owned window");
      }
      calls.Add("restore");
      Mutations++;
    }

    public UiaActivationCallResult BringWindowToTop(IntPtr window) {
      calls.Add("bring");
      Mutations++;
      return new UiaActivationCallResult(Acquire, 1400);
    }

    public UiaActivationCallResult SetForegroundWindow(IntPtr window) {
      calls.Add("set");
      Mutations++;
      if (Acquire) Foreground = window;
      return new UiaActivationCallResult(Acquire, 5);
    }

    public bool IsForegroundWindow(IntPtr window) {
      calls.Add("foreground");
      return window != IntPtr.Zero && Foreground == window;
    }
  }
}
