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
    private(set) var frames = [Data]()

    func receiveFrame() async throws -> Data {
      throw FramedMessageIO.IOError.connectionClosed
    }

    func sendFrame(_ data: Data) async throws {
      frames.append(data)
    }

    func close() async throws {}
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
    await channel.setActiveRequestID(requestID)
    try await channel.sendError(code: .requestFailed, message: "request failed")
    try await channel.sendResponse(requestID: requestID, event: .errorOccurred("response"))

    let frames = transport.frames
    XCTAssertEqual(frames.count, 3)
    let event = try JSONDecoder().decode(DaemonWireEnvelope.self, from: frames[0])
    let error = try JSONDecoder().decode(DaemonWireEnvelope.self, from: frames[1])
    let response = try JSONDecoder().decode(DaemonWireEnvelope.self, from: frames[2])
    XCTAssertEqual(event.sequence, 1)
    XCTAssertEqual(event.kind, .event)
    XCTAssertEqual(error.requestID, requestID)
    XCTAssertEqual(error.kind, .error)
    XCTAssertEqual(response.requestID, requestID)
    XCTAssertEqual(response.kind, .response)
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
