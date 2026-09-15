import Foundation

#if os(Windows)
  /// The Windows daemon build deliberately keeps session launch behind the
  /// frozen platform boundary. The ConPTY/zmx provider is supplied by the
  /// provider task; graph state and IPC remain fully usable without it.
  public enum CLISessionBackend {
    public static func ensureSession(_ node: LoopNode, projectPath: String?) {}
    public static func terminateSession(_ node: LoopNode, projectPath: String?) {}
    public static func deliverMessage(
      _ node: LoopNode,
      _ text: String,
      _ projectPath: String?
    ) async -> Bool {
      false
    }
    public static func readUsage(
      _ node: LoopNode,
      _ projectPath: String?
    ) async -> UsageSample? {
      nil
    }
    public static func readActivity(
      _ node: LoopNode,
      _ projectPath: String?
    ) async -> String? {
      nil
    }
    public static func readPresence(
      _ node: LoopNode,
      _ projectPath: String?
    ) async -> PresenceReading {
      .unknown
    }
  }

  public enum ShellPredicateEvaluator {
    public static func evaluate(_ predicate: ShellPredicate) async -> Bool {
      false
    }

    public static func capture(_ predicate: ShellPredicate) async -> String? {
      nil
    }
  }

  public enum PresenceHooks {
    public static func codexNotifyOverride(zmxPath: String) -> String {
      "echo graphcode-presence > nul"
    }
  }
#endif
