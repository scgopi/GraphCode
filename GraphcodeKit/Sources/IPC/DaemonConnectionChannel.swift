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
  private var watermarks: [UUID: UInt64] = [:]
  private var lastAccess: [UUID: Date] = [:]
  private var subscriptions: [UUID: DaemonWireSubscription] = [:]
  private var projectPaths: [UUID: Set<String>] = [:]
  private var projectPathsByConnection: [UUID: [UUID: Set<String>]] = [:]
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
    _ = ensureClient(clientID)
    let envelope = appendLocked(clientID: clientID, event: event)
    lastAccess[clientID] = now
    return envelope
  }

  /// Reserves a sequence for a connection-local snapshot without retaining that
  /// snapshot in canonical replay history. This keeps the client's sequence space
  /// monotonic while ensuring a repeated project join cannot manufacture history for
  /// disconnected logical clients.
  public func reserveSequence(clientID: UUID) -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    let now = Date()
    purgeExpired(now: now)
    _ = ensureClient(clientID)
    let sequence = nextSequences[clientID, default: 1]
    nextSequences[clientID] = sequence == UInt64.max ? UInt64.max : sequence + 1
    watermarks[clientID] = sequence
    lastAccess[clientID] = now
    return sequence
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
    _ = ensureClient(clientID)
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
    guard buffers[clientID] != nil || activeConnections[clientID]?.isEmpty == false else {
      return
    }
    if let subscription {
      subscriptions[clientID] = subscription
    } else {
      subscriptions.removeValue(forKey: clientID)
    }
    lastAccess[clientID] = Date()
  }

  public func join(clientID: UUID, connectionID: UUID, projectPath: String) {
    lock.lock()
    defer { lock.unlock() }
    guard buffers[clientID] != nil || activeConnections[clientID]?.isEmpty == false else {
      return
    }
    projectPaths[clientID, default: []].insert(projectPath)
    projectPathsByConnection[clientID, default: [:]][connectionID, default: []].insert(projectPath)
    lastAccess[clientID] = Date()
  }

  public func join(clientID: UUID, projectPath: String) {
    lock.lock()
    defer { lock.unlock() }
    guard buffers[clientID] != nil || activeConnections[clientID]?.isEmpty == false else {
      return
    }
    projectPaths[clientID, default: []].insert(projectPath)
    lastAccess[clientID] = Date()
  }

  public func leave(clientID: UUID, connectionID: UUID, projectPath: String) {
    lock.lock()
    defer { lock.unlock() }
    guard buffers[clientID] != nil || activeConnections[clientID]?.isEmpty == false else {
      return
    }
    var pathsByConnection = projectPathsByConnection[clientID] ?? [:]
    var paths = pathsByConnection[connectionID] ?? []
    paths.remove(projectPath)
    if paths.isEmpty {
      pathsByConnection.removeValue(forKey: connectionID)
    } else {
      pathsByConnection[connectionID] = paths
    }
    if pathsByConnection.isEmpty {
      projectPathsByConnection.removeValue(forKey: clientID)
    } else {
      projectPathsByConnection[clientID] = pathsByConnection
    }
    guard !pathsByConnection.values.contains(where: { $0.contains(projectPath) }) else {
      lastAccess[clientID] = Date()
      return
    }
    projectPaths[clientID]?.remove(projectPath)
    lastAccess[clientID] = Date()
  }

  public func leave(clientID: UUID, projectPath: String) {
    lock.lock()
    defer { lock.unlock() }
    guard buffers[clientID] != nil || activeConnections[clientID]?.isEmpty == false else {
      return
    }
    projectPaths[clientID]?.remove(projectPath)
    if let connectionIDs = projectPathsByConnection[clientID]?.keys {
      for connectionID in Array(connectionIDs) {
        projectPathsByConnection[clientID]?[connectionID]?.remove(projectPath)
        if projectPathsByConnection[clientID]?[connectionID]?.isEmpty == true {
          projectPathsByConnection[clientID]?.removeValue(forKey: connectionID)
        }
      }
    }
    if projectPathsByConnection[clientID]?.isEmpty == true {
      projectPathsByConnection.removeValue(forKey: clientID)
    }
    lastAccess[clientID] = Date()
  }

  public func disconnect(clientID: UUID, connectionID: UUID) {
    lock.lock()
    defer { lock.unlock() }
    activeConnections[clientID]?.remove(connectionID)
    projectPathsByConnection[clientID]?.removeValue(forKey: connectionID)
    if projectPathsByConnection[clientID]?.isEmpty == true {
      projectPathsByConnection.removeValue(forKey: clientID)
    }
    if buffers[clientID] == nil, activeConnections[clientID]?.isEmpty != false {
      removeClient(clientID)
      return
    }
    lastAccess[clientID] = Date()
  }

  /// Appends one canonical graph event to every known logical client attached to the
  /// project, including active clients without a replay buffer and clients whose sockets
  /// are currently gone. Multiple sockets for one client share the returned envelope.
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
    let clientIDs = Set(buffers.keys).union(activeConnections.keys)
    for clientID in clientIDs {
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
      guard let watermark = watermarks[clientID] else {
        throw DaemonReplayBuffer.ReplayError.replayUnavailable
      }
      lastAccess[clientID] = now
      if cursor == watermark { return [] }
      if cursor > watermark {
        throw DaemonReplayBuffer.ReplayError.cursorOutsideWindow
      }
      throw DaemonReplayBuffer.ReplayError.replayUnavailable
    }
    lastAccess[clientID] = now
    if cursor == watermarks[clientID] {
      return []
    }
    if buffer.latestSequence == nil {
      if cursor > (watermarks[clientID] ?? 0) {
        throw DaemonReplayBuffer.ReplayError.cursorOutsideWindow
      }
      throw DaemonReplayBuffer.ReplayError.replayUnavailable
    }
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

    guard
      let oldest =
        lastAccess
        .filter({ activeConnections[$0.key]?.isEmpty != false })
        .min(by: { $0.value < $1.value })?.key
    else {
      return
    }
    removeClient(oldest)
  }

  private func purgeExpired(now: Date) {
    guard retention.isFinite else { return }
    for (clientID, access) in lastAccess where now.timeIntervalSince(access) >= retention {
      guard activeConnections[clientID]?.isEmpty != false else { continue }
      removeClient(clientID)
    }
  }

  @discardableResult
  private func ensureClient(_ clientID: UUID) -> Bool {
    if buffers[clientID] != nil {
      ensureSequenceState(clientID)
      return true
    }
    if maxClients == 0 {
      ensureSequenceState(clientID)
      return false
    }
    evictIfNeeded()
    guard buffers.count < maxClients else {
      ensureSequenceState(clientID)
      return false
    }
    buffers[clientID] = DaemonReplayBuffer(capacity: capacity)
    ensureSequenceState(clientID)
    return true
  }

  private func ensureSequenceState(_ clientID: UUID) {
    if nextSequences[clientID] == nil {
      nextSequences[clientID] = 1
    }
    if watermarks[clientID] == nil {
      watermarks[clientID] = 0
    }
  }

  private func appendLocked(clientID: UUID, event: DaemonEvent) -> DaemonWireEnvelope {
    let sequence = nextSequences[clientID, default: 1]
    nextSequences[clientID] = sequence == UInt64.max ? UInt64.max : sequence + 1
    watermarks[clientID] = sequence
    guard buffers[clientID] != nil else {
      return .event(sequence: sequence, event: event)
    }
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
    watermarks.removeValue(forKey: clientID)
    lastAccess.removeValue(forKey: clientID)
    subscriptions.removeValue(forKey: clientID)
    projectPaths.removeValue(forKey: clientID)
    projectPathsByConnection.removeValue(forKey: clientID)
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
    replayStore.join(
      clientID: clientID, connectionID: connection.id, projectPath: projectPath)
  }

  public func leave(projectPath: String) {
    guard case .v2 = mode else { return }
    replayStore.leave(
      clientID: clientID, connectionID: connection.id, projectPath: projectPath)
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

  public func envelopeForEvent(_ event: DaemonEvent) -> DaemonWireEnvelope? {
    guard case .v2 = mode, isSubscribed(to: event) else { return nil }
    return replayStore.append(clientID: clientID, event: event)
  }

  /// Sends a current-graph snapshot to this socket only. Unlike a graph-change event,
  /// opening or rejoining a project is not a canonical mutation and must not be
  /// replayed to other sockets or retained for a disconnected logical client.
  public func sendConnectionSnapshot(_ event: DaemonEvent) async throws {
    guard isSubscribed(to: event) else { return }
    switch mode {
    case .v1:
      try await sendJSON(event)
    case .v2:
      let sequence = replayStore.reserveSequence(clientID: clientID)
      try await sendJSON(DaemonWireEnvelope.event(sequence: sequence, event: event))
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

  public func sendSuccess(requestID: UUID) async throws {
    guard case .v2 = mode else { return }
    try await sendJSON(DaemonWireEnvelope.success(id: requestID))
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
