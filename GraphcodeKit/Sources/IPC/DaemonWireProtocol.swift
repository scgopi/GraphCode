import Foundation

public struct DaemonWireError: Codable, Equatable, Sendable {
  public var code: String
  public var message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

public struct DaemonWireSubscription: Codable, Equatable, Sendable {
  /// `nil` means every project visible to the connection. A non-empty list is an
  /// explicit allow-list, so a reconnect cannot accidentally resume an unrelated
  /// project's events.
  public var projectPaths: [String]?

  public init(projectPaths: [String]? = nil) {
    self.projectPaths = projectPaths
  }
}

public struct DaemonWireEnvelope: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case hello
    case request
    case response
    case event
    case error
  }

  public var version: Int
  public var kind: Kind
  public var supportedVersions: [Int]?
  public var selectedVersion: Int?
  public var clientID: UUID?
  public var resumeFrom: UInt64?
  public var subscription: DaemonWireSubscription?
  public var requestID: UUID?
  public var sequence: UInt64?
  public var command: DaemonCommand?
  public var event: DaemonEvent?
  public var error: DaemonWireError?
  public var success: Bool?

  public init(
    version: Int,
    kind: Kind,
    supportedVersions: [Int]? = nil,
    selectedVersion: Int? = nil,
    clientID: UUID? = nil,
    resumeFrom: UInt64? = nil,
    subscription: DaemonWireSubscription? = nil,
    requestID: UUID? = nil,
    sequence: UInt64? = nil,
    command: DaemonCommand? = nil,
    event: DaemonEvent? = nil,
    error: DaemonWireError? = nil,
    success: Bool? = nil
  ) {
    self.version = version
    self.kind = kind
    self.supportedVersions = supportedVersions
    self.selectedVersion = selectedVersion
    self.clientID = clientID
    self.resumeFrom = resumeFrom
    self.subscription = subscription
    self.requestID = requestID
    self.sequence = sequence
    self.command = command
    self.event = event
    self.error = error
    self.success = success
  }

  public static func hello(
    supportedVersions: [Int],
    clientID: UUID? = nil,
    resumeFrom: UInt64? = nil,
    subscription: DaemonWireSubscription? = nil
  ) -> Self {
    Self(
      version: DaemonWireProtocol.currentVersion,
      kind: .hello,
      supportedVersions: supportedVersions,
      clientID: clientID,
      resumeFrom: resumeFrom,
      subscription: subscription)
  }

  public static func helloResponse(selectedVersion: Int) -> Self {
    Self(
      version: DaemonWireProtocol.currentVersion,
      kind: .hello,
      supportedVersions: DaemonWireProtocol.supportedVersions,
      selectedVersion: selectedVersion)
  }

  public static func request(id: UUID, command: DaemonCommand) -> Self {
    Self(
      version: DaemonWireProtocol.currentVersion,
      kind: .request,
      requestID: id,
      command: command)
  }

  public static func response(id: UUID, event: DaemonEvent) -> Self {
    Self(
      version: DaemonWireProtocol.currentVersion,
      kind: .response,
      requestID: id,
      event: event)
  }

  public static func success(id: UUID) -> Self {
    Self(
      version: DaemonWireProtocol.currentVersion,
      kind: .response,
      requestID: id,
      success: true)
  }

  public static func event(sequence: UInt64, event: DaemonEvent) -> Self {
    Self(
      version: DaemonWireProtocol.currentVersion,
      kind: .event,
      sequence: sequence,
      event: event)
  }

  public static func error(id: UUID?, code: String, message: String) -> Self {
    Self(
      version: DaemonWireProtocol.currentVersion,
      kind: .error,
      requestID: id,
      error: DaemonWireError(code: code, message: message))
  }

  @discardableResult
  public func validated() throws -> Self {
    guard version == DaemonWireProtocol.currentVersion else {
      throw ValidationError.unsupportedVersion(version)
    }

    switch kind {
    case .hello:
      guard let supportedVersions, !supportedVersions.isEmpty else {
        throw ValidationError.missingField("supportedVersions")
      }
      guard Set(supportedVersions).count == supportedVersions.count else {
        throw ValidationError.invalidField("supportedVersions")
      }
      if let selectedVersion {
        guard supportedVersions.contains(selectedVersion),
          DaemonWireProtocol.supportedVersions.contains(selectedVersion)
        else {
          throw ValidationError.invalidField("selectedVersion")
        }
      }
      if let subscription, let paths = subscription.projectPaths {
        guard paths.allSatisfy({ !$0.isEmpty }) else {
          throw ValidationError.invalidField("subscription")
        }
      }
      guard requestID == nil, sequence == nil, command == nil, event == nil, error == nil,
        success == nil
      else {
        throw ValidationError.unexpectedField
      }
    case .request:
      guard requestID != nil else { throw ValidationError.missingField("requestID") }
      guard command != nil else { throw ValidationError.missingField("command") }
      guard supportedVersions == nil, selectedVersion == nil, clientID == nil, resumeFrom == nil,
        subscription == nil, sequence == nil, event == nil, error == nil, success == nil
      else {
        throw ValidationError.unexpectedField
      }
    case .response:
      guard requestID != nil else { throw ValidationError.missingField("requestID") }
      guard event != nil || success == true else { throw ValidationError.missingField("event") }
      guard success != false else { throw ValidationError.invalidField("success") }
      guard supportedVersions == nil, selectedVersion == nil, clientID == nil, resumeFrom == nil,
        subscription == nil, sequence == nil, command == nil, error == nil
      else {
        throw ValidationError.unexpectedField
      }
    case .event:
      guard sequence != nil else { throw ValidationError.missingField("sequence") }
      guard event != nil else { throw ValidationError.missingField("event") }
      guard supportedVersions == nil, selectedVersion == nil, clientID == nil, resumeFrom == nil,
        subscription == nil, requestID == nil, command == nil, error == nil, success == nil
      else {
        throw ValidationError.unexpectedField
      }
    case .error:
      guard error != nil else { throw ValidationError.missingField("error") }
      guard let error, !error.code.isEmpty, !error.message.isEmpty else {
        throw ValidationError.invalidField("error")
      }
      guard supportedVersions == nil, selectedVersion == nil, clientID == nil, resumeFrom == nil,
        subscription == nil, sequence == nil, command == nil, event == nil, success == nil
      else {
        throw ValidationError.unexpectedField
      }
    }

    return self
  }

  public enum ValidationError: Error, Equatable {
    case unsupportedVersion(Int)
    case missingField(String)
    case invalidField(String)
    case payloadTooLarge
    case unexpectedField
  }
}
public enum DaemonClientFrame: Equatable, Sendable {
  case v1(DaemonCommand)
  case v2(DaemonWireEnvelope)
}
public enum DaemonWireProtocol {
  public static let supportedVersions = [1, 2]
  public static let currentVersion = 2

