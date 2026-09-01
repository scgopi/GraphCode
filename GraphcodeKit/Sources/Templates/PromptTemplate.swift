import Foundation

/// A reusable brief for a loop — one markdown file, human-readable and diffable.
/// See PROMPT_TEMPLATES.md (New Designs v4).
///
/// Four parts, only the first required:
/// - **body** — the prompt, with `{token}` placeholders the person using it fills in.
/// - **shape** — the loop type the text assumes; `nil` and the loop stays Main.
/// - **settings** — done check, cadence, agent, branch, each landing in its real field.
/// - **origin** — home or a project folder; project ones sort above home ones.
///
/// A composite template additionally carries its sub-graph, which is how an
/// orchestration gets shared; it serialises inside the front matter as one JSON line.
public struct PromptTemplate: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var body: String
  /// The loop type this brief assumes. Written in front matter with the human-facing
  /// word (`goal`, `timed`), read back through either that word or `LoopType`'s raw
  /// value — both have shipped, and a hand-edited file should never refuse to load.
  public var shape: LoopType?
  public var settings: TemplateSettings?
  public var origin: TemplateOrigin
  /// The name of the file this template was read from — the key the loader dedupes
  /// on, so a project's copy of `review-diff.md` wins over home's regardless of what
  /// either names itself inside. Fresh templates (not yet written) derive it from
  /// their name.
  public var fileName: String
  /// How many times this template has been applied, as this app has counted it.
  /// **Never written back into the file** — applying a template must not dirty a
  /// repository's working tree, and a project folder may not even be writable. It is
  /// app-local state the loader overlays, keyed on the filename.
  public var useCount: Int

  public init(
    id: UUID = UUID(),
    name: String,
    body: String,
    shape: LoopType? = nil,
    settings: TemplateSettings? = nil,
    origin: TemplateOrigin = .home,
    useCount: Int = 0
  ) {
    self.id = id
    self.name = name
    self.body = body
    self.shape = shape
    self.settings = settings
    self.origin = origin
    self.fileName = Self.fileName(for: name)
    self.useCount = useCount
  }

  /// The tokens the body still asks to be filled, in order of first appearance —
  /// the order the picker's chips show and the order tabbing walks.
  public var tokens: [String] {
    Self.tokens(in: body)
  }

  public static func tokens(in text: String) -> [String] {
    var seen = Set<String>()
    var ordered: [String] = []
    for range in text.ranges(of: Self.tokenPattern) {
      let token = String(text[range]).dropFirst().dropLast()
      if seen.insert(String(token)).inserted { ordered.append(String(token)) }
    }
    return ordered
  }

  /// What was typed over each `{token}`, recovered by matching the filled text
  /// against the template's own brief. The literals around the tokens have to
  /// match exactly — someone who rewrote more than the tokens gets `nil` and
  /// their text is saved as they wrote it, never guessed at.
  public static func tokenValues(of filled: String, against brief: String) -> [String: String]? {
    let tokenRanges = Array(brief.ranges(of: Self.tokenPattern))
    guard !tokenRanges.isEmpty else { return [:] }
    var pattern = "^"
    var tokensFound: [String] = []
    var cursor = brief.startIndex
    for range in tokenRanges {
      let literal = String(brief[cursor..<range.lowerBound])
      if !literal.isEmpty {
        pattern += NSRegularExpression.escapedPattern(for: literal)
      }
      let token = String(brief[range]).dropFirst().dropLast()
      tokensFound.append(String(token))
      pattern += "(.*?)"
      cursor = range.upperBound
    }
    let tail = String(brief[cursor...])
    if !tail.isEmpty { pattern += NSRegularExpression.escapedPattern(for: tail) }
    pattern += "$"
    guard
      let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
      let match = regex.firstMatch(
        in: filled, range: NSRange(location: 0, length: filled.utf16.count)),
      match.numberOfRanges == tokensFound.count + 1
    else { return nil }
    var values: [String: String] = [:]
    for (index, token) in tokensFound.enumerated() {
      let range = match.range(at: index + 1)
      guard let swiftRange = Range(range, in: filled) else { return nil }
      values[token] = String(filled[swiftRange])
    }
    return values
  }

  static let tokenPattern = /\{[A-Za-z_][A-Za-z0-9_]*\}/

  /// A copy under a new name, **with its filename re-derived**. `fileName` is stored
  /// rather than computed so a template loaded from disk keeps the name the file
  /// actually has; the cost is that renaming has to say so, and every rename in the
  /// app goes through here rather than assigning `name` and stranding the old slug.
  public func renamed(to newName: String) -> PromptTemplate {
    var renamed = self
    renamed.name = newName
    renamed.fileName = Self.fileName(for: newName)
    return renamed
  }

  /// The filename a new template is stored under — the slug of its name, so a
  /// committed `review-diff.md` reads in a diff the way the template reads in the app.
  public static func fileName(for name: String) -> String {
    let slug =
      name
      .lowercased()
      .replacingOccurrences(of: " ", with: "-")
      .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return (trimmed.isEmpty ? "template" : String(trimmed.prefix(64))) + ".md"
  }

  /// The body's first sentence — the picker's second line, so a list of briefs can
  /// be read without opening any of them. A sentence rather than a line, because a
  /// brief written as one paragraph would otherwise show its whole first paragraph
  /// and a brief written as bullets would show only its heading.
  public var summaryLine: String {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return name }
    let firstBreak = trimmed.firstIndex(where: { $0.isNewline }) ?? trimmed.endIndex
    let firstLine = String(trimmed[..<firstBreak])
    let sentence = Self.firstSentence(of: firstLine)
    guard sentence.count > 96 else { return sentence }
    return String(sentence.prefix(93)) + "…"
  }

  /// Up to and including the first sentence terminator that actually ends a
  /// sentence. A terminator followed by anything other than a space ends nothing —
  /// which is what keeps `./scripts/score.sh` and `v1.2` in one piece.
  static func firstSentence(of line: String) -> String {
    var index = line.startIndex
    while let stop = line[index...].firstIndex(where: { $0 == "." || $0 == "?" || $0 == "!" }) {
      let after = line.index(after: stop)
      if after == line.endIndex || line[after].isWhitespace {
        return String(line[..<after])
      }
      index = after
    }
    return line
  }

  /// What the picker's type label says past the type's own name — the cadence a
  /// timed template assumes, or how many loops a composite one carries.
  public var typeQualifier: String? {
    switch shape {
    case .timeBased:
      return settings?.cadence.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    case .composite:
      return nil  // The child count is composed by the view, off the carried graph.
    default:
      return nil
    }
  }

  /// What the settings chip in the picker says — one honest summary of everything
  /// the template will set, in the order the applied state sets them.
  public var settingsSummary: [String] {
    guard let settings else { return [] }
    var parts: [String] = []
    if settings.doneCheck != nil { parts.append("sets a done check") }
    if let cadence = settings.cadence { parts.append("runs every \(cadence)") }
    if settings.pausesBeforeWritesOnly == true { parts.append("pauses only before writes") }
    if settings.branch != nil { parts.append("cuts a branch") }
    if settings.metric != nil { parts.append("tracks a metric") }
    if let backend = settings.backend { parts.append("runs on \(backend.displayName)") }
    return parts
  }
}

