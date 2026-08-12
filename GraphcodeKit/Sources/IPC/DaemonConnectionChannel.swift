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
public final class DaemonReplayStore: @unchecked Sendable {
  public let capacity: Int
  public let maxClients: Int
  public let retention: TimeInterval
  private let lock = NSLock()
  private var buffers: [UUID: DaemonReplayBuffer] = [:]
  private var nextSequences: [UUID: UInt64] = [:]
  private var lastAccess: [UUID: Date] = [:]
  private var subscriptions: [UUID: DaemonWireSubscription] = [:]
  private var projectPaths: [UUID: Set<String>] = [:]
  private var activeConnections: [UUID: Set<UUID>] = [:]

  public init(
    capacity: Int = 128,
    maxClients: Int = 256,
    retention: TimeInterval = 3_600
  ) {
    self.capacity = max(0, capacity)
    self.maxClients = max(0, maxClients)
    self.retention = max(0, retention)
  }

  public func append(clientID: UUID, event: DaemonEvent) -> DaemonWireEnvelope {
    lock.lock()
    defer { lock.unlock() }
    let now = Date()
    purgeExpired(now: now)
    guard maxClients > 0 else {
      return .event(sequence: 1, event: event)
    }
    ensureClient(clientID)
    let envelope = appendLocked(clientID: clientID, event: event)
    lastAccess[clientID] = now
    return envelope
  }

  /// Registers a logical client independently of its current socket. Its bounded
  /// history remains eligible for canonical events while every socket for the client
  /// is disconnected.
  public func register(
    clientID: UUID,
    connectionID: UUID,
    subscription: DaemonWireSubscription?
  ) {
    lock.lock()
    defer { lock.unlock() }
    purgeExpired(now: Date())
    guard maxClients > 0 else { return }
    ensureClient(clientID)
    activeConnections[clientID, default: []].insert(connectionID)
    if let subscription {
      subscriptions[clientID] = subscription
    } else {
      subscriptions.removeValue(forKey: clientID)
    }
    lastAccess[clientID] = Date()
  }

  public func setSubscription(clientID: UUID, subscription: DaemonWireSubscription?) {
    lock.lock()
    defer { lock.unlock() }
    guard buffers[clientID] != nil else { return }
    if let subscription {
      subscriptions[clientID] = subscription
    } else {
      subscriptions.removeValue(forKey: clientID)
    }
    lastAccess[clientID] = Date()
  }

  public func join(clientID: UUID, projectPath: String) {
    lock.lock()
    defer { lock.unlock() }
    guard buffers[clientID] != nil else { return }
    projectPaths[clientID, default: []].insert(projectPath)
    lastAccess[clientID] = Date()
  }

  public func leave(clientID: UUID, projectPath: String) {
    lock.lock()
    defer { lock.unlock() }
    projectPaths[clientID]?.remove(projectPath)
    lastAccess[clientID] = Date()
  }

  public func disconnect(clientID: UUID, connectionID: UUID) {
    lock.lock()
    defer { lock.unlock() }
    activeConnections[clientID]?.remove(connectionID)
    lastAccess[clientID] = Date()
  }

  /// Appends one canonical graph event to every retained logical client that is
  /// attached to the project, including clients whose sockets are currently gone.
  /// The returned envelopes let live channels write the exact sequence assigned here.
  public func append(
    event: DaemonEvent,
    projectPath: String
  ) -> [UUID: DaemonWireEnvelope] {
    lock.lock()
    defer { lock.unlock() }
    let now = Date()
    purgeExpired(now: now)
    var envelopes: [UUID: DaemonWireEnvelope] = [:]
    for clientID in Array(buffers.keys) {
      guard projectPaths[clientID]?.contains(projectPath) == true,
        isSubscribed(clientID: clientID, projectPath: projectPath)
      else { continue }
      envelopes[clientID] = appendLocked(clientID: clientID, event: event)
      if activeConnections[clientID]?.isEmpty == false {
        lastAccess[clientID] = now
      }
    }
    return envelopes
  }

