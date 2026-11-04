import Foundation
import GraphcodeKit

public enum CardTransferOperation: String, Sendable {
  case export
  case `import`
}

public enum CardTransferScope: Equatable, Sendable {
  case root
  case composite(UUID)

  public var argument: String {
    switch self {
    case .root: return "root"
    case .composite(let id): return id.uuidString
    }
  }
}

public enum CardTransferStatus: String, Sendable {
  case succeeded
  case rejected
  case oversized
  case unavailable
  case failed
  case outcome_unknown

  public var exitCode: Int32 {
    switch self {
    case .succeeded: return 0
    case .unavailable: return 69
    case .outcome_unknown: return 75
    case .rejected, .oversized, .failed: return 1
    }
  }
}

public struct CardTransferFailure: Error, LocalizedError, Sendable {
  public let status: CardTransferStatus
  public let message: String

  public init(status: CardTransferStatus, message: String) {
    self.status = status
    self.message = message
  }

  public var errorDescription: String? { message }

  public static func exchange(_ error: Error, mutationDispatched: Bool) -> Self {
    if let failure = error as? Self,
      failure.status == .rejected || failure.status == .oversized
    {
      return failure
    }
    return Self(
      status: mutationDispatched ? .outcome_unknown : .failed,
      message: mutationDispatched
        ? "Import outcome is unknown. Check the graph; do not retry automatically. \(error.localizedDescription)"
        : "The daemon did not confirm the requested snapshot. \(error.localizedDescription)")
  }
}

public struct CardTransferRequest: Sendable {
  public static let optIn = "--windows-card-transfer"

  public let operation: CardTransferOperation
  public let invocation: UUID
  public let projectPath: String
  public let nodeID: UUID
  public let scope: CardTransferScope
  public let zipPath: String
  public let replaceExisting: Bool

  public static func parse(_ arguments: [String]) throws -> Self? {
    guard arguments.first == optIn else { return nil }
    guard arguments.count >= 2, let operation = CardTransferOperation(rawValue: arguments[1])
    else { throw refused("Expected export or import after \(optIn).") }
    let pathFlag = operation == .export ? "--output" : "--input"
    let valueFlags: Set<String> = [
      "--invocation", "--project", "--node", "--containing-composite", pathFlag,
    ]
    var values: [String: String] = [:]
    var replaceExisting = false
    var index = 2
    while index < arguments.count {
      let flag = arguments[index]
      if flag == "--replace-existing", operation == .export, !replaceExisting {
        replaceExisting = true
        index += 1
        continue
      }
      guard valueFlags.contains(flag), values[flag] == nil, index + 1 < arguments.count
      else { throw refused("Unknown, duplicated or incomplete transfer option: \(flag)") }
      let value = arguments[index + 1]
      guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !value.utf8.contains(0), !valueFlags.contains(value), value != "--replace-existing"
      else { throw refused("Missing or invalid value for \(flag).") }
      values[flag] = value
      index += 2
    }
    guard let invocation = values["--invocation"].flatMap(UUID.init(uuidString:)),
      let node = values["--node"].flatMap(UUID.init(uuidString:)),
      let project = values["--project"], let scopeText = values["--containing-composite"],
      let path = values[pathFlag]
    else { throw refused("Transfer requires invocation, project, node, containing-composite and ZIP path.") }
    let scope: CardTransferScope
    if scopeText == "root" {
      scope = .root
    } else if let id = UUID(uuidString: scopeText) {
      scope = .composite(id)
    } else {
      throw refused("Containing composite must be root or a UUID.")
    }
    guard CardTransferWindowsPath.isAbsolute(path), path.lowercased().hasSuffix(".zip") else {
      throw refused("The ZIP path must be an absolute Windows path ending in .zip.")
    }
    return Self(
      operation: operation, invocation: invocation, projectPath: project, nodeID: node,
      scope: scope, zipPath: path, replaceExisting: replaceExisting)
  }

  private static func refused(_ message: String) -> CardTransferFailure {
    CardTransferFailure(status: .rejected, message: message)
  }
}

public enum CardTransferWindowsPath {
  public static func isAbsolute(_ path: String) -> Bool {
    guard !path.utf8.contains(0) else { return false }
    var normalized = path.replacingOccurrences(of: "/", with: "\\")
    if normalized.range(of: "\\\\?\\UNC\\", options: [.anchored, .caseInsensitive]) != nil {
      normalized = "\\\\" + normalized.dropFirst(8)
    } else if normalized.hasPrefix("\\\\?\\") {
      normalized = String(normalized.dropFirst(4))
    }
    if normalized.hasPrefix("\\\\") {
      let parts = normalized.dropFirst(2).split(separator: "\\", omittingEmptySubsequences: false)
      return parts.count >= 2 && !parts[0].isEmpty && !parts[1].isEmpty
        && parts[0] != "." && parts[0] != "?" && !normalized.contains(":")
    }
    let characters = Array(normalized)
    return characters.count >= 3 && characters[0].isASCII && characters[0].isLetter
      && characters[1] == ":" && characters[2] == "\\"
      && !normalized.dropFirst(2).contains(":")
  }

