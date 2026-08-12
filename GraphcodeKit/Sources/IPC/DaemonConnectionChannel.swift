import Foundation

public enum DaemonProtocolMode: Equatable, Sendable {
  case v1
  case v2(version: Int)
}

public enum DaemonWireErrorCode: String, Codable, Sendable {
  case malformedFrame
  case malformedEnvelope
  case unsupportedVersion
  case expectedHello
  case replayUnavailable
  case requestFailed
  case connectionClosed
  case transportFailure
}

public enum DaemonConnectionChannelError: Error, Equatable, Sendable {
  case expectedHello
  case unsupportedVersion
  case malformedEnvelope
  case replayUnavailable
}

/// Replay state is kept separately from a socket. A reconnecting client presents
/// the same `clientID` in hello and can therefore resume a bounded event window.
public actor DaemonReplayStore {
  public let capacity: Int
  private var buffers: [UUID: DaemonReplayBuffer] = [:]
  private var nextSequences: [UUID: UInt64] = [:]

  public init(capacity: Int = 128) {
    self.capacity = max(0, capacity)
  }

  public func append(clientID: UUID, event: DaemonEvent) -> DaemonWireEnvelope {
    let sequence = nextSequences[clientID, default: 1]
    nextSequences[clientID] = sequence == UInt64.max ? UInt64.max : sequence + 1
    var buffer = buffers[clientID] ?? DaemonReplayBuffer(capacity: capacity)
    buffer.append(sequence: sequence, event: event)
    buffers[clientID] = buffer
    return .event(sequence: sequence, event: event)
  }

  public func replay(clientID: UUID, after cursor: UInt64) throws -> [DaemonWireEnvelope] {
    try (buffers[clientID] ?? DaemonReplayBuffer(capacity: capacity)).replay(after: cursor)
  }

  public func remove(clientID: UUID) {
    buffers.removeValue(forKey: clientID)
    nextSequences.removeValue(forKey: clientID)
  }
}

/// Serializes writes for one logical client and translates typed daemon events into
/// either the deployed v1 event shape or a v2 envelope.
public actor DaemonConnectionChannel {
  public let connection: any DaemonConnection
  public let mode: DaemonProtocolMode
  public let clientID: UUID

  private let replayStore: DaemonReplayStore
  private var subscription: DaemonWireSubscription?
  private var activeRequestID: UUID?

  public init(
    connection: any DaemonConnection,
    mode: DaemonProtocolMode = .v1,
    clientID: UUID? = nil,
    subscription: DaemonWireSubscription? = nil,
    replayStore: DaemonReplayStore = DaemonReplayStore()
  ) {
    self.connection = connection
    self.mode = mode
    self.clientID = clientID ?? connection.id
    self.subscription = subscription
    self.replayStore = replayStore
  }

  public func setSubscription(_ subscription: DaemonWireSubscription?) {
    self.subscription = subscription
  }

  public func setActiveRequestID(_ requestID: UUID?) {
    activeRequestID = requestID
  }

  public func sendHelloResponse(selectedVersion: Int) async throws {
    try await sendJSON(DaemonWireEnvelope.helloResponse(selectedVersion: selectedVersion))
  }

  public func sendEvent(_ event: DaemonEvent) async throws {
    guard isSubscribed(to: event) else { return }
    switch mode {
    case .v1:
      try await sendJSON(event)
    case .v2:
      let envelope = await replayStore.append(clientID: clientID, event: event)
      try await sendJSON(envelope)
    }
  }

  public func sendResponse(requestID: UUID, event: DaemonEvent) async throws {
    switch mode {
    case .v1:
      try await sendJSON(event)
    case .v2:
      try await sendJSON(DaemonWireEnvelope.response(id: requestID, event: event))
    }
  }

  public func sendError(
    requestID: UUID? = nil,
    code: DaemonWireErrorCode = .requestFailed,
    message: String
  ) async throws {
    switch mode {
    case .v1:
      try await sendJSON(DaemonEvent.errorOccurred(message))
    case .v2:
      try await sendJSON(
        DaemonWireEnvelope.error(
          id: requestID ?? activeRequestID, code: code.rawValue, message: message))
    }
  }

  public func replay(after cursor: UInt64) async throws {
    guard case .v2 = mode else { return }
    do {
      for envelope in try await replayStore.replay(clientID: clientID, after: cursor) {
        try await sendJSON(envelope)
      }
    } catch DaemonReplayBuffer.ReplayError.cursorOutsideWindow {
      throw DaemonConnectionChannelError.replayUnavailable
    }
  }

  public func receiveFrame() async throws -> Data {
    try await connection.receiveFrame()
  }

  public func close() async throws {
    try await connection.close()
  }

  private func isSubscribed(to event: DaemonEvent) -> Bool {
    guard let paths = subscription?.projectPaths else { return true }
    guard !paths.isEmpty else { return false }
    switch event {
    case .graphChanged(let graph):
      return paths.contains(graph.project.path)
    case .recentProjectsListed:
      return true
    case .errorOccurred:
      return true
    }
  }

  private func sendJSON<T: Encodable>(_ value: T) async throws {
    try await connection.sendFrame(try JSONEncoder().encode(value))
  }
}