/// Which loop type a template's shape names, as the file spells it. The human words
/// are what the app writes; the raw values are what older or hand-written files may
/// already carry.
public enum TemplateShapeWord: String, CaseIterable, Sendable {
  case main
  case sketch
  case goal
  case goalBased
  case timed
  case timeBased
  case turn
  case turnBased
  case composite
  case proactive

  public var loopType: LoopType? {
    switch self {
    case .main, .sketch: return .sketch
    case .goal, .goalBased: return .goalBased
    case .timed, .timeBased: return .timeBased
    case .turn, .turnBased: return .turnBased
    case .composite, .proactive: return .composite
    }
  }

  /// The word the app writes back — the human-facing one, `main` for a shapeless
  /// template rather than a missing key, because a file that says `main` says
  /// something a file with no key does not.
  public static func word(for loopType: LoopType?) -> String {
    switch loopType {
    case .sketch: return "main"
    case .goalBased: return "goal"
    case .timeBased: return "timed"
    case .turnBased: return "turn"
    case .composite: return "composite"
    case nil: return "main"
    }
  }

  public static func parse(_ raw: String) -> LoopType? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if let exact = TemplateShapeWord(rawValue: trimmed)?.loopType { return exact }
    // Case-insensitive fallback: `GoalBased`, `goalbased`, `TIMEBASED` all mean
    // what their lower-case spelling means — a hand-edited file should load.
    let lowered = trimmed.lowercased()
    return TemplateShapeWord.allCases
      .first(where: { $0.rawValue.lowercased() == lowered })?
      .loopType
  }
}

