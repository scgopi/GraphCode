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
  /// End the node's session for good. `projectPath` is what routes the kill to the
  /// right zmx: a remote project's session lives in another host's zmx daemon, and a
  /// kill spoken only to the local socket left remote sessions running forever after
  /// their node was stopped or deleted.
  public var terminate: @Sendable (LoopNode, String?) async -> Void
  /// Push text into a live session. The transport behind a `.message` edge — see
  /// `MessageBusClient`. Returns false when the backend can't accept mid-session input
  /// or the session isn't live. `projectPath` routes the send the same way `terminate`'s
  /// is routed: the local zmx has never heard of a remote loop's session, so every
  /// delivery to one failed (and staged) until the send learned to ride ssh.
  public var sendInput: @Sendable (LoopNode, String, String?) async -> Bool
  /// What the session is doing right now.
  public var presence: @Sendable (LoopNode) async -> PresenceReading
  /// What the backend says it has spent on this loop, or `nil` when it doesn't report.
  /// Never estimated — see `UsageSample`.
  public var usage: @Sendable (LoopNode) async -> UsageSample?
  /// What the session says it is doing right now, or `nil` when nothing reports it —
  /// see `LoopNode.activity`.
  public var activity: @Sendable (LoopNode) async -> String?

  public init(
    kind: CLISessionBackendKind,
    launch: @escaping @Sendable (LoopNode, String?) async -> Void,
    terminate: @escaping @Sendable (LoopNode, String?) async -> Void,
    sendInput: @escaping @Sendable (LoopNode, String, String?) async -> Bool,
    presence: @escaping @Sendable (LoopNode) async -> PresenceReading,
    usage: @escaping @Sendable (LoopNode) async -> UsageSample?,
    activity: @escaping @Sendable (LoopNode) async -> String? = { _ in nil }
  ) {
    self.kind = kind
    self.launch = launch
    self.terminate = terminate
    self.sendInput = sendInput
    self.presence = presence
    self.usage = usage
    self.activity = activity
  }
}

extension CLISessionBackend {
  /// The adapter every spiked backend shares, parameterized only by kind.
  ///
  /// All five operations go through `zmx`, which is what makes them work with no app
  /// running — and what makes them backend-*agnostic*: the session is a real detached
  /// PTY the daemon can start, inspect, type into, and kill whether it's running
  /// `claude`, `copilot`, or `codex`. What differs per backend is the launch command,
  /// and `ZmxSessionLauncher` already builds that from `node.backend`.
  ///
  /// This used to exist only as `claudeCode`, with Copilot and Codex still routed to
  /// `unspiked` from before they were wired — which made every daemon-side operation on
  /// their loops a silent no-op: a goal-based Copilot loop was created as a node that
  /// *looked* running but had no session until a human opened it, deleting one left its
  /// session alive forever, and message edges into one always failed.
  public static func zmxBacked(_ kind: CLISessionBackendKind) -> CLISessionBackend {
    CLISessionBackend(
      kind: kind,
      launch: { node, projectPath in
        await ZmxSessionLauncher.start(node, projectPath: projectPath)
      },
      terminate: { node, projectPath in
        await ZmxSessionLauncher.kill(node, projectPath: projectPath)
      },
      sendInput: { node, text, projectPath in
        await ZmxSessionLauncher.send(text, to: node, projectPath: projectPath)
      },
      // The one operation that is genuinely per-backend, because how a session can be
      // asked what it is doing is the thing the three CLIs differ on most. Claude Code
      // reports into its own label store through hooks graphcode installs; Copilot has no
      // hook mechanism at all and is read from the event log it writes regardless.
      presence: { node in
        switch kind {
        case .claudeCode: return await ZmxSessionLauncher.presence(of: node)
        case .copilotCLI: return await CopilotSessionLog.presence(of: node)
        case .codex: return await ZmxSessionLauncher.codexPresence(of: node)
        }
      },
      usage: { node in await ZmxSessionLauncher.usage(of: node) },
      activity: { node in await ZmxSessionLauncher.activity(of: node) }
    )
  }

  /// The reference backend — every other capability row is diffed against this one,
  /// since Claude Code is what graphcode itself is built in.
  public static let claudeCode = zmxBacked(.claudeCode)

  /// A backend graphcode knows the name of but has not been spiked against
  /// (docs/07-roadmap.md#phase-5--multi-backend).
  ///
  /// Every operation is a no-op that reports failure rather than a plausible-looking
  /// guess at the CLI's flags. An adapter that *looks* implemented but invokes a command
  /// nobody has run is worse than an honest stub: it turns "we haven't done this yet"
  /// into a silent runtime failure a user has to debug. All three current backends are
  /// spiked, so nothing reaches this today — it exists for the next backend added to the
  /// enum before anyone has run its CLI.
  public static func unspiked(_ kind: CLISessionBackendKind) -> CLISessionBackend {
    CLISessionBackend(
      kind: kind,
      launch: { _, _ in },
      terminate: { _, _ in },
      sendInput: { _, _, _ in false },
      presence: { _ in PresenceReading(presence: .absent, confidence: .reported) },
      usage: { _ in nil }
    )
  }

  /// Spiked backends share the zmx-backed adapter — the operations are session-level,
  /// not agent-level, so they never needed a per-backend implementation. `unspiked`
  /// remains the honest stub for any backend added to the enum before it's been run.
  public static func backend(for kind: CLISessionBackendKind) -> CLISessionBackend {
    kind.isSpiked ? zmxBacked(kind) : unspiked(kind)
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

  public static let terminateSession: @Sendable (LoopNode, String?) -> Void = { node, path in
    Task.detached { await backend(for: node).terminate(node, path) }
  }

  /// The `.message` transport `GraphStore` is wired with — routed through the *target's*
  /// backend, since it's the target's session being typed into.
  public static let deliverMessage: @Sendable (LoopNode, String, String?) async -> Bool = {
    node, text, path in
    await backend(for: node).sendInput(node, text, path)
  }

  /// The usage-reading hook `GraphStore` is wired with.
  public static let readUsage: @Sendable (LoopNode) async -> UsageSample? = { node in
    await backend(for: node).usage(node)
  }

  /// The activity-reading hook `GraphStore` is wired with.
  public static let readActivity: @Sendable (LoopNode) async -> String? = { node in
    await backend(for: node).activity(node)
  }

  /// The presence-reading hook `GraphStore` is wired with. The last missing link in a
  /// chain that was otherwise complete: `presence` was implemented on every adapter and
  /// called by nothing, so every surface had only `LoopState` to go on and a loop that
  /// had finished its turn read RUNNING until a human stopped it.
  public static let readPresence: @Sendable (LoopNode) async -> PresenceReading = { node in
    await backend(for: node).presence(node)
  }
}
