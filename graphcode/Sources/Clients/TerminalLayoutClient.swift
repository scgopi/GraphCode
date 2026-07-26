import Dependencies
import Foundation
import GraphcodeKit

/// Retroactive `DependencyKey` conformance for `GraphcodeKit`'s `TerminalLayoutStore` —
/// lives here, not in `GraphcodeKit`, because `GraphcodeKit` never imports
/// `Dependencies` (it's linked into the plain `graphcoded` daemon target too, and this
/// dependency is app-UI-only anyway).
extension TerminalLayoutStore: DependencyKey {
  public static let liveValue = TerminalLayoutStore(
    baseDirectory: FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("graphcode", isDirectory: true)
  )
}

extension DependencyValues {
  var terminalLayoutStore: TerminalLayoutStore {
    get { self[TerminalLayoutStore.self] }
    set { self[TerminalLayoutStore.self] = newValue }
  }
}
