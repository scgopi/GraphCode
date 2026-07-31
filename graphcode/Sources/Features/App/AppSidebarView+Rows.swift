import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The sidebar's project and loop rows — header, nested tree, and their menus. Split
/// out of `AppSidebarView` purely for size, the same split `ProjectCanvasView` got;
/// the stored state these read (`collapsedProjectPaths`, `expandedNodeIDs`, the
/// pending-dialog fields) stays on the struct, which is why none of it is `private`.
extension AppSidebarView {
  @ViewBuilder
  func projectGroup(for project: ProjectFeature.State) -> some View {
    projectHeaderRow(for: project)
      .tag(SidebarSelection.project(project.id))
      // No menu on the Graph row: it can't be closed, forgotten, or deleted, and a
      // menu of three disabled items reads as a bug rather than as a rule.
      .contextMenu {
        if !project.graph.isGlobal {
          projectMenu(for: project)
        }
      }

    if !collapsedProjectPaths.contains(project.id) {
      let rows = flattenedNodeRows(in: project)
      ForEach(rows) { entry in
        nestedNodeRow(entry, in: project)
      }
      // Drag-to-reorder, scoped to this project's own ForEach: SwiftUI only moves
      // rows within the ForEach the modifier hangs off, which is exactly the rule —
      // a loop rearranges inside its project and can never be dropped into another.
      // Only top-level rows reorder; a child's place is under its parent, so a drag
      // that includes one is ignored rather than half-applied.
      .onMove { offsets, target in
        guard offsets.allSatisfy({ rows[$0].depth == 0 }) else { return }
        var ids = rows.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: target)
        let rootIDs = ids.filter { id in rows.first { $0.id == id }?.depth == 0 }
        store.send(
          .projects(.element(id: project.id, action: .sidebarNodesReordered(rootIDs))))
      }
    }
  }

  func projectHeaderRow(for project: ProjectFeature.State) -> some View {
    HStack(spacing: 6) {
      // The chevron's slot is always reserved, chevron or not, so every header row's
      // icon and name start at the same x — rows that shifted with their expandability
      // read as misalignment, not as information.
      if canExpand(project) {
        Button {
          toggleExpanded(project.id)
        } label: {
          Image(
            systemName: collapsedProjectPaths.contains(project.id)
              ? "chevron.right" : "chevron.down"
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          .frame(width: 12)
        }
        .buttonStyle(.plain)
      } else {
        Color.clear.frame(width: 12)
      }

      // The Graph is not a folder and its row doesn't open one — it opens the whole
      // workspace drawn as one graph (`GraphOverviewView`), so it carries the same
      // connected-nodes glyph the canvas uses for itself rather than a folder icon it
      // would otherwise be indistinguishable from. A remote repository isn't a local
      // folder either: it gets the same `network` glyph the Add Remote Repository menu
      // item wears, so "this one lives on another machine" is readable at a glance —
      // the name alone ("widget @ build-box") only says so once you've read it.
      //
      // `folder`, not `folder.fill`, and in label ink rather than `.secondary`: a filled
      // folder at this size is a grey rectangle, and dimmed on top of that it was the
      // least legible thing in the window. See `SidebarIcon`.
      SidebarIcon(
        systemName: sidebarGlyph(for: project),
        tint: project.graph.isGlobal ? Color.accentColor : .primary)
      Text(project.graph.project.name).lineLimit(1)
      Spacer()
    }
    .contentShape(Rectangle())
  }

  func sidebarGlyph(for project: ProjectFeature.State) -> String {
    if project.graph.isGlobal { return "point.3.connected.trianglepath.dotted" }
    if RemoteProjectLocation.parse(projectPath: project.id) != nil { return "network" }
    return "folder"
  }

  /// Three verbs, deliberately distinct: closing is reversible from the Add Folder menu,
  /// removing forgets the project but keeps its loops for whenever you re-add it, and
  /// deleting throws the loops away. Only the last is destructive, so only it confirms
  /// and carries the destructive role.
  @ViewBuilder
  func projectMenu(for project: ProjectFeature.State) -> some View {
    Button("Move Up") { store.send(.projectMoveUpTapped(project.id)) }
    Button("Move Down") { store.send(.projectMoveDownTapped(project.id)) }
    Divider()
    Button("Close") { store.send(.projectCloseTapped(project.id)) }
    Button("Remove from GraphCode") { store.send(.projectRemoveTapped(project.id)) }
    Divider()
    Button("Delete Loops…", role: .destructive) { projectPendingLoopDeletion = project }
    Button("Delete \"\(project.graph.project.name)\"…", role: .destructive) {
      projectPendingDelete = project
    }
  }

  /// The sidebar lists every loop across every open project, so it's where people
  /// actually reach for a loop — right-clicking one here previously did nothing at all,
  /// with the same actions available only on the canvas card.
  ///
  /// Mirrors `ProjectCanvasView`'s node menu rather than offering a different subset:
  /// two right-click menus on the same object that disagree about what you can do to it
  /// is worse than either menu alone. The actions route into that loop's own project
  /// scope, since the sidebar spans several.
  @ViewBuilder
  func nodeMenu(for node: LoopNode, in projectPath: String) -> some View {
    Button("Open Terminal") { send(.nodeTapped(node.id), to: projectPath) }

    if node.loopType == .proactive {
      Button("Pilot Once…") { send(.pilotCompositeTapped(node.id), to: projectPath) }
      Button("Arm Schedule") { send(.armCompositeTapped(node.id), to: projectPath) }
        .disabled(!node.pilotState.canArm)
    }

    Button("Rename…") { send(.renameNodeRequested(node.id), to: projectPath) }

    if !node.isResolved {
      Button("Stop Loop") { send(.stopNodeTapped(node.id), to: projectPath) }
    }

    Divider()

    Button("Delete Loop…", role: .destructive) {
      send(.deleteNodeRequested(node.id), to: projectPath)
    }
  }

  func send(_ action: ProjectFeature.Action, to projectPath: String) {
    store.send(.projects(.element(id: projectPath, action: action)))
  }

  /// Whether this row has child rows at all — nothing does until it has a loop in it.
  /// The Graph row counts now too: its own loops (watchers and other cross-cutting
  /// triggers, creatable from its canvas since the overview gained "New Loop") list
  /// under it like any folder's.
  func canExpand(_ project: ProjectFeature.State) -> Bool {
    !project.graph.nodes.isEmpty
  }

  func toggleExpanded(_ path: String) {
    if collapsedProjectPaths.contains(path) {
      collapsedProjectPaths.remove(path)
    } else {
      collapsedProjectPaths.insert(path)
    }
  }

  /// This project's top-level rows — nodes nothing points at — in the human's
  /// arrangement (`sidebarNodeOrder`), not the graph's insertion order.
  func orderedRootNodes(in project: ProjectFeature.State) -> [LoopNode] {
    let roots = project.graph.nodes.filter { node in
      !project.graph.edges.contains { $0.to == node.id }
    }
    let order = project.sidebarNodeOrder
    return roots.sorted { a, b in
      (order.firstIndex(of: a.id) ?? .max) < (order.firstIndex(of: b.id) ?? .max)
    }
  }

  /// One visible row of the nested loop tree: the node, how deep it sits, and whether
  /// it has children to disclose.
  struct NodeRowEntry: Identifiable {
    let node: LoopNode
    let depth: Int
    let hasChildren: Bool
    var id: UUID { node.id }
  }

  /// The loop tree flattened to the rows currently visible, depth-first — parents
  /// first, each expanded parent followed by its children one level deeper. A flat
  /// emission rather than nested `DisclosureGroup`s for the same reason the file
  /// header gives for projects: the group's label swallows selection taps, and its
  /// List styling outdents children instead of indenting them. `visited` guards
  /// against edge cycles, which the graph explicitly allows (see `CycleGuard`).
  func flattenedNodeRows(in project: ProjectFeature.State) -> [NodeRowEntry] {
    var rows: [NodeRowEntry] = []
    var visited = Set<UUID>()

    func orderedChildren(of parentID: UUID) -> [LoopNode] {
      let childIDs = project.graph.edges.filter { $0.from == parentID }.map(\.to)
      let order = project.sidebarNodeOrder
      return childIDs.compactMap { project.graph.nodes[id: $0] }
        .sorted { a, b in
          (order.firstIndex(of: a.id) ?? .max) < (order.firstIndex(of: b.id) ?? .max)
        }
    }

    func visit(_ node: LoopNode, depth: Int) {
      guard visited.insert(node.id).inserted else { return }
      let children = orderedChildren(of: node.id)
      rows.append(NodeRowEntry(node: node, depth: depth, hasChildren: !children.isEmpty))
      guard expandedNodeIDs.contains(node.id) else { return }
      for child in children { visit(child, depth: depth + 1) }
    }

    for root in orderedRootNodes(in: project) { visit(root, depth: 0) }
    return rows
  }

  /// A loop row at its place in the tree: indented one step per level — rightward,
  /// under its parent. The chevron slot is reserved on leaf rows too, the same
  /// always-aligned rule the header rows follow, so siblings' titles share an edge
  /// whether or not they have children.
  func nestedNodeRow(_ entry: NodeRowEntry, in project: ProjectFeature.State) -> some View {
    HStack(spacing: 4) {
      if entry.hasChildren {
        Button {
          toggleNodeExpanded(entry.node.id)
        } label: {
          Image(
            systemName: expandedNodeIDs.contains(entry.node.id)
              ? "chevron.down" : "chevron.right"
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          .frame(width: 12)
        }
        .buttonStyle(.plain)
      } else {
        Color.clear.frame(width: 12)
      }
      nodeRow(for: entry.node)
    }
    .padding(.leading, CGFloat(entry.depth) * 16)
    .tag(SidebarSelection.node(entry.node.id))
    .contextMenu { nodeMenu(for: entry.node, in: project.id) }
  }

  func toggleNodeExpanded(_ id: UUID) {
    if expandedNodeIDs.contains(id) {
      expandedNodeIDs.remove(id)
    } else {
      expandedNodeIDs.insert(id)
    }
  }
}
