import Foundation
import Testing

@testable import GraphcodeKit

/// The back/forward stack behind ⌥⌘← / ⌥⌘→ (#154).
///
/// The rules worth pinning are the ones that separate a browser from a ring: a new visit
/// discards the forward branch, a repeat of the current place is not a visit at all, and
/// a step walks past what can no longer be opened instead of dead-ending on it.
@Suite
struct LoopHistoryTests {
  private let alpha = UUID()
  private let papa = UUID()
  private let quebec = UUID()

  private func visit(_ id: UUID, project: String = "/a") -> LoopVisit {
    .loop(projectPath: project, nodeID: id)
  }

  private let anythingResolves: (LoopVisit) -> Bool = { _ in true }

  @Test
  func backAndForwardRetraceTheOrderLoopsWereOpenedIn() {
    // The issue's own example: A, P, Q clicked across different projects, then back to
    // Q -> P -> A and forward again.
    var history = LoopHistory()
    history.record(visit(alpha, project: "/one"))
    history.record(visit(papa, project: "/two"))
    history.record(visit(quebec, project: "/three"))

    #expect(history.current == visit(quebec, project: "/three"))
    #expect(history.back(where: anythingResolves) == visit(papa, project: "/two"))
    #expect(history.back(where: anythingResolves) == visit(alpha, project: "/one"))
    #expect(!history.canGoBack)
    #expect(history.back(where: anythingResolves) == nil)

    #expect(history.forward(where: anythingResolves) == visit(papa, project: "/two"))
    #expect(history.forward(where: anythingResolves) == visit(quebec, project: "/three"))
    #expect(!history.canGoForward)
    #expect(history.forward(where: anythingResolves) == nil)
  }

  @Test
  func openingSomewhereNewDiscardsTheForwardTrail() {
    // What makes this a browser rather than a ring. Go back to A, open Q, and P is gone
    // — the branch was left, exactly as a browser drops forward history on a new
    // navigation.
    var history = LoopHistory()
    history.record(visit(alpha))
    history.record(visit(papa))
    _ = history.back(where: anythingResolves)

    history.record(visit(quebec))

    #expect(history.entries == [visit(alpha), visit(quebec)])
    #expect(!history.canGoForward)
    #expect(history.back(where: anythingResolves) == visit(alpha))
  }

  @Test
  func revisitingALoopAlreadyInTheStackPushesAgain() {
    // Browser-faithful rather than most-recent-wins: A is in the stack twice, so one
    // Back from the second A still lands on Q rather than skipping to P.
    var history = LoopHistory()
    history.record(visit(alpha))
    history.record(visit(papa))
    history.record(visit(quebec))
    history.record(visit(alpha))

    #expect(history.entries == [visit(alpha), visit(papa), visit(quebec), visit(alpha)])
    #expect(history.back(where: anythingResolves) == visit(quebec))
  }

  @Test
  func reopeningTheLoopAlreadyOnScreenIsNotAVisit() {
    // This happens constantly — tapping the selected row, a rename re-selecting its own
    // node — and each one would otherwise pad the stack with a step that goes nowhere.
    var history = LoopHistory()
    history.record(visit(alpha))
    history.record(visit(papa))
    history.record(visit(papa))
    history.record(visit(papa))

    #expect(history.entries == [visit(alpha), visit(papa)])
    #expect(history.back(where: anythingResolves) == visit(alpha))
  }

  @Test
  func aStepWalksPastLoopsThatCanNoLongerBeOpened() {
    // A closed project or a deleted loop must not dead-end the stack. P is gone, so one
    // Back from Q lands on A rather than stopping.
    var history = LoopHistory()
    history.record(visit(alpha))
    history.record(visit(papa))
    history.record(visit(quebec))

    let missingPapa: (LoopVisit) -> Bool = { $0.nodeID != self.papa }
    #expect(history.back(where: missingPapa) == visit(alpha))
    #expect(history.current == visit(alpha))
  }

