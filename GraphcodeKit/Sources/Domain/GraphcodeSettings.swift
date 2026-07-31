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
  ///
  /// Copilot gates tools, paths, and URLs as three separate confirmations, and only
  /// YOLO (`--yolo`, its own name for `--allow-all`) covers all three. `allowTools` was
  /// the default on the reasoning that a loop's bargain covers its own folder and no
  /// further — and field experience overruled it: an unattended Copilot loop doing any
  /// real work (fetching a URL, touching a path beyond its granted directories) stalled
  /// at a confirmation dialog nobody was watching, reported as `running` the whole
  /// time. YOLO is what an unattended loop actually needs, so it's the default; the
  /// narrower modes remain for humans who plan to sit with their loops.
  ///
  /// Raw values predate the renaming and stay as they are — they're what saved
  /// settings files hold.
  public enum CopilotPermissions: String, Codable, CaseIterable, Sendable {
    case ask
    /// Tools only — Copilot still confirms URL access and unlisted paths.
    case allowTools
    /// Copilot's `--yolo`: tools, paths, and URLs all approved.
    case allowEverything

    public var displayName: String {
      switch self {
      case .ask: return "Ask every time"
      case .allowTools: return "Allow tools only"
      case .allowEverything: return "YOLO (recommended)"
      }
    }

    public var explanation: String {
      switch self {
      case .ask:
        return "Copilot's own default. An unattended loop will wait at the first prompt."
      case .allowTools:
        return "Tools run without confirmation, but URL access and paths beyond the "
          + "granted directories still prompt — an unattended loop can stall on a "
          + "dialog nobody sees."
      case .allowEverything:
        return "Copilot's --yolo: tools, paths, and URLs all approved — what an "
          + "unattended loop needs to run without a human at the pane."
      }
    }

    public var arguments: [String] {
      switch self {
      case .ask: return []
      case .allowTools: return ["--allow-all-tools"]
      // `--yolo` and `--allow-all` are the same flag; emitted under the name Copilot
      // itself promotes, so what appears in `ps` matches what its docs say.
      case .allowEverything: return ["--yolo"]
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

  /// Whether graphcode picks a model for loops nobody chose one for.
  ///
  /// **Off by default.** On, an unpinned loop is routed by its type — a turn-based loop
  /// gets the capable tier, a time-based one the fast tier (`LoopType.defaultModelTier`).
  /// Off, no `--model` is passed at all and the backend runs on whatever `claude`,
  /// `copilot` or `codex` is already configured to use.
  ///
  /// This was unconditional routing until issue #10: every loop created in the app left
  /// `modelTier` nil, so *every* loop got a model graphcode chose, silently overriding the
  /// one the human had set up in their own CLI. A guess worth offering, not worth
  /// imposing — so it became a setting, defaulted to the behaviour people expected.
  public var autoSelectsModel: Bool

  // There is deliberately no window-opacity setting here any more. graphcode used to own
  // one and apply it as `NSWindow.alphaValue`, which fades the whole window — terminal
  // text included — rather than only the background behind it. Ghostty already has
  // `background-opacity`, which makes the background translucent and leaves the text
  // crisp, and a terminal's own config is where someone looks for this. A key left in an
  // older settings file is ignored.

  public init(
    defaultBackend: CLISessionBackendKind = .claudeCode,
    codexApprovals: CodexApprovals = .workspace,
    claudePermissionMode: ClaudePermissionMode = .auto,
    copilotPermissions: CopilotPermissions = .allowEverything,
    briefsSessionsAboutTheGraph: Bool = true,
    autoSelectsModel: Bool = false
  ) {
    self.defaultBackend = defaultBackend.isSpiked ? defaultBackend : .claudeCode
    self.codexApprovals = codexApprovals
    self.claudePermissionMode = claudePermissionMode
    self.copilotPermissions = copilotPermissions
    self.briefsSessionsAboutTheGraph = briefsSessionsAboutTheGraph
    self.autoSelectsModel = autoSelectsModel
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
      ?? .allowEverything
    briefsSessionsAboutTheGraph =
      try container.decodeIfPresent(Bool.self, forKey: .briefsSessionsAboutTheGraph) ?? true
    // Absent in files written before the setting existed, and those loops were all being
    // routed by graphcode. They take the new default — off — which is the point of #10:
    // the fix has to reach people who already have a settings file, not just new ones.
    autoSelectsModel =
      try container.decodeIfPresent(Bool.self, forKey: .autoSelectsModel) ?? false
  }
}