  public func replay(clientID: UUID, after cursor: UInt64) throws -> [DaemonWireEnvelope] {
    lock.lock()
    defer { lock.unlock() }
    let now = Date()
    purgeExpired(now: now)
    guard let buffer = buffers[clientID] else {
      throw DaemonReplayBuffer.ReplayError.replayUnavailable
    }
    lastAccess[clientID] = now
    return try buffer.replay(after: cursor)
  }

  public func remove(clientID: UUID) {
    lock.lock()
    defer { lock.unlock() }
    removeClient(clientID)
  }

  public func pruneExpired(at now: Date = Date()) {
    lock.lock()
    defer { lock.unlock() }
    purgeExpired(now: now)
  }

  public func startCleanup(
    every interval: Duration = .seconds(60)
  ) -> Task<Void, Never> {
    Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled else { return }
        self?.pruneExpired()
      }
    }
  }

  public var clientCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return buffers.count
  }

  private func evictIfNeeded() {
    guard buffers.count >= maxClients else { return }
    guard let oldest = lastAccess.min(by: { $0.value < $1.value })?.key else {
      return
    }
    buffers.removeValue(forKey: oldest)
    removeClient(oldest)
  }

  private func purgeExpired(now: Date) {
    guard retention.isFinite else { return }
    for (clientID, access) in lastAccess where now.timeIntervalSince(access) >= retention {
      guard activeConnections[clientID]?.isEmpty != false else { continue }
      removeClient(clientID)
    }
  }

  private func ensureClient(_ clientID: UUID) {
    guard buffers[clientID] == nil else { return }
    evictIfNeeded()
    buffers[clientID] = DaemonReplayBuffer(capacity: capacity)
    nextSequences[clientID] = 1
  }

  private func appendLocked(clientID: UUID, event: DaemonEvent) -> DaemonWireEnvelope {
    let sequence = nextSequences[clientID, default: 1]
    nextSequences[clientID] = sequence == UInt64.max ? UInt64.max : sequence + 1
    var buffer = buffers[clientID] ?? DaemonReplayBuffer(capacity: capacity)
    buffer.append(sequence: sequence, event: event)
    buffers[clientID] = buffer
    return .event(sequence: sequence, event: event)
  }

  private func isSubscribed(clientID: UUID, projectPath: String) -> Bool {
    guard let paths = subscriptions[clientID]?.projectPaths else { return true }
    return !paths.isEmpty && paths.contains(projectPath)
  }

  private func removeClient(_ clientID: UUID) {
    buffers.removeValue(forKey: clientID)
    nextSequences.removeValue(forKey: clientID)
    lastAccess.removeValue(forKey: clientID)
    subscriptions.removeValue(forKey: clientID)
    projectPaths.removeValue(forKey: clientID)
    activeConnections.removeValue(forKey: clientID)
  }
}

