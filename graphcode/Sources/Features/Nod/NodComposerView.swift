import AppKit
import ComposableArchitecture
import GraphcodeKit
import SwiftUI
import UniformTypeIdentifiers

/// Design section 2: attachments over the draft, the draft, then the chips — model (with
/// cost beside it), edit policy — and the key hints. ⏎ queues, ⌘⏎ steers, esc stops.
struct NodComposerView: View {
  @Bindable var store: StoreOf<NodChatFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !store.attachments.isEmpty {
        attachmentRow
      }
      NodComposerTextView(
        text: $store.draft.sending(\.draftChanged),
        placeholder: placeholder,
        onReturn: { store.send(.returnPressed) },
        onSteer: { store.send(.commandReturnPressed) },
        onEscape: { store.send(.escapePressed) },
        onTab: chooseFirstMentionAlternate
      )
      .fixedSize(horizontal: false, vertical: true)
      chipRow
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(RoundedRectangle(cornerRadius: 12).fill(NodStyle.composerBackground))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
    .overlay(alignment: .topLeading) {
      menu.alignmentGuide(.top) { $0[.bottom] + 6 }
    }
    .onDrop(of: [.fileURL], isTargeted: nil, perform: dropFiles)
  }

  private var placeholder: String {
    store.transcript.isRunning ? "Steer Nod while it works…" : "Ask Nod…"
  }

  private var attachmentRow: some View {
    FlowRow {
      ForEach(Array(store.attachments.enumerated()), id: \.offset) { index, attachment in
        HStack(spacing: 5) {
          Text(Self.glyph(attachment.kind)).foregroundStyle(NodStyle.muted)
          Text(Self.label(attachment)).foregroundStyle(NodStyle.body).lineLimit(1)
          Button {
            store.send(.attachmentRemoved(index))
          } label: {
            Text("×").foregroundStyle(NodStyle.muted)
          }
          .buttonStyle(.plain)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
      }
    }
  }

  private var chipRow: some View {
    HStack(spacing: 8) {
      Menu {
        Button("File…") { pickFiles(images: false) }
        Button("Image…") { pickFiles(images: true) }
        let finished = store.mentionCandidates.filter {
          if case .loop(_, false, _) = $0.kind { return true }
          return false
        }
        if !finished.isEmpty {
          Menu("Loop transcript") {
            ForEach(finished) { mention in
              Button(mention.title) { store.send(.mentionChosen(mention, alternate: false)) }
            }
          }
        }
      } label: {
        Text("＋").font(.system(size: 11)).foregroundStyle(NodStyle.muted)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()

      Menu {
        ForEach(NodModelCatalog.models(for: store.engine)) { model in
          Button(model.displayName) { store.send(.modelChosen(model.id)) }
        }
      } label: {
        NodChip { Text("\(NodChatPresentation.modelLabel(store.model, engine: store.engine)) ▾") }
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()

      if let cost = NodChatPresentation.costLabel(for: store.transcript) {
        Text(cost).font(.system(size: 11, design: .monospaced)).foregroundStyle(NodStyle.muted)
      }

      Menu {
        Button("Ask before edits") { store.send(.delegate(.editPolicyChosen(.reviewHunks))) }
        Button("Auto-accept edits") { store.send(.delegate(.editPolicyChosen(.auto))) }
      } label: {
        NodChip { Text("\(Self.editPolicyLabel(store.editPolicy)) ▾") }
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()

      Spacer(minLength: 8)
      Text(
        store.transcript.isRunning
          ? "⏎ queue · ⌘⏎ steer · esc stop" : "⏎ send · @ loops · / commands"
      )
      .font(.system(size: 11))
      .foregroundStyle(Color.white.opacity(0.5))
    }
  }

  @ViewBuilder
  private var menu: some View {
    switch store.trigger {
    case .slash(let query):
      let commands = NodSlashCommand.matching(query)
      if !commands.isEmpty {
        NodSlashMenuView(commands: commands) { store.send(.slashCommandChosen($0)) }
      }
    case .mention(let query):
      let mentions = NodMention.matching(query, in: store.mentionCandidates)
      if !mentions.isEmpty {
        NodMentionMenuView(query: query, mentions: mentions) {
          store.send(.mentionChosen($0, alternate: false))
        }
      }
    case nil:
      EmptyView()
    }
  }

  private func chooseFirstMentionAlternate() -> Bool {
    guard case .mention(let query) = store.trigger,
      let first = NodMention.matching(query, in: store.mentionCandidates).first
    else { return false }
    store.send(.mentionChosen(first, alternate: true))
    return true
  }

  private func pickFiles(images: Bool) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    if images { panel.allowedContentTypes = [.image] }
    guard panel.runModal() == .OK else { return }
    for url in panel.urls { attach(url) }
  }

  private func dropFiles(_ providers: [NSItemProvider]) -> Bool {
    for provider in providers {
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        DispatchQueue.main.async { attach(url) }
      }
    }
    return true
  }

  private func attach(_ url: URL) {
    let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    store.send(
      .attachmentAdded(
        NodAttachment(kind: isImage ? .image : .file, reference: url.path, label: nil)))
  }

  static func glyph(_ kind: NodAttachment.Kind) -> String {
    switch kind {
    case .file: return "#"
    case .image: return "▣"
    case .loopTranscript: return "◇"
    }
  }

  static func label(_ attachment: NodAttachment) -> String {
    if let label = attachment.label {
      return attachment.kind == .loopTranscript ? "\(label) · transcript" : label
    }
    return (attachment.reference as NSString).lastPathComponent
  }

  static func editPolicyLabel(_ policy: NodSettings.EditPolicy) -> String {
    switch policy {
    case .reviewHunks: return "Ask before edits"
    case .auto: return "Auto"
    }
  }
}

struct NodSlashMenuView: View {
  let commands: [NodSlashCommand]
  let onChoose: (NodSlashCommand) -> Void

  var body: some View {
    NodPopover {
      ForEach([NodSlashCommand.Group.thisLoop, .graph], id: \.self) { group in
        let rows = commands.filter { $0.group == group }
        if !rows.isEmpty {
          NodPopoverHeader(title: group.rawValue)
          ForEach(rows) { command in
            Button {
              onChoose(command)
            } label: {
              HStack(spacing: 10) {
                Text("/\(command.name)").font(.system(size: 12, design: .monospaced))
                  .foregroundStyle(NodStyle.ink)
                  .frame(width: 76, alignment: .leading)
                Text(command.detail).font(.system(size: 12)).foregroundStyle(NodStyle.muted)
                Spacer(minLength: 0)
              }
              .padding(.horizontal, 10)
              .padding(.vertical, 4)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }
}

struct NodMentionMenuView: View {
  let query: String
  let mentions: [NodMention]
  let onChoose: (NodMention) -> Void

  var body: some View {
    NodPopover {
      let loops = mentions.filter { if case .loop = $0.kind { return true } else { return false } }
      let files = mentions.filter { if case .file = $0.kind { return true } else { return false } }
      if !loops.isEmpty {
        NodPopoverHeader(title: query.isEmpty ? "Loops" : "Loops · @\(query)")
        ForEach(loops) { row($0) }
      }
      if !files.isEmpty {
        NodPopoverHeader(title: "Files")
        ForEach(files) { row($0) }
      }
    }
  }

  private func row(_ mention: NodMention) -> some View {
    Button {
      onChoose(mention)
    } label: {
      HStack(spacing: 8) {
        if case .file = mention.kind {
          Text("#").foregroundStyle(NodStyle.muted)
        }
        Text(mention.title).foregroundStyle(NodStyle.ink)
        if case .loop(_, _, let detail) = mention.kind {
          Text(detail).foregroundStyle(NodStyle.muted)
        }
        Spacer(minLength: 8)
        Text(mention.defaultActionLabel).foregroundStyle(NodStyle.actionInk)
      }
      .font(.system(size: 12))
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

private struct NodPopover<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) { content }
      .padding(.vertical, 6)
      .frame(width: 380, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.17)))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1))
      .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
  }
}

private struct NodPopoverHeader: View {
  let title: String

  var body: some View {
    Text(title)
      .font(.system(size: 10.5, weight: .bold))
      .textCase(.uppercase)
      .foregroundStyle(NodStyle.muted)
      .padding(.horizontal, 10)
      .padding(.top, 6)
      .padding(.bottom, 2)
  }
}

/// Lays chips left to right, wrapping when the row is full.
private struct FlowRow: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(width: proposal.width ?? .infinity, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let arrangement = arrange(width: bounds.width, subviews: subviews)
    for (subview, origin) in zip(subviews, arrangement.origins) {
      subview.place(
        at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
    }
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
    var origins: [CGPoint] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var widest: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      origins.append(CGPoint(x: x, y: y))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
      widest = max(widest, x - spacing)
    }
    return (CGSize(width: widest, height: y + rowHeight), origins)
  }
}

/// An `NSTextView` rather than a SwiftUI field: SwiftUI's focus cannot take first responder
/// off a Ghostty surface in the same window (the zsh split beside the chat), and the keys
/// that matter here — ⏎, ⌘⏎, esc, ⇥ — arrive as AppKit commands before SwiftUI sees them.
struct NodComposerTextView: NSViewRepresentable {
  @Binding var text: String
  var placeholder: String
  var onReturn: () -> Void
  var onSteer: () -> Void
  var onEscape: () -> Void
  /// Returns whether it consumed the ⇥.
  var onTab: () -> Bool

  static let font = NSFont.systemFont(ofSize: 13)
  /// The box grows with what is typed up to this many lines, then scrolls.
  static let maximumVisibleLines = 5

  /// The box's height for text laid out `usedHeight` tall: at least one line, at most
  /// `maximumVisibleLines`.
  static func height(forUsedHeight usedHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
    min(max(usedHeight, lineHeight), lineHeight * CGFloat(maximumVisibleLines))
  }

  static var lineHeight: CGFloat { NSLayoutManager().defaultLineHeight(for: font) }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let textView = ComposerTextView(frame: .zero)
    textView.delegate = context.coordinator
    textView.coordinator = context.coordinator
    textView.isRichText = false
    textView.allowsUndo = true
    textView.drawsBackground = false
    textView.font = Self.font
    textView.textColor = NSColor.white.withAlphaComponent(0.92)
    textView.insertionPointColor = .white
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    // Without a maximum size an NSTextView made in code never grows past its first line,
    // so the box got taller while the text inside stayed one line high.
    textView.minSize = .zero
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.containerSize = NSSize(
      width: 0, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    textView.placeholder = placeholder

    let scroll = ComposerScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.documentView = textView
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let textView = scroll.documentView as? ComposerTextView else { return }
    if textView.string != text {
      textView.string = text
      textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }
    if textView.placeholder != placeholder {
      textView.placeholder = placeholder
      textView.needsDisplay = true
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context)
    -> CGSize?
  {
    guard let textView = nsView.documentView as? NSTextView,
      let container = textView.textContainer, let manager = textView.layoutManager
    else { return nil }
    let width = proposal.width ?? max(nsView.frame.width, 1)
    container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    manager.ensureLayout(for: container)
    return CGSize(
      width: width,
      height: Self.height(
        forUsedHeight: manager.usedRect(for: container).height, lineHeight: Self.lineHeight))
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: NodComposerTextView

    init(_ parent: NodComposerTextView) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      parent.text = textView.string
      // Past five lines the box scrolls; keep the line being typed in view.
      textView.scrollRangeToVisible(textView.selectedRange())
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      switch selector {
      case #selector(NSResponder.insertNewline(_:)):
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
          parent.onSteer()
        } else {
          parent.onReturn()
        }
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        parent.onEscape()
        return true
      case #selector(NSResponder.insertTab(_:)):
        return parent.onTab()
      default:
        return false
      }
    }
  }

  /// Typing a new line grows the text view before SwiftUI grows the box, and AppKit scrolls
  /// to the caret in between; the offset outlived the resize and pushed a line out of view.
  /// After every resize the box shows everything when it fits, and the caret when it does not.
  final class ComposerScrollView: NSScrollView {
    override func layout() {
      super.layout()
      guard let textView = documentView as? NSTextView else { return }
      if textView.frame.height <= contentView.bounds.height + 0.5 {
        if contentView.bounds.origin != .zero {
          contentView.scroll(to: .zero)
          reflectScrolledClipView(contentView)
        }
      } else {
        textView.scrollRangeToVisible(textView.selectedRange())
      }
    }
  }

  final class ComposerTextView: NSTextView {
    weak var coordinator: Coordinator?
    var placeholder = ""

    /// ⌘⏎ never reaches `insertNewline` — AppKit treats it as a key equivalent — so it is
    /// caught here first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
      if window?.firstResponder === self, event.keyCode == 36,
        event.modifierFlags.contains(.command)
      {
        coordinator?.parent.onSteer()
        return true
      }
      return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      guard string.isEmpty else { return }
      (placeholder as NSString).draw(
        at: .zero,
        withAttributes: [
          .font: font ?? .systemFont(ofSize: 13),
          .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ])
    }
  }
}
