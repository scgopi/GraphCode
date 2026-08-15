import Foundation
import GraphcodeKit

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

// graphcoded — the graphcode orchestrator daemon.
//
// From Phase 3 on this is no longer an empty skeleton (see docs/07-roadmap.md): it
// speaks `DaemonProtocol` over the Unix socket, fires `.handoff` edges automatically,
// and arms time-based triggers that keep firing whether or not `graphcode.app` is
// running — see docs/03-architecture.md#why-a-daemon-at-all for why this has to be a
// separate, long-lived process rather than in-app state. From Phase 4 on it hosts one
// `LoopGraph` per opened project (`ProjectRegistry`, wrapping one `GraphStore` per
// project) rather than a single hardcoded graph, each persisted under this directory.

let fileManager = FileManager.default

// Launched by an agent rather than launchd — `make daemon-install` from a loop's own
// shell — the daemon inherits that session's identity and would hand it to every backend
// it starts. See `AgentEnvironment`.
AgentEnvironment.scrubInheritedAgentIdentity()

// Migrates a pre-existing `~/Library/Application Support/graphcode` and creates the
// directory. Has to happen before anything reads or writes — including the socket bind
// immediately below.
SupportDirectory.prepare()
let supportDirectory = SupportDirectory.url

let socketURL = DaemonSocketPath.url
// Clear a stale socket file left behind by a previous run that didn't shut down cleanly.
try? fileManager.removeItem(at: socketURL)

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("graphcoded: \(message)\n".utf8))
  exit(1)
}

#if canImport(Darwin)
  let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
#else
  // Glibc imports SOCK_STREAM as the `__socket_type` enum, not an Int32.
  let socketDescriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
#endif
guard socketDescriptor >= 0 else {
  fail("failed to create socket (errno \(errno))")
}

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
#if canImport(Darwin)
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
#endif

let path = socketURL.path
withUnsafeMutablePointer(to: &address.sun_path) { pathField in
  pathField.withMemoryRebound(
    to: CChar.self, capacity: MemoryLayout.size(ofValue: pathField.pointee)
  ) { pathPointer in
    _ = path.withCString { cPath in
      strncpy(pathPointer, cPath, MemoryLayout.size(ofValue: pathField.pointee) - 1)
    }
  }
}

let bindResult = withUnsafePointer(to: &address) { addressPointer -> Int32 in
  addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rawPointer in
    bind(socketDescriptor, rawPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
  }
}
guard bindResult == 0 else {
  fail("failed to bind \(path) (errno \(errno))")
}

guard listen(socketDescriptor, 8) == 0 else {
  fail("failed to listen on \(path) (errno \(errno))")
}

FileHandle.standardOutput.write(Data("graphcoded: listening on \(path)\n".utf8))

signal(SIGTERM) { _ in
  unlink(path)
  exit(0)
}
signal(SIGINT) { _ in
  unlink(path)
  exit(0)
}

let registry = ProjectRegistry(persistenceDirectory: supportDirectory)

/// Bridges a blocking socket read onto a background queue so the `Task` awaiting it
/// never blocks Swift concurrency's cooperative thread pool — the whole connection
/// handler below is otherwise just async/await hops (this, plus actor calls).
@Sendable func readFrameAsync(from fileDescriptor: Int32) async throws -> Data {
  try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global().async {
      do {
        continuation.resume(returning: try FramedMessageIO.readFrame(from: fileDescriptor))
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}

func handleConnection(_ fileDescriptor: Int32) {
  Task {
    let connectionID = UUID()
    await registry.addConnection(id: connectionID, fileDescriptor: fileDescriptor)
    FileHandle.standardOutput.write(Data("graphcoded: client connected\n".utf8))
    while true {
      let data: Data
      do {
        data = try await readFrameAsync(from: fileDescriptor)
      } catch {
        break
      }
      do {
        let command = try JSONDecoder().decode(DaemonCommand.self, from: data)
        await registry.handle(command, connectionID: connectionID)
      } catch {
        // A frame that read fine but didn't decode is version skew, not a dead socket:
        // a newer CLI sent a command this daemon predates. Dropping the connection here
        // failed *silently* — the client just saw a hang-up — so answer instead and
        // keep serving the commands this daemon does understand.
        let event = DaemonEvent.errorOccurred(
          "unrecognized command — graphcoded may be older than the client that sent it")
        if let encoded = try? JSONEncoder().encode(event) {
          try? FramedMessageIO.writeFrame(encoded, to: fileDescriptor)
        }
      }
    }
    await registry.removeConnection(connectionID)
    close(fileDescriptor)
    FileHandle.standardOutput.write(Data("graphcoded: client disconnected\n".utf8))
  }
}

DispatchQueue.global().async {
  while true {
    let clientDescriptor = accept(socketDescriptor, nil, nil)
    guard clientDescriptor >= 0 else { continue }
    handleConnection(clientDescriptor)
  }
}

dispatchMain()
