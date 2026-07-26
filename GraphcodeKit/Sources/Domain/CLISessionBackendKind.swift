/// Which CLI coding-agent backend a `LoopNode` runs inside — see
/// docs/04-cli-backends.md. Only `.claudeCode` has a live implementation (both the
/// app's `CLISessionClient` and `graphcoded`'s scheduler); the other two cases exist
/// because the backend set itself is fixed vocabulary, not because they're usable yet
/// (see docs/07-roadmap.md).
public enum CLISessionBackendKind: String, Codable, CaseIterable, Sendable {
  case claudeCode
  case copilotCLI
  case codex
}
