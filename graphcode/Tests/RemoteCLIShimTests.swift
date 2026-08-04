import Foundation
import Testing

@testable import GraphcodeKit

#if canImport(Darwin)
  import Darwin
#endif

/// The remote CLI shim is Python; these tests pin its wire contract by running the
/// exact source `RemoteGraphAccess` delivers against a socket whose other end is
/// Swift — every frame the shim sends is decoded with the same `JSONDecoder` and
/// types `graphcoded` itself uses, so a protocol drift fails here before it fails on
/// someone's build box.
@Suite
struct RemoteCLIShimTests {
  private static let project = "ssh://dev@build-box:2222/home/dev/widget"

  @Test
  func aMemoRidesTheWireExactlyAsTheSwiftCLIWould() throws {
    let nodeID = UUID()
    let sender = UUID()
    let run = try runShim(
      ["node", "memo", Self.project, nodeID.uuidString, "dead", "end:", "approach", "X"],
      environment: ["ZMX_SESSION": "graphcode-\(sender.uuidString)"])

    #expect(run.status == 0)
    #expect(run.stdout.contains("noted"))
    #expect(run.commands.first == .openProject(path: Self.project))
    #expect(
      run.commands.dropFirst().first
        == .graphCommand(
          projectPath: Self.project,
          command: .memoNode(nodeID, text: "dead end: approach X", from: sender)))
  }

  @Test
  func aCreatedNodeDecodesIntoAValidAttributedDraft() throws {
    let creator = UUID()
    let run = try runShim(
      [
        "node", "create", Self.project, "--title", "Fix issue 7", "--type", "goal",
        "--goal", "tests pass", "--predicate", "make test",
      ],
      environment: ["ZMX_SESSION": "graphcode-\(creator.uuidString)"])

    #expect(run.status == 0)
    let second = try #require(run.commands.dropFirst().first)
    guard case .graphCommand(let path, .createNode(let draft)) = second else {
      Issue.record("expected createNode, decoded \(second)")
      return
    }
    #expect(path == Self.project)
    #expect(draft.title == "Fix issue 7")
    #expect(draft.loopType == .goalBased)
    #expect(draft.goal?.summary == "tests pass")
    #expect(draft.goal?.predicate == "make test")
    // Run from inside a loop, the shim attributes the child to its creator the same
    // way the Swift CLI does — off `ZMX_SESSION`, with nothing passed explicitly.
    #expect(draft.createdBy == creator)
    #expect(draft.isValid)
  }

  @Test
  func aSendFromAHumanShellIsUnattributed() throws {
    let nodeID = UUID()
    let run = try runShim(
      ["node", "send", Self.project, nodeID.uuidString, "the", "API", "changed"])

    #expect(run.status == 0)
    #expect(run.stdout.contains("delivered"))
    #expect(
      run.commands.dropFirst().first
        == .graphCommand(
          projectPath: Self.project,
          command: .messageNode(nodeID, text: "the API changed", from: nil)))
  }

  // MARK: - Harness

  private struct ShimRun {
    var status: Int32
    var stdout: String
    var stderr: String
    var commands: [DaemonCommand]
  }

  private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [DaemonCommand] = []
    func append(_ command: DaemonCommand) {
      lock.lock()
      commands.append(command)
      lock.unlock()
    }
    var all: [DaemonCommand] {
      lock.lock()
      defer { lock.unlock() }
      return commands
    }
  }

  private struct HarnessError: Error {}

  /// Runs the delivered shim source against a one-connection Swift daemon stand-in
  /// that answers every decoded command with a `graphChanged` — the acknowledgement
  /// shape the real daemon uses.
  private func runShim(
    _ arguments: [String], environment: [String: String] = [:]
  ) throws -> ShimRun {
    // Under `/tmp` rather than `NSTemporaryDirectory()`, whose per-user path can push
    // the socket past `sun_path`'s 104 bytes.
    let socketPath = "/tmp/graphcode-shim-\(UUID().uuidString.prefix(8)).sock"
    defer { unlink(socketPath) }

    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw HarnessError() }
    defer { close(listener) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutablePointer(to: &address.sun_path) { field in
      field.withMemoryRebound(
        to: CChar.self, capacity: MemoryLayout.size(ofValue: field.pointee)
      ) { pointer in
        _ = socketPath.withCString {
          strncpy(pointer, $0, MemoryLayout.size(ofValue: field.pointee) - 1)
        }
      }
    }
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, listen(listener, 1) == 0 else { throw HarnessError() }

    let received = Received()
    DispatchQueue.global().async {
      let client = accept(listener, nil, nil)
      guard client >= 0 else { return }
      defer { close(client) }
      let graph = LoopGraph(project: ProjectRef(path: Self.project, name: "widget"))
      while let data = try? FramedMessageIO.readFrame(from: client) {
        guard let command = try? JSONDecoder().decode(DaemonCommand.self, from: data)
        else { return }
        received.append(command)
        guard let reply = try? JSONEncoder().encode(DaemonEvent.graphChanged(graph)),
          (try? FramedMessageIO.writeFrame(reply, to: client)) != nil
        else { return }
      }
    }

    let shimFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-shim-\(UUID().uuidString).py")
    try RemoteGraphAccess.cliShimSource.write(to: shimFile, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: shimFile) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", shimFile.path] + arguments
    var processEnvironment = ProcessInfo.processInfo.environment
    // The test may itself be running inside a zmx session; a leaked `ZMX_SESSION`
    // would attribute the "human shell" case to whatever loop ran the tests.
    processEnvironment.removeValue(forKey: "ZMX_SESSION")
    processEnvironment["GRAPHCODE_SOCKET"] = socketPath
    for (key, value) in environment { processEnvironment[key] = value }
    process.environment = processEnvironment
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    return ShimRun(
      status: process.terminationStatus,
      stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
      stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
      commands: received.all)
  }
}
