import Foundation

/// The one question a new workspace has to ask before it is any use: which agent runs
/// its loops.
///
/// It is genuinely per-workspace and easy to miss. `settings.json` lives *inside* the
/// support directory, so a workspace created by someone running Codex everywhere still
/// starts on the built-in default — silently, and not discovered until the first loop
/// opens the wrong CLI.
///
/// The invitation is a file rather than a flag in `UserDefaults`, for the reason the
/// tour's own `hasSeenOnboarding` cannot be reused: defaults are per *app*, and every
/// workspace on the machine is the same app. A file in the workspace's own directory is
/// the only thing that can say "this workspace has not been started yet".
///
/// Written by the instance that *creates* the workspace, because that is the one that
/// knows what to suggest — the agent the human is already using. Read, and removed, by
/// the instance that opens it.
public enum WorkspaceStarter {
  /// What the creating workspace passes on to the new one.
  public struct Invitation: Codable, Equatable, Sendable {
    /// Preselected in the dialog, and applied when the dialog closes with it still
    /// selected. An earlier rule — "the suggestion can never quietly become the
    /// setting" — applied it only on a tap, which made the preselection's checkmark a
    /// lie: Start Working over the suggested row kept the built-in default. The one
    /// case that keeps the old rule is a workspace whose starter never opened at all
    /// (created before this shipped): no dialog, no suggestion, no write.
    public var suggestedBackend: CLISessionBackendKind

    public init(suggestedBackend: CLISessionBackendKind) {
      self.suggestedBackend = suggestedBackend
    }
  }

  static func url(for workspace: Workspace) -> URL {
    workspace.url.appendingPathComponent("starter.json")
  }

  /// Leaves the invitation for a workspace that is about to be opened for the first time.
  ///
  /// Never for the default workspace: that one is configured by the tour, and an install
  /// upgrading into this feature must not be asked again about a workspace it has been
  /// using for months.
  public static func invite(_ workspace: Workspace, suggesting backend: CLISessionBackendKind) {
    guard !workspace.isDefault else { return }
    guard let data = try? JSONEncoder().encode(Invitation(suggestedBackend: backend)) else {
      return
    }
    try? data.write(to: url(for: workspace), options: .atomic)
  }

  /// The invitation this workspace was opened with, or `nil` — already answered, or a
  /// workspace made before this shipped, which is treated as answered rather than
  /// interrogated about a decision it has been living with.
  public static func pending(_ workspace: Workspace = .current) -> Invitation? {
    guard !workspace.isDefault,
      let data = try? Data(contentsOf: url(for: workspace))
    else { return nil }
    return try? JSONDecoder().decode(Invitation.self, from: data)
  }

  /// Answered — by choosing or by skipping. Both count: the dialog asks once, and a
  /// person who dismissed it does not want it again on the next launch.
  public static func clear(_ workspace: Workspace = .current) {
    try? FileManager.default.removeItem(at: url(for: workspace))
  }
}
