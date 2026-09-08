import GraphcodeKit
import MailroomKit

/// The envelope that marks a loop watching its project's Mailroom, and its tooltip.
///
/// Hidden on a resolved loop: `mailroomWatch` outlives the session that set it, but a
/// loop that has finished for good cannot be rung.
enum MailroomWatchPresentation {
  static let symbolName = "envelope"

  static func showsGlyph(for node: LoopNode) -> Bool { tooltip(for: node) != nil }

  static func tooltip(for node: LoopNode) -> String? {
    guard let watch = node.mailroomWatch, !node.isResolved else { return nil }
    guard let topic = watch.topic else { return "Watching the Mailroom" }
    return "Watching the Mailroom · topic \(topic)"
  }
}
