import Foundation

/// The models Nod offers on each engine, and which one a loop gets when nobody picked.
///
/// Settings › Agents › Nod and the new-loop agent menu both read this, and so does the
/// launch path, so a loop never starts on a model the menu would not have offered. A
/// stored choice that is no longer in the list (the lineup moved on, or the engine was
/// switched) falls back to the engine's default for that loop type rather than being
/// passed through to fail at launch.
public struct NodModel: Equatable, Hashable, Sendable, Identifiable {
  public enum Family: String, Sendable {
    case claude
    case gpt
    case gemini
    case other
  }

  /// The id the engine takes: an alias on the Claude Agent SDK, which keeps resolving to
  /// the current model in its class, and a versioned id on the Copilot SDK.
  public var id: String
  public var displayName: String
  public var family: Family
  public var tier: ModelTier

  public init(id: String, displayName: String, family: Family, tier: ModelTier) {
    self.id = id
    self.displayName = displayName
    self.family = family
    self.tier = tier
  }
}

public enum NodModelCatalog {
  public static func models(for engine: NodEngine) -> [NodModel] {
    switch engine {
    case .claudeAgentSDK:
      return [
        NodModel(id: "opus", displayName: "Opus", family: .claude, tier: .capable),
        NodModel(id: "sonnet", displayName: "Sonnet", family: .claude, tier: .standard),
        NodModel(id: "haiku", displayName: "Haiku", family: .claude, tier: .fast),
      ]
    case .copilotSDK:
      let builtIn = copilotModels
      return builtIn
        + discoveredCopilotModels.filter { model in !builtIn.contains { $0.id == model.id } }
    }
  }

  /// Read off `copilot help config` at 1.0.89. The first model of each tier is that tier's
  /// default, so the order of the first five matters; the rest follow the CLI's order.
  static let copilotModels: [NodModel] =
    [
      "gpt-6-sol", "gpt-5.6-luna", "claude-opus-5.5", "claude-sonnet-5", "gemini-3.8-flash",
      "claude-fable-5.1", "claude-fable-5", "claude-opus-5", "claude-opus-4.8",
      "claude-opus-4.8-fast", "claude-opus-4.7", "claude-sonnet-4.6", "claude-haiku-4.5",
      "gpt-6-luna", "gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.5", "gpt-5.4",
      "gpt-5.4-mini", "gpt-5.3-codex", "gpt-5-mini", "mai-code-1.1-flash", "gemini-3.7-flash",
      "gemini-3.6-flash", "gemini-3.5-flash", "grok-4.5", "kimi-k3", "kimi-k2.7-code", "auto",
    ].map { copilotModel(id: $0) }

  /// Models the Copilot SDK reported for the signed-in account (`graphcode-nod
  /// --list-models`) that the built-in list lacks. Set by the app; empty until it has asked.
  nonisolated(unsafe) public static var discoveredCopilotModels: [NodModel] = []

  /// A Copilot model from its id alone: the SDK's list and the CLI's both give ids, and the
  /// tier is what a loop type's default needs.
  public static func copilotModel(id: String, name: String? = nil) -> NodModel {
    let family: NodModel.Family =
      id.hasPrefix("claude")
      ? .claude
      : id.hasPrefix("gpt")
        ? .gpt
        : id.hasPrefix("gemini") ? .gemini : .other
    let tier: ModelTier =
      ["haiku", "mini", "flash", "luna", "fast"].contains { id.contains($0) }
      ? .fast
      : ["opus", "fable"].contains { id.contains($0) } ? .capable : .standard
    return NodModel(
      id: id, displayName: name ?? copilotDisplayName(id), family: family, tier: tier)
  }

  /// `claude-sonnet-5` → "Claude Sonnet 5", `gpt-6-sol` → "GPT-6 Sol".
  static func copilotDisplayName(_ id: String) -> String {
    if id == "auto" { return "Auto" }
    var words = id.split(separator: "-").map(String.init)
    if words.first == "gpt", words.count > 1 { words[0...1] = ["GPT-\(words[1])"] }
    return words.map { word in
      ["mai"].contains(word) ? word.uppercased() : word.prefix(1).uppercased() + word.dropFirst()
    }.joined(separator: " ")
  }

