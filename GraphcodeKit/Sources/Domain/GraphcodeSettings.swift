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
    /// `--yolo` plus `--autopilot`: same permissions, and Copilot keeps prompting itself
    /// to continue instead of stopping at its first reply (issue #86). An addition, not
    /// the new default — autopilot changes how far a session runs, which is a choice a
    /// human should make deliberately.
    case yoloAutopilot

    public var displayName: String {
      switch self {
      case .ask: return "Ask every time"
      case .allowTools: return "Allow tools only"
      case .allowEverything: return "YOLO (recommended)"
      case .yoloAutopilot: return "YOLO + Autopilot"
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
      case .yoloAutopilot:
        return "Everything YOLO approves, and Copilot continues its own work "
          + "(--autopilot) instead of stopping at the first reply."
      }
    }

    public var arguments: [String] {
      switch self {
      case .ask: return []
      case .allowTools: return ["--allow-all-tools"]
      // `--yolo` and `--allow-all` are the same flag; emitted under the name Copilot
      // itself promotes, so what appears in `ps` matches what its docs say.
      case .allowEverything: return ["--yolo"]
      case .yoloAutopilot: return ["--yolo", "--autopilot"]
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
    /// Never stops to ask, and may write inside its workspace.
    case workspace
    /// `--dangerously-bypass-approvals-and-sandbox`, which is exactly what it says.
    case unsandboxed
    /// Codex's YOLO mode: bypass approvals and the sandbox entirely.
    case yolo

    public var displayName: String {
      switch self {
      case .ask: return "Ask when unsure"
      case .workspace: return "Workspace (recommended)"
      case .unsandboxed: return "No sandbox"
      case .yolo: return "YOLO (recommended)"
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
      case .yolo:
        return "Codex's --dangerously-bypass-approvals-and-sandbox: a loop can do anything "
          + "you can, anywhere."
      }
    }

    public var arguments: [String] {
      switch self {
      case .ask: return []
      case .workspace: return ["--ask-for-approval", "never", "--sandbox", "workspace-write"]
      case .unsandboxed: return ["--dangerously-bypass-approvals-and-sandbox"]
      case .yolo: return ["--dangerously-bypass-approvals-and-sandbox"]
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

  /// How much an OpenCode session may do without stopping to ask.
  ///
  /// One flag: `--auto` approves every permission not explicitly denied in the user's
  /// own `opencode.json`, which is exactly the bargain an unattended loop needs — their
  /// deny rules still hold, and nothing else stops to ask. OpenCode's own default asks
  /// per tool, which leaves an unattended loop at a dialog nobody sees.
  public enum OpenCodePermissions: String, Codable, CaseIterable, Sendable {
    case ask
    case auto

    public var displayName: String {
      switch self {
      case .ask: return "Ask every time"
      case .auto: return "Auto-approve (recommended)"
      }
    }

    public var explanation: String {
      switch self {
      case .ask:
        return "OpenCode's own default. An unattended loop will wait at the first prompt."
      case .auto:
        return "OpenCode's --auto: everything your own opencode.json doesn't deny is "
          + "approved — what an unattended loop needs to run without a human at the pane."
      }
    }

    public var arguments: [String] {
      switch self {
      case .ask: return []
      case .auto: return ["--auto"]
      }
    }
  }

  public var openCodePermissions: OpenCodePermissions

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

  /// Per-folder worktree hygiene, keyed by the project's canonical path — the same key
  /// the graph files use. Folders without an entry get `WorktreeHygienePolicy()`.
  public var worktreePolicies: [String: WorktreeHygienePolicy]

  public func worktreePolicy(forProjectPath path: String) -> WorktreeHygienePolicy {
    worktreePolicies[path] ?? WorktreeHygienePolicy()
  }

  /// Whether the window carries the activity strip along its bottom edge.
  ///
  /// **Off by default**, and the reason is the strip's own honesty: it is *derived*
  /// rather than logged (see the app's `ActivityFeed`), so it starts empty at every
  /// launch and knows only the state changes it has watched since. That is genuinely
  /// useful during a working session and genuinely thin the moment you relaunch, which
  /// is a trade worth offering and not worth imposing.
  public var showsActivityStrip: Bool

  /// Whether graphcode narrates what loops are doing — the summary rail's *producer*.
  ///
  /// **Off by default, and experimental.** Off, nothing reads a session's transcript, no
  /// node carries a `summary`, the rail shows no section and the card's live line falls
  /// back to what the loop was handed, exactly as it did before this existed. On, each
  /// working loop's transcript tail is read once per poll and folded into
  /// `LoopNode.summary`.
  ///
  /// It was on by default for exactly one release (0.1.37) and is opt-in again. The
  /// reading is cheap — a tail of a file the app already reads, no model, no subprocess —
  /// but a beat is a *claim* about what an agent is trying to do, and a claim that is
  /// confidently wrong is worse than the scrollback it replaces. A feature that makes
  /// claims on every loop's behalf earns its default rather than being handed one.
  ///
  /// Deliberately distinct from hiding the rail. Hiding is a view, and this is the
  /// reading: the design's own division, kept because the two would otherwise be one
  /// switch that quietly does two things.
  public var summarisesLoops: Bool

  /// Whether the export/import surfaces are offered at all — the context-menu items on
  /// loop cards, sidebar loop and folder rows, the canvas background's counterparts,
  /// and the CLI's `node export` / `graph export` / `node import` verbs.
  ///
  /// **On by default** since 0.1.40, after one release opt-in. It earns the default the
  /// summary rail couldn't (`summarisesLoops`): every surface is a menu item that does
  /// nothing until deliberately clicked — no claims made on a loop's behalf, no tokens
  /// spent, nothing running unattended. Off, none of those surfaces appear and the CLI
  /// verbs refuse with a pointer here; bundles already exported remain ordinary zips,
  /// importable again the moment this is back on. A settings file that explicitly says
  /// `false` — anyone who tried the experiment and turned it off — is preserved.
  public var sharesLoops: Bool

  /// Whether a small model may rewrite the current beat, on top of the free reading.
  ///
  /// **Off by default, and meaningless with `summarisesLoops` off.** The rail works
  /// without this: the beat is the agent's own sentence, taken off its transcript for
  /// nothing. What a model buys is the last edit — the design's plain past tense, ten
  /// words, tools turned back into intent — and it is the one part of the feature that
  /// costs money, so it is the one part behind its own switch.
  ///
  /// One `claude -p` / `copilot -p` / `codex exec` per *changed* beat of a *working* loop,
  /// at the fast tier, over one sentence and one line of evidence. It is its own process,
  /// so its tokens never land on the loop's own budget line, and every failure path leaves
  /// the derived beat exactly as it was — see `SummaryModelWriter`.
  public var summaryUsesModel: Bool

  /// Whether a small model draws each finished pass — the summary rail's *picture*.
  ///
  /// **Off by default, experimental, and meaningless with `summarisesLoops` off.** The rail
  /// above it says what a loop is doing in a sentence; this says it in a shape, when the
  /// work had one. On, the end of a pass sends that pass's beats to the fast tier and asks
  /// for a Mermaid flowchart or a Markdown table, which graphcode parses and draws natively
  /// (`MermaidBoardParser`) rather than through a web view it does not ship.
  ///
  /// Its own switch rather than a mode of `summaryUsesModel`, and the reason is what the two
  /// buy. That one spends a call to improve a sentence already on screen — the failure mode
  /// is a worse sentence. This one spends a call to draw a claim about the *shape* of a run,
  /// which is a larger claim than a sentence makes and is wrong in a way that looks
  /// authoritative: a flowchart of work that had no flow reads as fact. So it is opt-in on
  /// its own terms, the composer is told to answer `NONE` and expected to (most passes are),
  /// and the Mermaid it produced is always one click from being read as text.
  ///
  /// One call per *finished pass* of a working loop, at most `SummaryBoardComposer.maxPerTick`
  /// loops a tick — not one per beat, which is what `summaryUsesModel` costs and what makes
  /// this the cheaper of the two on a busy graph.
  public var visualisesSummaries: Bool

  /// Whether the daemon may drive time-based loops on its own timer — the experiment
  /// that tests the *opposite* of this project's founding cadence decision.
  ///
  /// **Off by default, and experimental.** Off, recurrence lives where it always has:
  /// inside the loop's own prompt as a `/loop` directive the agent runs on itself, and
  /// the daemon holds no timers (`GraphStore`'s header explains the headless-timer
  /// failure that decision came from). On, a time-based loop created with a heartbeat
  /// interval is *ticked by the daemon*: a `[graphcode] heartbeat` typed into its
  /// session each interval, missed ticks coalescing (a busy session is skipped, not
  /// queued), and stopping the loop cancels the timer instead of asking the session to
  /// dismantle its own cadence.
  ///
  /// Both models coexist deliberately — a heartbeat loop's prompt carries no `/loop`,
  /// an ordinary time loop's timer never exists — so the experiment can be judged
  /// side by side. Read fresh at every tick, so flipping this off silences existing
  /// heartbeat loops immediately without restarting anything.
  public var daemonHeartbeatEnabled: Bool

  /// Whether `graphcoded` keeps the Mac awake while any loop is running
  /// (`AwakeAssertion`). Off by default and deliberately so: a background process that
  /// quietly stops a machine sleeping is a thing to opt into, not to inherit from an
  /// update. Read fresh whenever the answer is recomputed, so switching it off drops the
  /// assertion without restarting anything.
  public var keepsMacAwakeWhileLoopsRun: Bool

  // There is deliberately no window-opacity setting here any more. graphcode used to own
  // one and apply it as `NSWindow.alphaValue`, which fades the whole window — terminal
  // text included — rather than only the background behind it. Ghostty already has
  // `background-opacity`, which makes the background translucent and leaves the text
  // crisp, and a terminal's own config is where someone looks for this. A key left in an
  // older settings file is ignored.

  public init(
    defaultBackend: CLISessionBackendKind = .claudeCode,
    codexApprovals: CodexApprovals = .yolo,
    openCodePermissions: OpenCodePermissions = .auto,
    claudePermissionMode: ClaudePermissionMode = .auto,
    copilotPermissions: CopilotPermissions = .allowEverything,
    briefsSessionsAboutTheGraph: Bool = true,
    autoSelectsModel: Bool = false,
    showsActivityStrip: Bool = false,
    sharesLoops: Bool = true,
    summarisesLoops: Bool = false,
    summaryUsesModel: Bool = false,
    visualisesSummaries: Bool = false,
    daemonHeartbeatEnabled: Bool = false,
    keepsMacAwakeWhileLoopsRun: Bool = false,
    worktreePolicies: [String: WorktreeHygienePolicy] = [:]
  ) {
    self.defaultBackend = defaultBackend.isSpiked ? defaultBackend : .claudeCode
    self.codexApprovals = codexApprovals
    self.openCodePermissions = openCodePermissions
    self.claudePermissionMode = claudePermissionMode
    self.copilotPermissions = copilotPermissions
    self.briefsSessionsAboutTheGraph = briefsSessionsAboutTheGraph
    self.autoSelectsModel = autoSelectsModel
    self.showsActivityStrip = showsActivityStrip
    self.sharesLoops = sharesLoops
    self.summarisesLoops = summarisesLoops
    self.summaryUsesModel = summaryUsesModel
    self.visualisesSummaries = visualisesSummaries
    self.daemonHeartbeatEnabled = daemonHeartbeatEnabled
    self.keepsMacAwakeWhileLoopsRun = keepsMacAwakeWhileLoopsRun
    self.worktreePolicies = worktreePolicies
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
      try container.decodeIfPresent(CodexApprovals.self, forKey: .codexApprovals) ?? .yolo
    openCodePermissions =
      try container.decodeIfPresent(OpenCodePermissions.self, forKey: .openCodePermissions)
      ?? .auto
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
    showsActivityStrip =
      try container.decodeIfPresent(Bool.self, forKey: .showsActivityStrip) ?? false
    // Absent takes the new default — on. An explicit `false`, written by anyone who
    // tried the experiment and switched it off, is preserved; flipping a recorded
    // choice under someone is what the migration comments above never do.
    sharesLoops =
      try container.decodeIfPresent(Bool.self, forKey: .sharesLoops) ?? true
    // Absent means nobody has opted in, which is the default again. A person who switched
    // it on has `true` in their file — including anyone whose 0.1.37 install wrote the
    // then-default out — and that is preserved.
    summarisesLoops =
      try container.decodeIfPresent(Bool.self, forKey: .summarisesLoops) ?? false
    // Never inferred from `summarisesLoops`: turning the rail on must not start spending
    // money on a machine whose owner only asked to see what their loops were doing.
    summaryUsesModel =
      try container.decodeIfPresent(Bool.self, forKey: .summaryUsesModel) ?? false
    // Absent means nobody has opted in. Never inferred from either switch above it: the
    // reading is free, the rewrite is a sentence, and this draws a shape — three different
    // prices, so three different answers.
    visualisesSummaries =
      try container.decodeIfPresent(Bool.self, forKey: .visualisesSummaries) ?? false
    daemonHeartbeatEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .daemonHeartbeatEnabled) ?? false
    // Absent means nobody has asked for it, which is the default. An update must never
    // start holding a power assertion on a machine whose owner did not choose that.
    keepsMacAwakeWhileLoopsRun =
      try container.decodeIfPresent(Bool.self, forKey: .keepsMacAwakeWhileLoopsRun) ?? false
    worktreePolicies =
      try container.decodeIfPresent(
        [String: WorktreeHygienePolicy].self, forKey: .worktreePolicies) ?? [:]
  }
}
