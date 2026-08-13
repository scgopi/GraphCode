import Foundation

/// Turns one session's transcript into intent beats, for whichever backend wrote it.
///
/// **Why there is no model here.** The obvious way to narrate a loop is to summarise its
/// scrollback with a small model, and that costs money per loop per poll, has to be
/// bounded, cached and kept out of the loop's own budget line, and can be confidently
/// wrong — which the design is explicit is worse than the scrollback it replaced. All
/// three backends already write the sentence: Claude Code emits a text block before the
/// tool calls it is about to make, Codex an `agent_reasoning` with a bolded header, Copilot
/// an `assistant.message` alongside its `toolRequests`. That narration *is* the shift in
/// intent, in the agent's own words, and it is already on disk. So a beat costs a tail read
/// of a file graphcode is already reading for `activity`, and nothing is generated.
///
/// Feed events in transcript order and take `beats()` at the end. The builder holds the
/// three rules the design puts on the daemon: a beat is a shift (a new narration closes the
/// open beat, twenty greps in a row do not), it is under ten words (`condense`), and it
/// cites what it came from (`evidence`).
struct SummaryBeatBuilder {
  /// The narration and calls of one beat, before it is closed.
  private struct Open {
    var at: Date
    var pass: Int
    var text: String?
    var phrases: [String] = []
  }

  private var pass = 0
  private var open: Open?
  private var closed: [SummaryBeat] = []

  /// A user turn — a human typing, or a `/loop` waking the session. Either way it is the
  /// boundary the design rolls passes up at.
  mutating func noteUserTurn(at date: Date) {
    close()
    pass += 1
  }

  /// The agent saying what it is about to do. Closes whatever beat was open: this is the
  /// shift.
  mutating func noteNarration(_ raw: String, at date: Date) {
    guard let text = Self.condense(raw) else { return }
    close()
    open = Open(at: date, pass: max(pass, 1), text: text)
  }

  /// One tool call, in the phrase its backend reader already speaks — `"editing
  /// Foo.swift"`, `"running make check"`.
  ///
  /// Calls attach to the open beat rather than making one. A beat that never got a
  /// narration takes the first phrase as its own text: that is the tool call restated, not
  /// a summary invented over it, and it is exactly what `LoopNode.activity` has always put
  /// on the card.
  mutating func noteTool(_ phrase: String, at date: Date) {
    let clean = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    if open == nil { open = Open(at: date, pass: max(pass, 1)) }
    open?.phrases.append(clean)
  }

  mutating func close() {
    guard let open, open.text != nil || !open.phrases.isEmpty else {
      self.open = nil
      return
    }
    let kind = Self.kind(text: open.text, phrases: open.phrases)
    let text = open.text ?? Self.sentence(fromPhrase: open.phrases[0])
    closed.append(
      SummaryBeat(
        id: Self.identifier(pass: open.pass, at: open.at),
        at: open.at,
        pass: open.pass,
        kind: kind,
        text: text,
        evidence: Self.evidence(kind: kind, phrases: open.phrases)))
    self.open = nil
  }

  /// Every beat read, oldest first, including the one still open — a session mid-call is
  /// the case the rail exists for, so the current beat must not wait for the next
  /// narration to appear.
  mutating func beats() -> [SummaryBeat] {
    close()
    return closed
  }

  /// How many user turns the window saw. `LoopSummary` reads passes off the beats
  /// themselves; this is here for a reader that wants to know whether it saw the start.
  var passCount: Int { pass }

  // MARK: - Text

  /// Stable across polls: the same record read twice is the same beat. Position in the
  /// file would not be — the tail window moves as the session grows.
  static func identifier(pass: Int, at date: Date) -> String {
    "p\(pass)-\(Int(date.timeIntervalSince1970 * 1000))"
  }

  /// Openers that carry no intent, so the beat starts at the verb.
  private static let fillers = [
    "now", "okay", "ok", "alright", "right", "great", "perfect", "good", "so", "next",
  ]

