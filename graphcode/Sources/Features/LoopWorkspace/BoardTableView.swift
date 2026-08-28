import GraphcodeKit
import SwiftUI

/// A table board — rows and columns, drawn as a `Grid` rather than as a diagram.
///
/// What each cell *is* was decided before any of this ran; see `BoardTablePresentation`,
/// which is where the rules about verdicts, diffstats and numeric columns live. This only
/// draws what it is handed.
struct TableBoardView: View {
  let board: SummaryBoard
  let ceiling: CGFloat?

  /// One grid cell: a column's contents, or the rule between two columns.
  ///
  /// Interleaved into an explicit list rather than branched inside the row builder, because
  /// a `GridRow` counts the views it is handed and a conditional that sometimes emits two
  /// makes the header's columns and the body's stop lining up.
  private enum Slot: Hashable {
    case column(Int)
    case rule(Int)
  }

  private func slots(_ count: Int) -> [Slot] {
    (0..<count).flatMap { index -> [Slot] in
      index == 0 ? [.column(index)] : [.rule(index), .column(index)]
    }
  }

  var body: some View {
    if let table = board.table {
      let presentation = BoardTablePresentation(table: table)
      let slots = slots(presentation.columns.count)
      // Horizontally scrollable rather than squeezed: five columns at the rail's folded
      // width is 40 points each, which is a column of ellipses.
      ScrollView([.horizontal, .vertical]) {
        // Half the spacing it used to have, because there is now a rule in the middle of
        // each gutter and the two halves add back up to the gap the table had before.
        Grid(alignment: .leading, horizontalSpacing: 7, verticalSpacing: 0) {
          if presentation.hasHeaders {
            GridRow {
              ForEach(slots, id: \.self) { slot in
                switch slot {
                case .rule: rule
                case .column(let index):
                  let column = presentation.columns[index]
                  Text(column.header)
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: column.frameAlignment)
                }
              }
            }
            .padding(.vertical, 5)
          }
          // Ruled, not striped. A `GridRow` background is applied to each *cell*, not
          // across the row, so alternating fills came out as a ragged block behind each
          // piece of text rather than as a band — worse than the plain rules it was meant
          // to improve on.
          ForEach(Array(presentation.rows.enumerated()), id: \.offset) { _, row in
            Divider().overlay(.white.opacity(0.07))
              .gridCellUnsizedAxes(.horizontal)
              .gridCellColumns(slots.count)
            GridRow {
              ForEach(slots, id: \.self) { slot in
                switch slot {
                case .rule: rule
                case .column(let index):
                  BoardCellView(cell: row[index], column: presentation.columns[index])
                }
              }
            }
            .padding(.vertical, 5)
          }
        }
        .padding(.horizontal, 2)
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxHeight: ceiling ?? .infinity)
    } else {
      BoardSourceView(source: board.source)
    }
  }

  /// The line between two columns.
  ///
  /// Fainter than the rules between rows, and deliberately so: a row rule separates one
  /// fact from the next, where a column rule only says where a cell stops. Drawn at the
  /// same weight it competes with the text either side of it, and a five-column board reads
  /// as a spreadsheet rather than as a summary.
  private var rule: some View {
    Rectangle()
      .fill(.white.opacity(0.05))
      .frame(width: 1)
      .gridCellUnsizedAxes(.vertical)
  }
}

/// One cell, drawn as whatever `BoardTablePresentation` decided it was.
private struct BoardCellView: View {
  let cell: BoardTablePresentation.Cell
  let column: BoardTablePresentation.Column

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: column.frameAlignment)
      .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder
  private var content: some View {
    switch cell {
    case .plain(let text):
      Text(text)
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.85))
    case .verdict(let passed, let text):
      HStack(spacing: 4) {
        Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
          .font(.system(size: 9))
        Text(text)
          .font(.system(size: 10.5, weight: .medium))
      }
      .foregroundStyle(passed ? BoardPalette.affirm : BoardPalette.deny)
      .padding(.horizontal, 5)
      .padding(.vertical, 1.5)
      .background(
        (passed ? BoardPalette.affirm : BoardPalette.deny).opacity(0.12),
        in: Capsule())
    case .delta(let isAddition, let text):
      Text(text)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(isAddition ? BoardPalette.affirm : BoardPalette.deny)
    case .number(let text, let fraction):
      VStack(alignment: column.barAlignment, spacing: 2) {
        Text(text)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.white.opacity(0.72))
        if let fraction, column.showsBars {
          // Under the figure rather than behind it. A track behind the text tints the
          // number itself, and the one thing a number in a table has to stay is legible.
          Capsule()
            .fill(.white.opacity(0.22))
            .frame(width: max(3, 34 * fraction), height: 2)
        }
      }
    }
  }
}
