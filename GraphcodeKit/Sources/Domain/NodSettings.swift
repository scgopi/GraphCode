/// Settings › Agents › Nod. The runtime reads the same values from the settings file, so
/// the app and `graphcode-nod` never disagree about what Nod may do.
///
/// Credentials are not here. They live in the macOS Keychain under
/// `keychainService`, never in `~/.graphcode`.
public struct NodSettings: Codable, Equatable, Sendable {
  public static let keychainService = "app.graphcode.nod"

  public enum Ask: String, Codable, CaseIterable, Sendable {
    case always
    case ask
    case never
  }

  public enum EditPolicy: String, Codable, CaseIterable, Sendable {
    /// Hunks are staged and land on disk only when accepted.
    case reviewHunks
    /// Hunks arrive already accepted and stay reviewable until the turn ends.
    case auto
  }

  public enum MessagePolicy: String, Codable, CaseIterable, Sendable {
    case draftForMe
    case send
    case never
  }

  public var engine: NodEngine
  /// Keyed by `LoopType.rawValue`. A missing type falls back to the engine's default.
  public var modelsByLoopType: [String: String]
  public var compositeChildModel: String?
  public var goalEvaluatorModel: String?
  public var shell: Ask
  public var network: Ask
  public var editsInWorktree: EditPolicy
  public var editsOutsideWorktree: Ask
  public var messagesOtherLoops: MessagePolicy
  /// Shell patterns that run without asking, e.g. `swift test *`.
  public var shellAllowlist: [String]
  /// Per-run cap for unattended loops (timed and composite children), in dollars; 0 is no
  /// cap. Copilot reports premium requests instead and is capped by its plan.
  public var spendCapUSD: Double
  /// MCP servers from the project's `.mcp.json` switched off for Nod, by name. The
  /// built-in graphcode server is always on and never listed here.
  public var disabledMCPServers: [String]

  public init(
    engine: NodEngine = .claudeAgentSDK,
    modelsByLoopType: [String: String] = [:],
    compositeChildModel: String? = nil,
    goalEvaluatorModel: String? = nil,
    shell: Ask = .ask,
    network: Ask = .ask,
    editsInWorktree: EditPolicy = .auto,
    editsOutsideWorktree: Ask = .never,
    messagesOtherLoops: MessagePolicy = .draftForMe,
    shellAllowlist: [String] = [],
    spendCapUSD: Double = 2,
    disabledMCPServers: [String] = []
  ) {
    self.engine = engine
    self.modelsByLoopType = modelsByLoopType
    self.compositeChildModel = compositeChildModel
    self.goalEvaluatorModel = goalEvaluatorModel
    self.shell = shell
    self.network = network
    self.editsInWorktree = editsInWorktree
    self.editsOutsideWorktree = editsOutsideWorktree
    self.messagesOtherLoops = messagesOtherLoops
    self.shellAllowlist = shellAllowlist
    self.spendCapUSD = spendCapUSD
    self.disabledMCPServers = disabledMCPServers
  }

  public init(from decoder: Decoder) throws {
    let defaults = NodSettings()
    let container = try decoder.container(keyedBy: CodingKeys.self)
    func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
      try container.decodeIfPresent(T.self, forKey: key) ?? fallback
    }
    engine = try value(.engine, defaults.engine)
    modelsByLoopType = try value(.modelsByLoopType, defaults.modelsByLoopType)
    compositeChildModel = try container.decodeIfPresent(String.self, forKey: .compositeChildModel)
    goalEvaluatorModel = try container.decodeIfPresent(String.self, forKey: .goalEvaluatorModel)
    shell = try value(.shell, defaults.shell)
    network = try value(.network, defaults.network)
    editsInWorktree = try value(.editsInWorktree, defaults.editsInWorktree)
    editsOutsideWorktree = try value(.editsOutsideWorktree, defaults.editsOutsideWorktree)
    messagesOtherLoops = try value(.messagesOtherLoops, defaults.messagesOtherLoops)
    shellAllowlist = try value(.shellAllowlist, defaults.shellAllowlist)
    spendCapUSD = try value(.spendCapUSD, defaults.spendCapUSD)
    disabledMCPServers = try value(.disabledMCPServers, defaults.disabledMCPServers)
  }

  public func model(for loopType: LoopType) -> String? {
    modelsByLoopType[loopType.rawValue]
  }
}
