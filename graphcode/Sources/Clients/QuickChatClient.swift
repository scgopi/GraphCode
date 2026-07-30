import Dependencies
import Foundation
import GraphcodeKit

/// Retroactive `DependencyKey` conformance for `GraphcodeKit`'s `QuickChatStore` —
/// here rather than in `GraphcodeKit` for the same reason as `TerminalLayoutStore`'s:
/// `GraphcodeKit` never imports `Dependencies`, and quick chats are app-UI-only.
extension QuickChatStore: DependencyKey {
  public static let liveValue = QuickChatStore(baseDirectory: SupportDirectory.url)
}

extension DependencyValues {
  var quickChatStore: QuickChatStore {
    get { self[QuickChatStore.self] }
    set { self[QuickChatStore.self] = newValue }
  }
}
