import Foundation

/// What a human has chosen about how graphcode behaves — how it starts sessions, and how
/// its window looks.
///
/// Everything here was hardcoded first and made a setting second, which is the right order
/// — but only the parts a person could reasonably want different are here. A settings
/// screen full of knobs nobody turns is its own kind of failure.
///
/// Read by the **daemon**, not just the app: `graphcoded` is what builds a session's
/// launch command, so these live in a file both processes read (`LaunchSettingsStore`)
/// rather than in the app's `UserDefaults`, which the daemon cannot see.
public struct GraphcodeSettings: Codable, Equatable, Sendable {
  /// How much a Claude Code session may do without stopping to ask.
  ///
  /// `plan` is deliberately absent even though the CLI offers it: a loop in plan mode
  /// produces a plan and changes nothing, so every loop in the graph would resolve having
  /// done no work. That isn't a preference, it's a broken graph.
  public enum ClaudePermissionMode: String, Codable, CaseIterable, Sendable {
    /// The CLI's interactive default. Honest, and unusable for a loop nobody is watching.
    case manual
    case acceptEdits
    /// graphcode's default: the ordinary work of a coding session, guardrails intact.
    case auto
    case dontAsk
    /// No checks at all. Offered because it's the user's machine and their call.
    case bypassPermissions

    public var displayName: String {
      switch self {
      case .manual: return "Ask every time"
      case .acceptEdits: return "Accept file edits"
      case .auto: return "Auto (recommended)"
      case .dontAsk: return "Don't ask"
      case .bypassPermissions: return "Bypass all checks"
      }
    }

    /// What a human needs to know before choosing it, in one line.
    public var explanation: String {
      switch self {
      case .manual:
        return "The CLI's own default. An unattended loop will wait at the first prompt "
          + "forever while the graph reports it as running."
      case .acceptEdits:
        return "File edits go through; other tools still ask."
      case .auto:
        return "Approves the ordinary work of a coding session and keeps its guardrails."
      case .dontAsk:
        return "Stops asking, without removing the checks themselves."
      case .bypassPermissions:
        return "Every permission check is skipped. A loop can do anything you can."
      }
    }

    public var arguments: [String] { ["--permission-mode", rawValue] }
  }

  /// The same choice for Copilot CLI, whose flags don't map one-to-one.
  public enum CopilotPermissions: String, Codable, CaseIterable, Sendable {
    case ask
    /// Tools run without confirmation — the nearest thing to Claude Code's `auto`.
    case allowTools
    /// `--allow-all`: also disables path verification and URL checks, so a session can
    /// reach outside the project it was started in.
    case allowEverything

    public var displayName: String {
      switch self {
      case .ask: return "Ask every time"
      case .allowTools: return "Allow tools (recommended)"
      case .allowEverything: return "Allow everything"
      }
    }

    public var explanation: String {
      switch self {
      case .ask:
        return "Copilot's own default. An unattended loop will wait at the first prompt."
      case .allowTools:
        return "Tools run without confirmation, still scoped to this project's paths."
      case .allowEverything:
        return "Also disables path and URL checks — a session can reach outside the "
          + "project it was started in."
      }
    }

    public var arguments: [String] {
      switch self {
      case .ask: return []
      case .allowTools: return ["--allow-all-tools"]
      case .allowEverything: return ["--allow-all"]
      }
    }

    /// `--add-dir` for each directory a session legitimately needs to reach.
    ///
    /// Copilot gates **tools, paths and URLs separately**: `--allow-all-tools` lets it run
    /// a tool without asking and says nothing about *where* that tool may read or write.
    /// A session outside its working directory — a loop bound to a worktree needing the
    /// project, or any loop needing its briefing — is denied, which reads as the agent
    /// ignoring instructions rather than as a permission it was never given (issues #2
    /// and #4).
    ///
    /// Named directories rather than `--allow-all-paths`: the point is that a loop may
    /// reach the things graphcode pointed it at, not everything on the disk. Nothing to
    /// add under `.allowEverything`, which has already opened every path, and nothing
    /// under `.ask`, where a human is answering for each one anyway.
    public func readableDirectories(_ paths: [String]) -> [String] {
      guard self == .allowTools else { return [] }
      var seen: Set<String> = []
      return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
        .flatMap { ["--add-dir", $0] }
    }
  }

  /// Which backend a new loop starts on before anyone touches the picker.
  ///
  /// Only ever one graphcode can launch (`offerableAsDefault`). A default pointing at an
  /// unspiked backend would make every new loop start on something that can't run, which
  /// is a worse outcome than quietly correcting a value nobody can select in the UI
  /// anyway — it only arrives here by hand-editing the file or by downgrading.
  /// How much a Codex session may do without stopping to ask.
  ///
  /// Codex splits this across two flags rather than one: `--ask-for-approval` decides when
  /// it stops to ask, and `--sandbox` decides what it may touch when it doesn't. Setting
  /// only the first produces a session that never asks *and* can't write, which looks like
  /// a hung loop; they have to move together.
  public enum CodexApprovals: String, Codable, CaseIterable, Sendable {
    /// Codex's own default: it decides when to ask, and a human answers.
    case ask
    /// graphcode's default — never stops to ask, and may write inside its workspace.
    case workspace
    /// `--dangerously-bypass-approvals-and-sandbox`, which is exactly what it says.
    case unsandboxed

