import Foundation

/// Turns the composer's reply into something `SummaryBoardView` can draw, or into nothing.
///
/// **A deliberately small subset of Mermaid, and it says so.** Mermaid has a dozen diagram
/// types and a syntax that grows every release; this understands flowcharts and Markdown
/// tables, which are the two forms `SummaryBoardComposer` asks for. Anything else parses to
/// `nil`, the board keeps its source text, and the view shows that text as code — the
/// honest outcome, and the reason `SummaryBoard.source` is the field the composer actually
/// produces.
///
/// The reason for parsing at all rather than embedding a renderer: the canvas and the rail
/// both redraw at pointer-event rate inside a `scaleEffect`, and the app has no WebKit
/// dependency to give one. A parsed board is a few dozen structs that lay out in
/// microseconds and draw as SwiftUI shapes.
///
/// What is understood, in full:
///
/// - `flowchart TD|TB|LR|RL` and `graph …` headers, with `BT`/`RL` normalised
/// - node shapes `[]`, `()`, `{}`, `([])`, `(())`, `[[]]`, `[()]`, `{{}}`, `>]`
/// - links `-->`, `---`, `-.->`, `-.-`, `==>`, `===`, chained (`A --> B --> C`)
/// - edge labels in both spellings: `-->|yes|` and `-- yes -->`
/// - `%% title: …`, and `%%` comments otherwise dropped
/// - GitHub-flavoured Markdown tables
///
/// What is dropped without complaint, because a board that refuses to draw over a styling
/// directive is worse than one that draws unstyled: `subgraph`/`end`, `classDef`, `class`,
/// `style`, `linkStyle`, `click`.
public enum MermaidBoardParser {
  /// The composer's whole reply in, a board or nothing out.
  ///
  /// `pass` is stamped rather than parsed — it is the store's number, and nothing a model
  /// writes is allowed to set it.
  public static func board(fromReply reply: String, pass: Int, now: Date = Date())
    -> SummaryBoard?
  {
    guard let block = lastBlock(in: reply) else { return nil }
    if let flow = flow(from: block, pass: pass, now: now) { return flow }
    return table(from: block, pass: pass, now: now)
  }

  // MARK: - Fences

