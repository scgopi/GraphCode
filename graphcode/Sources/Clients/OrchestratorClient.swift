import Dependencies
import Foundation
import GraphcodeKit

#if canImport(Darwin)
  import Darwin
#endif

/// The app's thin proxy to `graphcoded`'s `GraphStore` — see
/// docs/03-architecture.md#clients. `GraphCanvasFeature` no longer owns graph state
/// itself; it mirrors whatever `graphcoded` broadcasts and sends commands for every
/// mutation, so automatic edge firing and time-based triggers (which the daemon can
/// run with no app attached at all) and the app's own view of the graph never
/// disagree.
struct OrchestratorClient: Sendable {
  var connect: @Sendable () -> AsyncStream<DaemonEvent>
  var send: @Sendable (_ command: DaemonCommand) async throws -> Void
}

enum OrchestratorClientError: Error, Equatable {
  case connectFailed(errno: Int32)
}

extension OrchestratorClient: DependencyKey {
  static let liveValue: OrchestratorClient = {
    let connection = DaemonConnection()
    return OrchestratorClient(
      connect: { connection.events() },
      send: { command in try await connection.send(command) }
    )
  }()
}

extension DependencyValues {
  var orchestratorClient: OrchestratorClient {
    get { self[OrchestratorClient.self] }
    set { self[OrchestratorClient.self] = newValue }
  }
}

/// Owns the one socket connection to `graphcoded`, connecting lazily and retrying with
/// backoff — the app can launch before the daemon has finished starting up.
private actor DaemonConnection {
  private var fileDescriptor: Int32?

  nonisolated func events() -> AsyncStream<DaemonEvent> {
    AsyncStream { continuation in
      Task {
        do {
          let fd = try await ensureConnected()
          while true {
            let data = try await readFrameAsync(from: fd)
            let event = try JSONDecoder().decode(DaemonEvent.self, from: data)
            continuation.yield(event)
          }
        } catch {
          continuation.finish()
        }
      }
    }
  }

  func send(_ command: DaemonCommand) async throws {
    let fd = try await ensureConnected()
    let data = try JSONEncoder().encode(command)
    try await writeFrameAsync(data, to: fd)
  }

  private func ensureConnected() async throws -> Int32 {
    if let fileDescriptor { return fileDescriptor }
    var lastError: Error = OrchestratorClientError.connectFailed(errno: 0)
    for attempt in 0..<10 {
      do {
        let fd = try await connectAsync()
        fileDescriptor = fd
        return fd
      } catch {
        lastError = error
        try? await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
      }
    }
    throw lastError
  }

  @Sendable
  private func connectAsync() async throws -> Int32 {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
          continuation.resume(throwing: OrchestratorClientError.connectFailed(errno: errno))
          return
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = DaemonSocketPath.url.path
        withUnsafeMutablePointer(to: &address.sun_path) { pathField in
          pathField.withMemoryRebound(
            to: CChar.self, capacity: MemoryLayout.size(ofValue: pathField.pointee)
          ) { pathPointer in
            _ = path.withCString { cPath in
              strncpy(pathPointer, cPath, MemoryLayout.size(ofValue: pathField.pointee) - 1)
            }
          }
        }

        let connectResult = withUnsafePointer(to: &address) { addressPointer -> Int32 in
          addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rawPointer in
            connect(fd, rawPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
          }
        }
        guard connectResult == 0 else {
          let capturedErrno = errno
          close(fd)
          continuation.resume(throwing: OrchestratorClientError.connectFailed(errno: capturedErrno))
          return
        }
        continuation.resume(returning: fd)
      }
    }
  }
}

@Sendable
private func readFrameAsync(from fileDescriptor: Int32) async throws -> Data {
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

@Sendable
private func writeFrameAsync(_ data: Data, to fileDescriptor: Int32) async throws {
  try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global().async {
      do {
        try FramedMessageIO.writeFrame(data, to: fileDescriptor)
        continuation.resume()
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}
