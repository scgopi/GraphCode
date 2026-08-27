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
        iconButton("doc.on.doc", help: copyHelp(board)) { copy(board) }
        if board.form == .flow {
          iconButton("square.and.arrow.down", help: "Export for Excalidraw") { export(board) }
        }
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
  private func copy(_ board: SummaryBoard) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(Self.pasteboardText(for: board), forType: .string)
  }

  /// What a board is portable *as*, which is not one answer for both forms.
  ///
  /// A flow is Mermaid and belongs in a fenced `mermaid` block, where a pull request or an
  /// issue draws it. A table is GitHub-flavoured Markdown and is already a table anywhere
  /// it is pasted — wrapping it in a Mermaid fence made it render as a failed diagram in
  /// every one of those places.
  static func pasteboardText(for board: SummaryBoard) -> String {
    switch board.form {
    case .flow: return "```mermaid\n\(board.source)\n```"
    case .table: return board.source
    }
  }

  private func copyHelp(_ board: SummaryBoard) -> LocalizedStringKey {
    board.form == .flow ? "Copy the Mermaid" : "Copy the Markdown"
  }

  /// The same diagram, somewhere it can be rearranged by hand.
  ///
  /// **Flow boards only.** A table has no geometry to export — it is rows and columns, and
  /// Excalidraw has no table. Copying the Markdown is what a table is portable *as*, so the
  /// button is simply absent rather than present and disappointing.
  ///
  /// A save panel rather than a fixed location: this is a file the human is going to open
  /// somewhere else, so where it lands is theirs to choose.
  private func export(_ board: SummaryBoard) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "\(fileStem(board)).excalidraw"
    panel.allowedContentTypes = []
    panel.canCreateDirectories = true
    panel.title = String(localized: "Export for Excalidraw")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    // Written from the same layout the rail is drawing, so what lands in the file is what
    // is on screen rather than a second interpretation of the Mermaid.
    guard
      let data = try? BoardExcalidrawExport.data(
        for: board, layout: BoardLayout(board: board))
    else { return }
    try? data.write(to: url)
  }

  private func fileStem(_ board: SummaryBoard) -> String {
    let name = board.title ?? node.title
    let safe = name.unicodeScalars.map {
      CharacterSet.alphanumerics.contains($0) ? Character($0) : "-"
    }
    let stem = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return stem.isEmpty ? "board" : stem
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