  public static func extended(_ path: String) throws -> String {
    guard isAbsolute(path) else {
      throw CardTransferFailure(status: .rejected, message: "Expected an absolute drive or UNC filesystem path.")
    }
    let normalized = path.replacingOccurrences(of: "/", with: "\\")
    if normalized.hasPrefix("\\\\?\\") { return normalized }
    if normalized.hasPrefix("\\\\") {
      return "\\\\?\\UNC\\" + String(normalized.dropFirst(2))
    }
    return "\\\\?\\" + normalized
  }

  public static func wide(_ url: URL) throws -> [UInt16] {
    Array(try extended(url.path).utf16) + [0]
  }
}

public enum CardTransferLocalProject {
  public static func beforeRuntime<T>(_ path: String, perform: () throws -> T) throws -> T {
    guard path != LoopGraphScope.globalPath,
      RemoteProjectLocation.parse(projectPath: path) == nil,
      CardTransferWindowsPath.isAbsolute(path)
    else {
      throw CardTransferFailure(
        status: .rejected,
        message: "This card-transfer route supports local drive or UNC projects only; remote and overview transfers are not available.")
    }
    return try perform()
  }
}

public struct CardTransferTarget: Sendable {
  public let nodeID: UUID
  public let graph: LoopGraph
  public let containingComposite: UUID?

  public static func resolve(
    nodeID: UUID, expectedScope: CardTransferScope, in root: LoopGraph
  ) throws -> Self {
    var matches: [Self] = []
    func visit(_ graph: LoopGraph, owner: UUID?, depth: Int) throws {
      guard depth <= 64 else {
        throw CardTransferFailure(status: .rejected, message: "The graph nesting is too deep to transfer.")
      }
      if graph.nodes[id: nodeID] != nil {
        matches.append(Self(nodeID: nodeID, graph: graph, containingComposite: owner))
      }
      for node in graph.nodes {
        if let nested = node.subGraph {
          try visit(nested, owner: node.id, depth: depth + 1)
        }
      }
    }
    try visit(root, owner: nil, depth: 0)
    guard matches.count == 1, let target = matches.first else {
      throw CardTransferFailure(
        status: .rejected, message: "The transfer card is missing or its identity is ambiguous.")
    }
    let actualScope = target.containingComposite.map(CardTransferScope.composite) ?? .root
    guard actualScope == expectedScope else {
      throw CardTransferFailure(
        status: .rejected, message: "The card moved to another graph. Open its menu again.")
    }
    return target
  }

  public func importCommand(_ request: GraphImportRequest) throws -> GraphCommand {
    guard request.asChildOf == nodeID else {
      throw CardTransferFailure(status: .rejected, message: "The import parent does not match the selected card.")
    }
    let command = GraphCommand.importNodes(request)
    return containingComposite.map { .subGraphCommand(nodeID: $0, command: command) } ?? command
  }
}

public enum CardTransferWire {
  public static func request(id: UUID, command: DaemonCommand) throws -> Data {
    let data = try JSONEncoder().encode(DaemonWireEnvelope.request(id: id, command: command))
    guard data.count <= FramedMessageIO.v2MaxPayloadBytes else {
      throw CardTransferFailure(status: .oversized, message: "The transfer request exceeds the v2 payload limit.")
    }
    return data
  }

  public static func hello() throws -> Data {
    try JSONEncoder().encode(DaemonWireEnvelope.hello(supportedVersions: [2], clientID: UUID()))
  }

  public static func validateHello(_ data: Data) throws {
    let envelope = try decode(data)
    if envelope.kind == .error {
      throw CardTransferFailure(
        status: .rejected, message: envelope.error?.message ?? "The daemon refused protocol v2.")
    }
    guard envelope.kind == .hello, envelope.selectedVersion == 2 else {
      throw CardTransferFailure(status: .rejected, message: "Card transfer requires daemon protocol v2; no downgrade is allowed.")
    }
  }

  public static func graphReply(
    _ data: Data, requestID: UUID, projectPath: String
  ) throws -> LoopGraph? {
    let envelope = try decode(data)
    if envelope.kind == .event { return nil }
    if envelope.kind == .response || envelope.kind == .error,
      let other = envelope.requestID, other != requestID
    {
      return nil
    }
    guard envelope.requestID == requestID else {
      throw CardTransferFailure(status: .failed, message: "The daemon reply has no matching request identity.")
    }
    if envelope.kind == .error, let error = envelope.error {
      guard error.code == DaemonWireErrorCode.requestFailed.rawValue else {
        throw CardTransferFailure(
          status: .failed,
          message: "The daemon did not provide an authoritative mutation verdict (\(error.code)): \(error.message)")
      }
      throw CardTransferFailure(
        status: error.message.lowercased().contains("exceeds the v2 payload limit") ? .oversized : .rejected,
        message: error.message)
    }
    guard envelope.kind == .response, case .graphChanged(let graph)? = envelope.event,
      graph.project.path == projectPath
    else {
      throw CardTransferFailure(status: .failed, message: "The daemon did not return this project's correlated graph.")
    }
    return graph
  }

