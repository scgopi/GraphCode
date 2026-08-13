import Foundation
import XCTest
@testable import GraphcodeKit

#if os(Windows)
  import WinSDK
#endif

final class WindowsDaemonTests: XCTestCase {
  #if os(Windows)
    func testEndpointIsPerUserAndSupportDirectory() throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("graphcode-identity-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let first = try WindowsNamedPipeEndpoint.name(
        environment: [
          SupportDirectory.environmentKey: root.appendingPathComponent("graphcode-a").path
        ])
      let second = try WindowsNamedPipeEndpoint.name(
        environment: [
          SupportDirectory.environmentKey: root.appendingPathComponent("graphcode-b").path
        ])

      XCTAssertTrue(first.hasPrefix("\\\\.\\pipe\\graphcode-"))
      XCTAssertNotEqual(first, second)
      XCTAssertLessThan(first.utf8.count, 240)
    }

    func testDaemonInstanceLockRejectsSecondOwner() throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("graphcode-lock-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let environment = [
        SupportDirectory.environmentKey: root.path
      ]
      let first = try WindowsDaemonInstanceLock(environment: environment)
      XCTAssertThrowsError(try WindowsDaemonInstanceLock(environment: environment)) { error in
        XCTAssertEqual(error as? WindowsPipeError, .instanceAlreadyRunning)
      }
      withExtendedLifetime(first) {}
    }

    func testRendezvousSecretPersistsRotatesAndScopesTaskIdentity() throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("graphcode-rendezvous-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
      let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
      let firstEnvironment = [SupportDirectory.environmentKey: firstDirectory.path]
      let secondEnvironment = [SupportDirectory.environmentKey: secondDirectory.path]

      let first = try WindowsNamedPipeEndpoint.name(environment: firstEnvironment)
      XCTAssertEqual(first, try WindowsNamedPipeEndpoint.name(environment: firstEnvironment))
      let secretFile = firstDirectory.appendingPathComponent(".graphcode-rendezvous.secret")
      XCTAssertTrue(FileManager.default.fileExists(atPath: secretFile.path))
      try FileManager.default.removeItem(at: secretFile)
      try Data("corrupt".utf8).write(to: secretFile)
      let rotated = try WindowsNamedPipeEndpoint.name(environment: firstEnvironment)
      XCTAssertNotEqual(first, rotated)
      XCTAssertNotEqual(
        try WindowsNamedPipeEndpoint.taskName(environment: firstEnvironment),
        try WindowsNamedPipeEndpoint.taskName(environment: secondEnvironment))
      XCTAssertNotEqual(
        rotated,
        try WindowsNamedPipeEndpoint.name(environment: secondEnvironment))
    }

    func testDaemonInstanceLockUsesGlobalCurrentUserScopedNameAndDescriptor() {
      let sid = "S-1-5-21-100-200-300-400"
      let name = WindowsDaemonInstanceLock.name(
        sid: sid,
        supportHash: "0123456789abcdef0123456789abcdef",
        rendezvousHash: "fedcba9876543210fedcba9876543210")
      XCTAssertTrue(name.hasPrefix("Global\\"))
      XCTAssertFalse(name.hasPrefix("Local\\"))
      XCTAssertEqual(
        WindowsDaemonInstanceLock.securityDescriptor(for: sid),
        "D:P(A;;GA;;;\(sid))")
      XCTAssertFalse(
        WindowsDaemonInstanceLock.securityDescriptor(for: sid).contains("WD"))
      XCTAssertNotEqual(
        WindowsNamedPipeEndpoint.taskName(
          sid: sid,
          supportHash: "0123456789abcdef0123456789abcdef",
          rendezvousHash: "fedcba9876543210fedcba9876543210"),
        WindowsNamedPipeEndpoint.taskName(
          sid: "S-1-5-21-900-800-700-600",
          supportHash: "0123456789abcdef0123456789abcdef",
          rendezvousHash: "fedcba9876543210fedcba9876543210"))
      XCTAssertNotEqual(
        WindowsNamedPipeEndpoint.taskName(
          sid: sid,
          supportHash: "0123456789abcdef0123456789abcdef",
          rendezvousHash: "fedcba9876543210fedcba9876543210"),
        WindowsNamedPipeEndpoint.taskName(
          sid: sid,
          supportHash: "fedcba9876543210fedcba9876543210",
          rendezvousHash: "0123456789abcdef0123456789abcdef"))
    }

    func testFrameHeaderRemainsBoundedBeforeAllocation() throws {
      XCTAssertThrowsError(
        try DaemonFrameHeader.decodeLength(
          [0x7f, 0xff, 0xff, 0xff],
          maxPayloadBytes: DaemonFrameHeader.legacySafetyCeilingBytes))
    }

    func testPeerDisconnectCodesMapToConnectionClosed() {
      let codes = [
        ERROR_BROKEN_PIPE,
        ERROR_NO_DATA,
        ERROR_PIPE_NOT_CONNECTED,
        ERROR_OPERATION_ABORTED,
        ERROR_CONNECTION_ABORTED,
        ERROR_NETNAME_DELETED,
      ]
      for code in codes {
        XCTAssertTrue(
          WindowsPipeError.isPeerDisconnectCode(UInt32(truncatingIfNeeded: code)),
          "code \(code) was not classified as a peer disconnect")
      }
    }

    func testWindowsPeerDisconnectUsesAmbiguousCLIExitCode() {
      XCTAssertEqual(DaemonSocketClient.ambiguousExitCode, 75)
      XCTAssertTrue(
        DaemonSocketClient.isAmbiguousConnectionClose(WindowsPipeError.connectionClosed))
      XCTAssertFalse(
        DaemonSocketClient.isAmbiguousConnectionClose(WindowsPipeError.timedOut))
    }

    func testWindowsTaskStateIgnoresLocalizedQueryText() {
      let localizedFixture = "Estado: En ejecución\r\nEstado: Ejecutándose"
      XCTAssertFalse(localizedFixture.isEmpty)
      XCTAssertEqual(
        WindowsStartupManager.status(taskQuerySucceeded: true, daemonProcessRunning: true),
        .running)
      XCTAssertEqual(
        WindowsStartupManager.status(taskQuerySucceeded: true, daemonProcessRunning: false),
        .stopped)
      XCTAssertEqual(
        WindowsStartupManager.status(taskQuerySucceeded: false, daemonProcessRunning: true),
        .notInstalled)
    }

    func testWindowsStopWaitsForDelayedProcessTermination() async throws {
      let started = Date()
      try await WindowsStartupManager.waitForExit(timeout: 1) {
        Date().timeIntervalSince(started) < 0.2
      }
      XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.2)
    }

    func testWriteCancellationRaceClassifiesPossibleDeliveryAsAmbiguous() {
      XCTAssertEqual(
        WindowsPipeError.classifyWriteCancellation(
          cancelSucceeded: true,
          cancelError: nil,
          completionSucceeded: false,
          completionCode: UInt32(truncatingIfNeeded: ERROR_OPERATION_ABORTED),
          transferred: 0),
        .timedOut)
      let ambiguous = WindowsPipeError.classifyWriteCancellation(
        cancelSucceeded: false,
        cancelError: UInt32(truncatingIfNeeded: ERROR_NOT_FOUND),
        completionSucceeded: true,
        completionCode: 0,
        transferred: 1)
      XCTAssertEqual(ambiguous, .writeOutcomeUnknown)
      XCTAssertTrue(DaemonSocketClient.isAmbiguousConnectionClose(ambiguous))
    }

    func testManyIdlePreHandshakeClientsCannotExhaustWorkerPermits() {
      let limiter = WindowsPipeHandshakeLimiter(limit: 4)
      let permits = (0..<4).compactMap { _ in limiter.tryAcquire() }
      XCTAssertEqual(permits.count, 4)
      XCTAssertNil(limiter.tryAcquire())
      permits[0].release()
      XCTAssertNotNil(limiter.tryAcquire())
      for permit in permits {
        permit.release()
      }
    }

    func testManyIdlePreHandshakeClientsEventuallyAllowLegitimateClient() async throws {
      let name =
        try WindowsNamedPipeEndpoint.name()
        + "-handshake-limit-\(UUID().uuidString.lowercased())"
      let listener = try WindowsNamedPipeListener(pipeName: name)
      defer { Task { try? await listener.close() } }
      let limiter = WindowsPipeHandshakeLimiter(limit: 4)
      let server = Task {
        for _ in 0..<5 {
          let connection = try await listener.accept()
          guard let permit = limiter.tryAcquire() else {
            try? await connection.close()
            continue
          }
          Task {
            defer { permit.release() }
            do {
              let frame = try await (connection as! WindowsNamedPipeConnection)
                .receiveFrameWithFirstByteDeadline(firstByteTimeout: 0.15)
              try await connection.sendFrame(frame)
            } catch {
              try? await connection.close()
            }
          }
        }
      }
      let idleClients = try (0..<4).map { _ in
        try WindowsNamedPipeClient.connect(to: name)
      }
      try await Task.sleep(for: .milliseconds(250))
      let legitimate = try WindowsNamedPipeClient.connect(to: name)
      let payload = Data("legitimate".utf8)
      try await legitimate.sendFrame(payload)
      let response = try await legitimate.receiveFrame()
      XCTAssertEqual(response, payload)
      try await legitimate.close()
      for client in idleClients {
        try await client.close()
      }
      try await server.value
    }

    func testManyAuthenticatedIdleClientsDoNotExhaustLegitimateService() async throws {
      let name =
        try WindowsNamedPipeEndpoint.name()
        + "-established-idle-\(UUID().uuidString.lowercased())"
      let listener = try WindowsNamedPipeListener(pipeName: name)
      defer { Task { try? await listener.close() } }

      let idleCount = 64
      let hello = try JSONEncoder().encode(
        DaemonWireEnvelope.hello(supportedVersions: [2], clientID: UUID()))
      let helloResponse = try JSONEncoder().encode(
        DaemonWireEnvelope.helloResponse(selectedVersion: 2))
      let server = Task {
        for _ in 0...idleCount {
          let connection = try await listener.accept()
          Task {
            defer { Task { try? await connection.close() } }
            do {
              let pipe = connection as! WindowsNamedPipeConnection
              _ = try await pipe.receiveFrameWithFirstByteDeadline()
              try await connection.sendFrame(helloResponse)
              let frame = try await pipe.receiveFrameWithPostHandshakeDeadline(1)
              try await connection.sendFrame(frame)
            } catch {
              try? await connection.close()
            }
          }
        }
      }

      var idleClients: [WindowsNamedPipeConnection] = []
      for _ in 0..<idleCount {
        let client = try WindowsNamedPipeClient.connect(to: name)
        try await client.sendFrame(hello)
        _ = try await client.receiveFrame()
        idleClients.append(client)
      }
      let legitimate = try WindowsNamedPipeClient.connect(to: name)
      try await legitimate.sendFrame(hello)
      _ = try await legitimate.receiveFrame()
      let payload = Data("legitimate-after-idle-flood".utf8)
      try await legitimate.sendFrame(payload)
      let response = try await legitimate.receiveFrame()
      XCTAssertEqual(response, payload)
      try await legitimate.close()
      for client in idleClients {
        try await client.close()
      }
      try await server.value
    }

    func testWindowsBootstrapInstallsRuntimeWithHelpersAtomically() throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("graphcode-bootstrap-\(UUID().uuidString)", isDirectory: true)
      let bundled = root.appendingPathComponent("bundle", isDirectory: true)
      let destination = root.appendingPathComponent("support-bin", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }
      try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: destination, withIntermediateDirectories: true)
      let oldDaemon = destination.appendingPathComponent("graphcoded.exe")
      try Data("old".utf8).write(to: oldDaemon)
      try Data("daemon".utf8).write(to: bundled.appendingPathComponent("graphcoded.exe"))
      try Data("cli".utf8).write(to: bundled.appendingPathComponent("graphcode.exe"))

      XCTAssertThrowsError(
        try DaemonBootstrap.installBundledFiles(from: bundled, to: destination)
      ) { error in
        XCTAssertEqual(error as? StartupManagerError, .missingRuntimeFiles)
      }
      XCTAssertEqual(try Data(contentsOf: oldDaemon), Data("old".utf8))

      try Data("swift-runtime".utf8).write(to: bundled.appendingPathComponent("swiftCore.dll"))
      try DaemonBootstrap.installBundledFiles(from: bundled, to: destination)
      XCTAssertEqual(
        try Data(contentsOf: destination.appendingPathComponent("graphcoded.exe")),
        Data("daemon".utf8))
      XCTAssertEqual(
        try Data(contentsOf: destination.appendingPathComponent("graphcode.exe")),
        Data("cli".utf8))
      XCTAssertEqual(
        try Data(contentsOf: destination.appendingPathComponent("swiftCore.dll")),
        Data("swift-runtime".utf8))

      try Data("cli-new".utf8).write(to: bundled.appendingPathComponent("graphcode.exe"))
      XCTAssertThrowsError(
        try DaemonBootstrap.installBundledFiles(
          from: bundled, to: destination, failAfterCopy: 2))
      XCTAssertEqual(
        try Data(contentsOf: destination.appendingPathComponent("graphcode.exe")),
        Data("cli".utf8))
    }

    func testWindowsTransportRoundTripsPartialFrameOperations() async throws {
      let name =
        try WindowsNamedPipeEndpoint.name()
        + "-\(UUID().uuidString.lowercased())"
      let listener = try WindowsNamedPipeListener(pipeName: name)
      defer { Task { try? await listener.close() } }

      let server = Task {
        let connection = try await listener.accept()
        let frame = try await connection.receiveFrame()
        try await connection.sendFrame(frame)
        try await connection.close()
        return frame
      }
      let client = try WindowsNamedPipeClient.connect(to: name)
      let payload = Data(repeating: 0x41, count: 128 * 1024)
      try await client.sendFrame(payload)
      let received = try await client.receiveFrame()
      try await client.close()

      XCTAssertEqual(received, payload)
      let serverFrame = try await server.value
      XCTAssertEqual(serverFrame, payload)
    }

    func testWindowsTransportSupportsMultipleClients() async throws {
      let name =
        try WindowsNamedPipeEndpoint.name()
        + "-\(UUID().uuidString.lowercased())"
      let listener = try WindowsNamedPipeListener(pipeName: name)
      defer { Task { try? await listener.close() } }

      let server = Task {
        var frames: [Data] = []
        for _ in 0..<2 {
          let connection = try await listener.accept()
          let frame = try await connection.receiveFrame()
          frames.append(frame)
          try await connection.sendFrame(frame)
          try await connection.close()
        }
        return frames
      }

      let first = try WindowsNamedPipeClient.connect(to: name)
      let firstPayload = Data("first".utf8)
      let secondPayload = Data("second".utf8)
      try await first.sendFrame(firstPayload)
      let firstReceived = try await first.receiveFrame()
      XCTAssertEqual(firstReceived, firstPayload)

      let second = try WindowsNamedPipeClient.connect(to: name)
      try await second.sendFrame(secondPayload)
      let secondReceived = try await second.receiveFrame()
      XCTAssertEqual(secondReceived, secondPayload)
      try await first.close()
      try await second.close()
      let serverFrames = try await server.value
      XCTAssertEqual(Set(serverFrames), Set([firstPayload, secondPayload]))
    }

    func testWindowsTransportUnavailableEndpointIsBounded() throws {
      let name =
        try WindowsNamedPipeEndpoint.name()
        + "-missing-\(UUID().uuidString.lowercased())"
      let start = Date()
      XCTAssertThrowsError(
        try WindowsNamedPipeClient.connect(to: name, timeoutMilliseconds: 100)
      ) { error in
        guard case WindowsPipeError.win32(_, let code) = error else {
          return XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(
          code == UInt32(ERROR_FILE_NOT_FOUND)
            || code == UInt32(bitPattern: ERROR_SEM_TIMEOUT),
          "unexpected Win32 error \(code)")
      }
      XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testWindowsListenerCloseCancelsPendingAccept() async throws {
      let name =
        try WindowsNamedPipeEndpoint.name()
        + "-close-\(UUID().uuidString.lowercased())"
      let listener = try WindowsNamedPipeListener(pipeName: name)
      let pending = Task {
        try await listener.accept()
      }
      try await Task.sleep(for: .milliseconds(50))
      try await listener.close()

      do {
        _ = try await pending.value
        XCTFail("closed listener unexpectedly accepted a connection")
      } catch WindowsPipeError.connectionClosed {
        return
      } catch {
        XCTFail("unexpected listener error: \(error)")
      }
    }

    func testWindowsListenerCloseRacingAcceptDoesNotLeaveWorkersPending() async throws {
      for _ in 0..<20 {
        let name =
          try WindowsNamedPipeEndpoint.name()
          + "-race-\(UUID().uuidString.lowercased())"
        let listener = try WindowsNamedPipeListener(pipeName: name)
        let pending = Task {
          try await listener.accept()
        }
        try await listener.close()

        do {
          _ = try await pending.value
          XCTFail("closed listener unexpectedly accepted a connection")
        } catch WindowsPipeError.connectionClosed {
          continue
        } catch {
          XCTFail("unexpected listener error: \(error)")
        }
      }
    }

    func testWindowsListenerCloseLosingHandoffNeverReturnsConnection() async throws {
      let name =
        try WindowsNamedPipeEndpoint.name()
        + "-handoff-close-\(UUID().uuidString.lowercased())"
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      let listener = try WindowsNamedPipeListener(
        pipeName: name,
        beforeConnectionReturn: {
          entered.signal()
          release.wait()
        })
      let pending = Task {
        try await listener.accept()
      }
      let client = try WindowsNamedPipeClient.connect(to: name)
      XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
      try await listener.close()
      release.signal()

      do {
        _ = try await pending.value
        XCTFail("listener returned a connection after close completed")
      } catch WindowsPipeError.connectionClosed {
        // Expected: close won the transfer/return handoff.
      } catch {
        XCTFail("unexpected listener error: \(error)")
      }
      try await client.close()
    }

    func testWindowsPostHandshakeDeadlineDoesNotExpireIdleClient() async throws {
      let name =
        try WindowsNamedPipeEndpoint.name()
        + "-idle-\(UUID().uuidString.lowercased())"
      let listener = try WindowsNamedPipeListener(pipeName: name)
      defer { Task { try? await listener.close() } }

      let server = Task {
        let connection = try await listener.accept()
        defer { Task { try? await connection.close() } }
        return try await (connection as! WindowsNamedPipeConnection)
          .receiveFrameWithPostHandshakeDeadline(0.2)
      }
      let client = try WindowsNamedPipeClient.connect(to: name)
      try await Task.sleep(for: .milliseconds(350))
      let payload = Data("idle-then-frame".utf8)
      try await client.sendFrame(payload)

      let received = try await server.value
      XCTAssertEqual(received, payload)
      try await client.close()
    }

    func testWindowsWholeResponseDeadlineStartsBeforeFirstByte() async throws {
      let name =
        try WindowsNamedPipeEndpoint.name()
        + "-whole-response-\(UUID().uuidString.lowercased())"
      let listener = try WindowsNamedPipeListener(pipeName: name)
      defer { Task { try? await listener.close() } }

      let server = Task {
        let connection = try await listener.accept()
        defer { Task { try? await connection.close() } }
        do {
          _ = try await (connection as! WindowsNamedPipeConnection)
            .receiveFrameWithDeadline(0.15)
          XCTFail("delayed response unexpectedly completed")
        } catch WindowsPipeError.timedOut {
          return
        }
      }
      let client = try WindowsNamedPipeClient.connect(to: name)
      try await Task.sleep(for: .milliseconds(250))
      try await client.close()
      try await server.value
    }

    func testWindowsStalledWriteTimesOutAndClosesChannel() async throws {
      let name =
        try WindowsNamedPipeEndpoint.name()
        + "-stalled-write-\(UUID().uuidString.lowercased())"
      let listener = try WindowsNamedPipeListener(pipeName: name, writeTimeout: 0.1)
      defer { Task { try? await listener.close() } }

      let server = Task {
        let connection = try await listener.accept()
        do {
          try await connection.sendFrame(
            Data(repeating: 0x5a, count: Int(DaemonFrameHeader.legacySafetyCeilingBytes)))
          XCTFail("non-reading peer allowed an unbounded write")
        } catch WindowsPipeError.timedOut {
          return
        }
        XCTFail("stalled write did not time out")
      }
      let client = try WindowsNamedPipeClient.connect(to: name)
      try await server.value
      try await client.close()
    }
  #endif
}
