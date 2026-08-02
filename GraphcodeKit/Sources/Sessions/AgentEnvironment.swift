import Foundation

/// The identity variables a live Claude Code session exports into everything it spawns
/// — `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_CHILD_SESSION`, and friends.
///
/// graphcode can be started from inside such a session — an agent running `open
/// graphcode.app`, or `make daemon-install` from a loop's own shell — and then inherits
/// them. Passed on to the backends graphcode starts, they make each *new* session take
/// itself for a spawned child of that long-dead one: transcript saving off, the wrong
/// session id, no `/resume` later. The processes are fresh top-level sessions however
/// graphcode itself was launched, so the variables are dropped before anything forks.
public enum AgentEnvironment {
  public static func isInheritedAgentIdentity(_ key: String) -> Bool {
    key.hasPrefix("CLAUDE") || key == "AI_AGENT"
  }

  /// Scrubs them from *this* process, at startup, rather than only from the environments
  /// graphcode builds for its own `Process` launches: a terminal surface's shell is
  /// spawned by libghostty, which copies our environment directly and never passes
  /// through `PTYProcessSession`. Scrubbing at the root covers both paths, and the zmx
  /// server that outlives them.
  public static func scrubInheritedAgentIdentity() {
    for key in ProcessInfo.processInfo.environment.keys where isInheritedAgentIdentity(key) {
      unsetenv(key)
    }
  }
}
