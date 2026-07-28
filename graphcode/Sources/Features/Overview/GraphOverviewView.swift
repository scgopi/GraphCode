import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The **Graph** view — every open folder's loops on one pan/zoom canvas, hanging off a
/// single start node (docs/06-ux-terminals.md#the-graph-view). What the pinned sidebar
/// row above the folders opens.
///
/// Cross-project by nature, so it's scoped to `AppFeature` rather than to any one
/// `ProjectFeature` the way `ProjectCanvasView` is — no single project's store can see
/// the other folders' graphs. Clicking a loop opens that loop's terminal workspace
/// through the exact same action a sidebar row sends, so navigating from here isn't a
/// second way in with its own behaviour.
///
/// **Read-only.** Nothing here creates, deletes, or rewires anything: no dragging cards
/// around, no drawing edges between folders, no create button. A `.handoff` between two
/// projects isn't a thing graphcode can express (docs/02-graph-of-loops.md keeps the
/// hierarchy flat and non-recursive), so offering the gesture would only ever end in a
/// refusal — and a surface whose job is "see everything at once" is the wrong place to
/// edit one thing. Editing happens on a folder's own canvas.
struct GraphOverviewView: View {
  @Bindable var store: StoreOf<AppFeature>

  /// Where the canvas is looking. See `CanvasTransform` for why the scale and offset are
  /// one value with arithmetic on it rather than two numbers the gestures nudge.
  @State private var transform = CanvasTransform()
  @State private var dragOffset: CGSize = .zero
  /// The scale the current pinch started from. `MagnifyGesture.magnification` is
  /// relative to the start of *that* gesture, so without a captured baseline every new
  /// pinch would snap the canvas back to 1× before it moved anywhere.
  @State private var pinchBaseScale: CGFloat?
  /// The pane's size, kept so the zoom buttons and shortcuts — which have no gesture
  /// location to work from — can still zoom about its centre.
  @State private var viewport: CGSize = .zero

  var overview: GraphOverview {
    GraphOverview(graphs: store.projects.map(\.graph))
  }

  /// Which loops want a human, by node id — the same rollup the sidebar's monitor and
  /// every project canvas use, so the overview can't disagree with either about what
  /// "needs attention" means.
  var attentionReasons: [UUID: AttentionReason] {
    Dictionary(
      store.attentionItems.map { ($0.nodeID, $0.reason) }, uniquingKeysWith: { first, _ in first })
  }

  /// No toolbar at all, on purpose. This view shows loops; it does not make them — not
  /// even the global graph's own triggers, which is why there's no "New Trigger" button
  /// and no node form here. A create button in the Graph's top bar would be the one
  /// affordance that authors something on a surface whose whole job is to be read, and
  /// the loop it created would belong to a graph this view deliberately draws no chip
  /// for. Global triggers are created from the CLI (`graphcode node create
  /// graphcode://global …`); a folder's loops are created on that folder's own canvas.
  var body: some View {
    canvas
      .overlay(alignment: .bottomTrailing) { zoomControls }
      .background(Theme.windowBackground)
  }

  /// Scale and offset as the canvas is currently drawn — the committed transform plus
  /// whatever the in-flight pan has moved so far.
  private var liveOffset: CGSize {
    CGSize(
      width: transform.offset.width + dragOffset.width,
      height: transform.offset.height + dragOffset.height)
  }

  /// Centres the graph, but only while the canvas is still where it started: once
  /// someone has panned or zoomed, their view is theirs and nothing here moves it.
  private func centreIfUntouched(in viewport: CGSize) {
    guard transform == CanvasTransform(), viewport != .zero, overview.size != .zero else {
      return
    }
    transform = .centred(overview.size, in: viewport)
  }

  private var canvas: some View {
    GeometryReader { proxy in
      ZStack {
        linksLayer
        foldersLayer
        loopsLayer
        // Nothing open means nothing to originate — the empty state speaks for the
        // canvas instead. Same rule as a folder's canvas; see `CanvasStart.origin`.
        if !overview.isEmpty {
          StartMarker().position(overview.start)
        }
      }
      .scaleEffect(transform.scale)
      .offset(liveOffset)
      .overlay { emptyState }
      // Nothing has been panned yet, so first paint should put the graph where the eye
      // is rather than in the top-left corner with the lanes running off the bottom.
      .onAppear {
        viewport = proxy.size
        centreIfUntouched(in: proxy.size)
      }
      .onChange(of: proxy.size) { _, size in
        viewport = size
        centreIfUntouched(in: size)
      }
      // Folders arrive from the daemon after this view does, so the first paint has
      // nothing to centre on.
      .onChange(of: overview.size) { _, _ in centreIfUntouched(in: viewport) }
    }
    .background {
      NotebookGrid(cellSize: 96, offset: liveOffset, scale: transform.scale)
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
    // Trackpad pinch, anchored where the fingers are: the graph under them stays put
    // while everything else moves around it, which is what makes zooming feel like
    // moving a sheet rather than like resizing a picture. `magnification` is relative to
    // the start of this gesture, so it multiplies the scale the pinch began at.
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
  }

  private var zoomControls: some View {
    CanvasZoomControls(
      transform: $transform, viewport: viewport,
      content: overview.isEmpty ? .zero : overview.size)
  }

  /// The Graph row is always in the sidebar, so this view is what a fresh install lands
  /// on — before any folder has been opened there is nothing but the start marker and an
  /// empty lane, which looks identical to a canvas that failed to load. This says the
  /// graph is empty on purpose and puts the first step in it, the way `CanvasEmptyState`
  /// does for a project.
  @ViewBuilder
  private var emptyState: some View {
    if overview.loops.isEmpty {
      VStack(spacing: 10) {
        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
          .font(.system(size: 34))
          .foregroundStyle(.secondary)
        Text("Nothing running yet").font(.title3)
        Text("Loops from every folder you open show up here, wired to how they run.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 340)
        // The same panel the sidebar's Add Folder menu opens — its `fileImporter` is
        // bound to `welcome.isOpenPanelPresented`, so it doesn't matter who asks.
        Button("Open Folder…") { store.send(.welcome(.openFolderButtonTapped)) }
      }
      .padding(24)
    }
  }

  func open(_ loop: GraphOverview.Loop) {
    store.send(.projects(.element(id: loop.projectPath, action: .nodeTapped(loop.node.id))))
  }

  func folderName(_ path: String) -> String {
    store.projects[id: path]?.graph.project.name ?? "folder"
  }

}

#Preview {
  GraphOverviewView(store: Store(initialState: AppFeature.State()) { AppFeature() })
}
