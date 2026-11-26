import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit

/// The gaps the live five-backend run of #346 found on 0.1.70-beta2.
@Suite
struct GoalResolutionFollowUpTests {
  // MARK: - A follow-up question reaches a finished loop

  private func finishedTarget(
    alive: Bool, delivered: LockIsolated<[String]>, memory: LockIsolated<[String]>
  ) async -> (GraphStore, UUID) {
    let store = GraphStore(
      onDeliverMessage: { _, text, _ in
        delivered.withValue { $0.append(text) }
        return true
      },
      onSessionAlive: { _, _ in alive },
      onAppendMemory: { _, entry in memory.withValue { $0.append(entry) } })
    await store.handle(
      .createNode(
        NodeDraft(title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write it"))))
    let id = await store.graph.nodes[0].id
    await store.handle(.completeNode(id, result: nil, from: id))
    return (store, id)
  }

  @Test
  func aQuestionToAFinishedLoopWithALiveSessionIsTypedInAndChangesNothing() async {
    let delivered = LockIsolated<[String]>([])
    let memory = LockIsolated<[String]>([])
    let (store, id) = await finishedTarget(alive: true, delivered: delivered, memory: memory)
    let resolution = await store.graph.nodes[id: id]?.resolution

    await store.handle(.messageNode(id, text: "what did you change?", from: nil, followUp: false))
    await store.finishSessionTyping()

    #expect(delivered.value.contains { $0.contains("what did you change?") })
    #expect(!memory.value.contains { $0.hasPrefix("while you were away") })
    #expect(await store.graph.nodes[id: id]?.state == .succeeded)
    #expect(await store.graph.nodes[id: id]?.resolution == resolution)
  }

  @Test
  func aQuestionToAFinishedLoopWhoseSessionEndedIsStaged() async {
    let delivered = LockIsolated<[String]>([])
    let memory = LockIsolated<[String]>([])
    let (store, id) = await finishedTarget(alive: false, delivered: delivered, memory: memory)

    await store.handle(.messageNode(id, text: "what did you change?", from: nil, followUp: false))
    await store.finishSessionTyping()

    #expect(!delivered.value.contains { $0.contains("what did you change?") })
    #expect(memory.value.contains { $0.hasPrefix("while you were away") })
  }

  private func stoppedTarget(
    alive: Bool, delivered: LockIsolated<[String]>, memory: LockIsolated<[String]>
  ) async -> (GraphStore, UUID) {
    let store = GraphStore(
      onDeliverMessage: { _, text, _ in
        delivered.withValue { $0.append(text) }
        return true
      },
      onSessionAlive: { _, _ in alive },
      onAppendMemory: { _, entry in memory.withValue { $0.append(entry) } })
    await store.handle(
      .createNode(
        NodeDraft(title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write it"))))
    let id = await store.graph.nodes[0].id
    await store.handle(.stopNode(id))
    return (store, id)
  }

  @Test
  func aMessageToAStoppedLoopWithALiveSessionIsTypedInAndLeavesItStopped() async {
    let delivered = LockIsolated<[String]>([])
    let memory = LockIsolated<[String]>([])
    let (store, id) = await stoppedTarget(alive: true, delivered: delivered, memory: memory)
    let stopped = await store.graph.nodes[id: id]
    let state = stopped?.state
    #expect(stopped.map { MessageBus.deliverability(to: $0) != nil } == true)

    await store.handle(.messageNode(id, text: "status?", from: nil, followUp: false))
    await store.finishSessionTyping()

    #expect(delivered.value.contains { $0.contains("status?") })
    #expect(!memory.value.contains { $0.hasPrefix("while you were away") })
    #expect(await store.graph.nodes[id: id]?.state == state)
  }

  @Test
  func aMessageToAStoppedLoopWhoseSessionEndedIsStaged() async {
    let delivered = LockIsolated<[String]>([])
    let memory = LockIsolated<[String]>([])
    let (store, id) = await stoppedTarget(alive: false, delivered: delivered, memory: memory)

    await store.handle(.messageNode(id, text: "status?", from: nil, followUp: false))
    await store.finishSessionTyping()

    #expect(!delivered.value.contains { $0.contains("status?") })
    #expect(memory.value.contains { $0.hasPrefix("while you were away") })
  }

  // MARK: - /goal stays the command when the prompt moves to a file

  @Test
  func aPointerForADirectiveLedPromptStillOpensWithTheDirective() {
    let pointer = "Your complete instructions are in the file at /x/PROMPT.md - read it."
    let led = ZmxSessionLauncher.directiveLedPointer(
      pointer, prompt: "/goal Write the docs for the login flow", directive: "/goal")
    #expect(led == "/goal Write the docs for the login flow - \(pointer)")
    #expect(led.hasPrefix("/goal "))

    let long = "/goal " + String(repeating: "word ", count: 80)
    let cut = ZmxSessionLauncher.directiveLedPointer(pointer, prompt: long, directive: "/goal")
    #expect(cut.hasPrefix("/goal word"))
    #expect(cut.contains("... - \(pointer)"))

    #expect(
      ZmxSessionLauncher.directiveLedPointer(
        pointer, prompt: "/goal Write the docs", directive: "/goal", headLength: 0)
        == "/goal \(pointer)")
    #expect(
      ZmxSessionLauncher.directiveLedPointer(pointer, prompt: "Work toward it", directive: nil)
        == pointer)
    #expect(
      ZmxSessionLauncher.directiveLedPointer(pointer, prompt: "Plain prose", directive: "/goal")
        == pointer)
  }

  @Test
  func aLongCodexGoalLaunchesWithGoalAsTheCommand() {
    let goal = String(repeating: "Write the single line into the file and verify it. ", count: 60)
    let node = LoopNode(
      title: "Long", loopType: .goalBased, goal: GoalSpec(summary: goal), backend: .codex)
    defer { NodeMemory.remove(projectPath: "/tmp", nodeID: node.id) }

    let arguments =
      ZmxSessionLauncher.arguments(
        forNode: node, projectPath: "/tmp", settings: GraphcodeSettings()) ?? []

    let typedPrompt = arguments.first { $0.contains(NodeMemory.promptFileName) }
    #expect(typedPrompt?.hasPrefix("/goal Write the single line") == true)
  }

  // MARK: - A backend with no verdict of its own is told to report done

  @Test
  func openCodeAndPiGoalsAreToldToRunNodeDone() {
    for backend in [CLISessionBackendKind.openCode, .pi] {
      let node = LoopNode(
        title: "a", loopType: .goalBased, goal: GoalSpec(summary: "Ship it"), backend: backend)
      #expect(node.sessionPrompt?.hasSuffix(LoopNode.reportDoneSentence) == true)
    }
    for backend in [CLISessionBackendKind.claudeCode, .codex, .copilotCLI] {
      let node = LoopNode(
        title: "a", loopType: .goalBased, goal: GoalSpec(summary: "Ship it"), backend: backend)
      #expect(node.sessionPrompt?.contains("graphcode node done") == false)
    }
    let pi = LoopNode(
      title: "a", loopType: .goalBased, goal: GoalSpec(summary: "Ship it"), backend: .pi)
    let literal = pi.sessionPrompt(forProjectPath: "/Volumes/SCG/wd/graphcode") ?? ""
    #expect(
      literal.contains(
        "run: graphcode node done /Volumes/SCG/wd/graphcode \(pi.id.uuidString) <one-line result>"))
    #expect(!literal.contains(LoopNode.reportDoneSentence))
    let predicated = LoopNode(
      title: "a", loopType: .goalBased, goal: GoalSpec(summary: "Ship it", predicate: "true"),
      backend: .pi)
    #expect(predicated.sessionPrompt?.contains("graphcode node done") == false)
  }

  @Test
  func aChildGoalLoopIsHandedTheDoneCommandAtBirth() async {
    let memory = LockIsolated<[(UUID, String)]>([])
    let store = GraphStore(onAppendMemory: { id, entry in
      memory.withValue { $0.append((id, entry)) }
    })
    await store.handle(
      .createNode(NodeDraft(title: "Lead", loopType: .goalBased, goal: GoalSpec(summary: "Lead"))))
    let leader = await store.graph.nodes[0].id
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Child", loopType: .goalBased, goal: GoalSpec(summary: "Child work"),
          backend: .pi, createdBy: leader)))
    let child = await store.graph.nodes[1].id

    let birth = memory.value.first { $0.0 == child }?.1 ?? ""
    #expect(birth.contains("graphcode node send"))
    #expect(birth.contains("graphcode node done"))
    #expect(birth.contains(child.uuidString))
  }
}
