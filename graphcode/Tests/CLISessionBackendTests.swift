import Foundation
import Testing

@testable import GraphcodeKit

/// The backend abstraction (docs/04-cli-backends.md). These test the argv graphcode
/// builds and the honesty of the unspiked adapters — not `zmx` itself, which has its own
/// tests upstream and isn't installed in CI.
@Suite
struct CLISessionBackendTests {
  private let node = LoopNode(
    title: "Implement", loopType: .timeBased, triggerPrompt: "/loop 1h Check")

  @Test
  func aMessageIsSentToTheSameSessionTheAppAttachesTo() {
    // The shared session name is the whole mechanism: a message has to land in the
    // terminal a human can open, not a second session nobody can see.
    let arguments = ZmxSessionLauncher.sendArguments("please review", toNode: node)
    let expectedName = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName

    #expect(arguments == ["send", expectedName, "please review"])
  }

  @Test
  func aMultilineMessageIsFlattened() {
    // `zmx` terminates what it types with `\r`; an embedded newline would truncate the
    // message at its first line.
    let arguments = ZmxSessionLauncher.sendArguments("first\nsecond\r\nthird", toNode: node)

    #expect(arguments.last == "first second third")
  }

  @Test
  func aHostileMessageIsPassedThroughUntouched() {
    // `zmx` shell-quotes each argument, so graphcode must not pre-escape — doing both
    // would double-escape and corrupt the text.
    let hostile = "'; rm -rf /; echo '"
    let arguments = ZmxSessionLauncher.sendArguments(hostile, toNode: node)

    #expect(arguments.last == hostile)
  }

  @Test
  func presenceIsReadFromTheSessionsOwnLabel() {
    let arguments = ZmxSessionLauncher.presenceLabelArguments(forNode: node)
    let expectedName = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName

    #expect(arguments == ["get", expectedName, "presence"])
  }

  @Test
  func aReportedPresenceLabelParses() {
    #expect(ZmxSessionLauncher.parsePresenceLabel("busy") == .busy)
    #expect(ZmxSessionLauncher.parsePresenceLabel(" awaitingInput \n") == .awaitingInput)
    #expect(ZmxSessionLauncher.parsePresenceLabel("presence=idle") == .idle)
  }

  @Test
  func anUnrecognisedLabelIsTreatedAsNoLabel() {
    // Coercing junk into the nearest case would turn a broken hook into a confident
    // wrong reading, which is worse than falling back to the heuristic.
    #expect(ZmxSessionLauncher.parsePresenceLabel("") == nil)
    #expect(ZmxSessionLauncher.parsePresenceLabel("working-ish") == nil)
  }

  @Test
  func anUnspikedBackendReportsFailureRatherThanGuessing() async {
    // An adapter that looks implemented but invokes a command nobody has run turns
    // "not done yet" into a silent runtime failure. These report honestly instead.
    for kind in [CLISessionBackendKind.copilotCLI, .codex] {
      let backend = CLISessionBackend.backend(for: kind)
      #expect(backend.kind == kind)
      #expect(await backend.sendInput(node, "hello") == false)
      #expect(await backend.presence(node) == .absent)
    }
  }

  @Test
  func aNodesBackendSelectsItsAdapter() {
    // The picker's choice has to mean something at runtime, not just at creation time.
    let codexNode = LoopNode(title: "Research", backend: .codex)
    #expect(CLISessionBackend.backend(for: codexNode).kind == .codex)
    #expect(CLISessionBackend.backend(for: node).kind == .claudeCode)
  }

  @Test
  func onlyBackendsThatAcceptMidSessionInputCanReceiveMessages() {
    // docs/02-graph-of-loops.md: a backend that can't be interrupted mid-session can
    // never be the `to` side of a `.message` edge.
    // All three are TUIs in a PTY, so `zmx send` can type into each of them — Codex
    // included, now that it has been spiked (issue #1).
    for backend in CLISessionBackendKind.allCases {
      #expect(backend.capabilities.supportsMidSessionInput)
    }
  }
}
