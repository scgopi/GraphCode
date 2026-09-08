import GraphcodeKit
import MailroomKit

/// The quiet mark for a loop that is watching its project's Mailroom: an outline
/// envelope on the sidebar row and the canvas card, and a tooltip that says what it
/// is listening for. Nothing more — no count, no unread dot, no colour. The watch is
/// a standing subscription, and the mark only says one exists.
///
/// Hidden on a resolved loop. `mailroomWatch` outlives the session that set it, but a
/// loop that has finished for good cannot be rung, and a glyph promising otherwise
/// would be the card claiming a mailbox that nobody will open.
enum MailroomWatchPresentation {
  static let symbolName = "envelope"

  static func showsGlyph(for node: LoopNode) -> Bool { tooltip(for: node) != nil }

  /// `"Watching the Mailroom"`, or with `· topic <t>` when the watch is narrowed to one;
  /// `nil` when there is nothing to draw.
  static func tooltip(for node: LoopNode) -> String? {
    guard let watch = node.mailroomWatch, !node.isResolved else { return nil }
    guard let topic = watch.topic else { return "Watching the Mailroom" }
    return "Watching the Mailroom · topic \(topic)"
  }
}
