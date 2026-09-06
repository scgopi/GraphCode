import Foundation
import GraphcodeKit
import Testing

#if canImport(Darwin)
  import Darwin
#endif

/// Issue #289's acceptance criteria, one test each: a slow subscriber is named by the
/// write that waited on it; a large graph is recorded as sizes and counts, never content;
/// the CLI's timeout says where it was and how to find itself in the log; and the log
/// stays within its bound.
@Suite(.serialized)
struct DaemonDiagnosticsTests {
  /// Every line the shared log records while `body` runs.
  private func recording(_ body: () async throws -> Void) async rethrows -> [String] {
    final class Lines: @unchecked Sendable {
      private let lock = NSLock()
      private var lines: [String] = []
      func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
      }
      var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
      }
    }
    let lines = Lines()
    let tap = DaemonLog.shared.tap { lines.append($0) }
    defer { DaemonLog.shared.untap(tap) }
    try await body()
    return lines.all
  }

  private func fields(_ line: String) -> [String: String] {
    var parsed: [String: String] = [:]
    for token in line.split(separator: " ").dropFirst() {
      guard let equals = token.firstIndex(of: "=") else { continue }
      parsed[String(token[..<equals])] = String(token[token.index(after: equals)...])
    }
    return parsed
  }

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

  /// A graph big enough that its snapshot outgrows a small socket buffer.
  private func bigGraph() -> LoopGraph {
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/diagnostics", name: "diagnostics"))
    for index in 0..<40 {
      graph.nodes.append(
        LoopNode(
          title: "SecretLoopTitle\(index)", loopType: .goalBased,
          goal: GoalSpec(summary: String(repeating: "goal text ", count: 40))))
    }
    return graph
  }

  /// Criterion 1 and 2: one client reads, one never does — the broadcast line records
  /// the fanout and the write line names the client that held its write.
  @Test
  func aSlowSubscriberIsNamedByTheWriteThatWaitedOnIt() async throws {
    let store = GraphStore(graph: bigGraph(), onEnsureSession: { _, _ in })
    var reading: [Int32] = [0, 0]
    var deaf: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &reading) == 0)
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &deaf) == 0)
    // A small buffer on the deaf client's socket so the snapshot cannot fit in one go.
    var small: Int32 = 4096
    setsockopt(deaf[0], SOL_SOCKET, SO_SNDBUF, &small, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(deaf[1], SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size))
    defer {
      OutboundChannels.close(reading[0])
      OutboundChannels.close(deaf[0])
      close(reading[1])
      close(deaf[1])
    }

    let lines = try await recording {
      await store.addConnection(id: UUID(), fileDescriptor: reading[0])
      await store.addConnection(id: UUID(), fileDescriptor: deaf[0])
      _ = try await frame(from: reading[1])
      await store.handle(.renameNode(store.graph.nodes[0].id, title: "Renamed"))
      _ = try await frame(from: reading[1])
      // Past the stall threshold, so the deaf channel's writer has named itself — its
      // write never completes, and a line only at completion would never come.
      try await Task.sleep(for: .milliseconds(600))
    }

    let broadcast = try #require(
      lines.map(fields).first { $0["event"] == "broadcast" && $0["kind"] == "graphChanged" })
    #expect(broadcast["recipients"] == "2")
    #expect(broadcast["accepted"] == "2")
    #expect(Int(broadcast["bytes"] ?? "") ?? 0 > 4096)
    #expect(broadcast["encode_ms"] != nil)

    let deafFD = String(deaf[0])
    let stalled = lines.map(fields).filter { line in
      line["event"] == "write-stall" && line["fd"] == deafFD
    }
    #expect(stalled.count == 1, "the deaf client's stalled write should be named once")
    let blocked = Double(stalled.first?["blocked_ms"] ?? "") ?? 0
    let remaining = Int(stalled.first?["remaining"] ?? "") ?? 0
    #expect(blocked >= 250)
    #expect(remaining > 0)
    let readingFD = String(reading[0])
    let parsed = lines.map(fields)
    let writeEvents: Set<String> = ["write", "write-stall"]
    let readerWrites = parsed.filter { line in
      writeEvents.contains(line["event"] ?? "") && line["fd"] == readingFD
    }
    #expect(readerWrites.isEmpty, "the reading client never waited, so it is never named")

    // Criterion 3: content never reaches the log — not a title, not a goal.
    #expect(!lines.contains { $0.contains("SecretLoopTitle") || $0.contains("goal text") })
    #expect(lines.contains { $0.contains("event=persist") })
  }

  /// Criterion 4: the CLI's message says the phase, the elapsed time, and the two
  /// numbers that find the run in the daemon's log.
  @Test
  func theTimeoutNamesItsPhaseElapsedAndCorrelationNumbers() {
    let message = GraphcodeCommand.renderTimeout(
      phase: "waiting for the mailbox answer", elapsed: 10.04, pid: 4321, framesSent: 2)
    #expect(message.contains("timed out after 10.0s waiting for the mailbox answer"))
    #expect(message.contains("pid 4321"))
    #expect(message.contains("2 frames sent"))
    #expect(message.contains("peer=4321"))
    #expect(message.contains("seq=2"))
    #expect(message.contains("may still have been applied"))
  }

  /// Criterion 5: past the bound the file rolls into one `.1` generation and starts
  /// again, so two files of the bound is the most it ever holds.
  @Test
  func theLogRollsOverAtItsBound() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-log-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DaemonLog()
    log.open(directory: directory, maxBytes: 2000)
    for index in 0..<60 {
      log.record("probe", [("n", String(index)), ("pad", String(repeating: "x", count: 40))])
    }
    log.drain()

    let current = directory.appendingPathComponent(DaemonLog.fileName)
    let previous = directory.appendingPathComponent(DaemonLog.fileName + ".1")
    let currentSize = try FileManager.default.attributesOfItem(atPath: current.path)[.size] as? Int
    let previousSize =
      try FileManager.default.attributesOfItem(atPath: previous.path)[.size] as? Int
    #expect(try #require(currentSize) <= 2000)
    #expect(try #require(previousSize) <= 2000)
    #expect(try #require(currentSize) + (previousSize ?? 0) < 60 * 100)
    let text = try String(contentsOf: current, encoding: .utf8)
    #expect(text.contains(" event=probe n=59 "))
    #expect(text.split(separator: "\n").allSatisfy { $0.hasSuffix("Z event=probe n=") == false })
    // Every line carries a UTC stamp with milliseconds.
    let stamped = text.split(separator: "\n").allSatisfy {
      $0.count > 24 && $0[$0.index($0.startIndex, offsetBy: 23)] == "Z"
    }
    #expect(stamped)
  }

  /// A command's kind is its case name and never its payload, down through a
  /// sub-graph command.
  @Test
  func aCommandIsLoggedByKindNotContent() {
    let memo = DaemonCommand.graphCommand(
      projectPath: "/tmp/p", command: .memoNode(UUID(), text: "the secret", from: nil))
    #expect(memo.kindName == "graphCommand.memoNode")
    #expect(!memo.kindName.contains("secret"))
    #expect(DaemonCommand.listRecentProjects.kindName == "listRecentProjects")
    let nested = DaemonCommand.graphCommand(
      projectPath: "/tmp/p",
      command: .subGraphCommand(nodeID: UUID(), command: .restartSessions))
    #expect(nested.kindName == "graphCommand.subGraphCommand.restartSessions")
    #expect(DaemonEvent.errorOccurred("x").kindName == "errorOccurred")
  }
}
