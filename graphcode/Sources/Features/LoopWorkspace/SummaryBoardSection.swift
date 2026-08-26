import AppKit
import GraphcodeKit
import SwiftUI

/// The picture of the run, under the sentence about it — the second section of the
/// workspace rail.
///
/// `LoopSummarySection` above answers *what is it doing*, in the agent's own words. This
/// answers *what shape did the work have*, which is the question a sentence is bad at: a
/// plan with a branch in it, a pipeline with four stages, a table of what six files each
/// gave up. The rail opens wider when one of these is showing, because a diagram at 188
/// points is a diagram nobody reads.
struct SummaryBoardSection: View {
  let node: LoopNode
  let isFolded: Bool
  let onToggleFold: () -> Void
  let onExpand: () -> Void

  private var presentation: SummaryBoardPresentation {
    SummaryBoardPresentation(node: node)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      let presentation = presentation
      header(presentation)
      if !isFolded {
        content(presentation)
      }
      Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
    }
  }

  @ViewBuilder
  private func content(_ presentation: SummaryBoardPresentation) -> some View {
    if let board = presentation.board {
      if let title = board.title, !title.isEmpty {
        Text(title)
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(.white.opacity(0.75))
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      SummaryBoardView(board: board, accent: node.loopType.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      Text("Nothing to draw yet")
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.35))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }
  }

  /// The word, which pass it is of, and the two things you can do to a board: take the
  /// Mermaid somewhere else, or give it the whole window.
  ///
  /// The whole row folds it, like the summary's — a 14pt chevron is not a click target
  /// anyone aims at. The buttons above it stop the tap from reaching the row, which is why
  /// they are buttons rather than tap gestures.
  private func header(_ presentation: SummaryBoardPresentation) -> some View {
    HStack(spacing: 7) {
      Text(headerTitle(presentation))
        .font(.system(size: 10.5, weight: .bold))
        .tracking(0.63)
        .foregroundStyle(.white.opacity(0.5))
      if let pass = presentation.pass, pass > 0 {
        Text("PASS \(pass)")
          .font(.system(size: 9.5, weight: .medium, design: .monospaced))
          .foregroundStyle(.white.opacity(presentation.isStale ? 0.35 : 0.5))
          .help(
            presentation.isStale
              ? "Drawn from pass \(pass); the loop has moved on since"
              : "Drawn from pass \(pass)")
      }
      Spacer(minLength: 0)
      if let board = presentation.board, !isFolded {
        iconButton("doc.on.doc", help: "Copy the Mermaid") { copy(board.source) }
        iconButton("arrow.up.left.and.arrow.down.right", help: "Fill the window", action: onExpand)
      }
      Image(systemName: isFolded ? "chevron.down" : "chevron.up")
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(.white.opacity(0.6))
        .frame(width: 14, height: 14)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: onToggleFold)
    .help(isFolded ? "Show the diagram" : "Collapse the diagram")
  }

  private func headerTitle(_ presentation: SummaryBoardPresentation) -> LocalizedStringKey {
    switch presentation.mode {
    case .pending: return "VISUALISED"
    case .drawn: return presentation.board?.form == .table ? "IN COLUMNS" : "THE SHAPE OF IT"
    }
  }

  private func iconButton(
    _ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 8.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.6))
        .frame(width: 14, height: 14)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
    }
    .buttonStyle(.plain)
    .help(help)
  }

  /// The source, not a rendering. A board's whole portability is that it is Mermaid — it
  /// pastes into a pull request, an issue or anywhere else that draws one, and graphcode
  /// happens to be a place that draws it natively.
  private func copy(_ source: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString("```mermaid\n\(source)\n```", forType: .string)
  }
}

/// A board with the workspace to itself — what the section's expand button opens.
///
/// A cover over the panes rather than a window of its own: the diagram is *about* the
/// session in the terminal underneath, and a separate window would be one more thing to
/// find, arrange and close. Escape and the button both put it back.
struct ExpandedBoardView: View {
  let node: LoopNode
  let board: SummaryBoard
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(board.title ?? node.title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
          Text(caption)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.45))
        }
        Spacer(minLength: 0)
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.7))
            .frame(width: 22, height: 22)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Close")
      }
      SummaryBoardView(board: board, accent: node.loopType.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.ultraThinMaterial)
  }

  private var caption: String {
    var parts: [String] = []
    if board.pass > 0 { parts.append("pass \(board.pass)") }
    parts.append(board.composedAt.formatted(date: .omitted, time: .shortened))
    return parts.joined(separator: " · ")
  }
}
