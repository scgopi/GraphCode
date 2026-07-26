/// Which CLI coding-agent backend a `LoopNode` runs inside — see
/// docs/04-cli-backends.md. Only `.claudeCode` has a live implementation (the app's
/// `CLISessionClient` and `graphcoded`'s `ZmxSessionLauncher`); the other two cases
/// exist because the backend set itself is fixed vocabulary, not because they're usable
/// yet (see docs/07-roadmap.md).
///
/// A time-based node's recurrence is expressed in its own prompt using whichever looping
/// skill its backend provides (`/loop` for `.claudeCode`), so nothing here needs a
/// per-backend scheduling capability — see `LoopNode.triggerPrompt`.
public enum CLISessionBackendKind: String, Codable, CaseIterable, Sendable {
  case claudeCode
  case copilotCLI
  case codex
}