/// Everything but the prompt a template can set. Each field lands in its *real*
/// dialog field when applied — never a preview — so the names mirror the form's own.
public struct TemplateSettings: Codable, Equatable, Sendable {
  /// The agent the prompt assumes; absent means the app's own default stands.
  public var backend: CLISessionBackendKind?
  /// A goal loop's done check (`GoalSpec.predicate`).
  public var doneCheck: String?
  /// A timed loop's cadence, as the `/loop` directive spells it — "1h", "daily",
  /// whatever `IntervalChoice.directiveValue` produces. The node's own session owns
  /// the timer; this only writes the directive.
  public var cadence: String?
  /// A turn loop's pause shape.
  public var pausesBeforeWritesOnly: Bool?
  /// The branch to cut a worktree for. An existing branch binds as `.existing`;
  /// this template only ever asks for a *new* one, because a name that exists on
  /// every machine a template reaches is a name the loader cannot promise.
  public var branch: String?
  /// A goal loop's progress metric.
  public var metric: String?
  /// A composite's carried sub-graph — the children and edges an orchestration
  /// shares. One JSON line, `LoopGraph`'s own encoding, re-identified on apply.
  public var graphJSON: String?

  public init(
    backend: CLISessionBackendKind? = nil,
    doneCheck: String? = nil,
    cadence: String? = nil,
    pausesBeforeWritesOnly: Bool? = nil,
    branch: String? = nil,
    metric: String? = nil,
    graphJSON: String? = nil
  ) {
    self.backend = backend
    self.doneCheck = doneCheck
    self.cadence = cadence
    self.pausesBeforeWritesOnly = pausesBeforeWritesOnly
    self.branch = branch
    self.metric = metric
    self.graphJSON = graphJSON
  }

  public var isEmpty: Bool {
    self == TemplateSettings()
  }
}

/// Where a template was read from — which is also where a copy of it lives.
/// `project` carries the folder's path, not the templates directory's, because the
/// destination for a later "put it in the project" is derived from it.
public enum TemplateOrigin: Codable, Equatable, Hashable, Sendable {
  /// `~/.graphcode/templates` — yours, offered in every project, the default
  /// write target.
  case home
  /// `<project>/.graphcode/templates` — read if present, sorted first.
  case project(String)

  public var isProject: Bool {
    if case .project = self { return true }
    return false
  }
}

// MARK: - File format

/// One template is one markdown file: a `---`-delimited front matter block for
/// shape, settings and identity, then the body. Deliberately plain — a template
/// should be editable in an editor, readable in a diff, and loadable by a script,
/// which is why this is a tiny bespoke parser rather than a YAML dependency: the
/// schema is flat key-value lines and nothing more.
public enum TemplateFileCodec {
  private static let frontMatterDelimiter = "---"