  /// The last fenced block in the reply, or the whole reply when there are no fences.
  ///
  /// **Last, not first.** A CLI in print mode prefixes banners, and a model asked for one
  /// diagram sometimes shows its working first — in both cases the answer is at the end.
  /// The same reasoning `SummaryModelWriter.accepted` takes the last line for.
  static func lastBlock(in reply: String) -> String? {
    let lines = reply.components(separatedBy: .newlines)
    var blocks: [[String]] = []
    var current: [String]?
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        if let open = current {
          blocks.append(open)
          current = nil
        } else {
          current = []
        }
        continue
      }
      current?.append(line)
    }
    // An unterminated fence is still an answer: a model that opened a block and ran out of
    // budget has usually written the whole diagram and only lost the closing ticks.
    if let open = current, !open.isEmpty { blocks.append(open) }
    let block = blocks.last?.joined(separator: "\n") ?? reply
    let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  // MARK: - Flowcharts

  static func flow(from block: String, pass: Int, now: Date) -> SummaryBoard? {
    var lines = block.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    var title: String?

    for line in lines where line.hasPrefix("%%") {
      let comment = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
      guard comment.lowercased().hasPrefix("title:") else { continue }
      let text = comment.dropFirst("title:".count).trimmingCharacters(in: .whitespaces)
      if !text.isEmpty { title = text }
    }

    guard let headerIndex = lines.firstIndex(where: { isHeader($0) }) else { return nil }
    let direction = direction(ofHeader: lines[headerIndex])
    lines = Array(lines[(headerIndex + 1)...])

    var nodes: [String: BoardNode] = [:]
    var order: [String] = []
    var edges: [BoardEdge] = []

    func remember(_ node: BoardNode) {
      // First declaration wins. Mermaid lets a node be named again later with no shape
      // (`B --> C` after `A --> B[Read it]`), and taking the later one would blank the
      // label the diagram was written to carry.
      if let existing = nodes[node.id] {
        guard existing.text == existing.id, node.text != node.id else { return }
      } else {
        order.append(node.id)
      }
      nodes[node.id] = node
    }

    for line in lines where !isIgnorable(line) {
      let (lineNodes, lineEdges) = parseFlowLine(line)
      lineNodes.forEach(remember)
      edges.append(contentsOf: lineEdges)
    }

    let ordered = order.compactMap { nodes[$0] }
    let board = SummaryBoard(
      form: .flow, title: title, direction: direction, nodes: ordered,
      edges: edges, source: block, pass: pass, composedAt: now)
    return board.isDrawable ? board : nil
  }

  static func isHeader(_ line: String) -> Bool {
    let lower = line.lowercased()
    return lower.hasPrefix("flowchart") || lower.hasPrefix("graph ") || lower == "graph"
  }

  static func direction(ofHeader line: String) -> BoardDirection {
    let token = line.split(separator: " ").dropFirst().first.map { $0.uppercased() } ?? "TD"
    // `RL` and `BT` are drawn as their mirrors rather than honoured. A board reads beside a
    // terminal whose newest line is at the bottom; one that ran the other way would have
    // the same run going two directions on one screen — the argument `LoopSummary.receding`
    // already settled for the rows above it.
    return token.hasPrefix("LR") || token.hasPrefix("RL") ? .leftRight : .topDown
  }

  static func isIgnorable(_ line: String) -> Bool {
    if line.isEmpty || line.hasPrefix("%%") { return true }
    let head = line.split(separator: " ").first.map { $0.lowercased() } ?? ""
    return ["subgraph", "end", "classdef", "class", "style", "linkstyle", "click", "direction"]
      .contains(head)
  }

  /// One line of a flowchart: the node tokens it declares and the edges between them.
  ///
  /// Chains are handled by construction — `A --> B --> C` is two edges — because splitting
  /// on links and pairing the survivors is the same work either way.
  static func parseFlowLine(_ line: String) -> ([BoardNode], [BoardEdge]) {
    let text = line.hasSuffix(";") ? String(line.dropLast()) : line
    let links = linkMatches(in: text)
    guard !links.isEmpty else {
      // A bare declaration — `A[Start]` on its own line. Legal Mermaid, and the only way a
      // one-box diagram is written; kept so the node has its label when an edge names it.
      guard let node = parseNodeToken(text) else { return ([], []) }
      return ([node], [])
    }

    var nodes: [BoardNode] = []
    var edges: [BoardEdge] = []
    var cursor = text.startIndex
    var previous: BoardNode?
    /// The link whose right-hand node has not been read yet. An edge can only be emitted
    /// once *both* its ends are known, and the link that joins them is the one before the
    /// node being read — not the one the loop is currently on.
    var pending: LinkMatch?

    func close(with node: BoardNode) {
      nodes.append(node)
      if let from = previous, let pending {
        edges.append(
          BoardEdge(from: from.id, to: node.id, label: pending.label, style: pending.style))
      }
      previous = node
    }

    for link in links {
      // A segment that holds no identifier breaks the chain rather than silently joining
      // the boxes either side of it.
      if let node = parseNodeToken(String(text[cursor..<link.range.lowerBound])) {
        close(with: node)
      } else {
        previous = nil
      }
      pending = link
      cursor = link.range.upperBound
    }
    if let tail = parseNodeToken(String(text[cursor...])) { close(with: tail) }
    return (nodes, edges)
  }

  struct LinkMatch {
    let range: Range<String.Index>
    let label: String?
    let style: BoardEdgeStyle
  }

  /// Every link on the line, in order.
  ///
  /// The alternation is ordered longest-first on purpose: `-- no -->` has to be tried
  /// before `-->`, or the label is left stranded as part of a node token.
  static func linkMatches(in line: String) -> [LinkMatch] {
    guard let regex = linkRegex else { return [] }
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    return regex.matches(in: line, range: range).compactMap { match in
      guard let full = Range(match.range, in: line) else { return nil }
      let inline = [1, 2, 3].lazy
        .compactMap { Range(match.range(at: $0), in: line) }
        .first
        .map { String(line[$0]).trimmingCharacters(in: .whitespaces) }
      let piped = Range(match.range(at: 4), in: line)
        .map { String(line[$0]).trimmingCharacters(in: .whitespaces) }
      let label = [piped, inline].compactMap { $0 }.first { !$0.isEmpty }
      let text = String(line[full])
      let style: BoardEdgeStyle =
        text.contains(".") ? .dashed : (text.contains("=") ? .thick : .solid)
      return LinkMatch(range: full, label: unquoted(label), style: style)
    }
  }

  private static let linkRegex: NSRegularExpression? = {
    let pattern = [
      "--\\s*([^>|\\n]*?)\\s*-{2,}>",  // -- label -->
      "-\\.\\s*([^>|\\n]*?)\\s*\\.-+>",  // -. label .->
      "==\\s*([^>|\\n]*?)\\s*={2,}>",  // == label ==>
      "-\\.-+>?",  // -.-> / -.-
      "={2,}>?",  // ==> / ===
      "-{2,}>?",  // --> / ---
    ]
    let alternation = "(?:" + pattern.joined(separator: "|") + ")"
    return try? NSRegularExpression(pattern: alternation + "(?:\\s*\\|([^|\\n]*)\\|)?")
  }()

  /// `B{Ready?}` → the node. `nil` when the segment holds no identifier, which is how a
  /// malformed line loses one edge instead of the whole board.
  static func parseNodeToken(_ segment: String) -> BoardNode? {
    let text = segment.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    guard let open = text.firstIndex(where: { "[({>".contains($0) }) else {
      let id = sanitisedIdentifier(text)
      return id.isEmpty ? nil : BoardNode(id: id, text: id, shape: .box)
    }
    let id = sanitisedIdentifier(String(text[text.startIndex..<open]))
    guard !id.isEmpty else { return nil }
    let body = String(text[open...])
    let (label, shape) = shapedLabel(body)
    let cleaned = unquoted(label.trimmingCharacters(in: .whitespaces)) ?? id
    return BoardNode(id: id, text: cleaned.isEmpty ? id : cleaned, shape: shape)
  }

  /// The delimiters, longest first — `([` has to be tested before `(`, or a stadium node
  /// parses as a rounded one whose label starts with a bracket.
  private static let delimiters: [(open: String, close: String, shape: BoardNodeShape)] = [
    ("([", "])", .terminal),
    ("((", "))", .terminal),
    ("[[", "]]", .box),
    ("[(", ")]", .box),
    ("{{", "}}", .decision),
    ("[", "]", .box),
    ("(", ")", .rounded),
    ("{", "}", .decision),
    (">", "]", .box),
  ]

  static func shapedLabel(_ body: String) -> (String, BoardNodeShape) {
    for delimiter in delimiters where body.hasPrefix(delimiter.open) {
      let inner = body.dropFirst(delimiter.open.count)
      guard let end = inner.range(of: delimiter.close, options: .backwards) else {
        return (String(inner), delimiter.shape)
      }
      return (String(inner[inner.startIndex..<end.lowerBound]), delimiter.shape)
    }
    return (body, .box)
  }

  /// Mermaid ids are alphanumerics and underscores; anything else on the left of a shape is
  /// a typo or a stray operator, and dropping it beats inventing a node called `-`.
  static func sanitisedIdentifier(_ raw: String) -> String {
    String(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" })
  }

  /// Mermaid quotes any label containing punctuation, and writes line breaks as `<br/>`.
  /// Both are the diagram's syntax rather than the label's content.
  static func unquoted(_ raw: String?) -> String? {
    guard var text = raw else { return nil }
    if text.hasPrefix("\""), text.hasSuffix("\""), text.count > 1 {
      text = String(text.dropFirst().dropLast())
    }
    for token in ["<br/>", "<br>", "<br />"] {
      text = text.replacingOccurrences(of: token, with: " ")
    }
    text = text.replacingOccurrences(of: "&nbsp;", with: " ")
    return text.trimmingCharacters(in: .whitespaces)
  }

  // MARK: - Tables

  /// A GitHub-flavoured Markdown table, which is what the composer emits for `.table`.
  ///
  /// The separator row is required rather than inferred. Without it a flowchart line
  /// containing a pipe — legal, if rare — parses as a one-row table, and a board that
  /// draws the wrong form is worse than one that draws nothing.
  static func table(from block: String, pass: Int, now: Date) -> SummaryBoard? {
    let rows =
      block
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.hasPrefix("|") }
    guard rows.count >= 3 else { return nil }
    let headers = cells(of: rows[0])
    guard !headers.isEmpty, isSeparator(rows[1]), cells(of: rows[1]).count == headers.count
    else { return nil }
    let body = rows.dropFirst(2).map { cells(of: $0) }.filter { row in
      row.contains { !$0.isEmpty }
    }
    guard !body.isEmpty else { return nil }
    let board = SummaryBoard(
      form: .table,
      table: BoardTable(
        headers: headers, rows: body, alignments: alignments(ofSeparator: rows[1])),
      source: block, pass: pass, composedAt: now)
    return board.isDrawable ? board : nil
  }

  static func cells(of row: String) -> [String] {
    var text = row
    if text.hasPrefix("|") { text = String(text.dropFirst()) }
    if text.hasSuffix("|") { text = String(text.dropLast()) }
    return text.components(separatedBy: "|").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
  }

  /// `|---|---:|:--:|` — what the author asked for, per column.
  ///
  /// A leading colon means left, a trailing one means right, both mean centre, neither
  /// means the author did not say and the renderer should decide from the content.
  static func alignments(ofSeparator row: String) -> [BoardColumnAlignment] {
    cells(of: row).map { cell in
      let rule = cell.trimmingCharacters(in: .whitespaces)
      switch (rule.hasPrefix(":"), rule.hasSuffix(":")) {
      case (true, true): return .center
      case (false, true): return .trailing
      case (true, false): return .leading
      case (false, false): return .unspecified
      }
    }
  }

  static func isSeparator(_ row: String) -> Bool {
    let parts = cells(of: row)
    guard !parts.isEmpty else { return false }
    return parts.allSatisfy { cell in
      !cell.isEmpty && cell.allSatisfy { "-: ".contains($0) } && cell.contains("-")
    }
  }
}
