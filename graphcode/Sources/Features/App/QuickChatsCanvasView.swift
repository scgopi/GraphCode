import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The **Quick Chats** canvas — every ad-hoc session on one pan/zoom surface, hanging off
/// a start marker, drawn exactly like a folder's graph. What the sidebar's Quick Chats
/// header row opens.
///
/// Chats are a project-like thing without a project (see `QuickChat`), so the surface that
/// shows them is a canvas rather than a list: clicking the row that lists sessions should
/// land you somewhere that looks like every other place sessions live, not on a blank
/// pane. Scoped to `AppFeature` rather than to a `ProjectFeature` because that's where the
/// chats are — they belong to no graph the daemon knows about, so there is no project
/// store to scope to.
///
/// **No edges, ever.** A chat has no goal, no trigger, and nothing to hand off to, so
/// there is nothing to wire between two of them — every card hangs straight off the start
/// marker, which is what each of them is: an entry point and nothing more. That's also
/// why the cards carry no loop-type stripe and no presence dot; both would claim
/// semantics a chat doesn't have.
struct QuickChatsCanvasView: View {
  @Bindable var store: StoreOf<AppFeature>

  /// Narrower than a loop card: a chat has a name and an age, not a state, a goal, and a
  /// trend. Kept here so the band that encloses these cards knows how wide they are.
  private static let cardWidth: CGFloat = 220
  /// Only the band needs this — the card itself is sized by its content.
  private static let cardHeight: CGFloat = 64

  /// Where the canvas is looking. See `CanvasTransform` for why the scale and offset are
  /// one value with arithmetic on it rather than two numbers the gestures nudge.
  @State private var transform = CanvasTransform()
  @State private var dragOffset: CGSize = .zero
  /// The scale the current pinch started from. `MagnifyGesture.magnification` is relative
  /// to the start of *that* gesture, so without a captured baseline every new pinch would
  /// snap the canvas back to 1× before it moved anywhere.
  @State private var pinchBaseScale: CGFloat?
  @State private var viewport: CGSize = .zero

  /// One chat and where its card goes. Derived rather than stored, and laid out with the
  /// same grid a folder's freshly synced nodes get (`ProjectFeature.gridPosition`), so a
  /// chat card lands on the same rhythm as a loop card — this is a viewer, not a second
  /// canvas you arrange by hand.
  private struct Placement: Identifiable {
    let chat: QuickChat
    let position: CGPoint

    var id: UUID { chat.id }
  }

  private var placements: [Placement] {
    store.quickChats.enumerated().map { index, chat in
      Placement(chat: chat, position: ProjectFeature.gridPosition(index))
    }
  }

  var body: some View {
    let placements = placements

    return canvas(placements)
      .overlay { emptyState }
      .overlay(alignment: .bottomTrailing) {
        CanvasZoomControls(
          transform: $transform, viewport: viewport, content: contentSize(placements))
      }
      // Top-right and quiet, the same placement and styling a folder canvas's New Loop
      // has — see `ProjectCanvasView` for why it isn't in the window toolbar.
      .overlay(alignment: .topTrailing) {
        CanvasAddButton(help: "New Chat") { store.send(.newQuickChatTapped) }
          .padding(12)
      }
      .background(Theme.windowBackground)
  }

  /// Scale and offset as the canvas is currently drawn — the committed transform plus
  /// whatever the in-flight pan has moved so far.
  private var liveOffset: CGSize {
    CGSize(
      width: transform.offset.width + dragOffset.width,
      height: transform.offset.height + dragOffset.height)
  }

  /// How much room the cards take up, for actual-size and fit. Measured out past the far
  /// edge of the furthest card rather than to its centre, so fitting doesn't crop the
  /// thing it was asked to fit.
  private func contentSize(_ placements: [Placement]) -> CGSize {
    guard let right = placements.map(\.position.x).max(),
      let bottom = placements.map(\.position.y).max()
    else { return .zero }
    return CGSize(width: right + 160, height: bottom + 120)
  }

  /// Centres the cards, but only while the canvas is still where it started: once someone
  /// has panned or zoomed, their view is theirs and nothing here moves it.
  private func centreIfUntouched(in viewport: CGSize, content: CGSize) {
    guard transform == CanvasTransform(), viewport != .zero, content != .zero else {
      return
    }
    transform = .fitting(content, in: viewport)
  }