  public static func decodeClientFrame(_ data: Data) throws -> DaemonClientFrame {
    let object = try JSONSerialization.jsonObject(with: data)
    if isV2ShapedFrame(object) {
      guard data.count <= FramedMessageIO.v2MaxPayloadBytes else {
        throw DaemonWireEnvelope.ValidationError.payloadTooLarge
      }
      let envelope = try JSONDecoder().decode(DaemonWireEnvelope.self, from: data)
      return .v2(try envelope.validated())
    }
    return .v1(try JSONDecoder().decode(DaemonCommand.self, from: data))
  }

  public static func isV2ShapedFrame(_ data: Data) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
    return isV2ShapedFrame(object)
  }

  public static func initialErrorFrame(for data: Data, message: String) throws -> Data {
    if isV2ShapedFrame(data) {
      return try JSONEncoder().encode(
        DaemonWireEnvelope.error(
          id: nil,
          code: initialV2ErrorCode(for: data),
          message: message))
    }
    return try JSONEncoder().encode(DaemonEvent.errorOccurred(message))
  }

  /// Extracts a request correlation ID before full envelope validation. This is
  /// intentionally conservative: only a version-2 request-shaped JSON object
  /// with a valid UUID is eligible for correlation.
  public static func requestIDIfPresent(in data: Data) -> UUID? {
    guard let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any],
      let version = dictionary["version"] as? Int,
      version == currentVersion,
      dictionary["kind"] as? String == DaemonWireEnvelope.Kind.request.rawValue,
      let rawID = dictionary["requestID"] as? String
    else {
      return nil
    }
    return UUID(uuidString: rawID)
  }

  public static func negotiatedVersion(for hello: DaemonWireEnvelope) throws -> Int {
    let validated = try hello.validated()
    guard validated.kind == .hello, let offered = validated.supportedVersions else {
      throw NegotiationError.expectedHello
    }
    guard let selected = Set(offered).intersection(supportedVersions).max() else {
      throw NegotiationError.noSupportedVersion
    }
    return selected
  }

  public static func negotiatedHelloResponse(for hello: DaemonWireEnvelope) throws
    -> DaemonWireEnvelope
  {
    DaemonWireEnvelope.helloResponse(
      selectedVersion: try negotiatedVersion(for: hello))
  }

  public enum NegotiationError: Error, Equatable {
    case expectedHello
    case noSupportedVersion
  }

  private static func isV2ShapedFrame(_ object: Any) -> Bool {
    guard let dictionary = object as? [String: Any] else { return false }
    return dictionary["version"] != nil || dictionary["kind"] != nil
  }

  private static func initialV2ErrorCode(for data: Data) -> String {
    guard let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any],
      let rawVersion = dictionary["version"],
      let version = rawVersion as? Int
    else {
      return DaemonWireErrorCode.malformedEnvelope.rawValue
    }
    return version == currentVersion
      ? DaemonWireErrorCode.malformedEnvelope.rawValue
      : DaemonWireErrorCode.unsupportedVersion.rawValue
  }
}

