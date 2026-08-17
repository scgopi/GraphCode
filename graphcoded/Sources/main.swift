import Foundation
import GraphcodeKit
#if os(Windows)
  import WinSDK
#endif

#if os(Windows)
  private enum DaemonStartupHandoffError: Error {
    case missingReadyEvent
    case openStartupEvent(UInt32)
    case waitStartupEvent(DWORD)
    case openReadyEvent(UInt32)
  }

  private final class DaemonStartupHandoff: @unchecked Sendable {
    let startupEvent: HANDLE?
    let readyEvent: HANDLE?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
      guard let startupEventName = environment["GRAPHCODE_DAEMON_STARTUP_EVENT"] else {
        startupEvent = nil
        readyEvent = nil
        return
      }
      var startupName = Array(startupEventName.utf16)
      startupName.append(0)
      guard
        let startupEvent = startupName.withUnsafeBufferPointer({
          OpenEventW(DWORD(SYNCHRONIZE), false, $0.baseAddress)
        })
      else {
        throw DaemonStartupHandoffError.openStartupEvent(GetLastError())
      }
      let startupResult = WaitForSingleObject(startupEvent, 5_000)
      guard startupResult == WAIT_OBJECT_0 else {
        CloseHandle(startupEvent)
        throw DaemonStartupHandoffError.waitStartupEvent(startupResult)
      }

      guard let readyEventName = environment["GRAPHCODE_DAEMON_HANDOFF_READY_EVENT"] else {
        CloseHandle(startupEvent)
        throw DaemonStartupHandoffError.missingReadyEvent
      }
      var readyName = Array(readyEventName.utf16)
      readyName.append(0)
      guard
        let readyEvent = readyName.withUnsafeBufferPointer({
          OpenEventW(DWORD(EVENT_MODIFY_STATE), false, $0.baseAddress)
        })
      else {
        let code = GetLastError()
        CloseHandle(startupEvent)
        throw DaemonStartupHandoffError.openReadyEvent(code)
      }
      self.startupEvent = startupEvent
      self.readyEvent = readyEvent
    }

    var isParentHandoff: Bool { startupEvent != nil }

    func publish() -> Bool {
      guard let readyEvent else { return true }
      return SetEvent(readyEvent)
    }

    deinit {
      if let startupEvent {
        CloseHandle(startupEvent)
      }
      if let readyEvent {
        CloseHandle(readyEvent)
      }
    }
  }

  private func writeDaemonHandoffTestState(_ state: String) {
    guard let path = ProcessInfo.processInfo.environment["GRAPHCODE_DAEMON_HANDOFF_TEST_STATE"]
    else { return }
    try? Data(state.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
  }

  SupportDirectory.prepare()
  private let startupHandoff: DaemonStartupHandoff = {
    do {
      return try DaemonStartupHandoff()
    } catch {
      FileHandle.standardError.write(Data("graphcoded: \(error)\n".utf8))
      exit(1)
    }
  }()
  if startupHandoff.isParentHandoff {
    writeDaemonHandoffTestState("startup-gate")
  }
  let endpointName: String = {
    do {
      return try WindowsNamedPipeEndpoint.name()
    } catch {
      writeDaemonHandoffTestState("failed: \(error)")
      FileHandle.standardError.write(Data("graphcoded: \(error)\n".utf8))
      exit(1)
    }
  }()

  let instanceLock: WindowsDaemonInstanceLock = {
    do {
      let startupReservation: WindowsDaemonStartupReservation?
      if startupHandoff.isParentHandoff {
        startupReservation = nil
      } else {
        startupReservation = try WindowsDaemonStartupReservation()
      }
      defer { _ = startupReservation }
      try WindowsNamedPipeEndpoint.recordActiveGeneration()
      return try WindowsDaemonInstanceLock()
    } catch WindowsPipeError.instanceAlreadyRunning {
      writeDaemonHandoffTestState("failed: instance already running")
      FileHandle.standardError.write(Data("graphcoded: daemon is already running\n".utf8))
      exit(1)
    } catch {
      writeDaemonHandoffTestState("failed: \(error)")
      FileHandle.standardError.write(Data("graphcoded: \(error)\n".utf8))
      exit(1)
    }
  }()
  if startupHandoff.isParentHandoff {
    writeDaemonHandoffTestState("lifetime-lock")
  }
  let supportDirectory = SupportDirectory.url
  let replayStore = DaemonReplayStore(capacity: 128)
  let handshakeLimiter = WindowsPipeHandshakeLimiter(limit: 32)
  let registry = ProjectRegistry(
    persistenceDirectory: supportDirectory,
    replayStore: replayStore)
  let replayCleanupTask = replayStore.startCleanup()
  let listener: WindowsNamedPipeListener = {
    do {
      return try WindowsNamedPipeListener(
        pipeName: endpointName,
        onPublished: {
          writeDaemonHandoffTestState(
            startupHandoff.publish() ? "published" : "failed: ready event")
        })
    } catch {
      writeDaemonHandoffTestState("failed: \(error)")
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

  #if os(Windows)
    if let shutdownEventName = ProcessInfo.processInfo.environment[
      "GRAPHCODE_DAEMON_SHUTDOWN_EVENT"
    ] {
      var wideName = Array(shutdownEventName.utf16)
      wideName.append(0)
      if let shutdownEvent = wideName.withUnsafeBufferPointer({
        OpenEventW(DWORD(SYNCHRONIZE), false, $0.baseAddress)
      }) {
        DispatchQueue.global(qos: .utility).async {
          _ = WaitForSingleObject(shutdownEvent, INFINITE)
          shutdown.lock.lock()
          shutdown.stopped = true
          shutdown.lock.unlock()
          Task {
            await ZmxSessionLauncher.shutdownWindowsRemoteBridge()
            try? await listener.close()
            CloseHandle(shutdownEvent)
            exit(0)
          }
        }
      }
    }
  #endif

  func handleWindowsConnection(_ connection: any DaemonConnection) {
    guard let handshakePermit = handshakeLimiter.tryAcquire() else {
      Task { try? await connection.close() }
      return
    }
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
          firstData = try await pipe.receiveFrameWithFirstByteDeadline()
        } else {
          firstData = try await connection.receiveFrame()
        }
        initialFrameData = firstData
        switch try DaemonWireProtocol.decodeClientFrame(firstData) {
        case .v1(let command):
          let v1Channel = DaemonConnectionChannel(connection: connection, mode: .v1)
          channel = v1Channel
          await registry.addConnection(id: connectionID, channel: v1Channel)
          handshakePermit.release()
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
          handshakePermit.release()
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
    Task {
      await ZmxSessionLauncher.shutdownWindowsRemoteBridge()
      try? await listener.close()
      exit(0)
    }
  }
  signal(SIGTERM) { _ in
    shutdown.lock.lock()
    shutdown.stopped = true
    shutdown.lock.unlock()
    Task {
      await ZmxSessionLauncher.shutdownWindowsRemoteBridge()
      try? await listener.close()
      exit(0)
    }
  }

  FileHandle.standardOutput.write(
    Data("graphcoded: listening on \(String(describing: listener.endpoint))\n".utf8))
  withExtendedLifetime((replayCleanupTask, instanceLock)) {
    dispatchMain()
  }
#endif
