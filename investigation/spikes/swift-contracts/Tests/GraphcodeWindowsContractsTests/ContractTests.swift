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

  func testCorrelatedSuccessResponseAllowsNoPayload() throws {
    let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
    let success = DaemonWireEnvelope.success(id: requestID)

    XCTAssertEqual(try success.validated(), success)
    XCTAssertEqual(success.kind, .response)
    XCTAssertEqual(success.requestID, requestID)
    XCTAssertNil(success.event)
    XCTAssertEqual(success.success, true)
  }

  func testV1ListRecentProjectsKeepsLegacyEventShape() async throws {
    let projects = [
      ProjectRef(path: "/work/listed", name: "listed")
    ]
    let event = DaemonEvent.recentProjectsListed(projects)
    let transport = RecordingConnection()
    let channel = DaemonConnectionChannel(connection: transport, mode: .v1)

    try await channel.sendEvent(event)

    let frame = try XCTUnwrap(transport.frames.first)
    XCTAssertEqual(try JSONDecoder().decode(DaemonEvent.self, from: frame), event)
    XCTAssertThrowsError(try JSONDecoder().decode(DaemonWireEnvelope.self, from: frame))
  }

  func testV2ListResponseIsSingleCorrelatedFrameAndNeverReplayed() async throws {
    let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000035")!
    let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000036")!
    let event = DaemonEvent.recentProjectsListed([
      ProjectRef(path: "/work/listed", name: "listed")
    ])
    let store = DaemonReplayStore(capacity: 8)
    let firstTransport = RecordingConnection()
    let firstChannel = DaemonConnectionChannel(
      connection: firstTransport,
      mode: .v2(version: 2),
      clientID: clientID,
      replayStore: store)

    try await firstChannel.sendResponse(requestID: requestID, event: event)

    XCTAssertEqual(firstTransport.frames.count, 1)
    let response = try JSONDecoder().decode(
      DaemonWireEnvelope.self,
      from: XCTUnwrap(firstTransport.frames.first))
    XCTAssertEqual(response.kind, .response)
    XCTAssertEqual(response.requestID, requestID)
    XCTAssertNil(response.sequence)
    guard case .recentProjectsListed(let listed) = response.event else {
      return XCTFail("expected recent-projects response event")
    }
    XCTAssertEqual(listed.first?.path, "/work/listed")

    try await firstChannel.close()
    let reconnectTransport = RecordingConnection()
    let reconnectChannel = DaemonConnectionChannel(
      connection: reconnectTransport,
      mode: .v2(version: 2),
      clientID: clientID,
      replayStore: store)
    try await reconnectChannel.replay(after: 0)
    XCTAssertTrue(reconnectTransport.frames.isEmpty)
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

    XCTAssertThrowsError(
      try DaemonFrameHeader.decodeLength(
        header, maxPayloadBytes: DaemonFrameHeader.legacySafetyCeilingBytes))
  }

  func testLegacySafetyCeilingRejectsUInt32MaximumBeforeAllocation() {
    XCTAssertThrowsError(
      try DaemonFrameHeader.decodeLength(
        [0xff, 0xff, 0xff, 0xff],
        maxPayloadBytes: DaemonFrameHeader.legacySafetyCeilingBytes))
  }

  func testFrameHeaderRoundTripsAllowedPayload() throws {
    let encoded = try DaemonFrameHeader.encodeLength(64 * 1024)

    XCTAssertEqual(try DaemonFrameHeader.decodeLength(Array(encoded)), 64 * 1024)
  }

  func testFrameHeaderPreservesLegacyUInt32PayloadRange() throws {
    let length = 2 * 1_048_576
    let encoded = try DaemonFrameHeader.encodeLength(length)

    XCTAssertEqual(try DaemonFrameHeader.decodeLength(Array(encoded)), length)
    XCTAssertEqual(
      try DaemonFrameHeader.decodeLength([0xff, 0xff, 0xff, 0xff]),
      Int(UInt32.max))
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
        Data(repeating: 0, count: FramedMessageIO.v2MaxPayloadBytes + 1),
        to: writer,
        maxPayloadBytes: FramedMessageIO.v2MaxPayloadBytes)
      XCTFail("expected oversized payload to be rejected")
    } catch FramedMessageIO.IOError.payloadTooLarge {
      XCTAssertTrue(writer.output.isEmpty)
    } catch {
      XCTFail("unexpected framing error: \(error)")
    }
  }

  func testLegacyV1CommandAndEventFramesExceedTheV2Cap() async throws {
    let largeText = String(
      repeating: "x",
      count: Int(DaemonFrameHeader.legacySafetyCeilingBytes) - 1_024)
    let command = DaemonCommand.openProject(path: largeText)
    let commandData = try JSONEncoder().encode(command)
    XCTAssertGreaterThan(commandData.count, FramedMessageIO.v2MaxPayloadBytes)
    XCTAssertLessThanOrEqual(
      commandData.count, Int(DaemonFrameHeader.legacySafetyCeilingBytes))

    let commandWriter = MemoryByteStream()
    try await FramedMessageIO.writeFrame(commandData, to: commandWriter)
    let commandReader = MemoryByteStream(input: commandWriter.output)
    let decodedCommand = try await FramedMessageIO.readFrame(from: commandReader)
    XCTAssertEqual(try DaemonWireProtocol.decodeClientFrame(decodedCommand), .v1(command))

    let event = DaemonEvent.errorOccurred(largeText)
    let eventData = try JSONEncoder().encode(event)
    XCTAssertGreaterThan(eventData.count, FramedMessageIO.v2MaxPayloadBytes)
    XCTAssertLessThanOrEqual(
      eventData.count, Int(DaemonFrameHeader.legacySafetyCeilingBytes))
    let eventWriter = MemoryByteStream()
    try await FramedMessageIO.writeFrame(eventData, to: eventWriter)
    let eventReader = MemoryByteStream(input: eventWriter.output)
    let decodedEvent = try await FramedMessageIO.readFrame(from: eventReader)
    XCTAssertEqual(try JSONDecoder().decode(DaemonEvent.self, from: decodedEvent), event)
  }

  func testOversizedV2EnvelopeIsRejectedAfterEnvelopeIdentification() throws {
    let largePath = String(repeating: "x", count: FramedMessageIO.v2MaxPayloadBytes)
    let envelope = DaemonWireEnvelope.request(
      id: UUID(), command: .openProject(path: largePath))
    let data = try JSONEncoder().encode(envelope)
    XCTAssertGreaterThan(data.count, FramedMessageIO.v2MaxPayloadBytes)

    XCTAssertThrowsError(try DaemonWireProtocol.decodeClientFrame(data)) { error in
      XCTAssertEqual(
        error as? DaemonWireEnvelope.ValidationError, .payloadTooLarge)
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
    let id: UUID
    let endpoint: DaemonEndpoint = .namedPipe("fixture")
    private let probe = SendProbe()
    private let sendDelay: Duration
    private(set) var frames = [Data]()

    init(id: UUID = UUID(), sendDelay: Duration = .milliseconds(2)) {
      self.id = id
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

  private final class SlowReplayConnection: @unchecked Sendable, DaemonConnection {
    let id = UUID()
    let endpoint: DaemonEndpoint = .namedPipe("slow-replay")
    private let state = SlowReplayState()

    func receiveFrame() async throws -> Data {
      throw FramedMessageIO.IOError.connectionClosed
    }

    func sendFrame(_ data: Data) async throws {
      let isClosed = await state.isClosed
      guard !isClosed else { throw FramedMessageIO.IOError.connectionClosed }
      try await Task.sleep(for: .milliseconds(5))
      guard !(await state.isClosed) else {
        throw FramedMessageIO.IOError.connectionClosed
      }
      await state.append(data)
    }

    func close() async throws {
      await state.close()
    }

    var isClosed: Bool {
      get async { await state.isClosed }
    }
  }

  private actor SlowReplayState {
    private(set) var isClosed = false
    private(set) var frames = [Data]()

    func append(_ data: Data) {
      frames.append(data)
    }

    func close() {
      isClosed = true
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

  func testReplayQueueOverflowClosesSlowConnectionDuringUpdateFlood() async throws {
    let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000045")!
    let store = DaemonReplayStore(capacity: 300)
    for index in 0..<300 {
      _ = store.append(clientID: clientID, event: .errorOccurred("history-\(index)"))
    }
    let transport = SlowReplayConnection()
    let channel = DaemonConnectionChannel(
      connection: transport,
      mode: .v2(version: 2),
      clientID: clientID,
      replayStore: store)
    let replayTask = Task {
      try? await channel.replay(after: 0)
    }
    try await Task.sleep(for: .milliseconds(10))

    var overflowed = false
    for index in 0..<(DaemonConnectionChannel.maxQueuedLiveEventCount + 32) {
      do {
        try await channel.sendEvent(.errorOccurred("update-\(index)"))
      } catch DaemonConnectionChannelError.replayQueueOverflow {
        overflowed = true
        break
      } catch {
        break
      }
    }

    XCTAssertTrue(overflowed)
    let closed = await transport.isClosed
    XCTAssertTrue(closed)
    _ = await replayTask.value
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

  func testActiveClientsAreNeverEvictedWhenReplayCapacityIsExhausted() throws {
    let first = UUID(uuidString: "00000000-0000-0000-0000-000000000015")!
    let second = UUID(uuidString: "00000000-0000-0000-0000-000000000016")!
    let third = UUID(uuidString: "00000000-0000-0000-0000-000000000017")!
    let firstConnection = UUID(uuidString: "00000000-0000-0000-0000-000000000018")!
    let secondConnection = UUID(uuidString: "00000000-0000-0000-0000-000000000019")!
    let thirdConnection = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
    let secondThirdConnection = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
    let store = DaemonReplayStore(capacity: 8, maxClients: 2)

    store.register(clientID: first, connectionID: firstConnection, subscription: nil)
    store.register(clientID: second, connectionID: secondConnection, subscription: nil)
    _ = store.append(clientID: first, event: .errorOccurred("first"))
    _ = store.append(clientID: second, event: .errorOccurred("second"))

    store.register(clientID: third, connectionID: thirdConnection, subscription: nil)
    let firstThirdEvent = store.append(clientID: third, event: .errorOccurred("third-1"))
    store.register(
      clientID: third,
      connectionID: secondThirdConnection,
      subscription: nil)
    let secondThirdEvent = store.append(clientID: third, event: .errorOccurred("third-2"))

    XCTAssertEqual(store.clientCount, 2)
    XCTAssertEqual(firstThirdEvent.sequence, 1)
    XCTAssertEqual(secondThirdEvent.sequence, 2)
    XCTAssertNoThrow(try store.replay(clientID: first, after: 0))
    XCTAssertNoThrow(try store.replay(clientID: second, after: 0))
    XCTAssertThrowsError(try store.replay(clientID: third, after: 0)) { error in
      XCTAssertEqual(error as? DaemonReplayBuffer.ReplayError, .replayUnavailable)
    }
  }

  func testOverflowClientPromotionPreservesSequenceWatermarkAndReplay() async throws {
    let first = UUID(uuidString: "00000000-0000-0000-0000-000000000024")!
    let second = UUID(uuidString: "00000000-0000-0000-0000-000000000025")!
    let overflow = UUID(uuidString: "00000000-0000-0000-0000-000000000026")!
    let firstConnection = UUID(uuidString: "00000000-0000-0000-0000-000000000027")!
    let secondConnection = UUID(uuidString: "00000000-0000-0000-0000-000000000028")!
    let overflowConnection = UUID(uuidString: "00000000-0000-0000-0000-000000000029")!
    let store = DaemonReplayStore(capacity: 8, maxClients: 2)

    store.register(clientID: first, connectionID: firstConnection, subscription: nil)
    store.register(clientID: second, connectionID: secondConnection, subscription: nil)
    let overflowTransport = RecordingConnection(id: overflowConnection)
    let overflowChannel = DaemonConnectionChannel(
      connection: overflowTransport,
      mode: .v2(version: 2),
      clientID: overflow,
      replayStore: store)

    try await overflowChannel.sendConnectionSnapshot(
      .graphChanged(LoopGraph(project: ProjectRef(path: "/work/overflow", name: "overflow"))))
    try await overflowChannel.sendEvent(.errorOccurred("live-before-promotion"))
    let initialSequences = try overflowTransport.frames.map {
      try JSONDecoder().decode(DaemonWireEnvelope.self, from: $0).sequence
    }
    XCTAssertEqual(initialSequences, [1, 2])

    store.disconnect(clientID: first, connectionID: firstConnection)
    let canonicalGraph = LoopGraph(
      project: ProjectRef(path: "/work/overflow", name: "overflow"),
      nodes: [LoopNode(title: "canonical")])
    try await overflowChannel.sendEvent(.graphChanged(canonicalGraph))
    let promotedEnvelope = try XCTUnwrap(
      JSONDecoder().decode(
        DaemonWireEnvelope.self,
        from: XCTUnwrap(overflowTransport.frames.last)))
    XCTAssertEqual(promotedEnvelope.sequence, 3)

    try await overflowChannel.close()
    let reconnectTransport = RecordingConnection()
    let reconnectChannel = DaemonConnectionChannel(
      connection: reconnectTransport,
      mode: .v2(version: 2),
      clientID: overflow,
      replayStore: store)
    try await reconnectChannel.replay(after: 2)

    let replayed = try reconnectTransport.frames.map {
      try JSONDecoder().decode(DaemonWireEnvelope.self, from: $0)
    }
    XCTAssertEqual(replayed.map(\.sequence), [3])
    guard case .graphChanged(let replayedGraph) = replayed.first?.event else {
      return XCTFail("expected the canonical graph event in replay")
    }
    XCTAssertEqual(replayedGraph.project.path, canonicalGraph.project.path)
    XCTAssertEqual(replayedGraph.nodes.first?.title, "canonical")
    XCTAssertThrowsError(try store.replay(clientID: first, after: 0)) { error in
      XCTAssertEqual(error as? DaemonReplayBuffer.ReplayError, .replayUnavailable)
    }
  }

  func testCanonicalAppendPromotesOverflowClientAfterInactiveEviction() throws {
    let path = "/work/production-overload"
    let retained = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
    let retainedConnection = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
    let overflow = UUID(uuidString: "00000000-0000-0000-0000-000000000043")!
    let overflowConnection = UUID(uuidString: "00000000-0000-0000-0000-000000000044")!
    let store = DaemonReplayStore(capacity: 8, maxClients: 1)
    store.register(
      clientID: retained, connectionID: retainedConnection, subscription: nil)
    store.join(clientID: retained, connectionID: retainedConnection, projectPath: path)
    let retainedGraph = LoopGraph(project: ProjectRef(path: path, name: "retained"))
    let retainedEnvelope = try XCTUnwrap(
      store.append(event: .graphChanged(retainedGraph), projectPath: path)[retained])
    XCTAssertEqual(retainedEnvelope.sequence, 1)

    store.register(
      clientID: overflow, connectionID: overflowConnection, subscription: nil)
    store.join(clientID: overflow, connectionID: overflowConnection, projectPath: path)
    store.disconnect(clientID: retained, connectionID: retainedConnection)

    let overflowGraph = LoopGraph(project: ProjectRef(path: path, name: "overflow"))
    let promoted = try XCTUnwrap(
      store.append(event: .graphChanged(overflowGraph), projectPath: path)[overflow])
    XCTAssertEqual(promoted.sequence, 1)
    XCTAssertEqual(store.clientCount, 1)
    XCTAssertEqual(try store.replay(clientID: overflow, after: 0), [promoted])
    XCTAssertThrowsError(try store.replay(clientID: retained, after: 0))
  }

  func testZeroCapacityTracksActiveSequencesAndReconnectsWithoutReplay() async throws {
    let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
    let store = DaemonReplayStore(capacity: 8, maxClients: 0)
    let firstTransport = RecordingConnection()
    let firstChannel = DaemonConnectionChannel(
      connection: firstTransport,
      mode: .v2(version: 2),
      clientID: clientID,
      replayStore: store)

    try await firstChannel.sendEvent(.errorOccurred("one"))
    try await firstChannel.sendConnectionSnapshot(.errorOccurred("two"))
    try await firstChannel.sendEvent(.errorOccurred("three"))

    let firstSequences = try firstTransport.frames.map {
      try JSONDecoder().decode(DaemonWireEnvelope.self, from: $0).sequence
    }
    XCTAssertEqual(firstSequences, [1, 2, 3])
    XCTAssertEqual(store.clientCount, 0)
    XCTAssertEqual(try store.replay(clientID: clientID, after: 3), [])
    XCTAssertThrowsError(try store.replay(clientID: clientID, after: 0)) { error in
      XCTAssertEqual(error as? DaemonReplayBuffer.ReplayError, .replayUnavailable)
    }

    try await firstChannel.close()
    let reconnectTransport = RecordingConnection()
    let reconnectChannel = DaemonConnectionChannel(
      connection: reconnectTransport,
      mode: .v2(version: 2),
      clientID: clientID,
      replayStore: store)
    do {
      try await reconnectChannel.replay(after: 3)
      XCTFail("expected reconnect cursor to be outside the new active window")
    } catch DaemonConnectionChannelError.cursorOutsideWindow {
      // Expected: maxClients zero drops the prior active state when disconnected.
    }

    try await reconnectChannel.sendEvent(.errorOccurred("reconnected"))
    let reconnectEnvelope = try XCTUnwrap(
      JSONDecoder().decode(
        DaemonWireEnvelope.self,
        from: XCTUnwrap(reconnectTransport.frames.first)))
    XCTAssertEqual(reconnectEnvelope.sequence, 1)
  }

  func testZeroCapacityBroadcastSharesOneEnvelopeAcrossLogicalSockets() async throws {
    let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
    let path = "/work/multi-socket"
    let store = DaemonReplayStore(capacity: 8, maxClients: 0)
    let firstTransport = RecordingConnection()
    let secondTransport = RecordingConnection()
    let firstChannel = DaemonConnectionChannel(
      connection: firstTransport,
      mode: .v2(version: 2),
      clientID: clientID,
      replayStore: store)
    let secondChannel = DaemonConnectionChannel(
      connection: secondTransport,
      mode: .v2(version: 2),
      clientID: clientID,
      replayStore: store)
    await firstChannel.join(projectPath: path)
    await secondChannel.join(projectPath: path)

    let graph = LoopGraph(project: ProjectRef(path: path, name: "multi-socket"))
    let envelope = try XCTUnwrap(
      store.append(event: .graphChanged(graph), projectPath: path)[clientID])
    try await firstChannel.sendEvent(envelope: envelope)
    try await secondChannel.sendEvent(envelope: envelope)

    let firstFrame = try XCTUnwrap(firstTransport.frames.first)
    let secondFrame = try XCTUnwrap(secondTransport.frames.first)
    let firstEnvelope = try JSONDecoder().decode(DaemonWireEnvelope.self, from: firstFrame)
    let secondEnvelope = try JSONDecoder().decode(DaemonWireEnvelope.self, from: secondFrame)
    XCTAssertEqual(firstEnvelope.sequence, secondEnvelope.sequence)
    guard case .graphChanged(let firstGraph) = firstEnvelope.event,
      case .graphChanged(let secondGraph) = secondEnvelope.event
    else {
      return XCTFail("expected graph events on both logical sockets")
    }
    XCTAssertEqual(firstGraph.id, secondGraph.id)
    XCTAssertEqual(firstGraph.project.path, secondGraph.project.path)
    XCTAssertEqual(firstEnvelope.sequence, 1)
  }

  func testProjectMembershipSurvivesOneSocketLeaveAndReplaysAfterBothDisconnect() async throws {
    let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
    let firstConnection = UUID(uuidString: "00000000-0000-0000-0000-000000000033")!
    let secondConnection = UUID(uuidString: "00000000-0000-0000-0000-000000000034")!
    let path = "/work/multi-join"
    let store = DaemonReplayStore(capacity: 8, maxClients: 2)
    store.register(clientID: clientID, connectionID: firstConnection, subscription: nil)
    store.register(clientID: clientID, connectionID: secondConnection, subscription: nil)
    store.join(clientID: clientID, connectionID: firstConnection, projectPath: path)
    store.join(clientID: clientID, connectionID: secondConnection, projectPath: path)

    let firstGraph = LoopGraph(project: ProjectRef(path: path, name: "multi-join"))
    let firstEnvelope = try XCTUnwrap(
      store.append(event: .graphChanged(firstGraph), projectPath: path)[clientID])
    store.leave(clientID: clientID, connectionID: firstConnection, projectPath: path)
    let secondGraph = LoopGraph(
      project: ProjectRef(path: path, name: "multi-join"),
      nodes: [NodeDraft(title: "second", loopType: .composite).makeNode()])
    let secondEnvelope = try XCTUnwrap(
      store.append(event: .graphChanged(secondGraph), projectPath: path)[clientID])
    XCTAssertEqual(firstEnvelope.sequence, 1)
    XCTAssertEqual(secondEnvelope.sequence, 2)

    store.disconnect(clientID: clientID, connectionID: firstConnection)
    store.disconnect(clientID: clientID, connectionID: secondConnection)
    let thirdGraph = LoopGraph(
      project: ProjectRef(path: path, name: "multi-join"),
      nodes: [NodeDraft(title: "third", loopType: .composite).makeNode()])
    let thirdEnvelope = try XCTUnwrap(
      store.append(event: .graphChanged(thirdGraph), projectPath: path)[clientID])
    XCTAssertEqual(thirdEnvelope.sequence, 3)
    XCTAssertEqual(
      try store.replay(clientID: clientID, after: 2).map(\.sequence),
      [3])

    let reconnectTransport = RecordingConnection()
    let reconnectChannel = DaemonConnectionChannel(
      connection: reconnectTransport,
      mode: .v2(version: 2),
      clientID: clientID,
      replayStore: store)
    try await reconnectChannel.replay(after: 2)
    let replayed = try JSONDecoder().decode(
      DaemonWireEnvelope.self,
      from: XCTUnwrap(reconnectTransport.frames.first))
    XCTAssertEqual(replayed.sequence, 3)
  }

  func testReplayStoreAutomaticallyExpiresIdleHistory() async throws {
    let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    let store = DaemonReplayStore(capacity: 2, retention: 0.01)
    let cleanup = store.startCleanup(every: .milliseconds(5))
    defer { cleanup.cancel() }
    _ = store.append(clientID: clientID, event: .errorOccurred("idle"))

    for _ in 0..<100 where store.clientCount != 0 {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(store.clientCount, 0)
  }

  func testReplayRetainsCanonicalEventsWhileLogicalClientIsDisconnected() throws {
    let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
    let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
    let path = "/work/disconnected"
    let store = DaemonReplayStore(capacity: 8)
    store.register(clientID: clientID, connectionID: connectionID, subscription: nil)
    store.join(clientID: clientID, projectPath: path)

    let first = LoopGraph(project: ProjectRef(path: path, name: "disconnected"))
    let second = LoopGraph(
      project: ProjectRef(path: path, name: "disconnected"),
      nodes: [NodeDraft(title: "later", loopType: .composite).makeNode()])
    let firstEnvelope = try XCTUnwrap(
      store.append(event: .graphChanged(first), projectPath: path)[clientID])
    store.disconnect(clientID: clientID, connectionID: connectionID)
    let secondEnvelope = try XCTUnwrap(
      store.append(event: .graphChanged(second), projectPath: path)[clientID])

    XCTAssertEqual(firstEnvelope.sequence, 1)
    XCTAssertEqual(secondEnvelope.sequence, 2)
    XCTAssertEqual(
      try store.replay(clientID: clientID, after: 1),
      [secondEnvelope])
  }

  func testRepeatedConnectionSnapshotsDoNotCreateReplayHistory() async throws {
    let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000014")!
    let store = DaemonReplayStore(capacity: 8)
    let graph = LoopGraph(project: ProjectRef(path: "/work/rejoin", name: "rejoin"))

    let first = RecordingConnection()
    let firstChannel = DaemonConnectionChannel(
      connection: first,
      mode: .v2(version: 2),
      clientID: clientID,
      replayStore: store)
    try await firstChannel.sendConnectionSnapshot(.graphChanged(graph))
    try await firstChannel.close()

    let second = RecordingConnection()
    let secondChannel = DaemonConnectionChannel(
      connection: second,
      mode: .v2(version: 2),
      clientID: clientID,
      replayStore: store)
    try await secondChannel.sendConnectionSnapshot(.graphChanged(graph))
    try await secondChannel.close()

    XCTAssertThrowsError(try store.replay(clientID: clientID, after: 0)) { error in
      XCTAssertEqual(error as? DaemonReplayBuffer.ReplayError, .replayUnavailable)
    }
  }

  func testSnapshotCursorCanResumeImmediatelyAfterDisconnect() async throws {
    let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000023")!
    let store = DaemonReplayStore(capacity: 8)
    let graph = LoopGraph(project: ProjectRef(path: "/work/snapshot", name: "snapshot"))
    _ = store.append(clientID: clientID, event: .errorOccurred("before-snapshot"))
    let firstTransport = RecordingConnection()
    let firstChannel = DaemonConnectionChannel(
      connection: firstTransport,
      mode: .v2(version: 2),
      clientID: clientID,
      replayStore: store)

    try await firstChannel.sendConnectionSnapshot(.graphChanged(graph))
    let snapshot = try XCTUnwrap(
      try JSONDecoder().decode(
        DaemonWireEnvelope.self,
        from: XCTUnwrap(firstTransport.frames.first)))
    let cursor = try XCTUnwrap(snapshot.sequence)
    try await firstChannel.close()

    let secondTransport = RecordingConnection()
    let secondChannel = DaemonConnectionChannel(
      connection: secondTransport,
      mode: .v2(version: 2),
      clientID: clientID,
      replayStore: store)
    try await secondChannel.replay(after: cursor)

    XCTAssertTrue(secondTransport.frames.isEmpty)
  }

  func testSnapshotGapEqualToNonReplayableCountStillReplaysCanonicalEvent() async throws {
    let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000048")!
    let store = DaemonReplayStore(capacity: 8)
    let firstTransport = RecordingConnection()
    let firstChannel = DaemonConnectionChannel(
      connection: firstTransport,
      mode: .v2(version: 2),
      clientID: clientID,
      replayStore: store)
    await firstChannel.join(projectPath: "/work/snapshot-gap")
    try await firstChannel.sendConnectionSnapshot(.errorOccurred("snapshot"))
    let envelope = try XCTUnwrap(
      store.append(
        event: .errorOccurred("canonical"),
        projectPath: "/work/snapshot-gap")[clientID])
    try await firstChannel.sendEvent(envelope: envelope)
    try await firstChannel.close()

    let reconnectTransport = RecordingConnection()
    let reconnectChannel = DaemonConnectionChannel(
      connection: reconnectTransport,
      mode: .v2(version: 2),
      clientID: clientID,
      replayStore: store)
    try await reconnectChannel.replay(after: 0)

    let replayed = try reconnectTransport.frames.map {
      try JSONDecoder().decode(DaemonWireEnvelope.self, from: $0)
    }
    XCTAssertEqual(replayed.map(\.sequence), [2])
    try await reconnectChannel.close()
  }

  func testSecondSocketSnapshotDoesNotInvalidateFirstSocketResumeCursor() async throws {
    let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000046")!
    let store = DaemonReplayStore(capacity: 8)
    let firstTransport = RecordingConnection()
    let firstChannel = DaemonConnectionChannel(
      connection: firstTransport,
      mode: .v2(version: 2),
      clientID: clientID,
      replayStore: store)
    try await firstChannel.sendConnectionSnapshot(.errorOccurred("first-snapshot"))
    let firstSnapshot = try JSONDecoder().decode(
      DaemonWireEnvelope.self,
      from: XCTUnwrap(firstTransport.frames.first))
    let firstCursor = try XCTUnwrap(firstSnapshot.sequence)

    let secondChannel = DaemonConnectionChannel(
      connection: RecordingConnection(),
      mode: .v2(version: 2),
      clientID: clientID,
      replayStore: store)
    try await secondChannel.sendConnectionSnapshot(.errorOccurred("second-snapshot"))
    try await firstChannel.sendEvent(.errorOccurred("canonical-after-snapshots"))
    try await firstChannel.close()
    try await secondChannel.close()

    let reconnectTransport = RecordingConnection()
    let reconnectChannel = DaemonConnectionChannel(
      connection: reconnectTransport,
      mode: .v2(version: 2),
      clientID: clientID,
      replayStore: store)
    try await reconnectChannel.replay(after: firstCursor)

    let replayed = try reconnectTransport.frames.map {
      try JSONDecoder().decode(DaemonWireEnvelope.self, from: $0)
    }
    XCTAssertEqual(replayed.map(\.sequence), [3])
    guard case .errorOccurred("canonical-after-snapshots") = replayed.first?.event else {
      return XCTFail("expected the canonical event after both snapshots")
    }
  }

  func testMultiSocketSubscriptionsUnionCanonicalReplayMembership() async throws {
    let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000047")!
    let firstPath = "/work/subscription-first"
    let secondPath = "/work/subscription-second"
    let store = DaemonReplayStore(capacity: 8)
    let firstTransport = RecordingConnection()
    let firstChannel = DaemonConnectionChannel(
      connection: firstTransport,
      mode: .v2(version: 2),
      clientID: clientID,
      subscription: DaemonWireSubscription(projectPaths: [firstPath]),
      replayStore: store)
    await firstChannel.join(projectPath: firstPath)

    let secondChannel = DaemonConnectionChannel(
      connection: RecordingConnection(),
      mode: .v2(version: 2),
      clientID: clientID,
      subscription: DaemonWireSubscription(projectPaths: [secondPath]),
      replayStore: store)
    await secondChannel.join(projectPath: secondPath)

    let graph = LoopGraph(project: ProjectRef(path: firstPath, name: "first"))
    let envelope = try XCTUnwrap(
      store.append(event: .graphChanged(graph), projectPath: firstPath)[clientID])
    try await firstChannel.sendEvent(envelope: envelope)
    try await firstChannel.close()

    let reconnectTransport = RecordingConnection()
    let reconnectChannel = DaemonConnectionChannel(
      connection: reconnectTransport,
      mode: .v2(version: 2),
      clientID: clientID,
      subscription: DaemonWireSubscription(projectPaths: [firstPath]),
      replayStore: store)
    try await reconnectChannel.replay(after: 0)

    let replayed = try reconnectTransport.frames.map {
      try JSONDecoder().decode(DaemonWireEnvelope.self, from: $0)
    }
    XCTAssertEqual(replayed.map(\.sequence), [1])
    guard case .graphChanged(let replayedGraph) = replayed.first?.event else {
      return XCTFail("expected the first socket's subscribed event")
    }
    XCTAssertEqual(replayedGraph.project.path, firstPath)
    try await secondChannel.close()
    try await reconnectChannel.close()
  }

  func testMalformedV2RequestKeepsSafelyExtractableRequestID() throws {
    let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
    var malformed = DaemonWireEnvelope.request(id: requestID, command: .listRecentProjects)
    malformed.event = .errorOccurred("unexpected")
    let data = try JSONEncoder().encode(malformed)

    XCTAssertThrowsError(try DaemonWireProtocol.decodeClientFrame(data))
    XCTAssertEqual(DaemonWireProtocol.requestIDIfPresent(in: data), requestID)
  }

  func testWrongKindEnvelopeDoesNotBorrowItsRequestID() throws {
    let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    let data = try JSONEncoder().encode(
      DaemonWireEnvelope.response(id: requestID, event: .errorOccurred("response")))

    XCTAssertNil(DaemonWireProtocol.requestIDIfPresent(in: data))
  }

  func testUnmarkedInvalidInitialFrameUsesV1ErrorShape() throws {
    let invalid = Data(#"{"notACommand":{}}"#.utf8)
    let errorFrame = try DaemonWireProtocol.initialErrorFrame(
      for: invalid, message: "invalid v1 command")

    XCTAssertFalse(DaemonWireProtocol.isV2ShapedFrame(invalid))
    XCTAssertEqual(
      try JSONDecoder().decode(DaemonEvent.self, from: errorFrame),
      .errorOccurred("invalid v1 command"))
  }

  func testMarkedInvalidInitialFrameUsesV2ErrorShape() throws {
    let invalid = Data(#"{"version":2,"kind":"response"}"#.utf8)
    let errorFrame = try DaemonWireProtocol.initialErrorFrame(
      for: invalid, message: "invalid v2 envelope")
    let decoded = try JSONDecoder().decode(DaemonWireEnvelope.self, from: errorFrame)

    XCTAssertTrue(DaemonWireProtocol.isV2ShapedFrame(invalid))
    XCTAssertEqual(decoded.kind, .error)
    XCTAssertEqual(decoded.error?.code, DaemonWireErrorCode.malformedEnvelope.rawValue)
    XCTAssertEqual(decoded.error?.message, "invalid v2 envelope")
  }

  func testUnsupportedInitialVersionUsesUnsupportedVersionErrorShape() throws {
    let invalid = Data(#"{"version":3,"kind":"hello"}"#.utf8)
    let errorFrame = try DaemonWireProtocol.initialErrorFrame(
      for: invalid, message: "unsupported version")
    let decoded = try JSONDecoder().decode(DaemonWireEnvelope.self, from: errorFrame)

    XCTAssertEqual(decoded.kind, .error)
    XCTAssertEqual(decoded.error?.code, DaemonWireErrorCode.unsupportedVersion.rawValue)
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
