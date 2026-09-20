import Foundation

/// An image a human dropped into the New Node dialog, and where it landed on disk.
///
/// **The image itself can never travel.** `zmx` starts a session by *typing* its launch
/// command into a PTY (`SessionBriefing`), so everything a loop opens with is text on a
/// line — a canonical-mode tty at that, which drops whatever runs past `MAX_CANON`. What
/// does travel is the path, and every backend graphcode drives can open one: `codex` and
/// `pi` have a flag for it, and the rest read the file with their own tools once the
/// prompt names it.
///
/// So the form writes the bytes down once, beside the node's memory
/// (`NodeMemory.attachmentsDirectory`), and the prompt carries the path. The node id is
/// chosen by the client (`NodeDraft.id`), which is what makes that possible before the
/// node exists.
///
/// Local graphs only. A remote project's session runs on another machine, and the ensure
/// dial that delivers graphcode's files there carries text (`remoteDeliveryScript`) — a
/// path to a file that host has never seen would read to the agent as a missing file.
public struct PromptAttachment: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  /// Absolute, on the machine that runs the loop.
  public var path: String

  public init(id: UUID = UUID(), path: String) {
    self.id = id
    self.path = path
  }

  public var fileName: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// How an attachment's path gets into the sentence a human wrote.
///
/// The human never types or sees a path: `[image #1]` stands in its place in the field,
/// and the token is swapped for the path when the prompt is composed
/// (`LoopNode.sessionPrompt`). That keeps the picture where the sentence wanted it —
/// "compare `[image #1]` with the current header" — rather than in a list at the end
/// that the agent has to guess the intent of.
public enum PromptAttachments {
  /// The placeholder for the `number`-th attachment, 1-based. ASCII and unmistakable:
  /// it has to survive a round trip through a text field, argv, and a typed command
  /// line, and it must not collide with anything a person would write by hand.
  public static func token(_ number: Int) -> String { "[image #\(number)]" }

  /// `text` with every `[image #N]` replaced by the N-th attachment's path, and any
  /// attachment the text never named stated at the end.
  ///
  /// The trailer keeps plain words on both sides of every path, for the reason
  /// `NodeMemory.promptPointer` does: this string rides argv, `zmx`'s typed command
  /// line and sometimes ssh, and punctuation touching a path has eaten a file extension
  /// before.
  public static func resolving(
    _ text: String?, attachments: [PromptAttachment]
  ) -> String? {
    guard !attachments.isEmpty else { return text }
    var resolved = text ?? ""
    var unnamed: [String] = []
    for (offset, attachment) in attachments.enumerated() {
      let placeholder = token(offset + 1)
      if resolved.contains(placeholder) {
        resolved = resolved.replacingOccurrences(of: placeholder, with: attachment.path)
      } else {
        unnamed.append(attachment.path)
      }
    }
    guard !unnamed.isEmpty else { return resolved }
    let trailer =
      unnamed.count == 1
      ? "An image for this task is at \(unnamed[0]) - open it before you start."
      : "Images for this task are at \(unnamed.joined(separator: " and ")) "
        + "- open them before you start."
    let body = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
    return body.isEmpty ? trailer : body + " " + trailer
  }

  /// `text` with the `number`-th placeholder dropped and every later one renumbered, so
  /// removing the middle chip of three doesn't leave `[image #3]` pointing at nothing.
  public static func removing(attachment number: Int, from text: String, of count: Int)
    -> String
  {
    var result = text.replacingOccurrences(of: token(number), with: "")
    var later = number + 1
    while later <= count {
      result = result.replacingOccurrences(of: token(later), with: token(later - 1))
      later += 1
    }
    while result.contains("  ") {
      result = result.replacingOccurrences(of: "  ", with: " ")
    }
    return result.trimmingCharacters(in: .whitespaces)
  }
}
