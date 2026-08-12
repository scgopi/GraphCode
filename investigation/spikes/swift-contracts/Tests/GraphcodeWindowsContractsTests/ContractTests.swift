import Foundation

import GraphcodeWindowsContracts

import XCTest

final class ContractTests: XCTestCase {
  func testDeployedV1CommandStillDecodes() throws {
    let data = Data(#"{"listRecentProjects":{}}"#.utf8)

    XCTAssertEqual(
      try DaemonWireProtocol.decodeClientFrame(data),
      .v1(.listRecentProjects))
  }

  func testFrozenV1AppAndPythonShimCommandsStillDecode() throws {
    let appCommand = Data(#"{"openProject":{"path":"C:\\Projects\\Demo"}}"#.utf8)
    let shimCommand = Data(#"{"openGlobalGraph":{}}"#.utf8)

    XCTAssertEqual(
      try DaemonWireProtocol.decodeClientFrame(appCommand),
      .v1(.openProject(path: #"C:\Projects\Demo"#)))
    XCTAssertEqual(
      try DaemonWireProtocol.decodeClientFrame(shimCommand),
      .v1(.openGlobalGraph))
  }

  func testV2RequestRoundTripsWithCorrelation() throws {
    let requestID = UUID()
    let envelope = DaemonWireEnvelope.request(
      id: requestID,
      command: .openProject(path: #"C:\Projects\Demo"#))

    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(DaemonWireEnvelope.self, from: data)

    XCTAssertEqual(decoded, envelope)
    XCTAssertEqual(try decoded.validated(), envelope)
  }

  func testNegotiationChoosesHighestMutualVersion() throws {
    let hello = DaemonWireEnvelope.hello(supportedVersions: [1, 2])

    XCTAssertEqual(try DaemonWireProtocol.negotiatedVersion(for: hello), 2)
  }

  func testResponseRequiresRequestID() {
    let invalid = DaemonWireEnvelope(
      version: 2,
      kind: .response,
      event: .errorOccurred("missing correlation"))

    XCTAssertThrowsError(try invalid.validated())
  }

  func testVersionOneEnvelopeIsRejected() {
    let invalid = DaemonWireEnvelope(
      version: 1,
      kind: .hello,
      supportedVersions: [1, 2])

    XCTAssertThrowsError(try invalid.validated())
  }

  func testRequestRejectsFieldsFromAnotherEnvelopeKind() {
    let invalid = DaemonWireEnvelope(
      version: 2,
      kind: .request,
      requestID: UUID(),
      command: .listRecentProjects,
      event: .errorOccurred("not a request field"))

    XCTAssertThrowsError(try invalid.validated())
  }

  func testFrameHeaderRejectsOversizedPayload() {
    let header: [UInt8] = [0x7f, 0xff, 0xff, 0xff]

    XCTAssertThrowsError(try DaemonFrameHeader.decodeLength(header))
  }

  func testFrameHeaderRoundTripsAllowedPayload() throws {
    let encoded = try DaemonFrameHeader.encodeLength(64 * 1024)

    XCTAssertEqual(try DaemonFrameHeader.decodeLength(Array(encoded)), 64 * 1024)
  }

  func testFramingRoundTripsThroughAByteStream() async throws {
    let writer = MemoryByteStream()
    try await FramedMessageIO.writeFrame(Data("hello".utf8), to: writer)

    let reader = MemoryByteStream(input: writer.output)
    let frame = try await FramedMessageIO.readFrame(from: reader)
    XCTAssertEqual(frame, Data("hello".utf8))
  }

  func testFramingRejectsOversizedPayloadBeforeWriting() async {
    let writer = MemoryByteStream()
    do {
      try await FramedMessageIO.writeFrame(
        Data(repeating: 0, count: FramedMessageIO.maxPayloadBytes + 1), to: writer)
      XCTFail("expected oversized payload to be rejected")
    } catch FramedMessageIO.IOError.payloadTooLarge {
      XCTAssertTrue(writer.output.isEmpty)
    } catch {
      XCTFail("unexpected framing error: \(error)")
    }
  }

  func testHelloCanCarrySubscriptionAndResumeCursor() throws {
    let hello = DaemonWireEnvelope.hello(
      supportedVersions: [1, 2],
      clientID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      resumeFrom: 41,
      subscription: DaemonWireSubscription(projectPaths: ["/work/demo"]))

    let decoded = try JSONDecoder().decode(
      DaemonWireEnvelope.self, from: JSONEncoder().encode(hello))

    XCTAssertEqual(decoded, hello)
    XCTAssertEqual(decoded.subscription?.projectPaths, ["/work/demo"])
    XCTAssertEqual(decoded.resumeFrom, 41)
  }

  private final class MemoryByteStream: @unchecked Sendable, DaemonByteStream {
    private var input: Data
    private var offset = 0
    private(set) var output = Data()

    init(input: Data = Data()) {
      self.input = input
    }

    func readExactly(_ count: Int) async throws -> Data {
      guard input.count - offset >= count else {
        throw FramedMessageIO.IOError.connectionClosed
      }
      defer { offset += count }
      return input.subdata(in: offset..<offset + count)
    }

    func writeAll(_ data: Data) async throws {
      output.append(data)
    }

    func close() async throws {}
  }

  private final class RecordingConnection: @unchecked Sendable, DaemonConnection {
    let id = UUID()
    let endpoint: DaemonEndpoint = .namedPipe("fixture")
    private let probe = SendProbe()
    private let sendDelay: Duration
    private(set) var frames = [Data]()

    init(sendDelay: Duration = .milliseconds(2)) {
      self.sendDelay = sendDelay
    }

    func receiveFrame() async throws -> Data {
      throw FramedMessageIO.IOError.connectionClosed
    }

    func sendFrame(_ data: Data) async throws {
      await probe.begin()
      try? await Task.sleep(for: sendDelay)
      frames.append(data)
      await probe.end()
    }

    func close() async throws {}

    var maxConcurrentSends: Int {
      get async { await probe.maximum }
    }
  }

  private actor SendProbe {
    private var current = 0
    private(set) var maximum = 0

    func begin() {
      current += 1
      maximum = max(maximum, current)
    }

    func end() {
      current -= 1
    }
  }

  func testReplayBufferReturnsContiguousEvents() throws {
    var buffer = DaemonReplayBuffer(capacity: 2)
    buffer.append(sequence: 1, event: .errorOccurred("one"))
    buffer.append(sequence: 2, event: .errorOccurred("two"))
    buffer.append(sequence: 3, event: .errorOccurred("three"))

    XCTAssertEqual(
      try buffer.replay(after: 1),
      [
        .event(sequence: 2, event: .errorOccurred("two")),
        .event(sequence: 3, event: .errorOccurred("three")),
      ])
  }

  func testReplayBufferReportsCursorOutsideWindow() {
    var buffer = DaemonReplayBuffer(capacity: 2)
    buffer.append(sequence: 1, event: .errorOccurred("one"))
    buffer.append(sequence: 2, event: .errorOccurred("two"))
    buffer.append(sequence: 3, event: .errorOccurred("three"))

    XCTAssertThrowsError(try buffer.replay(after: 0))
  }

  func testReplayBufferDistinguishesCaughtUpFromCursorBeyondLatest() throws {
    var buffer = DaemonReplayBuffer(capacity: 2)
    buffer.append(sequence: 1, event: .errorOccurred("one"))
    buffer.append(sequence: 2, event: .errorOccurred("two"))

    XCTAssertEqual(try buffer.replay(after: 2), [])
    XCTAssertThrowsError(try buffer.replay(after: 3)) { error in
      XCTAssertEqual(
        error as? DaemonReplayBuffer.ReplayError, .cursorOutsideWindow)
    }
  }

  func testUnknownReplayHistoryIsUnavailable() {
    let store = DaemonReplayStore(capacity: 2)
    do {
      _ = try store.replay(clientID: UUID(), after: 0)
      XCTFail("expected unknown replay history to be unavailable")
    } catch DaemonReplayBuffer.ReplayError.replayUnavailable {
      // Expected after a daemon restart with no retained client history.
    } catch {
      XCTFail("unexpected replay error: \(error)")
    }
  }

  func testReplayUsesTheReconnectingChannelsCurrentSubscription() async throws {
    let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    let store = DaemonReplayStore(capacity: 8)
    let first = LoopGraph(project: ProjectRef(path: "/work/first", name: "first"))
    let second = LoopGraph(project: ProjectRef(path: "/work/second", name: "second"))
    _ = store.append(clientID: clientID, event: .graphChanged(first))
    _ = store.append(clientID: clientID, event: .graphChanged(second))

    let transport = RecordingConnection()
    let channel = DaemonConnectionChannel(
      connection: transport,
      mode: .v2(version: 2),
      clientID: clientID,
      subscription: DaemonWireSubscription(projectPaths: ["/work/second"]),
      replayStore: store)

    try await channel.replay(after: 0)

    XCTAssertEqual(transport.frames.count, 1)
    let replayed = try JSONDecoder().decode(
      DaemonWireEnvelope.self, from: transport.frames[0])
    guard case .graphChanged(let graph) = replayed.event else {
      return XCTFail("expected a graphChanged replay")
    }
    XCTAssertEqual(graph.project.path, "/work/second")
  }

  func testReplayQueuesLiveEventsAfterReplaySequence() async throws {
    let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    let store = DaemonReplayStore(capacity: 8)
    _ = store.append(clientID: clientID, event: .errorOccurred("replay-1"))
    _ = store.append(clientID: clientID, event: .errorOccurred("replay-2"))
    let transport = RecordingConnection(sendDelay: .milliseconds(20))
    let channel = DaemonConnectionChannel(
      connection: transport,
      mode: .v2(version: 2),
      clientID: clientID,
      replayStore: store)

    let replay = Task { try await channel.replay(after: 0) }
    try await Task.sleep(for: .milliseconds(1))
    try await channel.sendEvent(.errorOccurred("live-3"))
    try await replay.value

    let sequences = try transport.frames.map {
      try JSONDecoder().decode(DaemonWireEnvelope.self, from: $0).sequence
    }
    XCTAssertEqual(sequences, [1, 2, 3])
  }

  func testReplayStoreEvictsAndExpiresClientHistory() throws {
    let first = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
    let second = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
    let third = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!
    let store = DaemonReplayStore(capacity: 2, maxClients: 2, retention: 60)

    _ = store.append(clientID: first, event: .errorOccurred("first"))
    _ = store.append(clientID: second, event: .errorOccurred("second"))
    _ = try store.replay(clientID: second, after: 0)
    _ = store.append(clientID: third, event: .errorOccurred("third"))

    XCTAssertThrowsError(try store.replay(clientID: first, after: 0)) { error in
      XCTAssertEqual(error as? DaemonReplayBuffer.ReplayError, .replayUnavailable)
    }
    XCTAssertEqual(store.clientCount, 2)

    store.pruneExpired(at: Date().addingTimeInterval(61))
    XCTAssertEqual(store.clientCount, 0)
  }

  func testMalformedV2RequestKeepsSafelyExtractableRequestID() throws {
    let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
    var malformed = DaemonWireEnvelope.request(id: requestID, command: .listRecentProjects)
    malformed.event = .errorOccurred("unexpected")
    let data = try JSONEncoder().encode(malformed)

    XCTAssertThrowsError(try DaemonWireProtocol.decodeClientFrame(data))
    XCTAssertEqual(DaemonWireProtocol.requestIDIfPresent(in: data), requestID)
  }

  func testV2ChannelSequencesEventsAndCorrelatesResponses() async throws {
    let transport = RecordingConnection()
    let store = DaemonReplayStore(capacity: 8)
    let channel = DaemonConnectionChannel(
      connection: transport,
      mode: .v2(version: 2),
      clientID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      replayStore: store)

    try await channel.sendEvent(.errorOccurred("event"))
    let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    try await channel.sendError(
      requestID: requestID, code: .requestFailed, message: "request failed")
    try await channel.sendError(code: .transportFailure, message: "broadcast failure")
    try await channel.sendResponse(requestID: requestID, event: .errorOccurred("response"))

    let frames = transport.frames
    XCTAssertEqual(frames.count, 4)
    let event = try JSONDecoder().decode(DaemonWireEnvelope.self, from: frames[0])
    let error = try JSONDecoder().decode(DaemonWireEnvelope.self, from: frames[1])
    let broadcastError = try JSONDecoder().decode(DaemonWireEnvelope.self, from: frames[2])
    let response = try JSONDecoder().decode(DaemonWireEnvelope.self, from: frames[3])
    XCTAssertEqual(event.sequence, 1)
    XCTAssertEqual(event.kind, .event)
    XCTAssertEqual(error.requestID, requestID)
    XCTAssertEqual(error.kind, .error)
    XCTAssertNil(broadcastError.requestID)
    XCTAssertEqual(response.requestID, requestID)
    XCTAssertEqual(response.kind, .response)
  }

  func testConcurrentChannelSendsNeverEnterTheTransportTogether() async {
    let transport = RecordingConnection()
    let channel = DaemonConnectionChannel(
      connection: transport, mode: .v2(version: 2), replayStore: DaemonReplayStore())

    await withTaskGroup(of: Void.self) { group in
      for index in 0..<16 {
        group.addTask {
          try? await channel.sendEvent(.errorOccurred("event-\(index)"))
        }
      }
    }

    let maximum = await transport.maxConcurrentSends
    XCTAssertEqual(maximum, 1)
    XCTAssertEqual(transport.frames.count, 16)
  }

  func testChannelsSharingAConnectionSerializeCompleteWrites() async {
    let transport = RecordingConnection()
    let first = DaemonConnectionChannel(
      connection: transport, mode: .v2(version: 2), replayStore: DaemonReplayStore())
    let second = DaemonConnectionChannel(
      connection: transport, mode: .v2(version: 2), replayStore: DaemonReplayStore())

    await withTaskGroup(of: Void.self) { group in
      for index in 0..<16 {
        group.addTask {
          let channel = index.isMultiple(of: 2) ? first : second
          try? await channel.sendError(
            code: .transportFailure, message: "error-\(index)")
        }
      }
    }

    let maximum = await transport.maxConcurrentSends
    XCTAssertEqual(maximum, 1)
    XCTAssertEqual(transport.frames.count, 16)
  }

  func testRemoteBridgeStateValidatesSecurityFields() throws {
    let issued = Date(timeIntervalSince1970: 1_700_000_000)
    let state = RemoteBridgeState(
      instanceID: UUID(),
      generation: 3,
      remotePort: 42_345,
      capability: String(repeating: "a", count: 64),
      issuedAt: issued,
      expiresAt: issued.addingTimeInterval(3_600))

    XCTAssertEqual(try state.validated(), state)
  }

  func testRemoteBridgeStateRejectsShortCapability() {
    let state = RemoteBridgeState(
      instanceID: UUID(),
      generation: 1,
      remotePort: 42_345,
      capability: "short",
      issuedAt: .now,
      expiresAt: .now.addingTimeInterval(60))

    XCTAssertThrowsError(try state.validated())
  }

  func testProcessRequestPreservesWindowsArguments() {
    let request = ProcessRequest(
      executable: URL(fileURLWithPath: #"C:\Tools\agent.exe"#),
      arguments: ["space value", #"quote"value"#, "雪"],
      workingDirectory: URL(fileURLWithPath: #"C:\Projects\Demo"#),
      environment: ["GRAPHCODE_TEST": "1"])

    XCTAssertEqual(request.arguments[0], "space value")
    XCTAssertEqual(request.environment["GRAPHCODE_TEST"], "1")
  }
}
