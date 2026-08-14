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
    var endsTurn = false
  }

  private var pass = 0
  private var open: Open?
  private var closed: [SummaryBeat] = []
  private var turns: [Date] = []

  /// A user turn — a human typing, or a `/loop` waking the session. Either way it is the
  /// boundary the design rolls passes up at.
  ///
  /// The pass it opens is one past whatever came before it *in this window*, and a window
  /// that starts mid-run has a partial pass in front of its first turn. Counting that
  /// partial as the same pass as the turn that ends it was the older reading, and it put
  /// the previous pass's beats on the current pass's rail. These numbers are still only
  /// relative to the window — `LoopSummary.merge` is what turns them into the number a
  /// person reads.
  mutating func noteUserTurn(at date: Date) {
    close()
    turns.append(date)
    pass = max(pass, closed.isEmpty ? 0 : 1) + 1
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
  /// The backend saying this turn is over: Claude Code's `stop_reason: end_turn`,
  /// Copilot's `assistant.turn_end`, Codex's `task_complete`.
  ///
  /// Marks the beat the record belongs to — the open one, or the last closed one when the
  /// record that ended the turn carried nothing a beat is made of (Claude stamps
  /// `end_turn` on a bare thinking block too). Anything narrated afterwards opens a fresh
  /// beat, which starts un-ended, so this cannot stick to a session that went back to
  /// work.
  mutating func noteTurnEnd() {
    if open != nil {
      open?.endsTurn = true
    } else if let last = closed.indices.last {
      closed[last] = closed[last].endingTurn()
    }
  }

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
        id: identifier(at: open.at),
        at: open.at,
        pass: open.pass,
        kind: kind,
        text: text,
        evidence: Self.evidence(kind: kind, phrases: open.phrases),
        endsTurn: open.endsTurn))
    self.open = nil
  }

  /// Every beat read, oldest first, including the one still open — a session mid-call is
  /// the case the rail exists for, so the current beat must not wait for the next
  /// narration to appear.
  mutating func beats() -> [SummaryBeat] {
    close()
    return closed
  }

  /// When each user turn in the window happened, oldest first — what `LoopSummary.merge`
  /// counts absolute passes with.
  mutating func userTurns() -> [Date] {
    turns
  }

  // MARK: - Text

  /// Stable across polls: the same record read twice is the same beat.
  ///
  /// The beat's own instant, and **not** its pass — the pass a window thinks a beat is on
  /// moves as the tail slides past the turn that opened it, and an id that moved with it
  /// re-animated every row in the rail and lost the `SINCE YOU LOOKED` watermark every
  /// time. Position in the file would not be stable either, for the same reason.
  ///
  /// Two beats can share a millisecond, so a repeat takes a suffix; that is stable too, as
  /// long as the window still holds the first of the pair.
  private mutating func identifier(at date: Date) -> String {
    let base = "b-\(Int(date.timeIntervalSince1970 * 1000))"
    var candidate = base
    var repeats = 1
    while closed.contains(where: { $0.id == candidate }) {
      repeats += 1
      candidate = "\(base)-\(repeats)"
    }
    return candidate
  }

  /// Openers that carry no intent, so the beat starts at the verb.
  private static let fillers = [
    "now", "okay", "ok", "alright", "right", "great", "perfect", "good", "so", "next",
  ]

  /// A narration turned into a beat: one sentence, under sixteen words, or nothing.
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
    // Before the sentence is cut, so a link's own dots and slashes cannot be mistaken for
    // where the sentence ends.
    text = stripLinks(text)
    text = firstSentence(of: text)
    text = stripMarkdown(text)
    text = stripLeadingFiller(text)
    guard text.count >= 3 else { return nil }
    return truncate(text, words: 16, characters: 118)
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

  /// The opening sentence, or the first two when the opening one is a fragment.
  ///
  /// "Clean. Rebuilding Release and reinstalling" is one beat, not two, and stopping at the
  /// full stop put the word `Clean` alone in the rail with the useful half discarded —
  /// seen on a real loop. Under three words is the test: a verdict like that is a preamble
  /// to the sentence that says what is being done, and the pair still fits the ten-word
  /// budget.
  static func firstSentence(of text: String) -> String {
    let line = text.split(separator: "\n").first.map(String.init) ?? text
    let sentences = split(intoSentences: line)
    guard var sentence = sentences.first else { return "" }
    if sentence.split(separator: " ").count < 3, sentences.count > 1 {
      sentence = "\(sentence). \(sentences[1])"
    }
    if sentence.hasSuffix(".") || sentence.hasSuffix(":") { sentence.removeLast() }
    return sentence.trimmingCharacters(in: .whitespaces)
  }

  /// Sentences, cut on `. ` rather than `.` — a sentence about `UsageProbe.swift` must not
  /// stop at the extension, which is the whole evidence the beat is carrying.
  static func split(intoSentences line: String) -> [String] {
    var sentences: [String] = []
    var rest = Substring(line)
    while let range = earliestRange(of: [". ", "! ", "? "], in: rest) {
      sentences.append(String(rest[rest.startIndex..<range.lowerBound]))
      rest = rest[range.upperBound...]
    }
    sentences.append(String(rest))
    return sentences.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  /// `[@cgopireddy](https://www.threads.com/@cgopireddy)` → `@cgopireddy`.
  ///
  /// Read off a real transcript, where the URL reached the rail and took the whole line
  /// with it: the words a beat gets are the label, and the address is not one of them.
  /// Each pass shortens the string, so the loop cannot run away on nested brackets.
  static func stripLinks(_ text: String) -> String {
    var result = text
    while let range = result.range(of: #"\[[^\]\n]*\]\([^)\n]*\)"#, options: .regularExpression) {
      let match = result[range]
      let label = match.dropFirst().prefix { $0 != "]" }
      result.replaceSubrange(range, with: label)
    }
    return result
  }

  /// The rail draws plain text, and agents narrate in markdown.
  ///
  /// Measured on a real transcript rather than guessed at: a line that is *entirely* bold
  /// is caught by `boldHeader`, but a bold **run** inside a longer sentence is not, and its
  /// asterisks were reaching the rail. Emphasis and code spans are dropped; the words
  /// inside them are the beat.
  ///
  /// A lone `*` or `_` is left alone: `total_tokens` and a glob are far commoner in this
  /// vocabulary than single-character emphasis, and stripping them would corrupt the one
  /// thing a beat has to get right — the name it is citing.
  static func stripMarkdown(_ text: String) -> String {
    var result = text
    for token in ["**", "__", "`"] {
      result = result.replacingOccurrences(of: token, with: "")
    }
    while result.hasPrefix("#") || result.hasPrefix(">") {
      result = String(result.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    return result.trimmingCharacters(in: .whitespaces)
  }

  /// The earliest of several terminators, so sentences are cut in the order they appear
  /// rather than in the order the list happens to be written.
  static func earliestRange(of terminators: [String], in text: Substring) -> Range<
    Substring.Index
  >? {
    terminators.compactMap { text.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
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

  /// Cut to the budget — between words, and preferably where a clause ends.
  ///
  /// A character cut through the middle of a word — `Threads/Instagr…` — reads as a
  /// rendering fault rather than as a summary, which is the impression the whole rail is
  /// trying not to give. And a word cut mid-thought — `…landed and the…` — reads as a
  /// dropped message, the complaint that raised the budget: when a clause closes past
  /// sixty percent of what survived the cut, the beat ends there instead, so the
  /// ellipsis only ever admits a *further* thought existed rather than beheading the
  /// one on screen.
  static func truncate(_ text: String, words limit: Int, characters: Int) -> String {
    var cut = text
    var truncated = false
    let parts = cut.split(separator: " ")
    if parts.count > limit {
      cut = parts.prefix(limit).joined(separator: " ")
      truncated = true
    }
    if cut.count > characters {
      truncated = true
      cut = String(cut.prefix(characters))
      if let space = cut.lastIndex(of: " "),
        cut.distance(from: cut.startIndex, to: space) > characters / 2
      {
        cut = String(cut[cut.startIndex..<space])
      }
    }
    guard truncated else { return cut }
    cut = endingOnAClause(cut)
    // However the cut landed, a beat must not end on the word that promised more —
    // "…disk image and…" is the mid-thought impression all of this exists to avoid.
    var words = cut.split(separator: " ").map(String.init)
    while let last = words.last,
      ["and", "but", "so", "then", "or", "while", "with", "—", "the", "a", "an", "to"]
        .contains(last.lowercased())
    {
      words.removeLast()
    }
    cut = words.joined(separator: " ")
    while let last = cut.last, ",;:—".contains(last) { cut.removeLast() }
    return cut.trimmingCharacters(in: .whitespaces) + "…"
  }

  /// The prefix up to the last clause boundary, when one closes past sixty percent of
  /// the text — otherwise the text unchanged.
  private static func endingOnAClause(_ text: String) -> String {
    let separators = [" — ", "; ", ", ", " and ", " but ", " so ", " then "]
    var best: String.Index?
    for separator in separators {
      var search = text.startIndex..<text.endIndex
      while let range = text.range(of: separator, range: search) {
        if best.map({ range.lowerBound > $0 }) ?? true { best = range.lowerBound }
        search = range.upperBound..<text.endIndex
      }
    }
    guard let boundary = best,
      text.distance(from: text.startIndex, to: boundary) * 5 > text.count * 3
    else { return text }
    return String(text[text.startIndex..<boundary])
  }

  /// A tool phrase as a beat of its own — `"editing Foo.swift"` → `"Editing Foo.swift"`.
  static func sentence(fromPhrase phrase: String) -> String {
    truncate(
      phrase.prefix(1).uppercased() + phrase.dropFirst(), words: 16, characters: 118)
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
  ///
  /// **The first call *of the beat's own kind*.** A beat that greps twice and then writes a
  /// file is an edit, and naming it after the grep put a search string under the word
  /// EDITING — observed on a real transcript, and it reads as a bug in the rail rather than
  /// as evidence.
  static func evidence(kind: BeatKind, phrases: [String]) -> String? {
    let matching = phrases.filter { BeatKind.inferred(fromPhrase: $0) == kind }
    let counted = matching.isEmpty ? phrases : matching
    guard let first = counted.first else { return nil }
    let target = target(ofPhrase: first)
    // The count is of the calls being named, not of everything the beat did — `3 edits`
    // beside a file name has to mean three edits.
    guard counted.count > 1 else { return target }
    let noun: String
    switch kind {
    case .reading: noun = "files read"
    case .editing: noun = "edits"
    case .running: noun = "commands"
    default: noun = "steps"
    }
    return "\(target) · \(counted.count) \(noun)"
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
    let object = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    // A path's useful half is its tail: `cat …/tasks/b2avzh5rp.output` names the file
    // where `cat /private/tmp/claude-501/-Vol…` names the mount point. Long path tokens
    // are compressed to their trailing components before the ordinary budget applies,
    // so the command and the filename both survive.
    guard object.count > 34 else { return object }
    let compressed = object.split(separator: " ")
      .map { token in
        token.count > 20 && token.contains("/") ? pathTail(String(token), characters: 24) : String(token)
      }
      .joined(separator: " ")
    return truncate(compressed, words: 6, characters: 34)
  }

  /// The trailing components of a path that fit the budget, whole — `…/tasks/x.output` —
  /// or the raw suffix when even the last component alone is too long.
  static func pathTail(_ path: String, characters: Int) -> String {
    guard path.count > characters else { return path }
    var tail = ""
    for component in path.split(separator: "/").reversed() {
      let candidate = "/" + component + tail
      if candidate.count + 1 > characters { break }
      tail = candidate
    }
    return "…" + (tail.isEmpty ? String(path.suffix(characters - 1)) : tail)
  }

  // MARK: - Reading a transcript

  /// How much of a transcript's tail is enough to see the current pass and the one before
  /// it. Bigger than the activity readers' windows because those need only the last tool
  /// call, and this needs the narration that opened the pass.
  static let tailBytes = 512 * 1024

  /// The tail of a JSONL transcript, as whole lines, still as bytes.
  ///
  /// The first line of a mid-file read is a fragment and is dropped rather than repaired —
  /// one record's worth of tail is nowhere near this window.
  ///
  /// **Bytes rather than a `String`, and this was measured.** Decoding the window into a
  /// `String` to split it, then re-encoding every kept line for `JSONSerialization`, was
  /// three quarters of the whole read: 8.3 ms of an 11.1 ms parse on a real 113 MB
  /// transcript, most of it spent on one 400 KB tool result that is dropped as a fragment
  /// two lines later. Splitting on the newline byte and handing the slices straight to
  /// `JSONSerialization` — which wanted `Data` all along — does no conversion at all.
  static func tailLines(of url: URL, bytes: Int = SummaryBeatBuilder.tailBytes) -> [Data] {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    guard let end = try? handle.seekToEnd() else { return [] }
    let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
    try? handle.seek(toOffset: start)
    guard let data = try? handle.readToEnd() else { return [] }
    var lines = data.split(separator: UInt8(ascii: "\n"))
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
  ///
  /// The **first** pass in a window that started mid-run is dropped rather than rolled up:
  /// its last beat is whatever the tail read happened to open on, which is not what that
  /// pass ended up doing. A pass is summarised from the turn that opened it or not at all.
  static func reading(
    from beats: [SummaryBeat], turns: [Date] = [], metricSamples: [MetricSample] = []
  ) -> SummaryReading {
    guard let newest = beats.map(\.pass).max() else { return SummaryReading(beats: []) }
    let partial = turns.count < newest ? beats.map(\.pass).min() : nil
    var endedAt: [Int: Date] = [:]
    for beat in beats { endedAt[beat.pass] = max(endedAt[beat.pass] ?? beat.at, beat.at) }
    let finished = Dictionary(grouping: beats.filter { $0.pass < newest }, by: \.pass)
      .compactMap { pass, passBeats -> PassSummary? in
        guard pass != partial, let last = passBeats.max(by: { $0.at < $1.at }) else { return nil }
        return PassSummary(pass: pass, text: last.text)
      }
      .sorted { $0.pass < $1.pass }
    return SummaryReading(
      beats: beats.filter { $0.pass == newest }, finishedPasses: finished, turns: turns,
      passEndedAt: endedAt, metricSamples: metricSamples)
  }
}