    public var displayName: String {
      switch self {
      case .ask: return "Ask when unsure"
      case .workspace: return "Workspace (recommended)"
      case .unsandboxed: return "No sandbox"
      }
    }

    public var explanation: String {
      switch self {
      case .ask:
        return "Codex's own default. An unattended loop will wait at the first prompt."
      case .workspace:
        return "Runs without asking, and may write inside the project it was given."
      case .unsandboxed:
        return "Skips every approval and the sandbox entirely — a loop can do anything "
          + "you can, anywhere."
      }
    }

    public var arguments: [String] {
      switch self {
      case .ask: return []
      case .workspace: return ["--ask-for-approval", "never", "--sandbox", "workspace-write"]
      case .unsandboxed: return ["--dangerously-bypass-approvals-and-sandbox"]
      }
    }

    /// `--add-dir` for each directory the loop's work spans. Codex sandboxes writes to its
    /// workspace, so a loop bound to a worktree cannot touch the repository it branched
    /// from unless told — the same gap that made Copilot look like it was ignoring
    /// instructions (issues #2 and #4).
    ///
    /// Nothing to add when there is no sandbox to widen, and nothing under `.ask`, where a
    /// human is answering for each one anyway.
    public func writableDirectories(_ paths: [String]) -> [String] {
      guard self == .workspace else { return [] }
      var seen: Set<String> = []
      return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
        .flatMap { ["--add-dir", $0] }
    }
  }

  public var codexApprovals: CodexApprovals

  public var defaultBackend: CLISessionBackendKind {
    didSet {
      if !defaultBackend.isSpiked { defaultBackend = oldValue.isSpiked ? oldValue : .claudeCode }
    }
  }
  public var claudePermissionMode: ClaudePermissionMode
  public var copilotPermissions: CopilotPermissions
  /// Whether a session is told it's part of a graph and how to add loops to it
  /// (`SessionBriefing`). Off means loops behave exactly as they did before briefings
  /// existed — they do the work they were given and never create anything.
  public var briefsSessionsAboutTheGraph: Bool

  /// How opaque the window is, 1 being solid. Stored as opacity rather than as
  /// "transparency" because every value then reads the same way it looks: 0.95 is a window
  /// you can *just* see through, where "95% transparent" would mean the opposite.
  ///
  /// Clamped on the way in, not merely in the slider: a settings file edited by hand
  /// shouldn't be able to make the window invisible and unrecoverable.
  public var windowOpacity: Double {
    didSet { windowOpacity = Self.clampedOpacity(windowOpacity) }
  }

  public static let minimumWindowOpacity = 0.5
  public static func clampedOpacity(_ value: Double) -> Double {
    min(max(value, minimumWindowOpacity), 1)
  }

  public init(
    defaultBackend: CLISessionBackendKind = .claudeCode,
    codexApprovals: CodexApprovals = .workspace,
    claudePermissionMode: ClaudePermissionMode = .auto,
    copilotPermissions: CopilotPermissions = .allowTools,
    briefsSessionsAboutTheGraph: Bool = true,
    windowOpacity: Double = 0.95
  ) {
    self.defaultBackend = defaultBackend.isSpiked ? defaultBackend : .claudeCode
    self.codexApprovals = codexApprovals
    self.claudePermissionMode = claudePermissionMode
    self.copilotPermissions = copilotPermissions
    self.briefsSessionsAboutTheGraph = briefsSessionsAboutTheGraph
    self.windowOpacity = Self.clampedOpacity(windowOpacity)
  }

  /// Decoding tolerates a file written by an older or newer graphcode: a missing key takes
  /// its default rather than failing the whole read, because the alternative is a settings
  /// file that silently reverts everything the moment one field is added.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let storedBackend =
      try container.decodeIfPresent(CLISessionBackendKind.self, forKey: .defaultBackend)
      ?? .claudeCode
    defaultBackend = storedBackend.isSpiked ? storedBackend : .claudeCode
    codexApprovals =
      try container.decodeIfPresent(CodexApprovals.self, forKey: .codexApprovals) ?? .workspace
    claudePermissionMode =
      try container.decodeIfPresent(ClaudePermissionMode.self, forKey: .claudePermissionMode)
      ?? .auto
    copilotPermissions =
      try container.decodeIfPresent(CopilotPermissions.self, forKey: .copilotPermissions)
      ?? .allowTools
    briefsSessionsAboutTheGraph =
      try container.decodeIfPresent(Bool.self, forKey: .briefsSessionsAboutTheGraph) ?? true
    windowOpacity = Self.clampedOpacity(
      try container.decodeIfPresent(Double.self, forKey: .windowOpacity) ?? 0.95)
  }
}
