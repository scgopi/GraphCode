import Foundation
import GraphcodeKit

#if os(Windows)
  SupportDirectory.prepare()
  let instanceLock: WindowsDaemonInstanceLock = {
    do {
      return try WindowsDaemonInstanceLock()
    } catch WindowsPipeError.instanceAlreadyRunning {
      FileHandle.standardError.write(Data("graphcoded: daemon is already running\n".utf8))
      exit(1)
    } catch {
      FileHandle.standardError.write(Data("graphcoded: \(error)\n".utf8))
      exit(1)
    }
  }()
  let supportDirectory = SupportDirectory.url
  let replayStore = DaemonReplayStore(capacity: 128)
  let registry = ProjectRegistry(
    persistenceDirectory: supportDirectory,
    replayStore: replayStore,
    ensureSession: nil,
    terminateSession: nil,
    evaluatePredicate: nil,
    deliverMessage: nil,
    captureScript: nil,
    readUsage: nil,
    readActivity: nil,
    readPresence: nil)
  let replayCleanupTask = replayStore.startCleanup()
  let listener: WindowsNamedPipeListener = {
    do {
      return try WindowsNamedPipeListener()
    } catch {
      FileHandle.standardError.write(Data("graphcoded: \(error)\n".utf8))
      exit(1)
    }
  }()

  final class ShutdownState: @unchecked Sendable {
    let lock = NSLock()
    var stopped = false

    func isStopped() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return stopped
    }
  }
  let shutdown = ShutdownState()

  func handleWindowsConnection(_ connection: any DaemonConnection) {
    Task {
      let connectionID = connection.id
      var channel: DaemonConnectionChannel?
      var initialFrameData: Data?
      FileHandle.standardOutput.write(Data("graphcoded: client connected\n".utf8))
      defer {
        let hadChannel = channel != nil
        Task {
          await registry.removeConnection(connectionID)
          if !hadChannel { try? await connection.close() }
        }
      }

      do {
        let firstData: Data
        if let pipe = connection as? WindowsNamedPipeConnection {
          firstData = try await pipe.receiveFrameWithPostHandshakeDeadline()
        } else {
          firstData = try await connection.receiveFrame()
        }
        initialFrameData = firstData
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
          let mode: DaemonProtocolMode = selectedVersion == 2 ? .v2(version: 2) : .v1
          let v2Channel = DaemonConnectionChannel(
            connection: connection,
            mode: mode,
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
          let data: Data
          if let pipe = connection as? WindowsNamedPipeConnection {
            data = try await pipe.receiveFrameWithPostHandshakeDeadline()
          } else {
            data = try await channel.receiveFrame()
          }
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
              guard let result = await registry.apply(command, connectionID: connectionID) else {
                try await channel.sendError(
                  requestID: requestID,
                  code: .connectionClosed,
                  message: "connection is no longer registered")
                continue
              }
              if let error = result.error {
                try await channel.sendError(
                  requestID: requestID, code: .requestFailed, message: error)
              } else if let response = result.response {
                try await channel.sendResponse(requestID: requestID, event: response)
              } else if result.succeeded {
                try await channel.sendSuccess(requestID: requestID)
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
      } catch WindowsPipeError.timedOut {
        try? await connection.close()
      } catch {
        if let channel {
          try? await channel.sendError(code: .transportFailure, message: "\(error)")
        } else if let initialFrameData,
          let errorFrame = try? DaemonWireProtocol.initialErrorFrame(
            for: initialFrameData, message: "\(error)")
        {
          try? await connection.sendFrame(errorFrame)
        }
      }
      FileHandle.standardOutput.write(Data("graphcoded: client disconnected\n".utf8))
    }
  }

  Task {
    while !Task.isCancelled {
      do {
        handleWindowsConnection(try await listener.accept())
      } catch {
        if shutdown.isStopped() { return }
      }
    }
  }

  signal(SIGINT) { _ in
    shutdown.lock.lock()
    shutdown.stopped = true
    shutdown.lock.unlock()
    Task { try? await listener.close() }
    exit(0)
  }
  signal(SIGTERM) { _ in
    shutdown.lock.lock()
    shutdown.stopped = true
    shutdown.lock.unlock()
    Task { try? await listener.close() }
    exit(0)
  }

  FileHandle.standardOutput.write(
    Data("graphcoded: listening on \(String(describing: listener.endpoint))\n".utf8))
  withExtendedLifetime((replayCleanupTask, instanceLock)) {
    dispatchMain()
  }
#endif
