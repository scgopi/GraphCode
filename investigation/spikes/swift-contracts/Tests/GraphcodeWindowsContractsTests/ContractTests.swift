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
