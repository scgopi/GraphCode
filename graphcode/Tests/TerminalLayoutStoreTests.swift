import Foundation
import GraphcodeKit
import Testing

/// Per-loop terminal workspace follow-up (docs/07-roadmap.md): `TerminalLayoutStore`
/// is what makes a loop's tabs/splits look the same the next time it's opened, even
/// after the app quits. Exercised against a throwaway temp directory, never the app's
/// real Application Support folder.
@Suite
struct TerminalLayoutStoreTests {
  private func makeStore() -> TerminalLayoutStore {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    return TerminalLayoutStore(baseDirectory: directory)
  }

  @Test
  func loadingBeforeAnySaveReturnsNil() {
    let store = makeStore()
    #expect(store.load(forNode: UUID()) == nil)
  }

  @Test
  func savingAndLoadingALayoutRoundTrips() {
    let store = makeStore()
    let nodeID = UUID()
    let layout = TerminalLayout.defaultLayout(forNode: nodeID)

    store.save(layout, forNode: nodeID)
    let loaded = store.load(forNode: nodeID)

    #expect(loaded == layout)
  }

  @Test
  func savingTwiceOverwritesRatherThanAppending() {
    let store = makeStore()
    let nodeID = UUID()
    var layout = TerminalLayout.defaultLayout(forNode: nodeID)
    store.save(layout, forNode: nodeID)

    layout.tabs.append(TabLayout(primary: SurfaceRef(id: UUID(), launchesClaudeCode: false)))
    store.save(layout, forNode: nodeID)

    #expect(store.load(forNode: nodeID)?.tabs.count == 2)
  }

  @Test
  func defaultLayoutsPrimarySurfaceReusesTheNodeID() {
    let nodeID = UUID()
    let layout = TerminalLayout.defaultLayout(forNode: nodeID)
    #expect(layout.tabs.first?.primary.id == nodeID)
    #expect(layout.tabs.first?.primary.launchesClaudeCode == true)
  }
}