  /// Reads a template out of a file's text. `origin` is supplied by the caller —
  /// the file cannot know where it lives.
  public static func decode(_ text: String, origin: TemplateOrigin) -> PromptTemplate? {
    var lines = Substring(text)
    guard lines.hasPrefix(frontMatterDelimiter + "\n") || lines == frontMatterDelimiter
    else {
      // No front matter: the whole file is the body. A template that is only a
      // prompt is a complete template — name from the first line, Main shape.
      let body = String(lines).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty else { return nil }
      let firstLine = body.split(separator: "\n", maxSplits: 1)[0]
      return PromptTemplate(
        name: String(firstLine.prefix(64)).trimmingCharacters(in: .whitespaces),
        body: body, origin: origin)
    }
    lines.removeFirst(frontMatterDelimiter.count + 1)
    guard let end = lines.range(of: "\n" + frontMatterDelimiter)
    else { return nil }
    let header = String(lines[..<end.lowerBound])
    var bodyText = String(lines[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

    var name: String?
    var id = UUID()
    var shape: LoopType?
    var settings = TemplateSettings()
    var hadSettings = false
    for rawLine in header.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#"),
        let colon = line.firstIndex(of: ":")
      else { continue }
      let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
      let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      let unwrapped = unwrapQuoted(value)
      switch key {
      case "name", "title":
        name = unwrapped.isEmpty ? name : unwrapped
      case "id":
        if let parsed = UUID(uuidString: unwrapped) { id = parsed }
      case "shape", "type", "kind":
        shape = TemplateShapeWord.parse(unwrapped) ?? shape
      case "backend", "agent":
        if let backend = CLISessionBackendKind(rawValue: unwrapped) {
          settings.backend = backend
          hadSettings = true
        }
      case "done-check", "check", "predicate":
        settings.doneCheck = unwrapped.isEmpty ? nil : unwrapped
        hadSettings = true
      case "cadence", "interval", "every":
        settings.cadence = unwrapped.isEmpty ? nil : unwrapped
        hadSettings = true
      case "pauses-before-writes-only", "writes-only":
        settings.pausesBeforeWritesOnly = unwrapped.lowercased() == "true"
        hadSettings = true
      case "branch", "worktree":
        settings.branch = unwrapped.isEmpty ? nil : unwrapped
        hadSettings = true
      case "metric":
        settings.metric = unwrapped.isEmpty ? nil : unwrapped
        hadSettings = true
      case "graph", "subgraph":
        settings.graphJSON = unwrapped.isEmpty ? nil : unwrapped
        hadSettings = true
      default:
        break
      }
    }

    // A composite body that is only a schedule line is noise next to the carried
    // graph; an empty one is fine — the name is the brief there.
    if shape == .composite, bodyText.isEmpty, settings.carriedGraph != nil {
      bodyText = "Intended schedule: as the template's schedule states."
    }

    let fallbackName =
      bodyText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
      .first.map { String($0.prefix(64)).trimmingCharacters(in: .whitespaces) } ?? ""
    let resolvedName = (name?.isEmpty == false ? name : fallbackName) ?? ""
    guard !bodyText.isEmpty || shape == .composite else { return nil }
    return PromptTemplate(
      id: id,
      name: resolvedName,
      body: bodyText,
      shape: shape,
      settings: hadSettings ? settings : nil,
      origin: origin)
  }

  /// Writes the whole file. The `id` line is what lets a following loop find its
  /// template after the file was renamed or moved — content is how a template is
  /// read, identity is how it is followed.
  public static func encode(_ template: PromptTemplate) -> String {
    var lines: [String] = [frontMatterDelimiter]
    lines.append("id: \(template.id.uuidString)")
    lines.append("name: \(quoteIfNeeded(template.name))")
    lines.append("shape: \(TemplateShapeWord.word(for: template.shape))")
    if let settings = template.settings, !settings.isEmpty {
      if let backend = settings.backend {
        lines.append("backend: \(backend.rawValue)")
      }
      if let check = settings.doneCheck { lines.append("done-check: \(quoteIfNeeded(check))") }
      if let cadence = settings.cadence { lines.append("cadence: \(cadence)") }
      if settings.pausesBeforeWritesOnly == true {
        lines.append("pauses-before-writes-only: true")
      }
      if let branch = settings.branch { lines.append("branch: \(quoteIfNeeded(branch))") }
      if let metric = settings.metric { lines.append("metric: \(quoteIfNeeded(metric))") }
      if let graph = settings.graphJSON { lines.append("graph: \(quoteIfNeeded(graph))") }
    }
    lines.append(frontMatterDelimiter)
    lines.append("")
    lines.append(template.body)
    return lines.joined(separator: "\n") + "\n"
  }

  private static func unwrapQuoted(_ value: String) -> String {
    guard value.count >= 2 else { return value }
    let first = value.first!
    let last = value.last!
    if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
      // `encode` escapes the quotes it adds around values that contain them; the
      // read side undoes exactly that, so a carried graph's JSON survives the trip.
      return String(value.dropFirst().dropLast())
        .replacingOccurrences(of: "\\\"", with: "\"")
    }
    return value
  }

  private static func quoteIfNeeded(_ value: String) -> String {
    // The last clause is the round trip talking: a value that already begins and ends
    // with a quote would come back through `unwrapQuoted` with those quotes eaten, so
    // it has to be quoted on the way out even when nothing else would require it.
    let looksQuoted =
      value.count >= 2
      && ((value.hasPrefix("\"") && value.hasSuffix("\""))
        || (value.hasPrefix("'") && value.hasSuffix("'")))
    let needsQuoting =
      value.contains(":") || value.hasPrefix("{") || value.hasPrefix("[")
      || value.hasPrefix("#") || looksQuoted
    return needsQuoting
      ? "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\"" : value
  }
}

extension TemplateSettings {
  /// The carried sub-graph, decoded — `nil` when the JSON doesn't decode, which is
  /// a template that simply doesn't carry one rather than a template that fails.
  public var carriedGraph: LoopGraph? {
    graphJSON.flatMap { json in
      guard let data = json.data(using: .utf8) else { return nil }
      return try? JSONDecoder().decode(LoopGraph.self, from: data)
    }
  }

  /// The carried sub-graph, encoded — the one JSON line `graph:` stores.
  public static func graphJSON(for graph: LoopGraph) -> String? {
    guard let data = try? JSONEncoder().encode(graph) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
