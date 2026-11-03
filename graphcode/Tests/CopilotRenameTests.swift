import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit
@testable import graphcode

/// What stands between a loop's new title and a live Copilot session: the window `/rename`
/// waits for, and the name the remote reads have to find afterwards.
@Suite
struct CopilotRenameTests {
  private let nodeID = UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID()

  private var sessionName: String {
    SurfaceRef(id: nodeID, launchesClaudeCode: true).zmxSessionName
  }

  private func node(_ backend: CLISessionBackendKind, title: String = "Fix login") -> LoopNode {
    LoopNode(
      id: nodeID, title: title, loopType: .goalBased, goal: GoalSpec(summary: "Tests pass"),
      backend: backend)
  }

  /// Copilot's first pass and its open questions both have to get out of the way first,
  /// and a rename that never gets a window is dropped rather than typed.
  @Test
  func aCopilotRenameWaitsForItsWindow() async {
    let typed = LockIsolated<[String]>([])
    let asked = LockIsolated(0)
    let store = GraphStore(
      graph: LoopGraph(
        project: ProjectRef(path: "/tmp/naming", name: "naming"),
        nodes: [node(.copilotCLI, title: NodeDraft.untitledFallback)]),
      onDeliverMessage: { _, text, _ in
        typed.withValue { $0.append(text) }
        return true
      },
      onAwaitRenameWindow: { _, _ in
        asked.withValue { $0 += 1 }
        return asked.value > 1
      })
    await SessionNaming.$rampOverride.withValue(true) {
      await store.handle(.renameNode(nodeID, title: "Closed"))
      await store.handle(.renameNode(nodeID, title: "Open"))
      await store.finishSessionTyping()
    }
    #expect(asked.value == 2)
    #expect(typed.value == ["/rename Open · 11111111"])
  }

  /// The title may have moved on by the time the window opens; only the newest is typed.
  @Test
  func aHeldRenameThatWasSupersededIsNotTyped() async {
    let typed = LockIsolated<[String]>([])
    let store = GraphStore(
      graph: LoopGraph(
        project: ProjectRef(path: "/tmp/naming", name: "naming"),
        nodes: [node(.copilotCLI, title: NodeDraft.untitledFallback)]),
      onDeliverMessage: { _, text, _ in
        typed.withValue { $0.append(text) }
        return true
      },
      onAwaitRenameWindow: { _, _ in
        try? await Task.sleep(for: .milliseconds(50))
        return true
      })
    await SessionNaming.$rampOverride.withValue(true) {
      await store.handle(.renameNode(nodeID, title: "Stale"))
      await store.handle(.renameNode(nodeID, title: "Fresh"))
      await store.finishSessionTyping()
    }
    #expect(typed.value == ["/rename Fresh · 11111111"])
  }

  /// Claude Code's rename has no such wait, so its timing stays what #703 shipped.
  @Test
  func aClaudeRenameAsksForNoWindow() async {
    let asked = LockIsolated(0)
    let store = GraphStore(
      graph: LoopGraph(
        project: ProjectRef(path: "/tmp/naming", name: "naming"),
        nodes: [node(.claudeCode, title: NodeDraft.untitledFallback)]),
      onDeliverMessage: { _, _, _ in true },
      onAwaitRenameWindow: { _, _ in
        asked.withValue { $0 += 1 }
        return true
      })
    await SessionNaming.$rampOverride.withValue(true) {
      await store.handle(.renameNode(nodeID, title: "Fix login"))
      await store.finishSessionTyping()
    }
    #expect(asked.value == 0)
  }

