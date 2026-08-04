import Foundation

/// How to actually invoke a backend's CLI — the argv graphcode builds for a node's
/// session, in the one place both callers can reach.
///
/// There are exactly two: `ZmxSessionLauncher`, which starts a detached session from the
/// daemon, and `GhosttyTerminalView`, which attaches the app's terminal to one. Before
/// this they each hardcoded `claude`, which meant a node whose backend said Copilot
/// opened a Claude Code session — the picker and the process disagreeing, silently. A
/// single source of truth is the fix.
extension CLISessionBackendKind {
  /// The binary a human would type. `nil` for a backend graphcode can't launch, which is
  /// also why `canHost` refuses everything for it.
  public var executableName: String? {
    switch self {
    case .claudeCode: return "claude"
    case .copilotCLI: return "copilot"
    case .codex: return "codex"
    }
  }

  /// The model each tier maps to for this backend.
  ///
  /// Deliberately per-backend rather than one shared alias list: Claude Code takes short
  /// aliases that keep resolving to the current model in a class, whereas Copilot's
  /// `--model` takes explicit versioned ids from a fixed set (read off `copilot --help`
  /// at 0.0.410). Pointing the same string at both would silently fail on one of them.
  ///
  /// `.standard` returns nil everywhere — passing no flag lets the backend's own default
  /// apply, which is different from asserting what we think it is.
  public func modelArguments(for tier: ModelTier) -> [String] {
    switch self {
    case .claudeCode:
      return tier.modelAlias.map { ["--model", $0] } ?? []
    case .copilotCLI:
      switch tier {
      case .fast: return ["--model", "claude-haiku-4.5"]
      case .standard: return []
      case .capable: return ["--model", "claude-opus-4.6"]
      }
    case .codex:
      // `-m` is real, but the valid model ids are not visible from `codex --help` and a
      // wrong one fails at launch. Passing nothing lets Codex's own default apply, which
      // is honest, where a guessed id would be a confident break.
      return []
    }
  }

  /// Everything after the executable, for a session that should open running `prompt`
  /// (or bare, when there isn't one), optionally carrying a `briefing` about the graph it
  /// belongs to (`SessionBriefing`).
  ///
  /// The shapes genuinely differ: `claude` takes its opening prompt as a positional
  /// argument, while `copilot` takes it as the value of `--interactive`. Note this is
  /// `--interactive`, not `-p/--prompt` — the latter exits when the work finishes, and a
  /// loop nobody can attach to and steer is the model graphcode deliberately moved away
  /// from.
  ///
  /// The briefing is delivered differently for the same reason, and the difference is not
  /// cosmetic. `claude` takes `--append-system-prompt-file <path>`, which adds the file's
  /// contents to its system prompt and leaves the human's prompt as the only thing in the
  /// conversation. `copilot` has no equivalent — its custom instructions come from
  /// `AGENTS.md` files it discovers on disk (hence `--no-custom-instructions` to switch
  /// that off), which graphcode has no business writing into someone's repository. So
  /// Copilot has no equivalent flag and no working equivalent mechanism, so it is told to
  /// read the file by a preamble on the prompt and granted access to it with `--add-dir`.
  ///
  /// Neither carries the prose on the command line. See `SessionBriefing` for why that is
  /// load-bearing rather than tidy: the launch command is typed into a terminal, and a
  /// briefing-sized argument overruns the tty's canonical input buffer.
  /// `briefingPath` is a path *string*, not a URL, because it may name a file on a
  /// different machine: a remote session's briefing lands at a `~/`-relative path the
  /// remote shell expands, which no local `URL` can represent honestly.
  public func launchArguments(
    prompt: String?, tier: ModelTier, briefingPath: String? = nil,
    settings: GraphcodeSettings = GraphcodeSettings(), workspacePaths: [String] = [],
    hooksFile: URL? = nil, sessionName: String? = nil, zmxPath: String? = nil
  ) -> [String] {
    let model =
      modelArguments(for: tier) + permissionArguments(settings)
      + presenceArguments(hooksFile: hooksFile, sessionName: sessionName, zmxPath: zmxPath)
    guard let prompt, !prompt.isEmpty else { return model }
    let briefingDirectory = (briefingPath as NSString?)?.deletingLastPathComponent
    switch self {
    case .claudeCode:
      let system = briefingPath.map { ["--append-system-prompt-file", $0] } ?? []
      return model + system + [prompt]
    case .copilotCLI:
      // Copilot gates tools, paths and URLs separately, so `--allow-all-tools` alone
      // leaves a session unable to touch anything outside its working directory — its
      // own project when it opened in a worktree, and the briefing either way. Both
      // failures read as the agent ignoring instructions (issues #2 and #4), which is
      // why the directories are granted explicitly rather than trusted to the tool flag.
      let access = settings.copilotPermissions.readableDirectories(
        workspacePaths + [briefingDirectory].compactMap { $0 })
      guard let briefingPath else { return model + access + ["--interactive", prompt] }
      // And the preamble telling it the briefing is there to read. See
      // `SessionBriefing.pointer` for why the tidier env-var route was abandoned.
      return model + access
        + [
          "--interactive", "\(SessionBriefing.pointer(toBriefingAt: briefingPath)) \(prompt)",
        ]
    case .codex:
      // Same shape as Claude Code — an interactive TUI taking its prompt positionally —
      // so the briefing rides the same way Copilot's does: `--add-dir` for access, a
      // preamble to point at it. Codex has no `--append-system-prompt` equivalent.
      let access = settings.codexApprovals.writableDirectories(workspacePaths)
      guard let briefingPath, let briefingDirectory else { return model + access + [prompt] }
      return model + access + ["--add-dir", briefingDirectory]
        + ["\(SessionBriefing.pointer(toBriefingAt: briefingPath)) \(prompt)"]
    }
  }

