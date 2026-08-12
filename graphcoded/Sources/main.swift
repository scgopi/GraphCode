import Foundation
import GraphcodeKit

#if canImport(Darwin)
  import Darwin
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

let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
guard socketDescriptor >= 0 else {
  fail("failed to create socket (errno \(errno))")
}

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

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

let replayStore = DaemonReplayStore(capacity: 128)
let replayCleanupTask = replayStore.startCleanup()

func handleConnection(_ connection: any DaemonConnection) {
  Task {
    let connectionID = connection.id
    var channel: DaemonConnectionChannel?
    FileHandle.standardOutput.write(Data("graphcoded: client connected\n".utf8))
    defer {
      let hadChannel = channel != nil
      Task {
        await registry.removeConnection(connectionID)
        if !hadChannel {
          try? await connection.close()
        }
      }
    }

    var initialFrameData: Data?
    do {
      let firstData = try await connection.receiveFrame()
      initialFrameData = firstData
      (connection as? UnixSocketConnection)?.setReadTimeout(nil)
      switch try DaemonWireProtocol.decodeClientFrame(firstData) {
      case .v1(let command):
        let v1Channel = DaemonConnectionChannel(connection: connection, mode: .v1)
        channel = v1Channel
        await registry.addConnection(id: connectionID, channel: v1Channel)
        await registry.handle(command, connectionID: connectionID)

      case .v2(let hello):
        guard hello.kind == .hello else {
          try await connection.sendFrame(
            JSONEncoder().encode(
              DaemonWireEnvelope.error(
                id: nil, code: DaemonWireErrorCode.expectedHello.rawValue,
                message: "the first v2 frame must be hello")))
          return
        }
        let selectedVersion: Int
        do {
          selectedVersion = try DaemonWireProtocol.negotiatedVersion(for: hello)
        } catch DaemonWireProtocol.NegotiationError.noSupportedVersion {
          try await connection.sendFrame(
            JSONEncoder().encode(
              DaemonWireEnvelope.error(
                id: nil, code: DaemonWireErrorCode.unsupportedVersion.rawValue,
                message: "no mutually supported daemon protocol version")))
          return
        }
        let negotiated: DaemonProtocolMode =
          selectedVersion == 2 ? .v2(version: 2) : .v1
        let v2Channel = DaemonConnectionChannel(
          connection: connection,
          mode: negotiated,
          clientID: hello.clientID ?? connectionID,
          subscription: hello.subscription,
          replayStore: replayStore)
        channel = v2Channel
        await registry.addConnection(id: connectionID, channel: v2Channel)
        try await v2Channel.sendHelloResponse(selectedVersion: selectedVersion)
        if selectedVersion == 2, let resumeFrom = hello.resumeFrom {
          do {
            try await v2Channel.replay(after: resumeFrom)
          } catch DaemonConnectionChannelError.replayUnavailable {
            try await v2Channel.sendError(
              code: .replayUnavailable,
              message: "requested replay history is unavailable")
          } catch DaemonConnectionChannelError.cursorOutsideWindow {
            try await v2Channel.sendError(
              code: .cursorOutsideWindow,
              message: "requested cursor is beyond the retained event history")
          }
        }
      }

      guard let channel else { return }
      while true {
        let data = try await channel.receiveFrame()
        do {
          switch try DaemonWireProtocol.decodeClientFrame(data) {
          case .v1(let command):
            guard channel.mode == .v1 else {
              try await channel.sendError(
                code: .malformedEnvelope,
                message: "v2 connections must send request envelopes")
              continue
            }
            await registry.handle(command, connectionID: connectionID)

          case .v2(let request):
            guard case .v2 = channel.mode, request.kind == .request,
              let requestID = request.requestID, let command = request.command
            else {
              try await channel.sendError(
                requestID: DaemonWireProtocol.requestIDIfPresent(in: data),
                code: .malformedEnvelope,
                message: "expected a v2 request envelope")
              continue
            }
            await registry.handle(command, connectionID: connectionID)
            if let response = await registry.responseEvent(for: command) {
              try await channel.sendResponse(requestID: requestID, event: response)
            } else {
              try await channel.sendError(
                requestID: requestID,
                code: .requestFailed,
                message: "request could not be applied")
            }
          }
        } catch {
          try await channel.sendError(
            requestID: DaemonWireProtocol.requestIDIfPresent(in: data),
            code: .malformedEnvelope,
            message: "\(error)")
        }
      }
    } catch {
      // Transport/framing failures close the socket. Per-frame envelope failures are
      // handled inside the loop so one malformed request does not strand a client.
      let readDeadlineExpired: Bool
      if case FramedMessageIO.IOError.readFailed(let code) = error {
        readDeadlineExpired = code == EAGAIN || code == EWOULDBLOCK
      } else {
        readDeadlineExpired = false
      }
      if readDeadlineExpired {
        try? await connection.close()
      } else if let channel {
        try? await channel.sendError(code: .transportFailure, message: "\(error)")
      } else if let initialFrameData,
        let errorFrame = try? DaemonWireProtocol.initialErrorFrame(
          for: initialFrameData, message: "\(error)")
      {
        try? await connection.sendFrame(errorFrame)
      } else {
        try? await connection.sendFrame(
          JSONEncoder().encode(
            DaemonWireEnvelope.error(
              id: nil,
              code: DaemonWireErrorCode.unsupportedVersion.rawValue,
              message: "unsupported or malformed initial protocol frame: \(error)")))
      }
    }
    FileHandle.standardOutput.write(Data("graphcoded: client disconnected\n".utf8))
  }
}

DispatchQueue.global().async {
  while true {
    let clientDescriptor = accept(socketDescriptor, nil, nil)
    guard clientDescriptor >= 0 else { continue }
    handleConnection(
      UnixSocketConnection(
        fileDescriptor: clientDescriptor,
        endpoint: .unixSocket(socketURL),
        readTimeout: 5,
        writeTimeout: 5))
  }
}

withExtendedLifetime(replayCleanupTask) {
  dispatchMain()
}
