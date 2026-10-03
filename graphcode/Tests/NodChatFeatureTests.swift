import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

private actor CommandSink {
  private(set) var commands: [NodCommand] = []
  func append(_ command: NodCommand) { commands.append(command) }
}

@MainActor
@Suite
struct NodChatFeatureTests {
  private static let directory = URL(fileURLWithPath: "/tmp/nod-test")

  private func makeStore(
    log: NodLog = NodLog(), sink: CommandSink = CommandSink(),
    send: (@Sendable (NodCommand) async throws -> Void)? = nil
  ) -> TestStoreOf<NodChatFeature> {
    var state = NodChatFeature.State(
      nodeID: UUID(), stateDirectory: Self.directory, loopTitle: "Monetization",
      loopType: .goalBased, goal: "Done when every paid route enforces the cap")
    state.transcript = log.transcript
    let store = TestStore(initialState: state) {
      NodChatFeature()
    } withDependencies: {
      $0.nodClient.send = { _, command in
        if let send { try await send(command) } else { await sink.append(command) }
      }
    }
    store.exhaustivity = .off
    return store
  }

  /// A finished loop's session may have ended, and a chat pane cannot attach one into
  /// being: an unreachable runtime is asked for, and the message is delivered once it is up.
  @Test
  func aMessageToAStoppedRuntimeAsksForItAndIsDeliveredWhenItIsUp() async {
    let attempts = LockIsolated(0)
    let clock = TestClock()
    var state = NodChatFeature.State(
      nodeID: UUID(), stateDirectory: Self.directory, loopTitle: "Monetization",
      loopType: .goalBased, goal: "Done when every paid route enforces the cap")
    state.draft = "one more thing"
    let store = TestStore(initialState: state) {
      NodChatFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.nodClient.send = { _, _ in
        let attempt = attempts.withValue {
          $0 += 1
          return $0
        }
        if attempt < 3 { throw NodControlError.unreachable("connect: 2") }
      }
    }
    store.exhaustivity = .off

    await store.send(.returnPressed)
    await store.skipReceivedActions()
    #expect(store.state.isStartingRuntime)
    #expect(store.state.sendError == nil)

    await clock.advance(by: .seconds(2))
    await store.skipReceivedActions()

    #expect(!store.state.isStartingRuntime)
    #expect(store.state.sendError == nil)
    #expect(attempts.value == 3)
  }

  @Test
  func theTailFeedsTheTranscript() async {
    let log = NodLog.monetization
    let store = TestStore(
      initialState: NodChatFeature.State(
        nodeID: UUID(), stateDirectory: Self.directory, loopTitle: "M", loopType: .goalBased)
    ) {
      NodChatFeature()
    } withDependencies: {
      $0.nodClient.events = { directory in
        #expect(directory == Self.directory)
        return AsyncStream { continuation in
          continuation.yield(log.records)
          continuation.finish()
        }
      }
    }
    store.exhaustivity = .off
    await store.send(.task)
    await store.receive(\.eventsReceived)
    #expect(store.state.transcript == log.transcript)
  }