  /// How much a session may do without stopping to ask.
  ///
  /// A loop is unattended by construction — the daemon starts it whether or not a window
  /// is open, and nobody is watching the pane when it asks whether it may edit a file. A
  /// backend left on its interactive default sits at that prompt indefinitely while the
  /// graph reports it as `running`, which is the same "looks alive, does nothing" failure
  /// as the trust-this-folder dialog.
  ///
  /// Claude Code's default is `auto` — guardrails intact, ordinary work approved;
  /// `bypassPermissions` removes the checks entirely and is offered, not defaulted.
  /// Copilot's default is `--yolo`: it gates tools, paths, and URLs as three separate
  /// confirmations, and the narrower `--allow-all-tools` default this used to have left
  /// unattended loops stalling at URL and path dialogs nobody was watching — reported
  /// as `running` the whole time. See `GraphcodeSettings.CopilotPermissions` for the
  /// full reasoning; the narrower modes remain for attended use.
  /// Public because the app builds its own argv rather than going through
  /// `launchArguments`: `GhosttyTerminalView` assembles a *shell command string*, where
  /// the daemon assembles an argv array. Both still have to answer this question the same
  /// way, and the app answering it by omission is what left app-created sessions on the
  /// CLI's interactive default while daemon-created ones were on `auto`.
  public func permissionArguments(_ settings: GraphcodeSettings) -> [String] {
    switch self {
    case .claudeCode: return settings.claudePermissionMode.arguments
    case .copilotCLI: return settings.copilotPermissions.arguments
    case .codex: return settings.codexApprovals.arguments
    }
  }

  /// The argv that makes a backend's session observable — what graphcode adds so that
  /// "is this loop actually working?" has an answer.
  ///
  /// The two backends answer it from opposite ends, which is why one function takes both
  /// arguments rather than each getting its own:
  ///
  /// - **Claude Code pushes.** It has lifecycle hooks, so it is handed a settings file
  ///   whose hooks write the answer into the session's own label store (`PresenceHooks`).
  ///   By *path*, like the briefing and for the same reason: `--settings` also takes a
  ///   JSON string, and inlining several hundred bytes of shell would overrun the
  ///   `MAX_CANON`-capped line `zmx` types (see `SessionBriefing`).
  /// - **Copilot is read.** It has no hook mechanism at all, so nothing can be installed
  ///   into it; instead it is given a *name*, which is the only handle that ties the
  ///   session-state directory it writes back to the node that owns it
  ///   (`CopilotSessionLog`). Without this flag the directory is a bare UUID Copilot
  ///   chose, and its event log — which marks turn boundaries better than any transcript
  ///   graphcode reads — belongs to nobody.
  ///
  /// Empty when the handle isn't available, which leaves presence at the heuristic: what
  /// every session did before any of this existed.
  public func presenceArguments(
    hooksFile: URL?, sessionName: String? = nil, zmxPath: String? = nil
  ) -> [String] {
    switch self {
    case .claudeCode:
      return hooksFile.map { ["--settings", $0.path] } ?? []
    case .copilotCLI:
      return sessionName.map { ["--name", $0] } ?? []
    case .codex:
      // Codex reports only the *end* of a turn, through `notify`, and needs no file to do
      // it — just somewhere to write, which is why this is the one backend that takes the
      // `zmx` path rather than a path to something graphcode wrote. Its other edge is
      // covered without asking Codex anything: see `ZmxSessionLauncher.codexPresence`.
      return zmxPath.map { ["-c", PresenceHooks.codexNotifyOverride(zmxPath: $0)] } ?? []
    }
  }
}