  @Test(arguments: [
    (lines: [#"{"type":"permission.requested","data":{}}"#], held: true),
    (
      lines: [#"{"type":"permission.requested"}"#, #"{"type":"permission.completed"}"#],
      held: false
    ),
    (
      lines: [#"{"type":"permission.requested"}"#, #"{"type":"session.resume"}"#],
      held: false
    ),
    (
      lines: [#"{"type":"tool.execution_start","data":{"toolCallId":"a","toolName":"ask_user"}}"#],
      held: true
    ),
    (
      lines: [
        #"{"type":"tool.execution_start","data":{"toolCallId":"a","toolName":"ask_user"}}"#,
        #"{"type":"tool.execution_complete","data":{"toolCallId":"b"}}"#,
      ],
      held: true
    ),
    (
      lines: [
        #"{"type":"tool.execution_start","data":{"toolCallId":"a","toolName":"ask_user"}}"#,
        #"{"type":"tool.execution_complete","data":{"toolCallId":"a"}}"#,
      ],
      held: false
    ),
    (
      lines: [#"{"type":"tool.execution_start","data":{"toolCallId":"a","toolName":"bash"}}"#],
      held: false
    ),
    (
      lines: [#"{"type":"assistant.message","data":{"content":"permission.requested"}}"#],
      held: false
    ),
  ])
  func aDecisionIsOnlyAnOpenQuestion(lines: [String], held: Bool) {
    #expect(CopilotSessionLog.holdsADecision(lines) == held)
  }

  @Test
  func aRemoteRenameOnlyProceedsOnAProvenAnswer() {
    let marker = ZmxSessionLauncher.remoteProbeMarker
    let pending = { CopilotSessionLog.remoteDecisionPending(succeeded: $0, output: $1) }
    #expect(pending(false, "\(marker) read"))
    #expect(pending(true, "a banner from zshrc"))
    #expect(pending(true, "\(marker) booting"))
    #expect(!pending(true, "\(marker) absent"))
    #expect(!pending(true, "banner\n\(marker) read"))
    #expect(pending(true, "{\"type\":\"permission.requested\"}\n\(marker) read"))
  }

  /// Runs the remote decision read against a fake home and a fake `zmx`, through the same
  /// wrapper a real dial uses.
  @Test
  func theRemoteDecisionReadFindsAnOpenDialogUnderATitledName() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("copilot-decision-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let session = home.appendingPathComponent(".copilot/session-state/the-session")
    let bin = home.appendingPathComponent("bin")
    for directory in [session, bin] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try "name: 'Fix: login · 11111111'\n".write(
      to: session.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
    try "{\"type\":\"permission.requested\"}\n".write(
      to: session.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
    let zmx = bin.appendingPathComponent("zmx")
    try "#!/bin/sh\nexit 0\n".write(to: zmx, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zmx.path)

    let location = RemoteProjectLocation(host: "box", remotePath: "/srv/widget")
    let invocation = CopilotSessionLog.remoteDecisionInvocation(
      forNode: node(.copilotCLI), at: location)
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", try #require(invocation.last)]
    process.environment = [
      "HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin", "LC_ALL": "en_US.UTF-8",
    ]
    process.standardOutput = pipe
    try process.run()
    let output = String(
      decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    #expect(output.contains("\(ZmxSessionLauncher.remoteProbeMarker) read"))
    #expect(CopilotSessionLog.remoteDecisionPending(succeeded: true, output: output))
  }

  @Test
  func copilotsNameFitsWhatItsRenameAccepts() throws {
    let name = CLISessionBackendKind.copilotSessionName(
      title: "A \"quoted\"\ttitle " + String(repeating: "x", count: 200), sessionName: sessionName)
    #expect(name.count <= 100)
    #expect(!name.contains("\""))
    #expect(!name.contains("\t"))
    #expect(CLISessionBackendKind.isCopilotSessionName(name, for: sessionName))
  }

  @Test
  func everyRemoteCopilotReadMatchesTheTitledName() {
    let location = RemoteProjectLocation(host: "box", remotePath: "/srv/widget")
    let node = node(.copilotCLI)
    let scripts = [
      CopilotSessionLog.remotePresenceInvocation(forNode: node, at: location),
      CopilotSessionLog.remoteSummaryInvocation(forNode: node, at: location, since: nil),
    ].map { $0.joined(separator: " ") }
    for script in scripts {
      #expect(script.contains(".* · 11111111"))
      #expect(!script.contains("grep -qx"))
    }
  }

  /// Every name Copilot can record for a node, in the spellings its YAML writer picks, as
  /// the remote walk reads them — a titled session it cannot find has no banked id, and a
  /// remote loop with no banked id restarts from scratch.
  @Test(arguments: [
    (locale: "en_US.UTF-8", name: "graphcode-11111111-2222-3333-4444-555555555555"),
    (locale: "en_US.UTF-8", name: "Fix login · 11111111"),
    (locale: "en_US.UTF-8", name: "'Fix: login · 11111111'"),
    (locale: "en_US.UTF-8", name: "\"Fix: login · 11111111\""),
    (locale: "C", name: "Fix login · 11111111"),
    (locale: "C", name: "'Fix: login · 11111111'"),
  ])
  func theRemoteWalkFindsEveryNameOfTheNode(locale: String, name: String) throws {
    let workspace = "client_name: github/cli\nname: \(name)\n"
    #expect(try bankedID(recording: workspace, locale: locale) != nil)
  }

  @Test(arguments: [
    "name: Fix login · 99999999",
    "name: Fix login",
    "name: graphcode-99999999-2222-3333-4444-555555555555",
    "client_name: Fix login · 11111111",
    "name: Fix login · 11111111x",
  ])
  func theRemoteWalkFindsNoOtherSession(line: String) throws {
    #expect(try bankedID(recording: "\(line)\n", locale: "en_US.UTF-8") == nil)
  }

  /// The pattern's quotes, `$` and `·` have to arrive intact through the one wrapper every
  /// remote script rides in.
  @Test
  func theRemoteWalkSurvivesTheLoginShellQuoting() throws {
    let location = RemoteProjectLocation(host: "box", remotePath: "/srv/widget")
    let workspace = "name: 'Fix: login · 11111111'\n"
    #expect(
      try bankedID(
        recording: workspace, locale: "en_US.UTF-8", wrap: location.remoteLoginShellCommand)
        != nil)
  }

  /// Runs the ensure's bank fragment under `/bin/sh` against a fake home, and reads back
  /// the id it banked.
  private func bankedID(
    recording workspace: String, locale: String, wrap: (String) -> String = { $0 }
  ) throws -> String? {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("copilot-walk-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let session = home.appendingPathComponent(".copilot/session-state/the-session")
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    try workspace.write(
      to: session.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", wrap(CopilotSessionLog.remoteIDBankFragment(forNodeID: nodeID))]
    process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "LC_ALL": locale]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let banked = home.appendingPathComponent(
      ".graphcode/sessions/\(nodeID.uuidString).id")
    return try? String(contentsOf: banked, encoding: .utf8)
  }

  /// `ask` held a real session at a prompt for two minutes with nothing in its log but
  /// `session.start`, so a session with an opening prompt counts as busy until it shows up.
  @Test
  func aSessionStillOpeningHoldsTheRename() {
    let start = #"{"type":"session.start"}"#
    let message = #"{"type":"user.message"}"#
    #expect(CopilotSessionLog.holdsADecision([start], expectingOpening: true))
    #expect(!CopilotSessionLog.holdsADecision([start, message], expectingOpening: true))
    #expect(!CopilotSessionLog.holdsADecision([start], expectingOpening: false))
    #expect(
      !CopilotSessionLog.holdsADecision(
        [start, #"{"type":"session.resume"}"#], expectingOpening: true))
  }
}
