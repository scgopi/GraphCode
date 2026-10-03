import AppKit
import Foundation
import GraphcodeKit
import Observation

/// The state behind "Set up Nod", shared by the Welcome sheet and Settings › Agents › Nod:
/// which engine, whether each one is signed in, the API-key field, and the Copilot
/// device flow's progress.
///
/// Settings are read and written through `settings`, which the app points at
/// `SettingsModel.shared` so a choice here is saved the moment it is made.
@MainActor
@Observable
final class NodSetupModel {
  enum CopilotPhase: Equatable {
    case idle
    case requesting
    case waiting(CopilotDeviceFlow.DeviceCode)
    case signedIn(CopilotDeviceFlow.Account?)
    case failed(String)
  }

  var settings: NodSettings {
    get { readSettings() }
    set { writeSettings(newValue) }
  }

  var apiKeyDraft = ""
  var apiKeyError: String?
  var showsAPIKeyField = false
  var copilotPhase: CopilotPhase = .idle
  private(set) var signedIn: [NodEngine: Bool] = [:]
  private(set) var claudeCodeSignInFound = false
  /// Signed in only through the Copilot CLI's login, which Nod uses but cannot sign out of.
  private(set) var usesCopilotCLISignIn = false

  @ObservationIgnored private let credentials: NodCredentialStore
  @ObservationIgnored private let deviceFlow: CopilotDeviceFlow
  @ObservationIgnored private let readSettings: () -> NodSettings
  @ObservationIgnored private let writeSettings: (NodSettings) -> Void
  @ObservationIgnored private let openURL: (URL) -> Void
  @ObservationIgnored private var copilotTask: Task<Void, Never>?
  @ObservationIgnored private let copilotCLISignInFound: () -> Bool

  init(
    credentials: NodCredentialStore = .live,
    deviceFlow: CopilotDeviceFlow = .live,
    readSettings: @escaping () -> NodSettings = { SettingsModel.shared.settings.nod },
    writeSettings: @escaping (NodSettings) -> Void = { SettingsModel.shared.settings.nod = $0 },
    openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
    claudeCodeSignInFound: () -> Bool = { NodClaudeSignIn.claudeCodeSignInFound() },
    copilotCLISignInFound: @escaping () -> Bool = { NodCredentialStore.copilotCLISignInFound() }
  ) {
    self.copilotCLISignInFound = copilotCLISignInFound
    self.credentials = credentials
    self.deviceFlow = deviceFlow
    self.readSettings = readSettings
    self.writeSettings = writeSettings
    self.openURL = openURL
    self.claudeCodeSignInFound =
      NodClaudeSignIn.subscriptionLoginAllowed && claudeCodeSignInFound()
    refreshSignIn()
  }

  func isSignedIn(_ engine: NodEngine) -> Bool { signedIn[engine] ?? false }

  /// Whether this build can run GitHub's device flow — it needs GraphCode's OAuth app id.
  var canStartDeviceFlow: Bool { deviceFlow.clientID != nil }

  func selectEngine(_ engine: NodEngine) {
    settings.switchEngine(to: engine)
  }

  func refreshSignIn() {
    for engine in NodEngine.allCases {
      signedIn[engine] = credentials.isSignedIn(engine)
    }
    usesCopilotCLISignIn = !isSignedIn(.copilotSDK) && copilotCLISignInFound()
    if usesCopilotCLISignIn { signedIn[.copilotSDK] = true }
    if isSignedIn(.copilotSDK), copilotPhase == .idle {
      copilotPhase = .signedIn(nil)
    }
  }

  func saveAPIKey() {
    switch NodClaudeSignIn.validateAPIKey(apiKeyDraft) {
    case .failure(.empty):
      apiKeyError = "Paste a key from console.anthropic.com."
    case .failure(.notAnAnthropicKey):
      apiKeyError = "That doesn't look like an Anthropic API key (sk-ant-…)."
    case .success(let key):
      do {
        try credentials.write(key, .anthropicAPIKey)
        apiKeyDraft = ""
        apiKeyError = nil
        showsAPIKeyField = false
      } catch {
        apiKeyError = "The Keychain refused the key (\(error))."
      }
    }
    refreshSignIn()
  }

  func signOut(_ engine: NodEngine) {
    try? credentials.signOut(engine)
    if engine == .copilotSDK {
      copilotTask?.cancel()
      copilotPhase = .idle
    }
    refreshSignIn()
  }

  /// Requests a device code, opens github.com/login/device, and polls in the background
  /// until GitHub answers. Starting again cancels a sign-in already in flight.
  func startCopilotSignIn() {
    copilotTask?.cancel()
    copilotPhase = .requesting
    let flow = deviceFlow
    let credentials = credentials
    copilotTask = Task { [weak self] in
      do {
        let code = try await flow.requestCode()
        guard let self, !Task.isCancelled else { return }
        self.copilotPhase = .waiting(code)
        self.openURL(code.verificationURL)
        let token = try await flow.pollForToken(code)
        try credentials.write(token, .githubCopilot)
        let account = try? await flow.account(token: token)
        guard !Task.isCancelled else { return }
        self.copilotPhase = .signedIn(account)
        self.refreshSignIn()
      } catch is CancellationError {
      } catch {
        guard let self, !Task.isCancelled else { return }
        self.copilotPhase = .failed(Self.describe(error))
      }
    }
  }

  func cancelCopilotSignIn() {
    copilotTask?.cancel()
    copilotPhase = isSignedIn(.copilotSDK) ? .signedIn(nil) : .idle
  }

  /// Waits for the sign-in started by `startCopilotSignIn`, for tests.
  func waitForCopilotSignIn() async {
    await copilotTask?.value
  }

  func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  static func describe(_ error: Error) -> String {
    switch error as? CopilotDeviceFlow.Failure {
    case .notConfigured:
      return "This build has no GitHub sign-in configured."
    case .expired:
      return "The code expired before GitHub saw it. Try again for a new one."
    case .denied:
      return "GitHub sign-in was cancelled."
    case .unexpected(let detail):
      return "GitHub sign-in failed: \(detail)"
    case nil:
      return "GitHub sign-in failed: \(error.localizedDescription)"
    }
  }
}

extension NodSetupModel: Identifiable {
  nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
