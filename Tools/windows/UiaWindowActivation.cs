using System;

namespace GraphCode.Windows {
  public struct UiaActivationCallResult {
    public readonly bool Succeeded;
    public readonly int Error;

    public UiaActivationCallResult(bool succeeded, int error) {
      Succeeded = succeeded;
      Error = error;
    }
  }

  public interface IUiaWindowActivationOperations {
    uint WindowProcessId(IntPtr window);
    bool IsRetainedProcessAlive(uint processId);
    void ShowWindow(IntPtr window, int command);
    UiaActivationCallResult BringWindowToTop(IntPtr window);
    UiaActivationCallResult SetForegroundWindow(IntPtr window);
    bool IsForegroundWindow(IntPtr window);
  }

  public static class UiaWindowActivation {
    public static bool ActivateWindow(
      IUiaWindowActivationOperations operations, IntPtr window, out string diagnostic
    ) {
      if (operations == null) throw new ArgumentNullException(nameof(operations));
      uint expectedProcessId = operations.WindowProcessId(window);
      if (window == IntPtr.Zero || !operations.IsRetainedProcessAlive(expectedProcessId)) {
        diagnostic = "invalid target HWND or no retained live launch identity";
        return false;
      }
      operations.ShowWindow(window, 9);
      UiaActivationCallResult broughtToTop = operations.BringWindowToTop(window);
      UiaActivationCallResult foregroundSet = operations.SetForegroundWindow(window);
      bool observed = operations.IsForegroundWindow(window) &&
        operations.WindowProcessId(window) == expectedProcessId &&
        operations.IsRetainedProcessAlive(expectedProcessId);
      diagnostic = String.Format(
        "BringWindowToTop={0} GetLastError={1} SetForegroundWindow={2} GetLastError={3} observedOwnedForeground={4}; no synthetic keys or input-queue attachment",
        broughtToTop.Succeeded, broughtToTop.Succeeded ? 0 : broughtToTop.Error,
        foregroundSet.Succeeded, foregroundSet.Succeeded ? 0 : foregroundSet.Error, observed);
      return observed;
    }
  }
}
