import Foundation

/// How an opening prompt and the preambles graphcode wraps around it are ordered.
///
/// Every backend graphcode drives reads a leading `/` as a slash command and anything
/// else as prose, and the prompts graphcode composes are not just the human's text: a
/// session is told where its briefing is (`SessionBriefing.pointer`) and where its wake
/// digest is (`NodeMemory`), both by preamble on the same message. Concatenating those
/// in front is what a preamble usually means, and for prose it is right.
///
/// It is wrong for exactly one prompt shape, and that shape is a whole loop type. A
/// time-based node's prompt *is* a slash command — `/loop 1h …`, the directive that makes
/// the session re-trigger itself, since graphcode holds no timer of its own
/// (`ZmxSessionLauncher`). Buried mid-message it is literal text: no schedule is created,
/// the loop runs exactly one pass and sits `idle` forever. Copilot hosts time-based loops
/// and receives its briefing as a preamble, so it got both halves of that and never armed
/// recurrence at all (issue #179).
///
/// So the preamble trails a prompt that opens with a directive and leads one that doesn't.
/// Trailing costs nothing: `/loop <interval> <task>` takes the rest of the line as the
/// task, so the pointer travels into every scheduled pass rather than only the first.
public enum SessionPrompt {
  /// Whether `prompt` opens with something its backend will read as a command rather than
  /// prose. A leading `/` is the whole test — a prompt that opens with an absolute path
  /// matches too, and trailing the preamble there is merely a different word order.
  public static func opensWithDirective(_ prompt: String) -> Bool {
    prompt.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
  }

  /// The recurring directives a session's own scheduler understands. Copilot's `/loop`
  /// is an alias of `/every`; both take an interval and then the prompt to submit.
  static let recurringDirectives = ["/loop", "/every"]

  /// The task inside a `/loop <interval> …` directive — everything the schedule will
  /// submit, without the directive that schedules it. `nil` when the prompt is not one.
  ///
  /// What it is for: `/every` submits its prompt *after* the first interval elapses, so
  /// arming an hourly loop does nothing at all for an hour. Sending this text as an
  /// ordinary message gives the session the pass now that the schedule will not give
  /// until later (`ZmxSessionLauncher`).
  public static func firstPass(of prompt: String) -> String? {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    for directive in recurringDirectives where trimmed.hasPrefix("\(directive) ") {
      let afterDirective = trimmed.dropFirst(directive.count).drop { $0 == " " }
      // The interval is one token; everything past it is the prompt the schedule carries.
      guard let interval = afterDirective.firstIndex(of: " ") else { return nil }
      let task = afterDirective[afterDirective.index(after: interval)...]
        .trimmingCharacters(in: .whitespaces)
      return task.isEmpty ? nil : task
    }
    return nil
  }

  /// `prompt` with `preamble` on whichever side keeps a leading directive leading.
  public static func composed(preamble: String, prompt: String) -> String {
    guard opensWithDirective(prompt) else { return "\(preamble) \(prompt)" }
    let directive = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    // A sentence boundary the human's task text can't be relied on to bring: without it
    // "…check the queue Before anything else, read…" reads as one run-on instruction.
    let separator = directive.last.map { ".!?".contains($0) } == true ? " " : ". "
    return "\(directive)\(separator)\(preamble)"
  }
}
