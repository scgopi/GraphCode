import Foundation
import GraphcodeKit
import Security

/// One secret Nod signs in with. Each is a generic-password item in the login Keychain
/// under `NodSettings.keychainService`, with the raw value as its account, never a file
/// under `~/.graphcode`.
enum NodCredential: String, CaseIterable, Sendable {
  case anthropicAPIKey = "anthropic-api-key"
  /// A Claude subscription token. Only stored when `NodClaudeSignIn.subscriptionLoginAllowed`.
  case claudeSubscription = "claude-subscription"
  /// The account NodRuntime reads (`KeychainAccount.githubToken` in credentials.ts).
  case githubCopilot = "github-token"

  var engine: NodEngine {
    switch self {
    case .anthropicAPIKey, .claudeSubscription: .claudeAgentSDK
    case .githubCopilot: .copilotSDK
    }
  }
}

enum NodKeychainError: Error, Equatable {
  case unexpectedStatus(OSStatus)
}

/// Reads and writes Nod's secrets. The live value talks to the Keychain; tests use
/// `inMemory()` or a live store on a throwaway service.
struct NodCredentialStore: Sendable {
  var read: @Sendable (NodCredential) throws -> String?
  var write: @Sendable (String, NodCredential) throws -> Void
  var delete: @Sendable (NodCredential) throws -> Void

  static let live = keychain(service: NodSettings.keychainService)

  static func keychain(service: String) -> NodCredentialStore {
    let query = { @Sendable (credential: NodCredential) -> [CFString: Any] in
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: credential.rawValue,
      ]
    }
    return NodCredentialStore(
      read: { credential in
        var item: CFTypeRef?
        var search = query(credential)
        search[kSecReturnData] = true
        search[kSecMatchLimit] = kSecMatchLimitOne
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        switch status {
        case errSecSuccess:
          return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
        case errSecItemNotFound:
          return nil
        default:
          throw NodKeychainError.unexpectedStatus(status)
        }
      },
      write: { secret, credential in
        let data = Data(secret.utf8)
        let update = SecItemUpdate(
          query(credential) as CFDictionary, [kSecValueData: data] as CFDictionary)
        switch update {
        case errSecSuccess:
          return
        case errSecItemNotFound:
          var add = query(credential)
          add[kSecValueData] = data
          add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
          add[kSecAttrLabel] = "GraphCode Nod"
          let status = SecItemAdd(add as CFDictionary, nil)
          guard status == errSecSuccess else { throw NodKeychainError.unexpectedStatus(status) }
        default:
          throw NodKeychainError.unexpectedStatus(update)
        }
      },
      delete: { credential in
        let status = SecItemDelete(query(credential) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
          throw NodKeychainError.unexpectedStatus(status)
        }
      }
    )
  }

  static func inMemory(_ seed: [NodCredential: String] = [:]) -> NodCredentialStore {
    let box = LockedBox(seed)
    return NodCredentialStore(
      read: { credential in box.withValue { $0[credential] } },
      write: { secret, credential in box.withValue { $0[credential] = secret } },
      delete: { credential in box.withValue { $0[credential] = nil } }
    )
  }

  /// Whether `engine` has something to sign in with. A Keychain error reads as signed
  /// out, which is what the person would have to fix anyway.
  func isSignedIn(_ engine: NodEngine) -> Bool {
    NodCredential.allCases.contains { credential in
      guard credential.engine == engine else { return false }
      return ((try? read(credential)) ?? nil)?.isEmpty == false
    }
  }

  /// The Copilot CLI's own GitHub login, which NodRuntime's Copilot engine falls back to
  /// when Nod holds no token. Attributes only, so it raises no Keychain prompt. Never in
  /// the test host, whose sign-in assertions must not depend on this Mac's own login.
  static func copilotCLISignInFound() -> Bool {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
      return false
    }
    return NodClaudeSignIn.genericPasswordExists(service: "copilot-cli")
  }

  func signOut(_ engine: NodEngine) throws {
    for credential in NodCredential.allCases where credential.engine == engine {
      try delete(credential)
    }
  }
}

private final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) { self.value = value }

  func withValue<T>(_ body: (inout Value) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }
}

/// The Claude half of Nod's sign-in.
///
/// Anthropic does not allow third-party products built on the Claude Agent SDK to offer
/// claude.ai login unless Anthropic has approved it
/// (code.claude.com/docs/en/agent-sdk/overview), so "Continue with Claude" and reusing a
/// Claude Code sign-in are built but hidden behind `subscriptionLoginAllowed`. An API
/// key is the path that ships.
enum NodClaudeSignIn {
  static let subscriptionLoginAllowed = false

  enum APIKeyProblem: Error, Equatable {
    case empty
    case notAnAnthropicKey
  }

  /// Trims what was pasted and checks it looks like an Anthropic key, so a GitHub token
  /// pasted into the wrong field is caught here rather than as a 401 mid-turn.
  static func validateAPIKey(_ raw: String) -> Result<String, APIKeyProblem> {
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return .failure(.empty) }
    guard key.hasPrefix("sk-ant-"), key.count > 20, !key.contains(where: \.isWhitespace) else {
      return .failure(.notAnAnthropicKey)
    }
    return .success(key)
  }

  /// Whether Claude Code is signed in on this Mac: its Keychain item exists, or its
  /// credentials file does. Asks for the item's attributes only, never its secret, so it
  /// raises no Keychain prompt.
  static func claudeCodeSignInFound(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    keychainItemExists: (String) -> Bool = genericPasswordExists(service:)
  ) -> Bool {
    if keychainItemExists("Claude Code-credentials") { return true }
    return FileManager.default.fileExists(
      atPath: home.appending(path: ".claude/.credentials.json").path)
  }

  static func genericPasswordExists(service: String) -> Bool {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecReturnAttributes: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
  }
}
