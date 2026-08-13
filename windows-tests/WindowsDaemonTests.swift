import Foundation
import XCTest
@testable import GraphcodeKit

#if os(Windows)
  import WinSDK
#endif

final class WindowsDaemonTests: XCTestCase {
  #if os(Windows)
    func testEndpointIsPerUserAndSupportDirectory() throws {
      let first = try WindowsNamedPipeEndpoint.name(
        environment: [SupportDirectory.environmentKey: "graphcode-a"],
        homeDirectory: URL(fileURLWithPath: #"C:\Users\Test"#, isDirectory: true))
      let second = try WindowsNamedPipeEndpoint.name(
        environment: [SupportDirectory.environmentKey: "graphcode-b"],
        homeDirectory: URL(fileURLWithPath: #"C:\Users\Test"#, isDirectory: true))

      XCTAssertTrue(first.hasPrefix("\\\\.\\pipe\\graphcode-"))
      XCTAssertNotEqual(first, second)
      XCTAssertLessThan(first.utf8.count, 240)
    }

    func testFrameHeaderRemainsBoundedBeforeAllocation() throws {
      XCTAssertThrowsError(
        try DaemonFrameHeader.decodeLength(
          [0x7f, 0xff, 0xff, 0xff],
          maxPayloadBytes: DaemonFrameHeader.legacySafetyCeilingBytes))
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
  #endif
}
