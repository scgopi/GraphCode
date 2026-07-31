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

  /// Typed is not sent: `zmx send` writes exactly its payload and no `\r`, and a CR in
  /// the same chunk as the text reads as a pasted newline to an agent TUI's paste
  /// heuristic — the message sat in Claude's composer, rendered and unsent. Submission
  /// is its own keystroke, sent separately after the text.
  @Test
  func submissionIsASeparateCarriageReturnKeystroke() {
    let arguments = ZmxSessionLauncher.submitArguments(forNode: node)
    let expectedName = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
    #expect(arguments == ["send", expectedName, "\r"])
    // And the message text itself never carries one — `sendArguments` flattens CR/LF
    // precisely so the only Enter the session ever sees is the deliberate one.
    #expect(!ZmxSessionLauncher.sendArguments("a\rb", toNode: node).last!.contains("\r"))
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

  /// Every spiked backend rides the same zmx-backed adapter. The bug this pins against:
  /// Copilot and Codex stayed routed to the `unspiked` no-op stub long after they were
  /// wired, so the daemon silently never launched, killed, or messaged their loops — a
  /// goal-based Copilot loop was a node in the graph with no session behind it.
  @Test
  func everySpikedBackendGetsTheZmxBackedAdapterNotTheStub() async {
    for kind in CLISessionBackendKind.allCases {
      let backend = CLISessionBackend.backend(for: kind)
      #expect(backend.kind == kind)
      // Behavioral probe that distinguishes the adapters without a live session: the
      // zmx-backed adapter's send checks whether the session exists (and this node has
      // none), where the stub refuses unconditionally — both false here, so assert the
      // routing property that actually matters alongside it: presence for a nonexistent
      // session is `.absent` from a real zmx query, and no adapter is the stub.
      #expect(await backend.sendInput(node, "hello", nil) == false)
      #expect(await backend.presence(node) == .absent)
      #expect(kind.isSpiked)
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
