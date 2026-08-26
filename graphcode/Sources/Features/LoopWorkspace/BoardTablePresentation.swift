import GraphcodeKit
import SwiftUI

/// What each cell of a table board *is*, worked out once for the whole table before any of
/// it is drawn.
///
/// A value type with no view in it, for the reason `BoardLayout` is one: deciding that a
/// column holds numbers, or that `pass` is a verdict and `pass 3` is a phrase, is the part
/// with rules in it, and rules that can only be checked by looking at a window are rules
/// nobody checks.
///
/// **Classified per column, not per cell.** A column is numeric only if *every* cell in it
/// is, which is what stops one stray `n/a` in a column of counts from making that column
/// ragged — and stops a lone `61` in a column of test names from being right-aligned on its
/// own. The alternative reads as a renderer guessing, one cell at a time.
struct BoardTablePresentation: Equatable {
  enum Cell: Equatable {
    case plain(String)
    /// A verdict: `yes`/`no`, `pass`/`fail`, `ok`/`error`, `✅`/`❌`, `true`/`false`.
    case verdict(Bool, String)
    /// A diffstat: `+52`, `-9`. Carries the sign separately so the renderer never has to
    /// re-parse what this already decided.
    case delta(isAddition: Bool, text: String)
    /// A plain number, and where it sits in its column's range — `nil` when the column is
    /// all one value, which is the case a bar would draw as either full or empty and mean
    /// neither.
    case number(String, fraction: Double?)
  }

  struct Column: Equatable {
    let header: String
    let alignment: BoardColumnAlignment
    let isNumeric: Bool
    /// Whether this column gets bars under its numbers. Only a numeric column with enough
    /// rows to compare and some actual spread — two numbers do not make a chart, and a
    /// column of identical values drawn as identical bars says nothing twice.
    let showsBars: Bool

    /// Right for numbers, leading for everything else — unless the author said otherwise in
    /// the separator row, which always wins.
    var effectiveAlignment: HorizontalAlignment {
      switch alignment {
      case .leading: return .leading
      case .center: return .center
      case .trailing: return .trailing
      case .unspecified: return isNumeric ? .trailing : .leading
      }
    }
  }

  let columns: [Column]
  let rows: [[Cell]]

  /// Below this a numeric column is a pair of figures to read, not a series to compare.
  static let minimumRowsForBars = 3

  init(table: BoardTable) {
    let body = table.normalisedRows
    let columns = table.headers.indices.map { index -> Column in
      let cells = body.map { $0[index] }.filter { !$0.isEmpty }
      let numbers = cells.compactMap { Self.number(from: $0) }
      let isNumeric = !cells.isEmpty && numbers.count == cells.count
      let spread = (numbers.max() ?? 0) - (numbers.min() ?? 0)
      return Column(
        header: table.headers[index],
        alignment: table.alignment(ofColumn: index),
        isNumeric: isNumeric,
        showsBars: isNumeric && cells.count >= Self.minimumRowsForBars && spread > 0)
    }
    // Each numeric column's own range, so a bar compares a value with the column it is in
    // and never with the table.
    let ranges = table.headers.indices.map { index -> (low: Double, high: Double)? in
      guard columns[index].showsBars else { return nil }
      let numbers = body.compactMap { Self.number(from: $0[index]) }
      guard let low = numbers.min(), let high = numbers.max(), high > low else { return nil }
      return (low, high)
    }

    self.columns = columns
    rows = body.map { row in
      row.indices.map { index in
        Self.cell(row[index], range: ranges[index])
      }
    }
  }

  static func cell(_ raw: String, range: (low: Double, high: Double)?) -> Cell {
    let text = raw.trimmingCharacters(in: .whitespaces)
    if let verdict = verdict(of: text) { return .verdict(verdict, text) }
    if let delta = delta(of: text) { return delta }
    guard let value = number(from: text) else { return .plain(text) }
    guard let range else { return .number(text, fraction: nil) }
    return .number(text, fraction: (value - range.low) / (range.high - range.low))
  }

  /// The words a verdict is written in, and nothing else.
  ///
  /// **Whole-cell match only.** `pass` is a verdict; `pass 3` is a phrase about which pass,
  /// and a table of pass numbers rendered as a column of green ticks would be actively
  /// misleading — which is the failure mode this whole feature is meant to avoid.
  static func verdict(of text: String) -> Bool? {
    switch text.lowercased() {
    case "yes", "pass", "passed", "ok", "true", "✅", "✔", "✓", "green", "clean": return true
    case "no", "fail", "failed", "error", "false", "❌", "✗", "✘", "red", "broken": return false
    default: return nil
    }
  }

  /// `+52` and `-9`, and only in that shape.
  ///
  /// **Coloured by sign, and that is a judgement about context rather than about
  /// arithmetic.** A signed integer in a table about code is a diffstat far more often than
  /// it is anything else, and green-added/red-removed is the convention every diff view
  /// already teaches. It would be the wrong reading for a column of temperature changes —
  /// which is not a thing a coding session produces. A bare `52` is never a delta, so a
  /// column of plain counts is untouched by this.
  static func delta(of text: String) -> Cell? {
    guard text.count >= 2, let first = text.first, "+-−".contains(first) else { return nil }
    let magnitude = String(text.dropFirst())
    guard number(from: magnitude) != nil else { return nil }
    return .delta(isAddition: first == "+", text: text)
  }

  /// A number, allowing the separators people write them with and the units they end them
  /// in — `1,024`, `93%`, `1.4k`, `250ms`.
  static func number(from text: String) -> Double? {
    var body = text.replacingOccurrences(of: ",", with: "")
    body = body.replacingOccurrences(of: "−", with: "-")
    let digits = body.prefix { "+-0123456789.".contains($0) }
    guard !digits.isEmpty, let value = Double(digits) else { return nil }
    let suffix = body.dropFirst(digits.count).lowercased()
    switch suffix {
    case "", "%", "ms", "s", "b", "pt", "px": return value
    case "k": return value * 1_000
    case "m": return value * 1_000_000
    default: return nil
    }
  }
}

extension BoardTablePresentation.Column {
  /// The frame alignment the cell views are laid out with.
  var frameAlignment: Alignment {
    switch effectiveAlignment {
    case .center: return .center
    case .trailing: return .trailing
    default: return .leading
    }
  }

  /// Which edge a bar grows from — the same edge its number is aligned to, so the two read
  /// as one mark rather than as a number with a stray rule under it.
  var barAlignment: HorizontalAlignment { effectiveAlignment }
}
