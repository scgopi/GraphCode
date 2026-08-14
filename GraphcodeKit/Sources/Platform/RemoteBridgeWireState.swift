/// The file format exchanged with the POSIX one-shot shim.
///
/// `RemoteBridgeState` is the frozen Swift-facing contract. This wire record is
/// deliberately separate: it carries the transport host/protocol and uses Unix
/// epoch seconds so a Python process does not need to know Foundation's date
/// encoding. The record is also the boundary where the stricter security checks
/// for a remotely readable state file live.
import Foundation

public struct RemoteBridgePreviousWireState: Codable, Equatable, Sendable {
  public var generation: UInt64
  public var capability: String
  public var expiresAt: Double

  public init(generation: UInt64, capability: String, expiresAt: Double) {
    self.generation = generation
    self.capability = capability
    self.expiresAt = expiresAt
  }
}
public struct RemoteBridgeWireState: Codable, Equatable, Sendable {
  public static let currentProtocolVersion = 1
  public static let loopbackHost = "127.0.0.1"

  public var schemaVersion: Int
  public var protocolVersion: Int
  public var daemonInstanceID: UUID
  public var generation: UInt64
  public var host: String
  public var port: UInt16
  public var capability: String
  public var issuedAt: Double
  public var expiresAt: Double
  public var previous: RemoteBridgePreviousWireState?

  public init(
    schemaVersion: Int = 1,
    protocolVersion: Int = RemoteBridgeWireState.currentProtocolVersion,
    daemonInstanceID: UUID,
    generation: UInt64,
    host: String = RemoteBridgeWireState.loopbackHost,
    port: UInt16,
    capability: String,
    issuedAt: Double,
    expiresAt: Double,
    previous: RemoteBridgePreviousWireState? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.protocolVersion = protocolVersion
    self.daemonInstanceID = daemonInstanceID
    self.generation = generation
    self.host = host
    self.port = port
    self.capability = capability
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.previous = previous
  }

  public init(
    remoteBridgeState state: RemoteBridgeState,
    previous: RemoteBridgePreviousWireState? = nil
  ) {
    self.init(
      daemonInstanceID: state.instanceID,
      generation: state.generation,
      port: state.remotePort,
      capability: state.capability,
      issuedAt: state.issuedAt.timeIntervalSince1970,
      expiresAt: state.expiresAt.timeIntervalSince1970,
      previous: previous)
  }

  @discardableResult
  public func validated(now: Double? = nil) throws -> Self {
    guard schemaVersion == 1 else {
      throw ValidationError.unsupportedSchema(schemaVersion)
    }
    guard protocolVersion == Self.currentProtocolVersion else {
      throw ValidationError.unsupportedProtocol(protocolVersion)
    }
    guard generation > 0 else { throw ValidationError.invalidGeneration }
    guard host == Self.loopbackHost else { throw ValidationError.invalidHost }
    guard port > 0 else { throw ValidationError.invalidPort }
    guard Self.isCapability(capability) else { throw ValidationError.invalidCapability }
    guard issuedAt.isFinite, expiresAt.isFinite, expiresAt > issuedAt else {
      throw ValidationError.invalidExpiry
    }
    if let now {
      guard now.isFinite else { throw ValidationError.invalidExpiry }
      guard expiresAt > now else { throw ValidationError.expired }
    }
    if let previous {
      guard previous.generation > 0,
        previous.generation < generation,
        Self.isCapability(previous.capability),
        previous.expiresAt.isFinite,
        previous.expiresAt > issuedAt,
        previous.expiresAt <= expiresAt
      else {
        throw ValidationError.invalidPrevious
      }
    }
    return self
  }

  public func remoteBridgeState() -> RemoteBridgeState {
    RemoteBridgeState(
      instanceID: daemonInstanceID,
      generation: generation,
      remotePort: port,
      capability: capability,
      issuedAt: Date(timeIntervalSince1970: issuedAt),
      expiresAt: Date(timeIntervalSince1970: expiresAt))
  }

  public static func isCapability(_ value: String) -> Bool {
    guard value.utf8.count == 64,
      value.unicodeScalars.allSatisfy({ $0.value < 128 })
    else { return false }
    return value.utf8.allSatisfy {
      (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
    }
  }

  public enum ValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case unsupportedProtocol(Int)
    case invalidGeneration
    case invalidHost
    case invalidPort
    case invalidCapability
    case invalidExpiry
    case expired
    case invalidPrevious
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case protocolVersion = "protocol_version"
    case daemonInstanceID = "daemon_instance_id"
    case generation
    case host
    case port
    case capability
    case issuedAt = "issued_at"
    case expiresAt = "expires_at"
    case previous
  }

  private enum PreviousCodingKeys: String, CodingKey {
    case generation
    case capability
    case expiresAt = "expires_at"
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(protocolVersion, forKey: .protocolVersion)
    try container.encode(daemonInstanceID.uuidString, forKey: .daemonInstanceID)
    try container.encode(generation, forKey: .generation)
    try container.encode(host, forKey: .host)
    try container.encode(port, forKey: .port)
    try container.encode(capability, forKey: .capability)
    try container.encode(issuedAt, forKey: .issuedAt)
    try container.encode(expiresAt, forKey: .expiresAt)
    if let previous {
      var nested = container.nestedContainer(keyedBy: PreviousCodingKeys.self, forKey: .previous)
      try nested.encode(previous.generation, forKey: .generation)
      try nested.encode(previous.capability, forKey: .capability)
      try nested.encode(previous.expiresAt, forKey: .expiresAt)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawID = try container.decode(String.self, forKey: .daemonInstanceID)
    guard let daemonInstanceID = UUID(uuidString: rawID) else {
      throw ValidationError.invalidGeneration
    }
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    self.daemonInstanceID = daemonInstanceID
    generation = try container.decode(UInt64.self, forKey: .generation)
    host = try container.decode(String.self, forKey: .host)
    port = try container.decode(UInt16.self, forKey: .port)
    capability = try container.decode(String.self, forKey: .capability)
    issuedAt = try container.decode(Double.self, forKey: .issuedAt)
    expiresAt = try container.decode(Double.self, forKey: .expiresAt)
    if container.contains(.previous) {
      let nested = try container.nestedContainer(
        keyedBy: PreviousCodingKeys.self, forKey: .previous)
      previous = RemoteBridgePreviousWireState(
        generation: try nested.decode(UInt64.self, forKey: .generation),
        capability: try nested.decode(String.self, forKey: .capability),
        expiresAt: try nested.decode(Double.self, forKey: .expiresAt))
    } else {
      previous = nil
    }
  }
}
