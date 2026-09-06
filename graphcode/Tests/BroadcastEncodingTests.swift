import Foundation
import GraphcodeKit
import Testing

#if canImport(Darwin)
  import Darwin
#endif

/// A broadcast is one encode handed to every connection, not one encode per
/// connection (issue #288's CPU amplifier). Encoding is not observable from outside,
/// so this pins what the refactor must keep: every client gets the same bytes, a
/// client that is gone is dropped on the spot, and the rest still hear the change.
@Suite
struct BroadcastEncodingTests {
  private func frame(from descriptor: Int32) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        do {
          continuation.resume(returning: try FramedMessageIO.readFrame(from: descriptor))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  @Test
  func everyConnectionReceivesTheSameBytesAndADeadOneIsDropped() async throws {
    let store = GraphStore(onEnsureSession: { _, _ in }, onDeliverMessage: { _, _, _ in true })
    var first: [Int32] = [0, 0]
    var second: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &first) == 0)
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &second) == 0)
    // The daemon ends belong to their channels (`OutboundChannels.open` in
    // `addConnection`), so they close through the registry; `second[0]` goes mid-test.
    defer {
      OutboundChannels.close(first[0])
      close(first[1])
      close(second[1])
    }
    await store.addConnection(id: UUID(), fileDescriptor: first[0])
    await store.addConnection(id: UUID(), fileDescriptor: second[0])
    _ = try await frame(from: first[1])
    _ = try await frame(from: second[1])

    await store.handle(
      .createNode(NodeDraft(title: "Loop", loopType: .turnBased, firstInstruction: "Work")))
    let toFirst = try await frame(from: first[1])
    let toSecond = try await frame(from: second[1])
    #expect(toFirst == toSecond)
    guard case .graphChanged(let graph) = try JSONDecoder().decode(DaemonEvent.self, from: toFirst)
    else {
      Issue.record("expected the broadcast")
      return
    }
    #expect(graph.nodes.map(\.title) == ["Loop"])

    // A connection whose channel is gone is dropped by the broadcast that finds it so,
    // and the live one still hears the change.
    OutboundChannels.close(second[0])
    await store.handle(.renameNode(graph.nodes[0].id, title: "Renamed"))
    guard
      case .graphChanged(let renamed) = try JSONDecoder().decode(
        DaemonEvent.self, from: try await frame(from: first[1]))
    else {
      Issue.record("expected the second broadcast")
      return
    }
    #expect(renamed.nodes.map(\.title) == ["Renamed"])
  }
}
