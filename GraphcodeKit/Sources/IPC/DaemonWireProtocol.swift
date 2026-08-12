import Foundation

public struct DaemonWireError: Codable, Equatable, Sendable {
  public var code: String
  public var message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
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
  public var requestID: UUID?
  public var sequence: UInt64?
  public var command: DaemonCommand?
  public var event: DaemonEvent?
  public var error: DaemonWireError?

  public init(
    version: Int,
    kind: Kind,
    supportedVersions: [Int]? = nil,
    requestID: UUID? = nil,
    sequence: UInt64? = nil,
    command: DaemonCommand? = nil,
    event: DaemonEvent? = nil,
    error: DaemonWireError? = nil
  ) {
    self.version = version
    self.kind = kind
    self.supportedVersions = supportedVersions
    self.requestID = requestID
    self.sequence = sequence
    self.command = command
    self.event = event
    self.error = error
  }

  public static func hello(supportedVersions: [Int]) -> Self {
    Self(
      version: DaemonWireProtocol.currentVersion,
      kind: .hello,
      supportedVersions: supportedVersions)
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
      guard requestID == nil, sequence == nil, command == nil, event == nil, error == nil else {
        throw ValidationError.unexpectedField
      }
    case .request:
      guard requestID != nil else { throw ValidationError.missingField("requestID") }
      guard command != nil else { throw ValidationError.missingField("command") }
      guard supportedVersions == nil, sequence == nil, event == nil, error == nil else {
        throw ValidationError.unexpectedField
      }
    case .response:
      guard requestID != nil else { throw ValidationError.missingField("requestID") }
      guard event != nil else { throw ValidationError.missingField("event") }
      guard supportedVersions == nil, sequence == nil, command == nil, error == nil else {
        throw ValidationError.unexpectedField
      }
    case .event:
      guard sequence != nil else { throw ValidationError.missingField("sequence") }
      guard event != nil else { throw ValidationError.missingField("event") }
      guard supportedVersions == nil, requestID == nil, command == nil, error == nil else {
        throw ValidationError.unexpectedField
      }
    case .error:
      guard error != nil else { throw ValidationError.missingField("error") }
      guard supportedVersions == nil, sequence == nil, command == nil, event == nil else {
        throw ValidationError.unexpectedField
      }
    }

    return self
  }

  public enum ValidationError: Error, Equatable {
    case unsupportedVersion(Int)
    case missingField(String)
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
    if let dictionary = object as? [String: Any],
      dictionary["version"] != nil || dictionary["kind"] != nil
    {
      let envelope = try JSONDecoder().decode(DaemonWireEnvelope.self, from: data)
      return .v2(try envelope.validated())
    }
    return .v1(try JSONDecoder().decode(DaemonCommand.self, from: data))
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

  public enum NegotiationError: Error, Equatable {
    case expectedHello
    case noSupportedVersion
  }
}
public enum DaemonFrameHeader {
  public static let byteCount = 4
  public static let maxPayloadBytes: UInt32 = 1_048_576

  public static func encodeLength(_ length: Int) throws -> Data {
    guard length >= 0, let value = UInt32(exactly: length), value <= maxPayloadBytes else {
      throw HeaderError.payloadTooLarge
    }
    return Data([
      UInt8((value >> 24) & 0xff),
      UInt8((value >> 16) & 0xff),
      UInt8((value >> 8) & 0xff),
      UInt8(value & 0xff),
    ])
  }

  public static func decodeLength(_ bytes: [UInt8]) throws -> Int {
    guard bytes.count == byteCount else { throw HeaderError.invalidHeader }
    let value =
      (UInt32(bytes[0]) << 24)
      | (UInt32(bytes[1]) << 16)
      | (UInt32(bytes[2]) << 8)
      | UInt32(bytes[3])
    guard value <= maxPayloadBytes else { throw HeaderError.payloadTooLarge }
    return Int(value)
  }

  public enum HeaderError: Error, Equatable {
    case invalidHeader
    case payloadTooLarge
  }
}
