/// How to actually invoke a backend's CLI — the argv graphcode builds for a node's
/// session, in the one place both callers can reach.
///
/// There are exactly two: `ZmxSessionLauncher`, which starts a detached session from the
/// daemon, and `GhosttyTerminalView`, which attaches the app's terminal to one. Before
/// this they each hardcoded `claude`, which meant a node whose backend said Copilot
/// opened a Claude Code session — the picker and the process disagreeing, silently. A
/// single source of truth is the fix.
import Foundation

extension CLISessionBackendKind {
  /// The binary a human would type. `nil` for a backend graphcode can't launch, which is
  /// also why `canHost` refuses everything for it.
  public var executableName: String? {
    switch self {
    case .claudeCode: return "claude"
    case .copilotCLI: return "copilot"
    case .codex: return "codex"
    case .openCode: return "opencode"
    case .pi: return "pi"
    }
  }

  public var supportsVersionPreference: Bool { self == .copilotCLI }

  public func versionArguments(_ settings: GraphcodeSettings) -> [String] {
    guard supportsVersionPreference, let version = settings.normalizedCopilotPreferredVersion else {
      return []
    }
    return ["--prefer-version", version]
  }

  /// The model each tier maps to for this backend.
  ///
  /// Deliberately per-backend rather than one shared alias list: Claude Code takes short
  /// aliases that keep resolving to the current model in a class, whereas Copilot's
  /// `--model` takes explicit versioned ids from a fixed set (read off `copilot help
  /// config` at 1.0.84). Pointing the same string at both would silently fail on one of
  /// them.
  ///
  /// `.standard` returns nil everywhere — passing no flag lets the backend's own default
  /// apply, which is different from asserting what we think it is. Copilot's `.capable`
  /// is nil too: its list turns over fast enough that the pinned id (`claude-opus-4.6`)
  /// had already gone by 1.0.84, and a capable loop that fails to launch is worse than
  /// one on Copilot's own default.
  public func modelArguments(for tier: ModelTier) -> [String] {
    switch self {
    case .claudeCode:
      return tier.modelAlias.map { ["--model", $0] } ?? []
    case .copilotCLI:
      switch tier {
      case .fast: return ["--model", "gpt-5.6-luna"]
      case .standard, .capable: return []
      }
    case .codex:
      // `-m` is real, but the valid model ids are not visible from `codex --help` and a
      // wrong one fails at launch. Passing nothing lets Codex's own default apply, which
      // is honest, where a guessed id would be a confident break.
      return []
    case .openCode:
      // `-m` takes `provider/model`, and which providers a user has connected is theirs
      // to know (`opencode auth list`), not something a tier can name. Passing nothing
      // lets whatever `opencode` is configured to use apply.
      return []
    case .pi:
      // `--model` takes `provider/id`, and which providers are logged in is the user's
      // (`pi --list-models`), so nothing is passed and pi's own default applies.
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
  /// instruction files it discovers on disk, which graphcode has no business writing into
  /// someone's repository — so it is pointed at a copy in graphcode's own directory through
  /// its environment instead (`briefingEnvironment`), which lands in its system prompt
  /// just as Claude's flag does.
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
    hooksFile: URL? = nil, sessionName: String? = nil, zmxPath: String? = nil,
    sessionsDirectory: String? = nil
  ) -> [String] {
    let model =
      versionArguments(settings) + modelArguments(for: tier) + permissionArguments(settings)
      + presenceArguments(
        hooksFile: hooksFile, sessionName: sessionName, zmxPath: zmxPath,
        sessionsDirectory: sessionsDirectory)
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
      // `/loop` — an alias of `/every` — is behind Copilot's experimental flag, so
      // without this the directive a time-based node opens with is not a command at all
      // and the session reads it as prose: no schedule, one pass, then idle. Passed only
      // for a prompt that actually is one, so an ordinary Copilot session keeps the
      // CLI's own defaults.
      let experimental = SessionPrompt.mentionsRecurrence(prompt) ? ["--experimental"] : []
      return model + access + experimental + ["--interactive", prompt]
    case .codex:
      // Same shape as Claude Code — an interactive TUI taking its prompt positionally —
      // so the briefing rides the same way Copilot's does: `--add-dir` for access, a
      // preamble to point at it. Codex has no `--append-system-prompt` equivalent.
      let access = settings.codexApprovals.writableDirectories(workspacePaths)
      guard let briefingPath, let briefingDirectory else { return model + access + [prompt] }
      return model + access + ["--add-dir", briefingDirectory]
        + [
          SessionPrompt.composed(
            preamble: SessionBriefing.pointer(toBriefingAt: briefingPath), prompt: prompt)
        ]
    case .openCode:
      // The prompt is the value of `--prompt`, the briefing a pointer inside it. No
      // directory grant: OpenCode's `read` permission defaults to allow, and `--auto`
      // approves everything not explicitly denied, so the briefing is readable as is.
      guard let briefingPath else { return model + ["--prompt", prompt] }
      return model
        + [
          "--prompt",
          SessionPrompt.composed(
            preamble: SessionBriefing.pointer(toBriefingAt: briefingPath), prompt: prompt),
        ]
    case .pi:
      // Positional, like Claude Code's. The briefing rides as a pointer inside the prompt:
      // pi's `read` has no path gate, so it needs no directory grant either.
      guard let briefingPath else { return model + [Self.piMessage(prompt)] }
      return model
        + [
          Self.piMessage(
            SessionPrompt.composed(
              preamble: SessionBriefing.pointer(toBriefingAt: briefingPath), prompt: prompt))
        ]
    }
  }

