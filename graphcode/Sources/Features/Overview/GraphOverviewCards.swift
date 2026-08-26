import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// What the Graph view actually draws: the lines, the folder chips, and one card per
/// loop. Split out of `GraphOverviewView` purely for size — the same split
/// `NodeDraftForm` got out of `ProjectCanvasView`.
/// The overview and the attention rollup are built once per body pass and passed in —
/// see `GraphOverviewView.Derived` for why these don't compute their own.
extension GraphOverviewView {
  func linksLayer(_ overview: GraphOverview) -> some View {
    ForEach(overview.links) { link in
      switch link.kind {
      case .edge(let kind, let fired):
        EdgeLineView(
          from: link.from, to: link.to, kind: kind, fired: fired, label: link.label)
      case .containment:
        // The overview never emits one — sub-graphs are expanded on a folder's own
        // canvas, not here — but the renderer covers every kind the shared type has.
        Path { path in
          path.move(to: link.from)
          path.addLine(to: link.to)
        }
        .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
      }
    }
  }

  /// A `+` at each lane's origin, revealed when the pointer comes near it: a top-level
  /// loop in *that* folder, which the origin then draws a line to like any other
  /// beginning. The same handle the folder's own canvas puts on its origin dot.
  ///
  /// The one create the Graph view was missing. A card's `+` continues a chain and the
  /// top-right New Loop lands in the global graph, so starting a *new* chain in a
  /// particular folder meant crossing to that folder's canvas first.
  /// Only on lanes that *have* an origin dot: `CanvasBandView` draws one exactly when a
  /// lane has entry ports, and a `+` floating where no dot is reads as a stray control.
  /// A lane whose loops are all in a cycle keeps the top-right New Loop.
  func entryHandleLayer(_ overview: GraphOverview) -> some View {
    ForEach(overview.tetheredFolders) { folder in
      CanvasEntryHandle(help: "New loop in \(folder.name)") {
        store.send(.projects(.element(id: folder.path, action: .addEntryLoopTapped)))
      }
      .position(folder.originPosition)
    }
  }

  @ViewBuilder
  func startNodeLayer(_ overview: GraphOverview) -> some View {
    if let center = overview.startNode {
      // Tethered lanes only — a folder with nothing in it has no origin dot for the
      // connector to land on, and a line into an empty band reads as a mistake.
      ForEach(overview.tetheredFolders) { folder in
        startConnector(from: center, to: folder.originPosition)
      }
      startNodeMarker.position(center)
    }
  }

