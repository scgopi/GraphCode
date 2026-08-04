/// What a loop's session is doing right now — the signal the graph canvas and the
/// orchestrator monitor both key off (docs/04-cli-backends.md#presence).
///
/// Distinct from `LoopState`, and the difference is the whole point: `LoopState` is what
/// the *graph* believes (idle, blocked, succeeded), owned by `graphcoded` and derived
/// from edges and resolutions. `Presence` is what the *session* is doing (typing,
/// waiting on a human), observed from outside. A node can be `.running` in the graph and
/// `.awaitingInput` in its session — that combination is precisely what the
/// needs-attention rollup exists to surface.
public enum Presence: String, Codable, Equatable, Sendable {
  /// The agent is working.
  case busy
  /// The agent has asked something and is waiting on a human.
  case awaitingInput
  /// A live session with nothing happening.
  case idle
  /// No session at all.
  case absent
  /// The session could not be asked — a remote project's probe failed in transport,
  /// which says nothing about the session itself. Distinct from `.absent` because the
  /// difference is the whole point: a dropped ssh link must degrade to "don't know",
  /// never to "stopped". `LoopNode.displayState` leaves `state` untouched for this
  /// reading, exactly as if no presence had ever been observed.
  case unknown

  /// Whether this presence is the kind a human needs to do something about.
  public var needsAttention: Bool { self == .awaitingInput }
}

/// How a given presence reading was arrived at. Surfaced because docs/04-cli-backends.md
/// asks for the heuristic fallback to be "flagged as lower-confidence in the UI" — a
/// guess and a hook-reported fact should not look identical to a human deciding whether
/// to intervene.
public enum PresenceConfidence: String, Codable, Equatable, Sendable {
  /// The backend told us, through hooks it supports natively.
  case reported
  /// Inferred from the terminal stream.
  case scanned
  /// Nothing better was available — inferred from how long the session has been quiet.
  case heuristic
}

public struct PresenceReading: Codable, Equatable, Sendable {
  public var presence: Presence
  public var confidence: PresenceConfidence

  public init(presence: Presence, confidence: PresenceConfidence) {
    self.presence = presence
    self.confidence = confidence
  }

  public static let absent = PresenceReading(presence: .absent, confidence: .reported)
  public static let unknown = PresenceReading(presence: .unknown, confidence: .heuristic)
}
