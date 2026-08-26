import Dependencies
import Foundation
import GraphcodeKit

/// Retroactive `DependencyKey` conformance for `GraphcodeKit`'s `LoopHistoryStore` —
/// here rather than in `GraphcodeKit` for the same reason as `QuickChatStore`'s:
/// `GraphcodeKit` never imports `Dependencies`, and where a human has been is app-UI-only.
extension LoopHistoryStore: DependencyKey {
  public static let liveValue = LoopHistoryStore(baseDirectory: SupportDirectory.url)

  /// A throwaway directory per access, so the dozens of tests that merely *open a loop*
  /// on their way to asserting something else don't each have to override this — and so
  /// none of them can read or write the developer's own history file.
  public static var testValue: LoopHistoryStore {
    LoopHistoryStore(
      baseDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("graphcode-history-tests-\(UUID().uuidString)", isDirectory: true))
  }
}

extension DependencyValues {
  var loopHistoryStore: LoopHistoryStore {
    get { self[LoopHistoryStore.self] }
    set { self[LoopHistoryStore.self] = newValue }
  }
}
