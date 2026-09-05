import Foundation

/// How an opening prompt and the preambles graphcode wraps around it are ordered.
///
/// Every backend graphcode drives reads a leading `/` as a slash command and anything
/// else as prose, and the prompts graphcode composes are not just the human's text: a
/// session is told where its briefing is (`SessionBriefing.pointer`) and where its wake
/// digest is (`NodeMemory`), both by preamble on the same message. Concatenating those
/// in front is what a preamble usually means, and for prose it is right.
///
/// It is wrong for the two prompt shapes that open with a slash command, and each of
/// those is a whole loop type. A time-based node whose session owns recurrence has a
/// slash-command prompt — `/loop 1h …`. Buried mid-message it is literal text: no
/// schedule is created, the loop runs exactly one pass and sits `idle` forever. Copilot
/// hosts this form of time-based loop and receives its briefing as a preamble, so it got
/// both halves of that and never armed recurrence at all (issue #179). A goal-based node
/// on a backend with `/goal` is the same shape and fails the same way — the directive
/// that arms the stop check would be typed as prose and nothing would be armed.
///
/// So the preamble trails a prompt that opens with a directive and leads one that doesn't.
/// Trailing costs nothing: `/loop <interval> <task>` takes the rest of the line as the
/// task, so the pointer travels into every scheduled pass rather than only the first.
/// `/goal <condition>` takes the rest of the line too, so a trailing pointer becomes part
/// of the condition — worth knowing, and still the right side: a condition carrying one
/// extra instruction the session discharges immediately beats a directive that never ran.
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

  /// The recurrence a `/loop <interval> <task>` directive describes — the interval token
  /// exactly as written and the task behind it — or `nil` for anything else. The token
  /// stays a string because its consumer repeats it back to the agent verbatim.
  public static func recurrence(of prompt: String) -> (interval: String, task: String)? {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    for directive in recurringDirectives where trimmed.hasPrefix("\(directive) ") {
      let afterDirective = trimmed.dropFirst(directive.count).drop { $0 == " " }
      let interval = afterDirective.prefix { $0 != " " }
      let task = afterDirective.dropFirst(interval.count)
        .trimmingCharacters(in: .whitespaces)
      guard !interval.isEmpty, !task.isEmpty else { return nil }
      return (String(interval), task)
    }
    return nil
  }

  public static func intervalSeconds(_ interval: String) -> Double? {
    let trimmed = interval.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return nil }
    let number =
      trimmed.last.map { "smhd".contains($0) ? String(trimmed.dropLast()) : trimmed } ?? trimmed
    guard let value = Double(number), value.isFinite, value > 0 else { return nil }
    switch trimmed.last {
    case "s": return value
    case "h": return value * 3600
    case "d": return value * 86400
    default: return value * 60
    }
  }

  /// Whether the prompt involves a recurring directive at all — leading or mentioned —
  /// which is what decides Copilot's `--experimental` flag: the session needs `/every`
  /// available whether the directive opens the message or the message asks the agent to
  /// arm it.
  public static func mentionsRecurrence(_ prompt: String) -> Bool {
    recurringDirectives.contains { prompt.contains($0) }
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
