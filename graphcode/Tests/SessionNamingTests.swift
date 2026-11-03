import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit
@testable import graphcode

/// A loop's title as its session's name, behind the `sessionNaming` ramp.
///
/// The per-backend shapes were read off real sessions (2026-10-11): Claude Code 2.1.296
/// and pi 0.85.1 take `--name` at launch and on resume, Copilot 1.0.96 takes it at launch
/// but exits 1 when it rides beside `--resume`, and Codex 0.160.0 and OpenCode have no
/// launch flag at all.
@Suite
struct SessionNamingTests {
  private let nodeID = UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID()

  private var sessionName: String {
    SurfaceRef(id: nodeID, launchesClaudeCode: true).zmxSessionName
  }

  private func node(_ backend: CLISessionBackendKind, title: String = "Fix login") -> LoopNode {
    LoopNode(
      id: nodeID, title: title, loopType: .goalBased, goal: GoalSpec(summary: "Tests pass"),
      backend: backend)
  }

  private func nameValue(in arguments: [String]) -> String? {
    arguments.firstIndex(of: "--name").map { arguments[$0 + 1] }
  }

  @Test
  func claudeCodeIsNamedAtLaunchAndOnResume() {
    #expect(
      CLISessionBackendKind.claudeCode.nameArguments(displayName: "Fix login", resuming: false)
        == ["--name", "Fix login"])
    #expect(
      CLISessionBackendKind.claudeCode.nameArguments(displayName: "Fix login", resuming: true)
        == ["--name", "Fix login"])
  }

  /// pi appends a `session_info` record for every `--name`, even an unchanged one.
  @Test
  func piIsNamedOnlyAtFirstLaunch() {
    #expect(
      CLISessionBackendKind.pi.nameArguments(displayName: "Fix login", resuming: false)
        == ["--name", "Fix login"])
    #expect(
      CLISessionBackendKind.pi.nameArguments(displayName: "Fix login", resuming: true).isEmpty)
  }

  @Test(arguments: [CLISessionBackendKind.copilotCLI, .codex, .openCode, .nod])
  func backendsWithoutAPlainNameFlagGetNone(_ backend: CLISessionBackendKind) {
    #expect(backend.nameArguments(displayName: "Fix login", resuming: false).isEmpty)
  }

  @Test
  func aBlankOrMultilineTitleIsCleanedUp() {
    #expect(
      CLISessionBackendKind.claudeCode.nameArguments(displayName: "  \n ", resuming: false).isEmpty)
    #expect(
      CLISessionBackendKind.claudeCode.nameArguments(displayName: "Fix\nlogin", resuming: false)
        == ["--name", "Fix login"])
  }

  @Test
  func copilotsNameKeepsTheNodesShortID() {
    let arguments = CLISessionBackendKind.copilotCLI.presenceArguments(
      hooksFile: nil, sessionName: sessionName, displayName: "Fix login")
    #expect(arguments == ["--name", "Fix login · 11111111"])
    #expect(
      CLISessionBackendKind.copilotCLI.presenceArguments(hooksFile: nil, sessionName: sessionName)
        == ["--name", sessionName])
  }

  @Test
  func copilotsLookupAcceptsEitherNaming() {
    #expect(CLISessionBackendKind.isCopilotSessionName(sessionName, for: sessionName))
    #expect(CLISessionBackendKind.isCopilotSessionName("Fix login · 11111111", for: sessionName))
    #expect(
      CLISessionBackendKind.isCopilotSessionName(#""Fix: login · 11111111""#, for: sessionName))
    #expect(!CLISessionBackendKind.isCopilotSessionName("Fix login · 99999999", for: sessionName))
    #expect(!CLISessionBackendKind.isCopilotSessionName("Fix login", for: sessionName))
  }

  @Test
  func copilotsSessionDirectoryIsFoundByItsTitledName() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("session-naming-\(UUID().uuidString)", isDirectory: true)
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "client_name: github/cli\nname: Fix login · 11111111\nuser_named: true\n".write(
      to: directory.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
    let found = CopilotSessionLog.directory(forSessionNamed: sessionName, in: root)
    #expect(found?.lastPathComponent == directory.lastPathComponent)
  }

  @Test
  func theRampOffLeavesEveryLaunchUnnamed() {
    SessionNaming.$rampOverride.withValue(false) {
      let claude = ZmxSessionLauncher.arguments(forNode: node(.claudeCode)) ?? []
      #expect(!claude.contains("--name"))
      let copilot = ZmxSessionLauncher.arguments(forNode: node(.copilotCLI)) ?? []
      #expect(nameValue(in: copilot) == sessionName)
    }
  }

  @Test
  func theDaemonNamesAFreshSessionAfterItsLoop() {
    SessionNaming.$rampOverride.withValue(true) {
      #expect(
        nameValue(in: ZmxSessionLauncher.arguments(forNode: node(.claudeCode)) ?? []) == "Fix login"
      )
      #expect(nameValue(in: ZmxSessionLauncher.arguments(forNode: node(.pi)) ?? []) == "Fix login")
      #expect(
        nameValue(in: ZmxSessionLauncher.arguments(forNode: node(.copilotCLI)) ?? [])
          == "Fix login · 11111111")
    }
  }

  /// Copilot exits 1 on `--resume` beside `--name`; pi would append a duplicate record.
  @Test
  func theDaemonsResumeNamesOnlyClaudeCode() {
    SessionNaming.$rampOverride.withValue(true) {
      let resume = { (backend: CLISessionBackendKind) in
        ZmxSessionLauncher.resumeArguments(forNode: node(backend), sessionID: "abc") ?? []
      }
      #expect(nameValue(in: resume(.claudeCode)) == "Fix login")
      #expect(!resume(.copilotCLI).contains("--name"))
      #expect(!resume(.pi).contains("--name"))
    }
  }

  @Test
  func aPaneStartedSessionIsNamedLikeTheDaemons() {
    SessionNaming.$rampOverride.withValue(true) {
      let pane = GhosttyTerminalView(
        surfaceID: UUID(), sessionName: sessionName, launchesClaudeCode: true,
        backend: .claudeCode, initialPrompt: "go", loopTitle: "Fix login",
        workingDirectory: nil, onProcessExited: { _ in })
      let command = pane.agentCommand(settings: GraphcodeSettings())?.last ?? ""
      #expect(command.contains("'--name' 'Fix login'"))
      let resume =
        pane.resumeCommand(settings: GraphcodeSettings(), remoteSettingsPath: nil)?.last ?? ""
      #expect(resume.contains("'--name' 'Fix login'"))
    }
  }

  /// OpenCode's TUI rejects `--title`, so the title reaches graphcode's plugin instead.
  @Test
  func openCodesTitleRidesInTheEnvironmentToItsPlugin() {
    SessionNaming.$rampOverride.withValue(true) {
      let arguments = ZmxSessionLauncher.arguments(forNode: node(.openCode)) ?? []
      #expect(!arguments.contains("--title"))
      #expect(
        arguments.contains { $0.contains("GRAPHCODE_SESSION_TITLE=") && $0.contains("Fix login") })
    }
    SessionNaming.$rampOverride.withValue(false) {
      let arguments = ZmxSessionLauncher.arguments(forNode: node(.openCode)) ?? []
      #expect(!arguments.contains { $0.contains("GRAPHCODE_SESSION_TITLE") })
    }
    #expect(CLISessionBackendKind.claudeCode.nameEnvironment(displayName: "Fix login").isEmpty)
  }

  @Test
  func openCodesPluginTitlesOnlyTheSessionItCreated() {
    let source = OpenCodePresencePlugin.source(zmxPath: "/z", sessionsDirectory: "/s")
    #expect(source.contains("process.env.GRAPHCODE_SESSION_TITLE"))
    #expect(
      source.contains("client.session.update({ path: { id: main }, body: { title: TITLE } })"))
  }

  @Test
  func aTitleCannotRunCodeThroughTheEnvironment() {
    let environment = CLISessionBackendKind.openCode.nameEnvironment(
      displayName: #"Fix "$(touch /tmp/x)" `id` \ now!"#)
    #expect(environment["GRAPHCODE_SESSION_TITLE"] == "Fix (touch /tmp/x) id  now")
  }

  @Test
  func theUntitledPlaceholderIsNeverASessionName() {
    SessionNaming.$rampOverride.withValue(true) {
      #expect(SessionNaming.displayName(forTitle: NodeDraft.untitledFallback) == nil)
      let claude =
        ZmxSessionLauncher.arguments(
          forNode: node(.claudeCode, title: NodeDraft.untitledFallback)) ?? []
      #expect(!claude.contains("--name"))
    }
  }

  private func typedAfterRenaming(
    _ backend: CLISessionBackendKind, to title: String = "Fix login",
    state: LoopState = .running, ramp: Bool = true
  ) async -> (typed: [String], memory: [String]) {
    let typed = LockIsolated<[String]>([])
    let memory = LockIsolated<[String]>([])
    var loop = node(backend, title: NodeDraft.untitledFallback)
    loop.state = state
    let store = GraphStore(
      graph: LoopGraph(project: ProjectRef(path: "/tmp/naming", name: "naming"), nodes: [loop]),
      onDeliverMessage: { _, text, _ in
        typed.withValue { $0.append(text) }
        return true
      },
      onAppendMemory: { _, note in memory.withValue { $0.append(note) } })
    await SessionNaming.$rampOverride.withValue(ramp) {
      await store.handle(.renameNode(nodeID, title: title))
      await store.finishSessionTyping()
    }
    return (typed.value, memory.value)
  }

  /// The suggested title lands after the session started, so it goes in as `/rename`,
  /// which Claude Code 2.1.296 applies even mid-turn.
  @Test
  func aRenamedClaudeLoopRenamesItsLiveSession() async {
    let result = await typedAfterRenaming(.claudeCode)
    #expect(result.typed == ["/rename Fix login"])
    #expect(result.memory.isEmpty)
  }

  /// A finished loop's session often stays up for follow-up questions.
  @Test(arguments: [LoopState.succeeded, .failed])
  func aFinishedLoopsOpenSessionIsRenamedToo(_ state: LoopState) async {
    #expect(await typedAfterRenaming(.claudeCode, state: state).typed == ["/rename Fix login"])
  }

  /// Copilot 1.0.96 applies a typed `/rename` idle and mid-turn, and the short id has to
  /// survive it: the name is how `CopilotSessionLog` finds the session afterwards.
  @Test
  func aRenamedCopilotLoopKeepsItsLookupKey() async throws {
    let result = await typedAfterRenaming(.copilotCLI)
    #expect(result.typed == ["/rename Fix login · 11111111"])
    #expect(result.memory.isEmpty)
    let name = try #require(result.typed.first?.dropFirst("/rename ".count))
    #expect(CLISessionBackendKind.isCopilotSessionName(String(name), for: sessionName))
  }

  @Test(arguments: [LoopState.succeeded, .failed])
  func aFinishedCopilotLoopsOpenSessionIsRenamedToo(_ state: LoopState) async {
    #expect(
      await typedAfterRenaming(.copilotCLI, state: state).typed
        == ["/rename Fix login · 11111111"])
  }

  @Test(arguments: [CLISessionBackendKind.claudeCode, .copilotCLI])
  func aRenameWaitsForTheRampAndARealTitle(_ backend: CLISessionBackendKind) async {
    #expect(await typedAfterRenaming(backend, ramp: false).typed.isEmpty)
    #expect(await typedAfterRenaming(backend, to: NodeDraft.untitledFallback).typed.isEmpty)
  }

  @Test(arguments: [CLISessionBackendKind.codex, .openCode, .pi, .nod])
  func aRenameReachesNoSessionItCannotName(_ backend: CLISessionBackendKind) async {
    #expect(await typedAfterRenaming(backend).typed.isEmpty)
  }
}