/// A bounded, monotonic event history used to replay a v2 subscription after a
/// reconnect. The daemon keeps this per logical client rather than per socket, so
/// reconnecting does not reset the sequence seen by the client.
public struct DaemonReplayBuffer: Equatable, Sendable {
  public enum ReplayError: Error, Equatable {
    case invalidCapacity
    case nonMonotonicSequence
    case replayUnavailable
    case cursorOutsideWindow
  }

  public let capacity: Int
  private var entries: [DaemonWireEnvelope] = []

  public init(capacity: Int = 128) {
    self.capacity = max(0, capacity)
  }

  public var firstSequence: UInt64? { entries.first?.sequence }
  public var latestSequence: UInt64? { entries.last?.sequence }

  public mutating func append(sequence: UInt64, event: DaemonEvent) {
    guard capacity > 0 else { return }
    if let latest = latestSequence, sequence <= latest {
      return
    }
    entries.append(.event(sequence: sequence, event: event))
    if entries.count > capacity {
      entries.removeFirst(entries.count - capacity)
    }
  }

  public func replay(
    after cursor: UInt64,
    skipping nonReplayableSequences: Set<UInt64> = []
  ) throws -> [DaemonWireEnvelope] {
    try replay(
      after: cursor,
      skippingRanges: Self.sequenceRanges(from: nonReplayableSequences))
  }

  public func replay(
    after cursor: UInt64,
    skippingRanges: [ClosedRange<UInt64>]
  ) throws -> [DaemonWireEnvelope] {
    guard capacity > 0 else {
      throw ReplayError.replayUnavailable
    }
    guard let first = firstSequence, let latest = latestSequence else {
      throw ReplayError.replayUnavailable
    }
    if cursor == latest { return [] }
    if cursor > latest { throw ReplayError.cursorOutsideWindow }
    if cursor < first {
      let missingCount = first - (cursor + 1)
      if missingCount > 0 {
        guard Self.rangesCover(
          lowerBound: cursor + 1,
          upperBound: first - 1,
          ranges: skippingRanges)
        else {
          throw ReplayError.cursorOutsideWindow
        }
      }
    }
    return entries.filter { ($0.sequence ?? 0) > cursor }
  }

  public static func sequenceRanges(from sequences: Set<UInt64>) -> [ClosedRange<UInt64>] {
    let sorted = sequences.sorted()
    guard var start = sorted.first else { return [] }
    var end = start
    var ranges: [ClosedRange<UInt64>] = []
    for sequence in sorted.dropFirst() {
      if end != UInt64.max, sequence == end + 1 {
        end = sequence
      } else {
        ranges.append(start...end)
        start = sequence
        end = sequence
      }
    }
    ranges.append(start...end)
    return ranges
  }

  public static func rangesCover(
    lowerBound: UInt64,
    upperBound: UInt64,
    ranges: [ClosedRange<UInt64>]
  ) -> Bool {
    guard lowerBound <= upperBound else { return true }
    var next = lowerBound
    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      guard range.upperBound >= next else { continue }
      guard range.lowerBound <= next else { return false }
      if range.upperBound >= upperBound { return true }
      guard range.upperBound < UInt64.max else { return true }
      next = range.upperBound + 1
    }
    return false
  }
}
public enum DaemonFrameHeader {
  public static let byteCount = 4
  /// The v2 envelope cap. Legacy frames use the larger bounded reader ceiling below.
  public static let maxPayloadBytes: UInt32 = 1_048_576
  /// Allocation ceiling for deployed v1 frames whose payloads exceed the v2 cap.
  public static let legacySafetyCeilingBytes: UInt32 = 2 * 1_048_576
  /// The four-byte header itself remains a full UInt32 length field.
  public static let maxUInt32PayloadBytes = UInt32.max

  public static func encodeLength(
    _ length: Int, maxPayloadBytes: UInt32? = nil
  ) throws -> Data {
    guard length >= 0, let value = UInt32(exactly: length),
      maxPayloadBytes.map({ value <= $0 }) ?? true
    else {
      throw HeaderError.payloadTooLarge
    }
    return Data([
      UInt8((value >> 24) & 0xff),
      UInt8((value >> 16) & 0xff),
      UInt8((value >> 8) & 0xff),
      UInt8(value & 0xff),
    ])
  }

  public static func decodeLength(
    _ bytes: [UInt8], maxPayloadBytes: UInt32? = nil
  ) throws -> Int {
    guard bytes.count == byteCount else { throw HeaderError.invalidHeader }
    let value =
      (UInt32(bytes[0]) << 24)
      | (UInt32(bytes[1]) << 16)
      | (UInt32(bytes[2]) << 8)
      | UInt32(bytes[3])
    guard maxPayloadBytes.map({ value <= $0 }) ?? true else {
      throw HeaderError.payloadTooLarge
    }
    return Int(value)
  }

  public enum HeaderError: Error, Equatable {
    case invalidHeader
    case payloadTooLarge
  }
}
