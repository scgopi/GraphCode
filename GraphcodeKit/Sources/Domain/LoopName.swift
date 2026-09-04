import Foundation

/// The one-word shape every loop name on a canvas has. A name is read in a sidebar row
/// and a card header, where one word carries further, so two concepts join in CamelCase
/// — "BoardVisibility" — instead of spending a space on them.
///
/// The backend namer asks for that shape and folds what it gets back
/// (`TitleSuggestionClient.sanitize`). This is the same fold applied where a name arrives
/// already written: `--title` on the CLI, typed by a loop fanning work out, where telling
/// is all the instruction can do.
public enum LoopName {
  /// `nil` when nothing alphanumeric survives, which is the caller's cue to keep whatever
  /// it was given rather than create a nameless card.
  public static func folded(_ raw: String) -> String? {
    let words =
      raw
      .split(whereSeparator: { $0.isWhitespace })
      .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
      .filter { !$0.isEmpty }
    guard !words.isEmpty else { return nil }
    return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
  }
}