  @Test
  func anUnreachableEntryIsSteppedOverNotDeleted() {
    // Unreachable is not the same as wrong: the project may well be open again next
    // launch. A history that erased itself on a transient miss would be worse than no
    // history at all.
    var history = LoopHistory()
    history.record(visit(alpha))
    history.record(visit(papa))
    history.record(visit(quebec))

    _ = history.back(where: { $0.nodeID != self.papa })
    #expect(history.entries.contains(visit(papa)))

    // Once its project is back, the entry works again.
    #expect(history.forward(where: anythingResolves) == visit(papa))
  }

  @Test
  func aStepThatFindsNothingReachableLeavesTheCursorAlone() {
    // The alternative — moving anyway — would drop the user somewhere they never were.
    var history = LoopHistory()
    history.record(visit(alpha))
    history.record(visit(papa))

    #expect(history.back(where: { _ in false }) == nil)
    #expect(history.current == visit(papa))
    #expect(history.canGoBack)
  }

  @Test
  func quickChatsShareTheStackWithLoops() {
    // They open the same workspace, so a Back that stepped over the chat you were just
    // in would be a Back that lies.
    let chat = UUID()
    var history = LoopHistory()
    history.record(visit(alpha))
    history.record(.quickChat(id: chat))
    history.record(visit(papa))

    #expect(history.back(where: anythingResolves) == .quickChat(id: chat))
    #expect(history.back(where: anythingResolves) == visit(alpha))
  }

  @Test
  func aDeletedChatIsSteppedOverLikeAnyOtherUnreachableEntry() {
    let chat = UUID()
    var history = LoopHistory()
    history.record(visit(alpha))
    history.record(.quickChat(id: chat))
    history.record(visit(papa))

    #expect(history.back(where: { $0 != .quickChat(id: chat) }) == visit(alpha))
  }

  @Test
  func theStackIsBoundedAndDropsItsOldestEntriesFirst() {
    // A runaway loop of opens must not grow the file without bound; the oldest end is
    // the one nobody is walking back to.
    var history = LoopHistory()
    let ids = (0..<(LoopHistory.limit + 10)).map { _ in UUID() }
    for id in ids { history.record(visit(id)) }

    #expect(history.entries.count == LoopHistory.limit)
    #expect(history.entries.first == visit(ids[10]))
    #expect(history.entries.last == visit(ids[ids.count - 1]))
    #expect(history.current == visit(ids[ids.count - 1]))
  }

  @Test
  func anEmptyHistoryOffersNeitherDirection() {
    let history = LoopHistory()
    #expect(!history.canGoBack)
    #expect(!history.canGoForward)
    #expect(history.current == nil)
  }

  @Test
  func aHistoryRoundTripsThroughItsFile() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-history-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LoopHistoryStore(baseDirectory: directory)

    #expect(store.load() == LoopHistory())

    var history = LoopHistory()
    history.record(visit(alpha, project: "/one"))
    history.record(.quickChat(id: papa))
    history.record(visit(quebec, project: "/three"))
    _ = history.back(where: anythingResolves)
    store.save(history)

    let restored = store.load()
    #expect(restored == history)
    #expect(restored.current == .quickChat(id: papa))
    #expect(restored.canGoForward)
  }

  @Test
  func aCorruptOrOutOfRangeFileDoesNotStrandTheCursor() throws {
    // The file is small, local and hand-editable, and a cursor pointing past the end
    // would crash the walk rather than merely losing history.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-history-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LoopHistoryStore(baseDirectory: directory)

    try Data("not json".utf8)
      .write(to: directory.appendingPathComponent("loop-history.json"))
    #expect(store.load() == LoopHistory())

    let overshot = LoopHistory(entries: [visit(alpha), visit(papa)], cursor: 99)
    #expect(overshot.cursor == 1)
    #expect(!overshot.canGoForward)

    let undershot = LoopHistory(entries: [visit(alpha)], cursor: -5)
    #expect(undershot.cursor == 0)
    #expect(!undershot.canGoBack)

    #expect(LoopHistory(entries: [], cursor: 3).cursor == nil)
  }
}