  @Test
  func returnQueuesAndCommandReturnSteersWithTheAttachments() async {
    let sink = CommandSink()
    let store = makeStore(log: .monetization, sink: sink)
    let file = NodAttachment(kind: .file, reference: "/repo/UsageGate.swift")

    await store.send(.attachmentAdded(file))
    await store.send(.draftChanged("  also log blocks  "))
    await store.send(.returnPressed)
    await store.receive(\.commandFinished)
    #expect(store.state.draft == "")
    #expect(store.state.attachments.isEmpty)

    await store.send(.draftChanged("use the fixture clock"))
    await store.send(.commandReturnPressed)
    await store.receive(\.commandFinished)

    #expect(
      await sink.commands == [
        .send(.init(text: "also log blocks", delivery: .queue, attachments: [file])),
        .send(.init(text: "use the fixture clock", delivery: .steer)),
      ])
  }

  @Test
  func anEmptyDraftSendsNothing() async {
    let sink = CommandSink()
    let store = makeStore(sink: sink)
    await store.send(.draftChanged("   "))
    await store.send(.returnPressed)
    #expect(await sink.commands.isEmpty)
  }

  @Test
  func escapeClosesWhatIsOpenBeforeItStopsNod() async {
    let sink = CommandSink()
    let store = makeStore(log: .monetization, sink: sink)

    await store.send(.forkMenuToggled(messageID: "m1"))
    await store.send(.escapePressed)
    #expect(store.state.forkMenuMessageID == nil)

    await store.send(.draftChanged("/com"))
    await store.send(.escapePressed)
    #expect(store.state.draft == "")
    #expect(await sink.commands.isEmpty)

    await store.send(.escapePressed)
    await store.receive(\.commandFinished)
    #expect(await sink.commands == [.stop])
  }

  @Test
  func escapeWhileIdleStopsNothing() async {
    let sink = CommandSink()
    var log = NodLog()
    log.turn(1)
    log.endTurn(1)
    let store = makeStore(log: log, sink: sink)
    await store.send(.escapePressed)
    #expect(await sink.commands.isEmpty)
  }

  @Test
  func cardDecisionsGoOutAsCommands() async {
    let sink = CommandSink()
    let store = makeStore(log: .monetization, sink: sink)

    await store.send(.hunkDecided(hunkID: "h1", .accept))
    await store.receive(\.commandFinished)
    await store.send(.permissionDecided(askID: "a1", .alwaysAllow))
    await store.receive(\.commandFinished)
    await store.send(.markGoalDoneTapped)
    await store.receive(\.commandFinished)
    await store.send(.compactNowTapped)
    await store.receive(\.commandFinished)
    await store.send(.forkChosen(messageID: "m1", asSibling: false))
    await store.receive(\.commandFinished)

    #expect(
      await sink.commands == [
        .resolveHunk(.init(hunkID: "h1", decision: .accept)),
        .resolvePermission(.init(askID: "a1", decision: .alwaysAllow)),
        .markGoalDone,
        .compact,
        .fork(.init(messageID: "m1")),
      ])
  }

  @Test
  func aCommentSendsTheHunkBackWithItsNote() async {
    let sink = CommandSink()
    let store = makeStore(log: .monetization, sink: sink)

    await store.send(.hunkDecided(hunkID: "h1", .comment))
    await store.receive(\.hunkCommentStarted)
    #expect(store.state.commentingHunkID == "h1")
    await store.send(.hunkCommentChanged("use 51 so it's past the cap"))
    await store.send(.hunkCommentSubmitted)
    await store.receive(\.commandFinished)

    #expect(store.state.commentingHunkID == nil)
    #expect(
      await sink.commands == [
        .resolveHunk(.init(hunkID: "h1", decision: .comment, note: "use 51 so it's past the cap"))
      ])
  }

  @Test
  func graphVerbsAndTheGoalGoUpAsDelegates() async {
    let sink = CommandSink()
    let store = makeStore(log: .monetization, sink: sink)

    await store.send(.draftChanged("/handoff Release notes"))
    await store.send(.returnPressed)
    await store.receive(\.delegate.graphCommand)

    await store.send(.draftChanged("/goal"))
    await store.send(.returnPressed)
    await store.receive(\.delegate.editGoal)

    await store.send(.forkChosen(messageID: "m1", asSibling: true))
    await store.receive(\.delegate.forkAsSibling)

    await store.send(.runPlanTapped(planID: "p1", mode: .composite))
    await store.receive(\.delegate.runPlanAsComposite)

    await store.send(.openInShellTabTapped(command: "swift test --filter UsageCap"))
    await store.receive(\.delegate.openInShellTab)

    #expect(await sink.commands.isEmpty)
  }

  @Test
  func runHereSendsThePlanAsTheHumanLeftIt() async {
    let sink = CommandSink()
    var log = NodLog.monetization
    log.add(
      "planProposed",
      [
        "planID": "p1", "title": "Caps",
        "steps": [["id": "s1", "text": "Move /export", "files": [], "editedByHuman": false]],
      ])
    let store = makeStore(log: log, sink: sink)
    let edited = [NodPlanStep(id: "s1", text: "Move /export and log it", editedByHuman: true)]

    await store.send(.runPlanTapped(planID: "p1", mode: .here))
    await store.receive(\.commandFinished)
    await store.send(.runPlanTapped(planID: "p1", mode: .here, steps: edited))
    await store.receive(\.commandFinished)

    #expect(
      await sink.commands == [
        .runPlan(
          .init(planID: "p1", steps: [NodPlanStep(id: "s1", text: "Move /export")], mode: .here)),
        .runPlan(.init(planID: "p1", steps: edited, mode: .here)),
      ])
  }

  @Test
  func slashCompactIsTheCompactCommand() async {
    let sink = CommandSink()
    let store = makeStore(sink: sink)
    await store.send(.draftChanged("/compact"))
    await store.send(.returnPressed)
    await store.receive(\.commandFinished)
    #expect(await sink.commands == [.compact])
  }

  @Test
  func aRunningLoopIsMessagedAndAFinishedOneAttachedWithTabSwapping() async {
    let running = UUID()
    let done = UUID()
    let store = makeStore()

    await store.send(.draftChanged("check that @bi"))
    await store.send(
      .mentionChosen(
        NodMention(title: "Billing UI", kind: .loop(id: running, isRunning: true, detail: "")),
        alternate: false))
    await store.receive(\.delegate.messageLoop)
    #expect(store.state.draft == "check that @Billing UI ")

    await store.send(.draftChanged("@mig"))
    await store.send(
      .mentionChosen(
        NodMention(
          title: "Billing migration", kind: .loop(id: done, isRunning: false, detail: "")),
        alternate: false))
    #expect(
      store.state.attachments == [
        NodAttachment(kind: .loopTranscript, reference: done.uuidString, label: "Billing migration")
      ])

    await store.send(.draftChanged("@bi"))
    await store.send(
      .mentionChosen(
        NodMention(title: "Billing UI", kind: .loop(id: running, isRunning: true, detail: "")),
        alternate: true))
    #expect(store.state.attachments.count == 2)
  }

  @Test
  func aChosenModelShowsOnceTheRuntimeTakesIt() async {
    let store = makeStore(log: .monetization)
    #expect(store.state.model == "claude-sonnet-4-5")
    await store.send(.modelChosen("opus"))
    await store.receive(\.commandFinished)
    #expect(store.state.model == "opus")
  }

  @Test
  func aGatedCommandTheRuntimeRefusesIsDisabledNotAnError() async {
    let store = makeStore(log: .monetization) { command in
      if command.type == "fork" { throw NodControlError.rejected("fork is not available yet") }
    }
    await store.send(.forkChosen(messageID: "m1", asSibling: false))
    await store.receive(\.commandFinished)
    #expect(store.state.unavailableCommands == ["fork"])
    #expect(store.state.sendError == nil)
  }

  @Test
  func alwaysAllowingAShellCommandSavesItToTheProjectAllowlist() async {
    let saved = LockIsolated<[String]>([])
    var log = NodLog.monetization
    log.ask("net", kind: "network", subject: "curl example.com", reason: "network")
    var state = NodChatFeature.State(
      nodeID: UUID(), stateDirectory: URL(fileURLWithPath: "/tmp/nod-test"), loopTitle: "M",
      loopType: .goalBased)
    state.transcript = log.transcript
    let store = TestStore(initialState: state) {
      NodChatFeature()
    } withDependencies: {
      $0.nodClient.send = { _, _ in }
      $0.nodSettings.addAllowlistPattern = { command in saved.withValue { $0.append(command) } }
    }
    store.exhaustivity = .off

    await store.send(.permissionDecided(askID: "a1", .allowOnce))
    await store.receive(\.commandFinished)
    await store.send(.permissionDecided(askID: "net", .alwaysAllow))
    await store.receive(\.commandFinished)
    #expect(saved.value.isEmpty)

    await store.send(.permissionDecided(askID: "a1", .alwaysAllow))
    await store.receive(\.commandFinished)
    await store.finish()
    #expect(saved.value == ["swift package resolve"])
  }

  @Test
  func aRefusedCommandShowsItsError() async {
    let store = makeStore(log: .monetization) { _ in
      throw NodControlError.rejected("no such hunk")
    }
    await store.send(.hunkDecided(hunkID: "nope", .accept))
    await store.receive(\.commandFinished)
    #expect(store.state.sendError == "no such hunk")
    await store.send(.errorDismissed)
    #expect(store.state.sendError == nil)
  }

  @Test
  func failedToolCallsOpenOnTheirOwn() {
    var log = NodLog()
    log.turn(1)
    log.tool("ok", turn: 1, tool: "Bash", title: "ls")
    log.tool("bad", turn: 1, tool: "Bash", title: "swift build", status: "error")
    var state = NodChatFeature.State(nodeID: UUID(), loopTitle: "M", loopType: .sketch)
    state.transcript = log.transcript
    let cards = state.transcript.turns[0].items.toolCards
    #expect(cards.map(state.isToolExpanded) == [false, true])
  }
}