  /// pi reads a positional argument that starts with `-` as an option and one that starts
  /// with `@` as a file to attach (`cli/args.js`), so a goal opening with a bullet or a
  /// mention would never reach the agent. A leading space keeps it a message. `--` is not
  /// an option: it cannot rescue `@`, and the remote `-e` suffix follows the prompt.
  public static func piMessage(_ prompt: String) -> String {
    prompt.hasPrefix("-") || prompt.hasPrefix("@") ? " " + prompt : prompt
  }

  /// The flag a backend's opening prompt rides behind, or `nil` for one that takes it
  /// positionally. The app assembles a shell string rather than an argv and needs the
  /// same answer `launchArguments` gives.
  public var promptFlag: String? {
    switch self {
    case .claudeCode, .codex, .pi: return nil
    case .copilotCLI: return "--interactive"
    case .openCode: return "--prompt"
    }
  }

  /// Whether a backend that verifies paths needs `--add-dir` for the briefing's folder.
  public var briefingNeedsDirectoryGrant: Bool {
    switch self {
    case .claudeCode, .openCode, .pi: return false
    case .copilotCLI, .codex: return true
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
    case .openCode: return settings.openCodePermissions.arguments
    case .pi: return settings.piProjectTrust.arguments
    }
  }

  /// Whether the backend can pick a session back up from a persisted ID (`--resume`).
  /// The one answer both resumers consult — the daemon's ensure
  /// (`ZmxSessionLauncher.resumeArguments`) and the app's reboot restore
  /// (`GhosttyTerminalView.resumeCommand`) — so a backend gaining or losing resume
  /// support changes both paths together rather than one silently drifting.
  public var supportsResume: Bool {
    self == .claudeCode || self == .copilotCLI || self == .codex || self == .openCode
      || self == .pi
  }

  /// The argv that picks `sessionID` back up. OpenCode's `--session` and Codex's
  /// `resume <id>` both name the exact conversation rather than selecting the last one.
  public func resumeArguments(sessionID: String) -> [String] {
    switch self {
    case .claudeCode, .copilotCLI: return ["--resume", sessionID]
    case .codex: return ["resume", sessionID]
    case .openCode, .pi: return ["--session", sessionID]
    }
  }

  /// Environment a session needs for its reporting to reach graphcode — the fourth
  /// shape of the `presenceArguments` problem. OpenCode takes no hook flag; its plugin
  /// is named by a config file, and `OPENCODE_CONFIG` is the one route that *merges over*
  /// the user's own config instead of replacing it (`OPENCODE_CONFIG_DIR` would drop
  /// their providers and plugins on the floor — read off the config loader, not the docs).
  /// The environment that delivers the briefing at `briefingPath`, for the one backend
  /// that takes it that way (`SessionBriefing.copilotInstructionsDirectoryVariable`).
  public func briefingEnvironment(briefingPath: String?) -> [String: String] {
    guard self == .copilotCLI, let briefingPath else { return [:] }
    return SessionBriefing.copilotInstructionsEnvironment(briefingPath: briefingPath)
  }

  public func presenceEnvironment(hooksFile: URL?) -> [String: String] {
    switch self {
    case .openCode:
      return hooksFile.map { ["OPENCODE_CONFIG": $0.path] } ?? [:]
    case .claudeCode, .copilotCLI, .codex, .pi:
      return [:]
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
    hooksFile: URL?, sessionName: String? = nil, zmxPath: String? = nil,
    sessionsDirectory: String? = nil
  ) -> [String] {
    switch self {
    case .claudeCode:
      return hooksFile.map { ["--settings", $0.path] } ?? []
    case .copilotCLI:
      return sessionName.map { ["--name", $0] } ?? []
    case .codex:
      // Codex reports only the *end* of a turn, through `notify`. Its other edge is
      // covered without asking Codex anything: see `ZmxSessionLauncher.codexPresence`.
      // A remote launch has no local hooks file and names the one its ensure wrote on
      // the host, which only a remote `sessionsDirectory` distinguishes from a local
      // launch whose write failed.
      if let hooksFile {
        return ["-c", PresenceHooks.codexNotifyOverride(scriptPath: hooksFile.path)]
      }
      return sessionsDirectory == nil ? [] : ["-c", PresenceHooks.remoteCodexNotifyOverride]
    case .openCode:
      // Reports through a plugin, which rides in the environment rather than the argv —
      // see `presenceEnvironment`.
      return []
    case .pi:
      // An extension, loaded by path alongside the user's own — see `PiPresenceExtension`.
      return hooksFile.map { ["-e", $0.path] } ?? []
    }
  }
}