  private func canvas(_ placements: [Placement]) -> some View {
    let content = contentSize(placements)
    return GeometryReader { proxy in
      ZStack {
        bandLayer(placements)
        cardsLayer(placements)
      }
      .scaleEffect(transform.scale)
      .offset(liveOffset)
      .onAppear {
        viewport = proxy.size
        centreIfUntouched(in: proxy.size, content: content)
      }
      .onChange(of: proxy.size) { _, size in
        viewport = size
        centreIfUntouched(in: size, content: content)
      }
      // Chats are read off disk a beat after this view first draws, so the first paint
      // often has nothing to centre on.
      .onChange(of: content) { _, size in centreIfUntouched(in: viewport, content: size) }
    }
    .background {
      // The same ruled sheet a folder's canvas has, glued to the cards rather than to the
      // window so dragging empty space reads as moving the sheet under you.
      NotebookGrid(
        cellSize: NotebookGrid.defaultCellSize, offset: liveOffset, scale: transform.scale
      )
      .background(Theme.canvasBackground)
    }
    .contentShape(Rectangle())
    .gesture(
      DragGesture()
        .onChanged { value in dragOffset = value.translation }
        .onEnded { value in
          transform.offset.width += value.translation.width
          transform.offset.height += value.translation.height
          dragOffset = .zero
        }
    )
    // Trackpad pinch, anchored where the fingers are, exactly as on the other two
    // canvases — `magnification` is relative to the start of this gesture, so it
    // multiplies the scale the pinch began at rather than replacing it.
    .simultaneousGesture(
      MagnifyGesture()
        .onChanged { value in
          let base = pinchBaseScale ?? transform.scale
          pinchBaseScale = base
          transform = transform.zoomed(
            to: base * value.magnification, around: value.startLocation, in: viewport)
        }
        .onEnded { _ in pinchBaseScale = nil }
    )
    .background { CanvasScrollHandler(transform: $transform, viewport: viewport) }
  }

  /// The band the chats sit in — unlabelled, like a project canvas's, since this pane is
  /// already entirely Quick Chats. It replaced an origin dot and a tether per card: chats
  /// hand off to nothing and start nowhere, so lines drawn from a shared origin were
  /// saying something about them that was never true.
  ///
  /// **Emits a sibling — never wrap this in a container**: it is placed with
  /// `.position()`, which resolves against its immediate parent's frame, so it has to
  /// land directly in `canvas`'s pane-filling `ZStack`.
  @ViewBuilder
  private func bandLayer(_ placements: [Placement]) -> some View {
    let rect = CanvasBand.rect(
      around: placements.map(\.position),
      cardSize: CGSize(width: Self.cardWidth, height: Self.cardHeight),
      captioned: false)
    if let rect {
      CanvasBandView(rect: rect)
    }
  }

  private func cardsLayer(_ placements: [Placement]) -> some View {
    ForEach(placements) { placement in
      chatCard(placement.chat).position(placement.position)
    }
  }

  private func chatCard(_ chat: QuickChat) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(chat.title).font(.headline).lineLimit(1)
      HStack(spacing: 4) {
        Image(systemName: "bubble.left.and.bubble.right")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text("chat").font(.caption2).foregroundStyle(.secondary)
        // Only when it isn't the default, the same rule a loop card follows — a backend
        // badge on every card would be noise in the common single-backend case.
        if chat.backend != .claudeCode {
          Text(chat.backend.displayName).font(.caption2).foregroundStyle(.tertiary)
        }
      }
    }
    .padding(10)
    .frame(width: Self.cardWidth, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    // A neutral stripe, not one of the four loop-kind hues: those four mean "this is what
    // the loop does", and a fifth colour here would read as a fifth kind of loop rather
    // than as the absence of one.
    .overlay(alignment: .leading) {
      UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10)
        .fill(Color.secondary.opacity(0.5))
        .frame(width: 4)
    }
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
    )
    // Neutral lift — `cardGlow`'s default — since the tint a loop card glows with is its
    // kind's, and a chat has none. See `cardGlow` for why elevation here is a glow at all.
    .cardGlow()
    .contentShape(Rectangle())
    .onTapGesture { store.send(.quickChatTapped(chat.id)) }
    .contextMenu {
      Button("Open Chat") { store.send(.quickChatTapped(chat.id)) }
      Button("Rename…") { store.send(.quickChatRenameRequested(chat.id)) }
      Divider()
      Button("Delete Chat…", role: .destructive) {
        store.send(.quickChatDeleteRequested(chat.id))
      }
    }
  }

  /// Drawn as an overlay rather than as a branch on `canvas` so panning and zooming stay
  /// live underneath: `CanvasEmptyState` fills no hit-testable shape, so drags on the
  /// surrounding space still reach the canvas gesture.
  @ViewBuilder
  private var emptyState: some View {
    if store.quickChats.isEmpty {
      CanvasEmptyState(
        symbol: "bubble.left.and.bubble.right",
        title: "No chats yet",
        message:
          "A quick chat is a bare session with no goal, no trigger, and no place in any "
          + "graph — for the questions that aren't a loop's work.",
        actionTitle: "New Chat"
      ) {
        store.send(.newQuickChatTapped)
      }
    }
  }
}

#Preview {
  QuickChatsCanvasView(store: Store(initialState: AppFeature.State()) { AppFeature() })
}