  private var startNodeMarker: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10)
        .fill(Color.white.opacity(0.06))
        .overlay {
          RoundedRectangle(cornerRadius: 10)
            .stroke(CanvasBand.railTint, lineWidth: 1.5)
        }
      Text("START")
        .font(.system(size: 10, weight: .bold))
        .tracking(0.5)
        .foregroundStyle(.white.opacity(0.55))
    }
    .frame(width: 52, height: 28)
    .allowsHitTesting(false)
  }

  private func startConnector(from origin: CGPoint, to target: CGPoint) -> some View {
    Path { path in
      path.move(to: origin)
      let reach = max((target.x - origin.x) * 0.5, 20)
      path.addCurve(
        to: target,
        control1: CGPoint(x: origin.x + reach, y: origin.y),
        control2: CGPoint(x: target.x - reach, y: target.y))
    }
    .stroke(CanvasBand.railTint, lineWidth: 1.5)
    .allowsHitTesting(false)
  }

  /// One band per open folder, drawn under everything. The band *is* the folder now —
  /// there is no chip and no tether, because a lane containing a project's loops says
  /// "these belong together" without a line drawn to explain it.
  func bandsLayer(_ overview: GraphOverview) -> some View {
    ForEach(overview.folders) { folder in
      CanvasBandView(
        rect: folder.band,
        name: folder.name,
        caption: folder.caption,
        glyph: folder.isGlobal ? "globe" : "folder.fill",
        entryPorts: folder.entryPorts,
        // A folder's caption goes to that folder's own canvas — where you can actually
        // edit it. The overview is for seeing the whole thing, not for rewiring it. The
        // global lane leads nowhere: this view already *is* it.
        onCaptionTapped: folder.isGlobal
          ? nil : { store.send(.projectHeaderTapped(folder.path)) },
        worktreeChip: worktreeChip(for: folder),
        onWorktreeChipTapped: {
          store.send(.worktrees(.sweepRequested(projectPath: folder.path)))
        }
      )
      .help(folder.isGlobal ? "Loops that belong to no folder" : folder.path)
      // Only the caption row takes hits (the band itself must not swallow canvas pans),
      // so this is a right-click on the caption — the same menu, same position, as the
      // sidebar row's, because the band is the folder.
      .contextMenu {
        if !folder.isGlobal {
          FolderHygieneMenuItems(store: store, projectPath: folder.path)
          RemoteConnectionMenuItems(store: store, projectPath: folder.path)
          Divider()
          Button("Close Folder") { store.send(.projectCloseTapped(folder.path)) }
        }
      }
    }
  }

  private func worktreeChip(for folder: GraphOverview.Folder) -> WorktreeChipModel? {
    guard !folder.isGlobal else { return nil }
    return WorktreeChipModel(
      stats: store.worktreeStats[folder.path],
      policy: SettingsModel.shared.settings.worktreePolicy(forProjectPath: folder.path))
  }

  /// One card per loop, all of them clickable — a composite is drawn as the single loop
  /// it is, not expanded into its sub-graph. See `GraphOverview` for why.
  func loopsLayer(
    _ overview: GraphOverview, reasons: [UUID: AttentionReason], now: Date
  ) -> some View {
    ForEach(overview.loops) { loop in
      HoverRevealingCard {
        loopCard(loop, reason: reasons[loop.node.id], now: now)
      } handle: {
        connectorHandle(for: loop)
      }
      .position(loop.position)
    }
  }

  /// The same hover-revealed `+` a folder's canvas puts on a card, minus the drag half:
  /// a click creates a loop in *that card's folder*, already handed off from it.
  ///
  /// Tap-only because a `.handoff` between two folders isn't something graphcode can
  /// express (docs/02-graph-of-loops.md keeps the hierarchy flat), so a wire dragged
  /// across lanes could only ever end in a refusal. Creating from here is a different
  /// matter — the loop lands on the folder the parent already belongs to, which is a
  /// thing the graph can hold, and it saves crossing to that folder's canvas to say so.
  private func connectorHandle(for loop: GraphOverview.Loop) -> some View {
    CanvasConnectorHandle()
      .onTapGesture {
        store.send(
          .projects(.element(id: loop.projectPath, action: .addChildNodeTapped(loop.node.id))))
      }
      .help("New loop handed off from \(loop.node.title)")
  }

  /// The same `LoopCardView` a project's own canvas draws, so a loop reads identically
  /// wherever you meet it. Only the menu differs: from here a loop can be opened or
  /// revealed in its folder, but not rewired — see this view's own doc comment.
  private func loopCard(
    _ loop: GraphOverview.Loop, reason: AttentionReason?, now: Date
  ) -> some View {
    let node = loop.node
    return LoopCardView(
      node: node, reason: reason, now: now, entryRole: loop.entryRole,
      onPrimaryAction: { open(loop) },
      // The overview is read-only — rewiring happens on the folder's own canvas, which
      // is where you can see what you are rewiring. Both verbs go there.
      onWireUp: { store.send(.projectHeaderTapped(loop.projectPath)) },
      onMarkAsEntry: { store.send(.projectHeaderTapped(loop.projectPath)) },
      // The resolve moment reads the same here as on the folder's own canvas — the
      // offer lives in that project's scope either way.
      reclaimOffer: store.projects[id: loop.projectPath]?.worktreeReclaimOffers[node.id],
      onReclaim: {
        store.send(
          .projects(.element(id: loop.projectPath, action: .reclaimWorktreeTapped(node.id))))
      },
      onKeep: {
        store.send(
          .projects(.element(id: loop.projectPath, action: .keepWorktreeTapped(node.id))))
      }
    )
    .contentShape(Rectangle())
    .onTapGesture { open(loop) }
    .contextMenu { loopMenu(loop) }
  }

  /// The same verbs the sidebar offers on a loop row, in the same order — a loop should
  /// answer to the same menu wherever you right-click it, and until now this one stopped
  /// at Open, Reveal and Stop.
  ///
  /// All of them work from here without switching folders first. Export and Import run
  /// their own panels straight from the reducer; Rename and Delete present from
  /// `AppView`, which hosts those two dialogs for the whole window; and the creation
  /// sheet has a host per folder mounted on this view already (`nodeFormHosts`), which is
  /// what the sidebar has to select a project to get.
  ///
  /// What stays out is what the overview cannot show you the consequences of: rewiring,
  /// and drilling into a composite's sub-graph. Reveal is the answer to both.
  @ViewBuilder
  private func loopMenu(_ loop: GraphOverview.Loop) -> some View {
    let node = loop.node
    Button("Open Terminal") { open(loop) }
    if !node.isResolved {
      Button("New Child Loop…") { send(.newChildLoopTapped(node.id), to: loop.projectPath) }
    }
    if node.loopType == .composite {
      Button("Pilot Once…") { send(.pilotCompositeTapped(node.id), to: loop.projectPath) }
      Button("Arm Schedule") { send(.armCompositeTapped(node.id), to: loop.projectPath) }
        .disabled(!node.pilotState.canArm)
    }
    Button("Rename…") { send(.renameNodeRequested(node.id), to: loop.projectPath) }
    if !node.isResolved {
      Button("Stop Loop") {
        store.send(.stopNodeTapped(projectPath: loop.projectPath, nodeID: node.id))
      }
    }

    Divider()

    Button("Reveal in \(folderName(loop.projectPath))") {
      store.send(.projectHeaderTapped(loop.projectPath))
    }

    Divider()

    // Behind the experiments switch, exactly as on a folder's canvas and in the sidebar:
    // a right-click verb that writes files and splices loops into graphs is one a person
    // should choose, not find. Read inline like the folder canvas's menu does — the
    // sidebar's outline is the one place that cannot (see `AppSidebarView.sharesLoops`).
    if SettingsModel.shared.settings.sharesLoops {
      Button("Export Loop…") { send(.exportNodeRequested(node.id), to: loop.projectPath) }
      Button("Import Loops Here…") {
        send(.importLoopsRequested(asChildOf: node.id), to: loop.projectPath)
      }
      Divider()
    }

    Button("Delete Loop…", role: .destructive) {
      send(.deleteNodeRequested(node.id), to: loop.projectPath)
    }
  }

  private func send(_ action: ProjectFeature.Action, to projectPath: String) {
    store.send(.projects(.element(id: projectPath, action: action)))
  }

}
