import Foundation

public protocol PlatformPaths: Sendable {
  var supportDirectory: URL { get }
  var binDirectory: URL { get }
  var hooksDirectory: URL { get }
  var sessionsDirectory: URL { get }

  func canonicalProjectPath(_ path: String) throws -> String
  func persistenceKey(forProjectPath path: String) -> String
}
public struct ProcessRequest: Equatable, Sendable {
  public var executable: URL
  public var arguments: [String]
  public var workingDirectory: URL?
  public var environment: [String: String]
  public var standardInput: Data?

  public init(
    executable: URL,
    arguments: [String] = [],
    workingDirectory: URL? = nil,
    environment: [String: String] = [:],
    standardInput: Data? = nil
  ) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.standardInput = standardInput
  }
}
public struct ProcessResult: Equatable, Sendable {
  public var exitCode: Int32
  public var standardOutput: Data
  public var standardError: Data

  public init(exitCode: Int32, standardOutput: Data, standardError: Data) {
    self.exitCode = exitCode
    self.standardOutput = standardOutput
    self.standardError = standardError
  }
}
public protocol ProcessRunner: Sendable {
  func run(_ request: ProcessRequest, timeout: Duration?) async throws -> ProcessResult
}
public enum ShellKind: String, Codable, Equatable, Sendable {
  case direct
  case commandPrompt
  case powerShell
  case posix
  case wsl
}
public struct ShellInvocation: Equatable, Sendable {
  public var kind: ShellKind
  public var request: ProcessRequest

  public init(kind: ShellKind, request: ProcessRequest) {
    self.kind = kind
    self.request = request
  }
}
public protocol ShellStrategy: Sendable {
  func invocation(
    executable: URL,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String]
  ) throws -> ShellInvocation
}
public protocol SessionService: Sendable {
  func ensureSession(_ node: LoopNode, projectPath: String?) async throws
  func terminateSession(_ node: LoopNode, projectPath: String?) async throws
  func send(_ text: String, to node: LoopNode, projectPath: String?) async throws -> Bool
  func presence(of node: LoopNode, projectPath: String?) async throws -> PresenceReading
  func usage(of node: LoopNode, projectPath: String?) async throws -> UsageSample?
  func activity(of node: LoopNode, projectPath: String?) async throws -> String?
}
public enum StartupStatus: Equatable, Sendable {
  case notInstalled
  case stopped
  case running
}
public protocol StartupManager: Sendable {
  func installAndStart() async throws
  func stopAndUninstall() async throws
  func status() async throws -> StartupStatus
}
public struct RemoteBridgeState: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var instanceID: UUID
  public var generation: UInt64
  public var remotePort: UInt16
  public var capability: String
  public var issuedAt: Date
  public var expiresAt: Date

  public init(
    schemaVersion: Int = RemoteBridgeState.currentSchemaVersion,
    instanceID: UUID,
    generation: UInt64,
    remotePort: UInt16,
    capability: String,
    issuedAt: Date,
    expiresAt: Date
  ) {
    self.schemaVersion = schemaVersion
    self.instanceID = instanceID
    self.generation = generation
    self.remotePort = remotePort
    self.capability = capability
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
  }

  @discardableResult
  public func validated() throws -> Self {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw ValidationError.unsupportedSchema(schemaVersion)
    }
    guard generation > 0 else { throw ValidationError.invalidGeneration }
    guard remotePort > 0 else { throw ValidationError.invalidPort }
    guard capability.utf8.count >= 32 else { throw ValidationError.capabilityTooShort }
    guard expiresAt > issuedAt else { throw ValidationError.invalidExpiry }
    return self
  }

  public enum ValidationError: Error, Equatable {
    case unsupportedSchema(Int)
    case invalidGeneration
    case invalidPort
    case capabilityTooShort
    case invalidExpiry
  }
}
public protocol RemoteBridge: Sendable {
  func ensureForwarding(authority: String) async throws -> RemoteBridgeState
  func stopForwarding(authority: String) async throws
}
