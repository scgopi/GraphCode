import Foundation

/// Where a stopped loop's agent is in answering the stop prompt.
///
/// Stop asks the session to stop looping, it does not kill it, so the agent's reply (busy,
/// then awaitingInput or idle) arrives as presence readings on a loop whose `state` is
/// already `.stopped`. That reply is not the loop asking for anything. But a human can
/// also open the still-live pane and type, or a reboot restore can bring the session
/// back, and a question that follows is genuine. A presence reading carries no timestamp
/// or turn identity, so the daemon tells the two apart by the order of what it observes:
/// readings are masked until the reply has settled, and until the next busy turn after
/// that (`GraphStore.maskStopReply`). Persisted, so a daemon restart does not forget which
/// side of the line it is on.
public struct StopReply: Codable, Equatable, Sendable {
  public enum Phase: String, Codable, Equatable, Sendable {
    /// The stop prompt was delivered and nothing has answered yet.
    case awaitingReply
    /// The agent is mid-reply.
    case replying
    /// The reply is over. Readings stay masked until a new busy turn.
    case settled
  }

  public var requestedAt: Date
  public var phase: Phase

  public init(requestedAt: Date, phase: Phase = .awaitingReply) {
    self.requestedAt = requestedAt
    self.phase = phase
  }
}
