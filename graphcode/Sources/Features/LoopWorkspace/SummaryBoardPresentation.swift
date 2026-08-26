import GraphcodeKit
import SwiftUI

/// What the board section says and whether it says anything — worked out once and drawn
/// twice, the same split `LoopSummaryPresentation` makes and for the same reason: the rules
/// about when a picture is worth 460 points of window are assertable without a window.
struct SummaryBoardPresentation: Equatable {
  enum Mode: Equatable {
    /// A working loop that has finished a pass and has no board for it. Honest about
    /// latency for the same reason `LoopSummaryPresentation.starting` is — a person who has
    /// just switched the experiment on needs to see that something is coming.
    case pending
    case drawn
  }

  let mode: Mode
  let board: SummaryBoard?
  /// The pass the board describes, which is not always the pass the loop is on.
  let pass: Int?
  /// Whether the loop has moved on since this was drawn. Not an error and not hidden: a
  /// board is an account of one finished pass, and saying which one is what stops it being
  /// read as a claim about right now.
  let isStale: Bool

  /// Whether the composer is switched on, from the app's own live copy of the settings
  /// file — the same read `LoopSummaryPresentation.isProducing` makes, and no disk on the
  /// render path.
  ///
  /// Both switches, in the same order the daemon asks them: a board is drawn from the
  /// summary, so the picture without the reading behind it would be a drawing of a run
  /// nothing is narrating.
  static var isDrawing: Bool {
    let settings = SettingsModel.shared.settings
    return settings.summarisesLoops && settings.visualisesSummaries
  }

  /// Whether the section has anything worth the space.
  ///
  /// A drawn board always qualifies. A *pending* one qualifies only while the loop is
  /// working: the composer is told to answer `NONE` for a thin pass and most passes are
  /// thin, so a quiet loop with no board has probably been looked at and declined — and a
  /// permanent "nothing yet" on every finished loop is precisely the blank chrome
  /// `LoopWorkspaceRail.hasContent` exists to keep out of the rail.
  static func hasContent(node: LoopNode, drawing: Bool = isDrawing) -> Bool {
    guard drawing else { return false }
    if node.board?.isDrawable == true { return true }
    return isWorking(node) && node.summary?.passes.isEmpty == false
  }

  private static func isWorking(_ node: LoopNode) -> Bool {
    node.presence?.presence == .busy && !node.isResolved
  }

  init(node: LoopNode) {
    let board = node.board?.isDrawable == true ? node.board : nil
    self.board = board
    mode = board == nil ? .pending : .drawn
    pass = board?.pass
    isStale = (node.summary?.currentPass ?? 0) > (board?.pass ?? Int.max)
  }
}