  /// "Opus · Sonnet · Haiku" or "GPT · Claude · Gemini", the line under each engine card.
  public static func familySummary(for engine: NodEngine) -> String {
    switch engine {
    case .claudeAgentSDK:
      return models(for: engine).map(\.displayName).joined(separator: " · ")
    case .copilotSDK:
      return "GPT · Claude · Gemini"
    }
  }

  public static func model(id: String, engine: NodEngine) -> NodModel? {
    models(for: engine).first { $0.id == id }
  }

  /// The first model of `tier` on `engine`; every engine offers all three tiers.
  public static func model(for tier: ModelTier, engine: NodEngine) -> NodModel {
    models(for: engine).first { $0.tier == tier } ?? models(for: engine)[0]
  }

  /// What a loop type runs on when Settings has no choice for it: the design's Main
  /// Sonnet, Goal Opus, Timed Haiku, Turn Sonnet, Composite Opus.
  public static func defaultTier(for loopType: LoopType) -> ModelTier {
    switch loopType {
    case .sketch, .turnBased: return .standard
    case .goalBased, .composite: return .capable
    case .timeBased: return .fast
    }
  }

  public static let defaultCompositeChildTier = ModelTier.standard
  public static let defaultEvaluatorTier = ModelTier.fast
}

extension NodSettings {
  /// The model a new `loopType` loop starts on. An explicit `tier` (the new-loop menu's
  /// pick) wins; otherwise the per-type setting, if it still names a model this engine
  /// offers; otherwise the type's default.
  public func resolvedModel(for loopType: LoopType, tier: ModelTier? = nil) -> NodModel {
    if let tier { return NodModelCatalog.model(for: tier, engine: engine) }
    return stored(model(for: loopType))
      ?? NodModelCatalog.model(for: NodModelCatalog.defaultTier(for: loopType), engine: engine)
  }

  public var resolvedCompositeChildModel: NodModel {
    stored(compositeChildModel)
      ?? NodModelCatalog.model(for: NodModelCatalog.defaultCompositeChildTier, engine: engine)
  }

  public var resolvedGoalEvaluatorModel: NodModel {
    stored(goalEvaluatorModel)
      ?? NodModelCatalog.model(for: NodModelCatalog.defaultEvaluatorTier, engine: engine)
  }

  /// Sets the per-type model; choosing the type's default clears the entry, so a later
  /// change to the defaults reaches it.
  public mutating func setModel(_ model: NodModel, for loopType: LoopType) {
    let isDefault =
      model
      == NodModelCatalog.model(for: NodModelCatalog.defaultTier(for: loopType), engine: engine)
    modelsByLoopType[loopType.rawValue] = isDefault ? nil : model.id
  }

  /// Switching engines drops model choices the new engine cannot run. Existing loops keep
  /// the engine they started on; this only changes what new loops get.
  public mutating func switchEngine(to newEngine: NodEngine) {
    guard newEngine != engine else { return }
    engine = newEngine
    modelsByLoopType = modelsByLoopType.filter {
      NodModelCatalog.model(id: $0.value, engine: newEngine) != nil
    }
    if let child = compositeChildModel, NodModelCatalog.model(id: child, engine: newEngine) == nil {
      compositeChildModel = nil
    }
    if let evaluator = goalEvaluatorModel,
      NodModelCatalog.model(id: evaluator, engine: newEngine) == nil
    {
      goalEvaluatorModel = nil
    }
  }

  /// Adds a shell pattern, trimmed, ignoring blanks and duplicates. Returns whether the
  /// list changed.
  @discardableResult
  public mutating func addAllowlistPattern(_ pattern: String) -> Bool {
    let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !shellAllowlist.contains(trimmed) else { return false }
    shellAllowlist.append(trimmed)
    return true
  }

  public mutating func removeAllowlistPattern(_ pattern: String) {
    shellAllowlist.removeAll { $0 == pattern }
  }

  /// A negative or non-finite cap is stored as no cap rather than as a value the runtime
  /// would have to second-guess.
  public mutating func setSpendCap(_ dollars: Double) {
    spendCapUSD = dollars.isFinite && dollars > 0 ? (dollars * 100).rounded() / 100 : 0
  }

  private func stored(_ id: String?) -> NodModel? {
    id.flatMap { NodModelCatalog.model(id: $0, engine: engine) }
  }
}
