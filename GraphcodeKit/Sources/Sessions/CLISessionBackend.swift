import Foundation

/// The abstraction over Claude Code, Copilot CLI, and Codex —
/// docs/04-cli-backends.md#clisessionbackend-protocol.
///
/// Deliberately *not* a lowest-common-denominator facade. graphcode's stated non-goal is
/// abstracting away what makes each CLI different (docs/00-vision.md#non-goals); this
/// exists so the differences are addressable — `capabilities` is what lets a loop type
/// refuse a backend rather than silently degrade onto it.
///
/// A struct of closures rather than a Swift protocol, matching how the app's other
/// clients (`GitClient`, `OrchestratorClient`) are shaped: adapters are values that can
/// be swapped wholesale in a test without a stub type per backend.
///
/// **`launch` must work headlessly.** `graphcoded` calls it with no app window open at
/// all, so it can't assume a terminal view exists to attach to. Only `attach`/`detach`
/// may assume that; `launch`, `sendInput`, and `presence` may not
/// (docs/04-cli-backends.md#launch-must-work-headlessly-with-no-app-running).
public struct CLISessionBackend: Sendable {
  public let kind: CLISessionBackendKind
  public var capabilities: BackendCapabilities { kind.capabilities }

  /// Start (or adopt) the node's detached session. Idempotent: a session that already
  /// exists is joined, never restarted.
  ///
  /// `projectPath` is where the session should open when the node has no worktree of
  /// its own. Without it a daemon-launched loop inherits `graphcoded`'s directory,
  /// which is `/` under launchd — nowhere near the project the loop belongs to.
  public var launch: @Sendable (LoopNode, String?) async -> Void
  /// End the node's session for good.
  public var terminate: @Sendable (LoopNode) async -> Void
  /// Push text into a live session. The transport behind a `.message` edge — see
  /// `MessageBusClient`. Returns false when the backend can't accept mid-session input
  /// or the session isn't live.
  public var sendInput: @Sendable (LoopNode, String) async -> Bool
  /// What the session is doing right now.
  public var presence: @Sendable (LoopNode) async -> PresenceReading
  /// What the backend says it has spent on this loop, or `nil` when it doesn't report.
  /// Never estimated — see `UsageSample`.
  public var usage: @Sendable (LoopNode) async -> UsageSample?

  public init(
    kind: CLISessionBackendKind,
    launch: @escaping @Sendable (LoopNode, String?) async -> Void,
    terminate: @escaping @Sendable (LoopNode) async -> Void,
    sendInput: @escaping @Sendable (LoopNode, String) async -> Bool,
    presence: @escaping @Sendable (LoopNode) async -> PresenceReading,
    usage: @escaping @Sendable (LoopNode) async -> UsageSample?
  ) {
    self.kind = kind
    self.launch = launch
    self.terminate = terminate
    self.sendInput = sendInput
    self.presence = presence
    self.usage = usage
  }
}

extension CLISessionBackend {
  /// The reference backend — every other capability row is diffed against this one,
  /// since Claude Code is what graphcode itself is built in.
  ///
  /// All four operations go through `zmx`, which is what makes them work with no app
  /// running: the session is a real detached PTY the daemon can start, inspect, and type
  /// into whether or not anything is attached to it.
  public static let claudeCode = CLISessionBackend(
    kind: .claudeCode,
    launch: { node, projectPath in
      await ZmxSessionLauncher.start(node, projectPath: projectPath)
    },
    terminate: { node in await ZmxSessionLauncher.kill(node) },
    sendInput: { node, text in await ZmxSessionLauncher.send(text, to: node) },
    presence: { node in await ZmxSessionLauncher.presence(of: node) },
    usage: { node in await ZmxSessionLauncher.usage(of: node) }
  )

  /// A backend graphcode knows the name of but has not been spiked against
  /// (docs/07-roadmap.md#phase-5--multi-backend).
  ///
  /// Every operation is a no-op that reports failure rather than a plausible-looking
  /// guess at the CLI's flags. An adapter that *looks* implemented but invokes a command
  /// nobody has run is worse than an honest stub: it turns "we haven't done this yet"
  /// into a silent runtime failure a user has to debug. `canHost` already keeps these
  /// backends to turn-based loops, where a human drives the session directly.
  public static func unspiked(_ kind: CLISessionBackendKind) -> CLISessionBackend {
    CLISessionBackend(
      kind: kind,
      launch: { _, _ in },
      terminate: { _ in },
      sendInput: { _, _ in false },
      presence: { _ in PresenceReading(presence: .absent, confidence: .reported) },
      usage: { _ in nil }
    )
  }

  public static func backend(for kind: CLISessionBackendKind) -> CLISessionBackend {
    switch kind {
    case .claudeCode: return .claudeCode
    case .copilotCLI, .codex: return .unspiked(kind)
    }
  }

  /// The adapter a node's own `backend` selects. One lookup so no call site has to
  /// remember the mapping.
  public static func backend(for node: LoopNode) -> CLISessionBackend {
    backend(for: node.backend)
  }

  // MARK: - The hooks `GraphStore` is wired with

  /// Fire-and-forget, matching `GraphStore.onEnsureSession`'s synchronous shape — the
  /// caller is an actor applying a graph command and shouldn't block on process
  /// spawning. Routing through `backend(for:)` is what makes a node's chosen backend
  /// mean something at runtime rather than only in the picker.
  public static let ensureSession: @Sendable (LoopNode, String?) -> Void = { node, path in
    Task.detached { await backend(for: node).launch(node, path) }
  }

  public static let terminateSession: @Sendable (LoopNode) -> Void = { node in
    Task.detached { await backend(for: node).terminate(node) }
  }

  /// The `.message` transport `GraphStore` is wired with — routed through the *target's*
  /// backend, since it's the target's session being typed into.
  public static let deliverMessage: @Sendable (LoopNode, String) async -> Bool = { node, text in
    await backend(for: node).sendInput(node, text)
  }

  /// The usage-reading hook `GraphStore` is wired with.
  public static let readUsage: @Sendable (LoopNode) async -> UsageSample? = { node in
    await backend(for: node).usage(node)
  }
}
