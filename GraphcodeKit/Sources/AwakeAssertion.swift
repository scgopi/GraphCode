import Foundation
#if canImport(Darwin)
  import IOKit.pwr_mgt
#endif

/// Keeps the Mac from falling asleep while loops are actually running — the power
/// assertion `caffeinate -i` takes, held by the daemon rather than by a person at a
/// terminal.
///
/// It lives in `graphcoded` because that is the process that knows. A loop's session
/// outlives every window (`ZmxSessionLauncher`), so the app is not running when this
/// matters most: the lid comes down on a machine with six loops mid-turn and the work
/// stops until someone wakes it. The app cannot hold an assertion for work it is not
/// present for.
///
/// Deliberately the *idle* assertion and nothing stronger. It stops the system sleeping
/// on its own while there is work in flight; it does not keep the display awake, does not
/// override a lid close, and does not survive a human choosing Sleep from the menu. An
/// idle machine with no loops running still sleeps exactly as it always did — the
/// assertion is dropped the moment the last loop stops, not held for the daemon's
/// lifetime.
///
/// Behind `GraphcodeSettings.keepsMacAwakeWhileLoopsRun`, off by default: a background
/// process that quietly stops a laptop sleeping is not something to switch on for
/// somebody.
public actor AwakeAssertion {
  public static let shared = AwakeAssertion()

  #if canImport(Darwin)
    private var held: IOPMAssertionID?
  #else
    // No IOKit power assertions on Linux: nothing is ever held, `apply` does nothing,
    // and the daemon's call site stays platform-independent.
    private var held: Void?
  #endif

  /// Whether the machine should be kept awake right now. Pure, and separate from the
  /// IOKit call, because the interesting part is the decision: a setting that is off
  /// beats any number of running loops, and no running loops beats the setting.
  public static func shouldStayAwake(runningLoops: Int, enabled: Bool) -> Bool {
    enabled && runningLoops > 0
  }

  /// Takes or drops the assertion to match `shouldHold`. Idempotent: holding while held
  /// and releasing while released both do nothing, so the caller can simply state the
  /// current answer on every graph change without tracking edges itself.
  public func apply(shouldHold: Bool, runningLoops: Int) {
    #if canImport(Darwin)
      if shouldHold {
        guard held == nil else { return }
        var identifier = IOPMAssertionID(0)
        let reason =
          runningLoops == 1
          ? "a GraphCode loop is running" : "\(runningLoops) GraphCode loops are running"
        let result = IOPMAssertionCreateWithName(
          kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
          IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &identifier)
        // A refused assertion is not worth failing anything over: the machine sleeps as it
        // did before this existed, which is the behaviour every release until now had.
        guard result == kIOReturnSuccess else { return }
        held = identifier
      } else {
        guard let identifier = held else { return }
        held = nil
        IOPMAssertionRelease(identifier)
      }
    #endif
  }

  /// Whether an assertion is currently held — for the daemon's own logging and for a test
  /// that wants to know without reading `pmset`.
  public var isHolding: Bool { held != nil }
}
