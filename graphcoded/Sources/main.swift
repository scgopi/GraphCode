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

// Both platform daemons live in this one file because only `main.swift` may carry
// top-level code: a second file holding the Darwin entry point compiles on Windows,
// where it is excluded, and fails everywhere else.

#if !os(Windows)
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

// A broadcast writes to every connected client, and a client can vanish without a
// clean close — the app killed, a CLI exiting early, a pane crashing. The write then
// raises SIGPIPE, whose default action *terminates the daemon*: observed as exit
// status -13 in `launchctl list`, with every loop's in-flight send failing until
// launchd restarted the process seconds later.
//
// Ignoring it turns that into what the code already handles correctly:
// `FramedMessageIO.writeAll` sees write() return -1/EPIPE, throws, and
// `GraphStore.send` drops the dead connection. The error path was always right; the
// process just never lived long enough to run it.
signal(SIGPIPE, SIG_IGN)

// Termination is handled on the main queue, not in signal context (#167). The handlers
// this replaces called `exit(0)` from inside the signal handler itself, and `exit` is
// not async-signal-safe: it runs atexit and runtime teardown after interrupting whatever
// thread happened to be running — which can be a thread mid-`malloc` or mid-`write`,
// holding exactly the locks teardown needs. An idle daemon died cleanly in milliseconds
// every time; a busy one could deadlock until launchd's ExitTimeOut escalated to
// SIGKILL, observed as `launchctl bootout` taking ~29 seconds while a workspace was
// being deleted. A dispatch signal source delivers the signal as an ordinary work item,
// where `exit` is just a function call.
//
// `SIG_IGN` first, so the default terminate-without-cleanup disposition can't win the
// race before the sources are resumed.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

func makeShutdownSource(for signalNumber: Int32) -> DispatchSourceSignal {
  let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
  source.setEventHandler {
    unlink(path)
    exit(0)
  }
  source.resume()
  return source
}

// Top-level lets, so the sources outlive this file's execution — a released source
// stops delivering, and the signal falls back to the ignored disposition above, which
// would make the daemon *unkillable* by SIGTERM instead of slow.
let terminateSource = makeShutdownSource(for: SIGTERM)
let interruptSource = makeShutdownSource(for: SIGINT)

let replayStore = DaemonReplayStore(capacity: 128)
let registry = ProjectRegistry(
  persistenceDirectory: supportDirectory,
  replayStore: replayStore)
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
        let data: Data
        if let unixConnection = connection as? UnixSocketConnection {
          data = try await unixConnection.receiveFrameWithPostHandshakeDeadline()
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
                requestID: requestID,
                code: .requestFailed,
                message: error)
            } else if let response = result.response {
              try await channel.sendResponse(requestID: requestID, event: response)
            } else if result.succeeded {
              // Some mutations intentionally have no payload. A correlated success
              // envelope completes the request without manufacturing an error.
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
    // Belt and braces beside the process-wide ignore above: this socket raises no
    // SIGPIPE whatever any library does to the signal disposition later.
    var noSignal: Int32 = 1
    setsockopt(
      clientDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    handleConnection(
      UnixSocketConnection(
        fileDescriptor: clientDescriptor,
        endpoint: .unixSocket(socketURL),
        readTimeout: 5,
        writeTimeout: 5))
  }
}

withExtendedLifetime((replayCleanupTask, terminateSource, interruptSource)) {
  dispatchMain()
}
#endif
