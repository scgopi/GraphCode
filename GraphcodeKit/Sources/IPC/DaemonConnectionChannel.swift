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
  case cursorOutsideWindow
  case requestFailed
  case connectionClosed
  case transportFailure
}

public enum DaemonConnectionChannelError: Error, Equatable, Sendable {
  case expectedHello
  case unsupportedVersion
  case malformedEnvelope
  case replayUnavailable
  case cursorOutsideWindow
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
    guard let buffer = buffers[clientID] else {
      throw DaemonReplayBuffer.ReplayError.replayUnavailable
    }
    return try buffer.replay(after: cursor)
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
  private let writeGate: DaemonFrameWriteGate
  private var subscription: DaemonWireSubscription?

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
    self.writeGate = daemonFrameWriteGates.gate(
      for: connection.id, connection: connection)
  }

  public func setSubscription(_ subscription: DaemonWireSubscription?) {
    self.subscription = subscription
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
          id: requestID, code: code.rawValue, message: message))
    }
  }

  public func replay(after cursor: UInt64) async throws {
    guard case .v2 = mode else { return }
    do {
      for envelope in try await replayStore.replay(clientID: clientID, after: cursor) {
        guard let event = envelope.event, isSubscribed(to: event) else { continue }
        try await sendJSON(envelope)
      }
    } catch DaemonReplayBuffer.ReplayError.cursorOutsideWindow {
      throw DaemonConnectionChannelError.cursorOutsideWindow
    } catch DaemonReplayBuffer.ReplayError.replayUnavailable {
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
    try await writeGate.send(try JSONEncoder().encode(value))
  }
}

/// A task chain keeps complete framed writes non-reentrant. Actor isolation alone
/// is insufficient here: an `await` inside `sendFrame` lets another channel call
/// run before the first header/payload pair has finished.
private actor DaemonFrameWriteGate {
  private let connection: any DaemonConnection
  private var tail: Task<Void, Error>?

  init(connection: any DaemonConnection) {
    self.connection = connection
  }

  func send(_ data: Data) async throws {
    let previous = tail
    let connection = self.connection
    let operation = Task {
      if let previous {
        try await previous.value
      }
      try await connection.sendFrame(data)
    }
    tail = operation
    try await operation.value
  }
}

private let daemonFrameWriteGates = DaemonFrameWriteGateRegistry()

private final class DaemonFrameWriteGateRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var gates: [UUID: DaemonFrameWriteGate] = [:]

  func gate(for id: UUID, connection: any DaemonConnection) -> DaemonFrameWriteGate {
    lock.lock()
    defer { lock.unlock() }
    if let gate = gates[id] {
      return gate
    }
    let gate = DaemonFrameWriteGate(connection: connection)
    gates[id] = gate
    return gate
  }
}