/// Serializes writes for one logical client and translates typed daemon events into
/// either the deployed v1 event shape or a v2 envelope.
public actor DaemonConnectionChannel {
  public let connection: any DaemonConnection
  public let mode: DaemonProtocolMode
  public let clientID: UUID
  public let replayStore: DaemonReplayStore

  private let writeGate: DaemonFrameWriteGate
  private var subscription: DaemonWireSubscription?
  private var replayInProgress = false
  private var queuedLiveEvents: [DaemonWireEnvelope] = []

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
    if case .v2 = mode {
      replayStore.register(
        clientID: self.clientID,
        connectionID: connection.id,
        subscription: subscription)
    }
  }

  public func setSubscription(_ subscription: DaemonWireSubscription?) {
    self.subscription = subscription
    if case .v2 = mode {
      replayStore.setSubscription(clientID: clientID, subscription: subscription)
    }
  }

  public func join(projectPath: String) {
    guard case .v2 = mode else { return }
    replayStore.join(clientID: clientID, projectPath: projectPath)
  }

  public func leave(projectPath: String) {
    guard case .v2 = mode else { return }
    replayStore.leave(clientID: clientID, projectPath: projectPath)
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
      let envelope = replayStore.append(clientID: clientID, event: event)
      if replayInProgress {
        queuedLiveEvents.append(envelope)
        return
      }
      try await sendJSON(envelope)
    }
  }

  /// Writes a sequence already assigned by the canonical replay store. This is used
  /// when a graph changed while another socket for the same logical client was away.
  public func sendEvent(envelope: DaemonWireEnvelope) async throws {
    guard case .v2 = mode, let event = envelope.event, isSubscribed(to: event) else { return }
    if replayInProgress {
      queuedLiveEvents.append(envelope)
      return
    }
    try await sendJSON(envelope)
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
    replayInProgress = true
    do {
      let envelopes = try replayStore.replay(clientID: clientID, after: cursor)
      try await writeGate.flush()
      for envelope in envelopes {
        guard let event = envelope.event, isSubscribed(to: event) else { continue }
        try await sendJSON(envelope)
      }
      try await flushQueuedLiveEvents()
      replayInProgress = false
    } catch DaemonReplayBuffer.ReplayError.cursorOutsideWindow {
      try? await flushQueuedLiveEvents()
      replayInProgress = false
      throw DaemonConnectionChannelError.cursorOutsideWindow
    } catch DaemonReplayBuffer.ReplayError.replayUnavailable {
      try? await flushQueuedLiveEvents()
      replayInProgress = false
      throw DaemonConnectionChannelError.replayUnavailable
    } catch {
      replayInProgress = false
      queuedLiveEvents.removeAll()
      throw error
    }
  }

  public func receiveFrame() async throws -> Data {
    try await connection.receiveFrame()
  }

  public func close() async throws {
    replayInProgress = false
    queuedLiveEvents.removeAll()
    if case .v2 = mode {
      replayStore.disconnect(clientID: clientID, connectionID: connection.id)
    }
    do {
      try await connection.close()
    } catch {
      daemonFrameWriteGates.remove(for: connection.id)
      throw error
    }
    daemonFrameWriteGates.remove(for: connection.id)
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
    let data = try JSONEncoder().encode(value)
    if case .v2 = mode, data.count > FramedMessageIO.v2MaxPayloadBytes {
      throw FramedMessageIO.IOError.payloadTooLarge
    }
    try await writeGate.send(data)
  }

  private func flushQueuedLiveEvents() async throws {
    while !queuedLiveEvents.isEmpty {
      let events = queuedLiveEvents
      queuedLiveEvents.removeAll(keepingCapacity: true)
      for envelope in events {
        guard let event = envelope.event, isSubscribed(to: event) else { continue }
        try await sendJSON(envelope)
      }
    }
  }
}

/// A task chain keeps complete framed writes non-reentrant. Actor isolation alone
/// is insufficient here: an `await` inside `sendFrame` lets another channel call
/// run before the first header/payload pair has finished.
private actor DaemonFrameWriteGate {
  private let connection: any DaemonConnection
  private var tail: Task<Void, Error>?
  private var tailID: UInt64?
  private var nextOperationID: UInt64 = 0

  init(connection: any DaemonConnection) {
    self.connection = connection
  }

  func send(_ data: Data) async throws {
    let previous = tail
    let operationID = nextOperationID
    nextOperationID = nextOperationID == UInt64.max ? 0 : nextOperationID + 1
    let connection = self.connection
    let operation = Task {
      if let previous {
        try await previous.value
      }
      try await connection.sendFrame(data)
    }
    tail = operation
    tailID = operationID
    do {
      try await operation.value
    } catch {
      if tailID == operationID {
        tail = nil
        tailID = nil
      }
      throw error
    }
    if tailID == operationID {
      tail = nil
      tailID = nil
    }
  }

  func flush() async throws {
    try await tail?.value
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

  func remove(for id: UUID) {
    lock.lock()
    defer { lock.unlock() }
    gates.removeValue(forKey: id)
  }
}