  /// A narration turned into a beat: one sentence, under ten words, or nothing.
  ///
  /// Codex's reasoning arrives as `**Planning code mode inspection**\n\nI'm preparing to…`
  /// — the bolded header is already a beat and the paragraph under it is already too long,
  /// so the header wins where there is one. Everything else takes its first sentence.
  ///
  /// Nothing here rewrites the agent's words beyond dropping a leading filler and cutting
  /// at ten. Rephrasing into the design's past tense would mean generating a sentence the
  /// session never said, which is the one thing a derived beat must not do.
  static func condense(_ raw: String) -> String? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if let header = boldHeader(of: text) { text = header }
    text = firstSentence(of: text)
    text = stripLeadingFiller(text)
    guard text.count >= 3 else { return nil }
    return truncate(text, words: 10, characters: 64)
  }

  /// `**Planning code mode inspection**` → `Planning code mode inspection`, but only when
  /// the whole first line is one.
  static func boldHeader(of text: String) -> String? {
    guard let line = text.split(separator: "\n").first else { return nil }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("**"), trimmed.hasSuffix("**"), trimmed.count > 4 else { return nil }
    let inner = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
    return inner.isEmpty ? nil : inner
  }

  static func firstSentence(of text: String) -> String {
    let line = text.split(separator: "\n").first.map(String.init) ?? text
    var sentence = line
    // `. ` rather than `.`: a sentence about `UsageProbe.swift` must not stop at the
    // extension, which is the whole evidence the beat is carrying.
    for terminator in [". ", "! ", "? "] {
      if let range = sentence.range(of: terminator) {
        sentence = String(sentence[sentence.startIndex..<range.lowerBound])
      }
    }
    if sentence.hasSuffix(".") || sentence.hasSuffix(":") { sentence.removeLast() }
    return sentence.trimmingCharacters(in: .whitespaces)
  }

  static func stripLeadingFiller(_ text: String) -> String {
    var words = text.split(separator: " ").map(String.init)
    while let first = words.first {
      let bare = first.trimmingCharacters(in: CharacterSet(charactersIn: ",.!—-"))
      guard fillers.contains(bare.lowercased()), words.count > 2 else { break }
      words.removeFirst()
    }
    guard var rebuilt = words.first else { return text }
    // Capitalising only the first character leaves `UsageProbe` and `I'll` alone; a
    // `capitalized` would lowercase every one of them.
    rebuilt = rebuilt.prefix(1).uppercased() + rebuilt.dropFirst()
    return ([rebuilt] + words.dropFirst()).joined(separator: " ")
  }

  static func truncate(_ text: String, words limit: Int, characters: Int) -> String {
    var result = text
    let parts = result.split(separator: " ")
    if parts.count > limit { result = parts.prefix(limit).joined(separator: " ") + "…" }
    if result.count > characters {
      result = String(result.prefix(characters)).trimmingCharacters(in: .whitespaces) + "…"
    }
    return result
  }

  /// A tool phrase as a beat of its own — `"editing Foo.swift"` → `"Editing Foo.swift"`.
  static func sentence(fromPhrase phrase: String) -> String {
    truncate(
      phrase.prefix(1).uppercased() + phrase.dropFirst(), words: 10, characters: 64)
  }

  // MARK: - Kind and evidence

  /// Past-tense openers that mean the beat is a finding rather than a step. Small and
  /// literal on purpose: a finding gets a green dot, and a dot that lights up for every
  /// third beat says nothing.
  private static let findingOpeners = [
    "found", "turns out", "confirmed", "the bug", "the issue", "root cause", "spotted",
    "identified", "the cause", "fixed",
  ]

  /// What the beat mostly was. An edit outranks the reads that led to it — a pass that
  /// read five files and changed one is an edit, and that is the shape the dots are meant
  /// to show.
  static func kind(text: String?, phrases: [String]) -> BeatKind {
    if let text {
      let lowered = text.lowercased()
      if findingOpeners.contains(where: { lowered.hasPrefix($0) }) { return .found }
    }
    let kinds = phrases.map(BeatKind.inferred(fromPhrase:))
    for candidate in [BeatKind.editing, .running, .reading] where kinds.contains(candidate) {
      return candidate
    }
    return .thinking
  }

  /// `"UsageProbe.swift · 3 files read"` — what the beat came from, one line.
  ///
  /// The target is the first call's, not the last: the beat is named for what it opened
  /// on, and the count says how far it went. A beat with no calls under it has nothing to
  /// cite and says nothing rather than something vague.
  static func evidence(kind: BeatKind, phrases: [String]) -> String? {
    guard let first = phrases.first else { return nil }
    let target = target(ofPhrase: first)
    guard phrases.count > 1 else { return target }
    let noun: String
    switch kind {
    case .reading: noun = phrases.count == 1 ? "file read" : "files read"
    case .editing: noun = "edits"
    case .running: noun = "commands"
    default: noun = "steps"
    }
    return "\(target) · \(phrases.count) \(noun)"
  }

  /// The object of a phrase — `"editing UsageProbe.swift"` → `"UsageProbe.swift"`. The
  /// verb is already said by the kind row above it, so repeating it costs a line the rail
  /// does not have.
  ///
  /// Two words of verb where the readers speak two: `searching for X` and `looking for X`
  /// leave a dangling "for" otherwise, which reads as a truncation bug rather than as
  /// evidence.
  static func target(ofPhrase phrase: String) -> String {
    var words = phrase.split(separator: " ").map(String.init)
    guard words.count > 1 else { return phrase }
    words.removeFirst()
    while let first = words.first, ["for", "the", "web"].contains(first.lowercased()),
      words.count > 1
    {
      words.removeFirst()
    }
    let object = words.joined(separator: " ")
    return truncate(object.trimmingCharacters(in: .whitespaces), words: 6, characters: 34)
  }

  // MARK: - Reading a transcript

  /// How much of a transcript's tail is enough to see the current pass and the one before
  /// it. Bigger than the activity readers' windows because those need only the last tool
  /// call, and this needs the narration that opened the pass.
  static let tailBytes = 512 * 1024

  /// The tail of a JSONL transcript, as whole lines.
  ///
  /// The first line of a mid-file read is a fragment and is dropped rather than repaired —
  /// one record's worth of tail is nowhere near this window.
  static func tailLines(of url: URL, bytes: Int = SummaryBeatBuilder.tailBytes) -> [Substring] {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    guard let end = try? handle.seekToEnd() else { return [] }
    let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
    try? handle.seek(toOffset: start)
    guard let data = try? handle.readToEnd() else { return [] }
    var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
    if start > 0, !lines.isEmpty { lines.removeFirst() }
    return lines
  }

  /// ISO-8601 with fractional seconds, which is what all three backends stamp records
  /// with. A record whose timestamp doesn't parse takes the reader's fallback rather than
  /// being dropped: a beat with an approximate time still says what the loop is doing.
  static let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  static func date(fromTimestamp raw: Any?) -> Date? {
    guard let text = raw as? String else { return nil }
    if let date = timestampFormatter.date(from: text) { return date }
    return ISO8601DateFormatter().date(from: text)
  }

  /// Folds beats into the reading the store merges: the newest pass's beats, and one line
  /// per finished pass before it.
  ///
  /// A pass's summary is its **last** beat — what it ended up doing, which is the honest
  /// one-line account of a pass and the only one available without generating a sentence.
  static func reading(from beats: [SummaryBeat], deltas: [Int: String] = [:]) -> SummaryReading {
    guard let newest = beats.map(\.pass).max() else { return SummaryReading(beats: []) }
    let finished = Dictionary(grouping: beats.filter { $0.pass < newest }, by: \.pass)
      .compactMap { pass, passBeats -> PassSummary? in
        guard let last = passBeats.max(by: { $0.at < $1.at }) else { return nil }
        return PassSummary(pass: pass, text: last.text, delta: deltas[pass])
      }
      .sorted { $0.pass < $1.pass }
    return SummaryReading(
      beats: beats.filter { $0.pass == newest }, finishedPasses: finished)
  }
}