  private static func decode(_ data: Data) throws -> DaemonWireEnvelope {
    guard data.count <= FramedMessageIO.v2MaxPayloadBytes else {
      throw CardTransferFailure(status: .failed, message: "The daemon reply exceeds the v2 payload limit.")
    }
    do {
      return try JSONDecoder().decode(DaemonWireEnvelope.self, from: data).validated()
    } catch {
      throw CardTransferFailure(status: .failed, message: "Invalid daemon v2 reply: \(error.localizedDescription)")
    }
  }
}

public struct CardTransferPublication {
  public private(set) var hasArchiveReceipt = false
  public private(set) var committed = false

  public init() {}

  public mutating func writeAndCommit(
    writeArchive: () throws -> Void, acquireArchive: () throws -> Void,
    validateOwnership: () throws -> Void, commit: () throws -> Void
  ) throws {
    try writeArchive()
    try acquireArchive()
    hasArchiveReceipt = true
    try validateOwnership()
    try commit()
    committed = true
  }

  public func cleanup(removeOwnedEmptyDirectory: () throws -> Void) throws {
    guard committed else {
      throw CardTransferFailure(
        status: .failed, message: "Staging is retained because archive publication was not confirmed.")
    }
    try removeOwnedEmptyDirectory()
  }
}

public struct CardTransferFileIdentity: Equatable, Sendable {
  public let volume: UInt32
  public let index: UInt64

  public init(volume: UInt32, index: UInt64) {
    self.volume = volume
    self.index = index
  }
}

public struct CardTransferOwnership: Sendable {
  public let directory: CardTransferFileIdentity
  public let archive: CardTransferFileIdentity

  public init(directory: CardTransferFileIdentity, archive: CardTransferFileIdentity) {
    self.directory = directory
    self.archive = archive
  }

  public func validate(
    directory: CardTransferFileIdentity, archive: CardTransferFileIdentity,
    directoryIsReparse: Bool, archiveIsRegular: Bool, children: [String]
  ) throws {
    guard self.directory == directory, self.archive == archive, !directoryIsReparse,
      archiveIsRegular, children == ["bundle.zip"]
    else {
      throw CardTransferFailure(
        status: .rejected, message: "Export staging identity, file type or children changed; nothing was published or deleted.")
    }
  }

  public static func removeEmptyDirectory(
    expected: CardTransferFileIdentity, observed: CardTransferFileIdentity,
    isReparse: Bool, children: [String], remove: () throws -> Void
  ) throws {
    guard expected == observed, !isReparse, children.isEmpty else {
      throw CardTransferFailure(
        status: .rejected, message: "Staging changed or has unexpected children; nothing was deleted.")
    }
    try remove()
  }
}

public struct CardTransferResult: Encodable, Sendable {
  public static let prefix = "GRAPHCODE_CARD_TRANSFER_RESULT "
  public let version = 1
  public let operation: String
  public let invocation: String
  public let containingComposite: String
  public let status: String
  public let message: String
  public let sessionPreparationStarted: Bool
  public let outputPath: String?
  public var exitCode: Int32 { resultStatus.exitCode }
  public var outcome: CardTransferStatus { resultStatus }
  private let resultStatus: CardTransferStatus
  private let expectedOutputPath: String?

  private enum CodingKeys: String, CodingKey {
    case version, operation, invocation, containingComposite, status, message
    case sessionPreparationStarted, outputPath
  }

  public init(
    request: CardTransferRequest?, status: CardTransferStatus, message: String,
    sessionPreparationStarted: Bool, outputPath: String? = nil
  ) {
    operation = request?.operation.rawValue ?? ""
    invocation = request?.invocation.uuidString ?? ""
    containingComposite = request?.scope.argument ?? ""
    self.status = status.rawValue
    resultStatus = status
    self.message = String(message.unicodeScalars.prefix(2048))
    self.sessionPreparationStarted = sessionPreparationStarted
    self.outputPath = status == .succeeded && request?.operation == .export ? outputPath : nil
    expectedOutputPath = request?.zipPath
  }

  public func record() throws -> String {
    guard !message.isEmpty,
      resultStatus != .succeeded || (!invocation.isEmpty && !containingComposite.isEmpty),
      !(resultStatus == .succeeded && operation == "export")
        || (outputPath?.isEmpty == false && outputPath == expectedOutputPath)
    else {
      throw CardTransferFailure(status: .failed, message: "The transfer result is incomplete.")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let record = Self.prefix + String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
    guard record.utf8.count <= 256 * 1024 else {
      throw CardTransferFailure(status: .failed, message: "The transfer result exceeds the output limit.")
    }
    return record
  }
}
