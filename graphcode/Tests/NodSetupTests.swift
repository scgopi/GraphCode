import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

@Suite struct NodModelCatalogTests {
  @Test func everyEngineOffersEveryTier() {
    for engine in NodEngine.allCases {
      for tier in ModelTier.allCases {
        #expect(NodModelCatalog.model(for: tier, engine: engine).tier == tier)
      }
    }
  }

  /// The SDK's `listModels()` answers only "Auto" for some accounts, so the built-in list
  /// is what the pickers show; it tracks `copilot help config`.
  @Test func copilotOffersTheCLIsModelsAndKeepsItsDefaults() {
    let ids = NodModelCatalog.models(for: .copilotSDK).map(\.id)
    for id in ["claude-fable-5.1", "gpt-6-luna", "gpt-5-mini", "grok-4.5", "kimi-k3", "auto"] {
      #expect(ids.contains(id))
    }
    #expect(NodModelCatalog.model(for: .capable, engine: .copilotSDK).id == "claude-opus-5.5")
    #expect(NodModelCatalog.model(for: .standard, engine: .copilotSDK).id == "gpt-6-sol")
    #expect(NodModelCatalog.model(for: .fast, engine: .copilotSDK).id == "gpt-5.6-luna")
  }

  @Test func copilotIDsReadAsNames() {
    #expect(NodModelCatalog.copilotModel(id: "gpt-6-sol").displayName == "GPT-6 Sol")
    #expect(
      NodModelCatalog.copilotModel(id: "claude-opus-4.8-fast").displayName == "Claude Opus 4.8 Fast"
    )
    #expect(
      NodModelCatalog.copilotModel(id: "mai-code-1.1-flash").displayName == "MAI Code 1.1 Flash")
    #expect(NodModelCatalog.copilotModel(id: "auto").displayName == "Auto")
  }

  /// `graphcode-nod --list-models` repeats ids (the SDK listed "auto" twice); each model
  /// appears once, named as the SDK names it.
  @Test func aDiscoveredListIsReadOncePerModel() {
    let json =
      #"{"engine":"copilot","models":[{"id":"auto","name":"Auto"},{"id":"auto","name":"Auto"},{"id":"o-next","name":"O Next"}]}"#

    let models = NodModelDiscovery.models(from: Data(json.utf8))

    #expect(models.map(\.id) == ["auto", "o-next"])
    #expect(models.last?.displayName == "O Next")
    #expect(
      NodModelDiscovery.models(from: Data(#"{"engine":"claude","models":null}"#.utf8)).isEmpty)
  }

  @Test func defaultsFollowTheDesignPerLoopType() {
    let settings = NodSettings()
    #expect(settings.resolvedModel(for: .sketch).displayName == "Sonnet")
    #expect(settings.resolvedModel(for: .goalBased).displayName == "Opus")
    #expect(settings.resolvedModel(for: .timeBased).displayName == "Haiku")
    #expect(settings.resolvedModel(for: .turnBased).displayName == "Sonnet")
    #expect(settings.resolvedModel(for: .composite).displayName == "Opus")
    #expect(settings.resolvedCompositeChildModel.displayName == "Sonnet")
    #expect(settings.resolvedGoalEvaluatorModel.displayName == "Haiku")
  }

  @Test func anExplicitTierBeatsTheStoredChoice() {
    var settings = NodSettings()
    settings.modelsByLoopType[LoopType.goalBased.rawValue] = "haiku"
    #expect(settings.resolvedModel(for: .goalBased).id == "haiku")
    #expect(settings.resolvedModel(for: .goalBased, tier: .standard).id == "sonnet")
  }

  @Test func aStaleStoredModelFallsBackToTheDefault() {
    var settings = NodSettings()
    settings.modelsByLoopType[LoopType.sketch.rawValue] = "claude-2"
    settings.goalEvaluatorModel = "gone"
    #expect(settings.resolvedModel(for: .sketch).id == "sonnet")
    #expect(settings.resolvedGoalEvaluatorModel.id == "haiku")
  }

  @Test func choosingTheDefaultClearsTheEntry() {
    var settings = NodSettings()
    settings.setModel(NodModelCatalog.model(for: .fast, engine: .claudeAgentSDK), for: .sketch)
    #expect(settings.modelsByLoopType == ["sketch": "haiku"])
    settings.setModel(NodModelCatalog.model(for: .standard, engine: .claudeAgentSDK), for: .sketch)
    #expect(settings.modelsByLoopType.isEmpty)
  }

  @Test func switchingEngineDropsModelsTheNewEngineCannotRun() {
    var settings = NodSettings(
      modelsByLoopType: ["sketch": "haiku"], compositeChildModel: "opus",
      goalEvaluatorModel: "haiku")
    settings.switchEngine(to: .copilotSDK)
    #expect(settings.engine == .copilotSDK)
    #expect(settings.modelsByLoopType.isEmpty)
    #expect(settings.compositeChildModel == nil)
    #expect(settings.goalEvaluatorModel == nil)
    #expect(settings.resolvedModel(for: .goalBased).family == .claude)
    #expect(settings.resolvedModel(for: .timeBased).id == "gpt-5.6-luna")
  }

  @Test func allowlistTrimsAndIgnoresDuplicates() {
    var settings = NodSettings()
    let added = settings.addAllowlistPattern("  swift test *  ")
    let duplicate = settings.addAllowlistPattern("swift test *")
    let blank = settings.addAllowlistPattern("   ")
    let second = settings.addAllowlistPattern("make lint")
    #expect(added && !duplicate && !blank && second)
    settings.removeAllowlistPattern("swift test *")
    #expect(settings.shellAllowlist == ["make lint"])
  }

  @Test func spendCapRejectsNonsense() {
    var settings = NodSettings()
    settings.setSpendCap(2.499)
    #expect(settings.spendCapUSD == 2.5)
    settings.setSpendCap(-1)
    #expect(settings.spendCapUSD == 0)
    settings.setSpendCap(.infinity)
    #expect(settings.spendCapUSD == 0)
  }

  @Test func nodSettingsRoundTripThroughGraphcodeSettings() throws {
    var settings = GraphcodeSettings()
    settings.nod.switchEngine(to: .copilotSDK)
    settings.nod.disabledMCPServers = ["sentry"]
    settings.nod.addAllowlistPattern("make lint")
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(GraphcodeSettings.self, from: data)
    #expect(decoded.nod == settings.nod)
  }

  @Test func olderSettingsWithoutTheNewFieldStillDecode() throws {
    let decoded = try JSONDecoder().decode(
      NodSettings.self, from: Data(#"{"engine":"copilot","spendCapUSD":5}"#.utf8))
    #expect(decoded.engine == .copilotSDK)
    #expect(decoded.spendCapUSD == 5)
    #expect(decoded.disabledMCPServers.isEmpty)
  }
}

@Suite struct NodCredentialStoreTests {
  @Test func inMemoryStoreTracksSignInPerEngine() throws {
    let store = NodCredentialStore.inMemory()
    #expect(!store.isSignedIn(.claudeAgentSDK))
    try store.write("sk-ant-api03-0123456789abcdef", .anthropicAPIKey)
    #expect(store.isSignedIn(.claudeAgentSDK))
    #expect(!store.isSignedIn(.copilotSDK))
    try store.write("gho_token", .githubCopilot)
    #expect(store.isSignedIn(.copilotSDK))
    try store.signOut(.claudeAgentSDK)
    #expect(!store.isSignedIn(.claudeAgentSDK))
    #expect(store.isSignedIn(.copilotSDK))
  }

  @Test func anEmptySecretIsNotASignIn() throws {
    let store = NodCredentialStore.inMemory([.githubCopilot: ""])
    #expect(!store.isSignedIn(.copilotSDK))
  }

  @Test func liveKeychainWritesReadsOverwritesAndDeletes() throws {
    let store = NodCredentialStore.keychain(service: "app.graphcode.nod.tests.\(UUID())")
    defer { try? store.delete(.anthropicAPIKey) }
    #expect(try store.read(.anthropicAPIKey) == nil)
    try store.write("sk-ant-first", .anthropicAPIKey)
    #expect(try store.read(.anthropicAPIKey) == "sk-ant-first")
    try store.write("sk-ant-second", .anthropicAPIKey)
    #expect(try store.read(.anthropicAPIKey) == "sk-ant-second")
    try store.delete(.anthropicAPIKey)
    #expect(try store.read(.anthropicAPIKey) == nil)
    try store.delete(.anthropicAPIKey)
  }

  @Test func liveStoreUsesNodsKeychainService() {
    #expect(NodSettings.keychainService == "app.graphcode.nod")
  }
}

@Suite struct NodClaudeSignInTests {
  @Test func subscriptionLoginStaysOffUntilAnthropicApprovesIt() {
    #expect(!NodClaudeSignIn.subscriptionLoginAllowed)
  }

  @Test func apiKeyIsTrimmedAndChecked() {
    #expect(
      NodClaudeSignIn.validateAPIKey("  sk-ant-api03-abcdefghijklmnop\n")
        == .success("sk-ant-api03-abcdefghijklmnop"))
    #expect(NodClaudeSignIn.validateAPIKey("   ") == .failure(.empty))
    #expect(
      NodClaudeSignIn.validateAPIKey("gho_abcdefghijklmnopqrstuvwxyz")
        == .failure(.notAnAnthropicKey))
    #expect(NodClaudeSignIn.validateAPIKey("sk-ant-short") == .failure(.notAnAnthropicKey))
  }

  @Test func claudeCodeSignInIsFoundByKeychainItemOrFile() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "nod-home-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(!NodClaudeSignIn.claudeCodeSignInFound(home: home) { _ in false })
    #expect(NodClaudeSignIn.claudeCodeSignInFound(home: home) { $0 == "Claude Code-credentials" })
    try FileManager.default.createDirectory(
      at: home.appending(path: ".claude"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: home.appending(path: ".claude/.credentials.json"))
    #expect(NodClaudeSignIn.claudeCodeSignInFound(home: home) { _ in false })
  }
}

@Suite struct CopilotDeviceFlowTests {
  final class Script: @unchecked Sendable {
    var replies: [(String, Int, String)]
    var requests: [URLRequest] = []
    var sleeps: [Duration] = []
    let lock = NSLock()

    init(_ replies: [(String, Int, String)]) { self.replies = replies }

    func reply(to request: URLRequest) -> (Data, Int) {
      lock.withLock {
        requests.append(request)
        guard
          let index = replies.firstIndex(where: {
            request.url!.absoluteString.hasSuffix($0.0)
          })
        else { return (Data(), 404) }
        let reply = replies.remove(at: index)
        return (Data(reply.2.utf8), reply.1)
      }
    }

    func flow(clientID: String? = "Iv1.test", now: Date = Date(timeIntervalSince1970: 0))
      -> CopilotDeviceFlow
    {
      CopilotDeviceFlow(
        clientID: clientID,
        transport: { request in
          self.reply(to: request)
        },
        sleep: { duration in
          self.lock.withLock { self.sleeps.append(duration) }
        },
        now: { now })
    }
  }

  static let code = CopilotDeviceFlow.DeviceCode(
    deviceCode: "dev", userCode: "8F2K-QW7D",
    verificationURL: URL(string: "https://github.com/login/device")!,
    expiresAt: Date(timeIntervalSince1970: 900), interval: .seconds(5))

  @Test func requestsACodeWithTheClientIDAndScope() async throws {
    let script = Script([
      (
        "/login/device/code", 200,
        #"{"device_code":"dev","user_code":"8F2K-QW7D","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
      )
    ])
    let code = try await script.flow().requestCode()
    #expect(code == Self.code)
    let body = String(data: script.requests[0].httpBody!, encoding: .utf8)
    #expect(body == "client_id=Iv1.test&scope=read:user")
    #expect(script.requests[0].value(forHTTPHeaderField: "Accept") == "application/json")
  }

  @Test func withoutAClientIDItSaysSoInsteadOfCallingGitHub() async {
    let script = Script([])
    await #expect(throws: CopilotDeviceFlow.Failure.notConfigured) {
      try await script.flow(clientID: nil).requestCode()
    }
    #expect(script.requests.isEmpty)
  }

  @Test func pollsThroughPendingAndSlowDownToAToken() async throws {
    let script = Script([
      ("/login/oauth/access_token", 200, #"{"error":"authorization_pending"}"#),
      ("/login/oauth/access_token", 200, #"{"error":"slow_down","interval":10}"#),
      ("/login/oauth/access_token", 200, #"{"access_token":"gho_abc","token_type":"bearer"}"#),
    ])
    let token = try await script.flow().pollForToken(Self.code)
    #expect(token == "gho_abc")
    #expect(script.sleeps == [.seconds(5), .seconds(5), .seconds(10)])
    let body = String(data: script.requests[0].httpBody!, encoding: .utf8)!
    #expect(body.contains("grant_type=urn:ietf:params:oauth:grant-type:device_code"))
  }

  @Test func expiryAndDenialEndThePoll() async {
    let expired = Script([("/login/oauth/access_token", 200, #"{"error":"expired_token"}"#)])
    await #expect(throws: CopilotDeviceFlow.Failure.expired) {
      try await expired.flow().pollForToken(Self.code)
    }
    let denied = Script([("/login/oauth/access_token", 200, #"{"error":"access_denied"}"#)])
    await #expect(throws: CopilotDeviceFlow.Failure.denied) {
      try await denied.flow().pollForToken(Self.code)
    }
    let late = Script([])
    await #expect(throws: CopilotDeviceFlow.Failure.expired) {
      try await late.flow(now: Date(timeIntervalSince1970: 901)).pollForToken(Self.code)
    }
    #expect(late.requests.isEmpty)
  }

  @Test func readsTheAccountPlanPremiumRequestsAndModels() async throws {
    let script = Script([
      ("api.github.com/user", 200, #"{"login":"scgopi"}"#),
      (
        "/copilot_internal/user", 200,
        #"{"copilot_plan":"business","quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":88,"unlimited":false}}}"#
      ),
      ("/copilot_internal/v2/token", 200, #"{"token":"tid=abc"}"#),
      (
        "/models", 200,
        #"{"data":[{"id":"a","model_picker_enabled":true},{"id":"b"},{"id":"c","model_picker_enabled":false}]}"#
      ),
    ])
    let account = try await script.flow().account(token: "gho_abc")
    #expect(
      account
        == .init(
          login: "scgopi", plan: "business", modelCount: 2, premiumRequestsUsed: 212,
          premiumRequestsLimit: 300))
    #expect(account.planName == "Copilot Business")
    #expect(script.requests[0].value(forHTTPHeaderField: "Authorization") == "token gho_abc")
    #expect(script.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer tid=abc")
  }

  @Test func aMissingPlanStillSignsIn() async throws {
    let script = Script([("api.github.com/user", 200, #"{"login":"scgopi"}"#)])
    let account = try await script.flow().account(token: "gho_abc")
    #expect(account == .init(login: "scgopi"))
    #expect(CopilotSignInText.accountDetail(account) == "")
  }

  @Test func signInText() {
    let now = Date(timeIntervalSince1970: 0)
    #expect(
      CopilotSignInText.countdown(until: Date(timeIntervalSince1970: 852), now: now) == "14:12")
    #expect(CopilotSignInText.countdown(until: Date(timeIntervalSince1970: -5), now: now) == "0:00")
    #expect(
      CopilotSignInText.accountDetail(
        .init(
          login: "scgopi", plan: "business", modelCount: 7, premiumRequestsUsed: 212,
          premiumRequestsLimit: 300))
        == "7 models available · premium requests 212 / 300 this month")
  }
}

@Suite struct AgentMenuSectionTests {
  @Test func groupsChatThenTerminal() {
    let sections = AgentMenuSection.sections(for: .sketch)
    #expect(sections.map(\.title) == ["Chat", "Terminal"])
    #expect(sections[0].entries.map(\.backend) == [.nod])
    #expect(
      sections[1].entries.map(\.backend) == [.claudeCode, .codex, .copilotCLI, .openCode, .pi])
  }

  @Test func withNodsRampOffOnlyTerminalIsOffered() {
    let sections = AgentMenuSection.sections(for: .sketch, nodEnabled: false)
    #expect(sections.map(\.title) == ["Terminal"])
    #expect(!CLISessionBackendKind.agentsOffered(nodEnabled: false).contains(.nod))
    #expect(CLISessionBackendKind.agentsOffered(nodEnabled: true).first == .nod)
  }

  @Test func nodIsHeldToTheBetaRamp() {
    #expect(FeatureRamps.Feature.nod.defaultPercents == ["beta": 100, "stable": 0])
  }

  @Test func greyingFollowsCanHost() {
    for loopType in LoopType.allCases {
      for entry in AgentMenuSection.sections(for: loopType).flatMap(\.entries) {
        #expect(entry.isEnabled == entry.backend.canHost(loopType))
        #expect((entry.note == nil) == entry.isEnabled)
      }
    }
  }

  @Test func piIsGreyedForACompositeWithTheReason() {
    let pi = AgentMenuSection.sections(for: .composite)[1].entries.first { $0.backend == .pi }
    #expect(pi?.isEnabled == CLISessionBackendKind.pi.canHost(.composite))
    if pi?.isEnabled == false { #expect(pi?.note == "no sub-agents") }
  }

  @Test func nodWaitsForItsRuntime() {
    let nod = AgentMenuSection.sections(for: .sketch)[0].entries[0]
    #expect(nod.isEnabled == CLISessionBackendKind.nod.isSpiked)
    if !nod.isEnabled { #expect(nod.note == "not available yet") }
  }

  @Test func labelNamesNodsModel() {
    let nod = NodSettings()
    #expect(
      AgentMenuSection.label(backend: .nod, tier: nil, loopType: .goalBased, nod: nod)
        == "Nod · Opus")
    #expect(
      AgentMenuSection.label(backend: .nod, tier: .fast, loopType: .goalBased, nod: nod)
        == "Nod · Haiku")
    #expect(
      AgentMenuSection.label(backend: .codex, tier: .fast, loopType: .goalBased, nod: nod)
        == "Codex")
  }
}

@Suite struct NodCardPresentationTests {
  static func nodNode(state: LoopState = .running, activity: String? = nil) -> LoopNode {
    LoopNode(
      title: "Monetization", loopType: .goalBased,
      goal: GoalSpec(summary: "every paid route enforces the cap"), backend: .nod,
      activity: activity, state: state)
  }

  @Test func goalClausesBecomeAProgressBar() {
    let card = LoopCardPresentation(
      node: Self.nodNode(activity: "Running swift test · turn 4"),
      nod: NodCardDetail(goalMet: 1, goalTotal: 2))
    #expect(card.liveLine == "Running swift test · turn 4")
    #expect(card.detail == .progress(.init(fraction: 0.5, readings: "goal 1 / 2", change: "")))
    #expect(card.showsNodGlyph)
    #expect(card.meta.contains("Nod"))
  }

  @Test func allClausesMetFillsTheBar() {
    let card = LoopCardPresentation(
      node: Self.nodNode(), nod: NodCardDetail(goalMet: 3, goalTotal: 3))
    #expect(card.detail == .progress(.init(fraction: 1, readings: "goal 3 / 3", change: "all met")))
  }

  @Test func aPendingAskOutranksProgressAndTheGenericReply() {
    let ask = NodCardDetail.Ask(
      askID: "a1", kind: .shell, subject: "swift test", answerableFromCard: true)
    let card = LoopCardPresentation(
      node: Self.nodNode(state: .awaitingInput, activity: "asks to run swift test"),
      nod: NodCardDetail(goalMet: 1, goalTotal: 2, ask: ask))
    #expect(card.detail == .nodAsk(ask))
    #expect(card.liveLine == "asks to run swift test")
  }

  @Test func withoutNodStateANodCardDrawsLikeAnyOther() {
    let card = LoopCardPresentation(node: Self.nodNode())
    #expect(card.detail == .none)
    #expect(card.showsNodGlyph)
  }

  @Test func cliCardsIgnoreNodDetailAndKeepTheBadgeRule() {
    let codex = LoopNode(title: "Billing UI", loopType: .turnBased, backend: .codex)
    let card = LoopCardPresentation(node: codex, nod: NodCardDetail(goalMet: 1, goalTotal: 2))
    #expect(card.detail == .none)
    #expect(!card.showsNodGlyph)
    #expect(card.meta.contains("Codex"))
    let claude = LoopCardPresentation(node: LoopNode(title: "x", loopType: .sketch))
    #expect(!claude.meta.contains("Claude Code"))
  }

  @Test func zeroClausesDrawNoBar() {
    let card = LoopCardPresentation(
      node: Self.nodNode(), nod: NodCardDetail(goalMet: 0, goalTotal: 0))
    #expect(card.detail == .none)
  }
}

@Suite struct NodMCPServerTests {
  @Test func parsesLocalAndRemoteServers() {
    let json = #"""
      {"mcpServers":{
        "github":{"type":"http","url":"https://api.githubcopilot.com/mcp","headers":{"Authorization":"Bearer x"}},
        "sentry":{"type":"http","url":"https://mcp.sentry.dev/mcp"},
        "legacy":{"url":"https://example.com/sse"},
        "files":{"command":"npx","args":["fs"]},
        "graphcode":{"command":"graphcode"}
      }}
      """#
    let servers = NodMCPServer.parse(Data(json.utf8), projectName: "graphcode")
    #expect(servers.map(\.name) == ["files", "github", "legacy", "sentry"])
    #expect(servers.filter(\.needsSignIn).map(\.name) == ["legacy", "sentry"])
    #expect(servers.allSatisfy { $0.source == .project("graphcode") })
  }

  @Test func brokenJSONYieldsNothing() {
    #expect(NodMCPServer.parse(Data("{".utf8), projectName: "p").isEmpty)
    #expect(NodMCPServer.parse(Data("[]".utf8), projectName: "p").isEmpty)
  }

  @Test func loadsBuiltInFirstAndFirstProjectWinsOnAClash() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "nod-mcp-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    for (name, body) in [
      ("a", #"{"mcpServers":{"github":{"command":"gh"}}}"#),
      ("b", #"{"mcpServers":{"github":{"url":"https://x"},"sentry":{"url":"https://s"}}}"#),
    ] {
      let dir = root.appending(path: name)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try Data(body.utf8).write(to: dir.appending(path: ".mcp.json"))
    }
    let servers = NodMCPServer.load(projects: [
      ProjectRef(path: root.appending(path: "a").path, name: "a"),
      ProjectRef(path: root.appending(path: "b").path, name: "b"),
      ProjectRef(path: "ssh://host/repo", name: "remote"),
    ])
    #expect(servers.map(\.name) == ["graphcode", "github", "sentry"])
    #expect(servers[1].source == .project("a"))
    #expect(!servers[1].needsSignIn)
  }
}

@MainActor
@Suite struct NodSetupModelTests {
  final class Box: @unchecked Sendable {
    var settings = NodSettings()
    var opened: [URL] = []
  }

  static func model(
    _ box: Box, credentials: NodCredentialStore = .inMemory(),
    flow: CopilotDeviceFlow = CopilotDeviceFlow(clientID: nil, transport: { _ in (Data(), 500) }),
    copilotCLISignInFound: @escaping () -> Bool = { false }
  ) -> NodSetupModel {
    NodSetupModel(
      credentials: credentials, deviceFlow: flow,
      readSettings: { box.settings }, writeSettings: { box.settings = $0 },
      openURL: { box.opened.append($0) }, claudeCodeSignInFound: { true },
      copilotCLISignInFound: copilotCLISignInFound)
  }

  @Test func savingAValidKeySignsClaudeIn() throws {
    let box = Box()
    let store = NodCredentialStore.inMemory()
    let model = Self.model(box, credentials: store)
    #expect(!model.isSignedIn(.claudeAgentSDK))
    model.apiKeyDraft = "gho_wrongfield_abcdefghijk"
    model.saveAPIKey()
    #expect(model.apiKeyError != nil)
    #expect(!model.isSignedIn(.claudeAgentSDK))
    model.apiKeyDraft = " sk-ant-api03-abcdefghijklmnop "
    model.saveAPIKey()
    #expect(model.apiKeyError == nil)
    #expect(model.apiKeyDraft.isEmpty)
    #expect(model.isSignedIn(.claudeAgentSDK))
    #expect(try store.read(.anthropicAPIKey) == "sk-ant-api03-abcdefghijklmnop")
  }

  @Test func claudeCodeSignInIsNotOfferedWhileGated() {
    #expect(!Self.model(Box()).claudeCodeSignInFound)
  }

  @Test func selectingAnEngineWritesSettings() {
    let box = Box()
    let model = Self.model(box)
    model.selectEngine(.copilotSDK)
    #expect(box.settings.engine == .copilotSDK)
    #expect(model.settings.engine == .copilotSDK)
  }

  @Test func copilotDeviceFlowEndsSignedInWithTheTokenInTheKeychain() async throws {
    let box = Box()
    let store = NodCredentialStore.inMemory()
    let script = CopilotDeviceFlowTests.Script([
      (
        "/login/device/code", 200,
        #"{"device_code":"dev","user_code":"8F2K-QW7D","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
      ),
      ("/login/oauth/access_token", 200, #"{"access_token":"gho_abc"}"#),
      ("api.github.com/user", 200, #"{"login":"scgopi"}"#),
    ])
    let model = Self.model(box, credentials: store, flow: script.flow(now: Date()))
    model.startCopilotSignIn()
    await model.waitForCopilotSignIn()
    #expect(model.copilotPhase == .signedIn(.init(login: "scgopi")))
    #expect(try store.read(.githubCopilot) == "gho_abc")
    #expect(model.isSignedIn(.copilotSDK))
    #expect(box.opened == [URL(string: "https://github.com/login/device")!])
    model.signOut(.copilotSDK)
    #expect(model.copilotPhase == .idle)
    #expect(!model.isSignedIn(.copilotSDK))
  }

  /// NodRuntime's Copilot engine falls back to the Copilot CLI's own login, so a Mac
  /// signed in there is signed in for Nod, with nothing of Nod's to sign out of.
  @Test func theCopilotCLILoginSignsCopilotIn() {
    var found = false
    let model = Self.model(Box(), copilotCLISignInFound: { found })
    #expect(!model.isSignedIn(.copilotSDK))
    #expect(!model.canStartDeviceFlow)

    found = true
    model.refreshSignIn()

    #expect(model.isSignedIn(.copilotSDK))
    #expect(model.usesCopilotCLISignIn)
    #expect(model.copilotPhase == .signedIn(nil))
  }

  @Test func nodsOwnTokenWinsOverTheCopilotCLILogin() {
    let model = Self.model(
      Box(), credentials: .inMemory([.githubCopilot: "gho_x"]), copilotCLISignInFound: { true })
    #expect(model.isSignedIn(.copilotSDK))
    #expect(!model.usesCopilotCLISignIn)
  }

  /// The runtime reads `github-token` (NodRuntime/src/credentials.ts); a token written under
  /// any other account never reaches the Copilot engine.
  @Test func theCopilotTokenIsStoredWhereTheRuntimeReadsIt() {
    #expect(NodCredential.githubCopilot.rawValue == "github-token")
  }

  @Test func anUnconfiguredBuildSaysSo() async {
    let model = Self.model(Box())
    model.startCopilotSignIn()
    await model.waitForCopilotSignIn()
    #expect(model.copilotPhase == .failed("This build has no GitHub sign-in configured."))
  }
}
