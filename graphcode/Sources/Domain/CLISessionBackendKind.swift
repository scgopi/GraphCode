/// Which CLI coding-agent backend a `LoopNode` runs inside — see
/// docs/04-cli-backends.md. Phase 1 only implements a live `CLISessionClient` for
/// `.claudeCode`; the other two cases exist because the backend set itself is fixed
/// vocabulary, not because they're usable yet (see docs/07-roadmap.md).
public enum CLISessionBackendKind: String, Codable, CaseIterable, Sendable {
  case claudeCode
  case copilotCLI
  case codex
}
