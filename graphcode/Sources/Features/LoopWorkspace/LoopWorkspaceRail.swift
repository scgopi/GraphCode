import GraphcodeKit
import SwiftUI

/// The workspace's 212pt right rail — where this loop sits in the graph, what it hands
/// off to, and how its metric has moved. ⌥G hides it.
///
/// Inside a terminal the graph disappears: the one surface that says a loop has a
/// downstream at all is the canvas, and getting back to it means leaving the work.
/// This is the graph made reachable without going anywhere — deliberately read-only,
/// because rewiring belongs on the canvas where you can see what you're rewiring.
struct LoopWorkspaceRail: View {
  let node: LoopNode
  let graph: LoopGraph
  let now: Date
  /// What the rail is this window, after any drag. The section inside it is the reason
  /// this is a variable at all — a beat is a sentence, and 188 points of content is where
  /// a sentence starts wrapping to four lines.
  var width: CGFloat = LoopWorkspaceRail.defaultWidth
  /// Whether the summary section is collapsed to its one truncated line. Per window and
  /// persisted, beside the rail's own visibility.
  let isSummaryFolded: Bool
  /// The newest beat this window had on screen when it was last left — see
  /// `LoopWorkspaceFeature.seenBeatID`.
  let seenBeatID: String?
  /// Whether the board section is collapsed to its header. Per window and persisted,
  /// beside the summary's own fold.
  let isBoardFolded: Bool
  let onSummaryFoldToggled: () -> Void
  let onSummaryAnswerTapped: () -> Void
  let onBoardFoldToggled: () -> Void
  let onBoardExpanded: () -> Void
  let onTargetTapped: (UUID) -> Void

  /// The handoff's number, and now the floor rather than the fixed size. Below this the
  /// receding rows stop being one line each.
  static let minimumWidth: CGFloat = 212
  /// Half a 1280pt window is already more than a summary needs; past this the terminal —
  /// the pane someone is actually working in — is the thing being taken from.
  ///
  /// Raised from 520 when boards arrived. A sentence stops needing width at 520; a diagram
  /// does not, and a person who drags the rail out to read one has said plainly which of
  /// the two panes they want.
  static let maximumWidth: CGFloat = 760
  /// Wider than the 212 the design specified, because the section that arrived after it
  /// carries prose rather than chips and rows of three.
  static let defaultWidth: CGFloat = 280

  /// What the rail opens at when the loop carries a board — and *only* when nobody has ever
  /// dragged the rail themselves (`hasStoredWidth`).
  ///
  /// A diagram is not prose: 280 points is four boxes across before it starts scrolling
  /// sideways, which is the width at which a flowchart stops being worth drawing. 460 fits
  /// a five-box layer at full size and still leaves two thirds of a 1280pt window to the
  /// terminal. It is a default and nothing more — the drag handle is unchanged, and the
  /// moment a width is chosen it wins over this for ever.
  static let boardWidth: CGFloat = 460

  /// Whether a width has ever been committed by a drag. What keeps `boardWidth` from
  /// overruling a choice somebody actually made.
  static func hasStoredWidth() -> Bool {
    UserDefaults.standard.double(forKey: widthDefaultsKey) > 0
  }

  static let boardFoldedDefaultsKey = "loopBoardSectionFolded"

  static func loadBoardFolded() -> Bool {
    UserDefaults.standard.bool(forKey: boardFoldedDefaultsKey)
  }

  static func saveBoardFolded(_ folded: Bool) {
    UserDefaults.standard.set(folded, forKey: boardFoldedDefaultsKey)
  }

  static let visibleDefaultsKey = "loopWorkspaceRailVisible"

  static let widthDefaultsKey = "loopWorkspaceRailWidth"

  static func loadWidth() -> CGFloat {
    let stored = UserDefaults.standard.double(forKey: widthDefaultsKey)
    guard stored > 0 else { return defaultWidth }
    return clamped(stored)
  }

  static func saveWidth(_ width: CGFloat) {
    UserDefaults.standard.set(Double(clamped(width)), forKey: widthDefaultsKey)
  }

  static func clamped(_ width: CGFloat) -> CGFloat {
    min(max(width, minimumWidth), maximumWidth)
  }

  static let summaryFoldedDefaultsKey = "loopSummarySectionFolded"

  static func loadSummaryFolded() -> Bool {
    UserDefaults.standard.bool(forKey: summaryFoldedDefaultsKey)
  }

  static func saveSummaryFolded(_ folded: Bool) {
    UserDefaults.standard.set(folded, forKey: summaryFoldedDefaultsKey)
  }

  /// **Off** until someone asks for it. It used to default on, which meant every loop
  /// that feeds nothing opened with 212 points of empty panel beside its terminal.
  static func loadVisible() -> Bool {
    UserDefaults.standard.object(forKey: visibleDefaultsKey) as? Bool ?? false
  }

  static func saveVisible(_ visible: Bool) {
    UserDefaults.standard.set(visible, forKey: visibleDefaultsKey)
  }

  /// Whether this loop gives the rail anything to say.
  ///
  /// 212 points is 15% of the window, taken from the terminal — the pane someone is
  /// actually working in. A loop wired to nothing with no metric renders as a caption, a
  /// rect between two dashes, and a date; blank chrome is worse than absent chrome, and
  /// a panel that is permanently empty teaches people to stop looking at the panel next
  /// to it (the argument that already keeps the cost rollup out of the sidebar).
  static func hasContent(
    node: LoopNode, graph: LoopGraph,
    summarising: Bool = LoopSummaryPresentation.isProducing
  ) -> Bool {
    graph.edges.contains { $0.from == node.id || $0.to == node.id }
      || node.metricHistory.count >= 2
      // A loop that is narrating has something to say whether or not it is wired to
      // anything — and that narration is the reason to open the rail at all. With the
      // producer off it is not narrating, whatever a previous switch-on left on the node.
      || LoopSummaryPresentation.hasContent(node: node, producing: summarising)
      // A loop wired to nothing whose run has been drawn has the one thing the rail is
      // widest for. Its own switch, so the board's absence is never inferred from the
      // beats' — see `SummaryBoardPresentation.hasContent`.
      || SummaryBoardPresentation.hasContent(node: node)
  }

  /// How many loops this one hands off to — what the loop bar's control counts.
  static func downstreamCount(node: LoopNode, graph: LoopGraph) -> Int {
    graph.edges.count { $0.from == node.id }
  }

  private var outbound: [(edge: LoopEdge, target: LoopNode)] {
    graph.edges
      .filter { $0.from == node.id }
      .compactMap { edge in
        guard let target = graph.nodes[id: edge.to] else { return nil }
        return (edge, target)
      }
  }

  private var inbound: [LoopNode] {
    graph.edges.filter { $0.to == node.id }.compactMap { graph.nodes[id: $0.from] }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Above `THIS LOOP` rather than below it: what the loop is doing this second
      // outranks where it sits in the graph, and a section you have to scroll to is a
      // section that answers nothing at a glance.
      if LoopSummaryPresentation.hasContent(node: node) {
        LoopSummarySection(
          node: node, now: now, isFolded: isSummaryFolded, seenBeatID: seenBeatID,
          onToggleFold: onSummaryFoldToggled, onAnswer: onSummaryAnswerTapped)
      }
      // Under the sentence and above the graph. The order is the order of the questions:
      // what is it doing, what shape did that have, where does it sit. A diagram above the
      // beat would put the account of a finished pass over the thing happening now.
      if SummaryBoardPresentation.hasContent(node: node) {
        SummaryBoardSection(
          node: node, isFolded: isBoardFolded, onToggleFold: onBoardFoldToggled,
          onExpand: onBoardExpanded)
      }
      section("THIS LOOP") {
        RailMinimap(node: node, upstream: inbound, downstream: outbound.map(\.target))
      }
      if !outbound.isEmpty {
        section("HANDS OFF TO") {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(outbound, id: \.edge.id) { handoff in
              handoffRow(handoff.edge, handoff.target)
            }
          }
        }
      }
      if node.metricHistory.count >= 2 {
        section("RECENT PASSES") { RailSparkline(node: node) }
      }
      Spacer(minLength: 0)
      footer
    }
    .padding(12)
    .frame(width: width, alignment: .leading)
    .frame(maxHeight: .infinity)
    .background(Theme.workspaceRail)
    .overlay(alignment: .leading) {
      Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
    }
  }

  private func section<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.system(size: 10.5, weight: .bold))
        .tracking(0.6)
        .foregroundStyle(.white.opacity(0.4))
      content()
    }
  }

  private func handoffRow(_ edge: LoopEdge, _ target: LoopNode) -> some View {
    HStack(spacing: 7) {
      RoundedRectangle(cornerRadius: 1.5)
        .fill(target.loopType.accent)
        .frame(width: 3, height: 20)
      VStack(alignment: .leading, spacing: 1) {
        Text(target.title).font(.system(size: 12)).lineLimit(1)
        Text(condition(edge))
          .font(.system(size: 10))
          .foregroundStyle(.white.opacity(0.45))
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      StateIndicator(state: target.state, diameter: 5)
    }
    .padding(.vertical, 3)
    .padding(.horizontal, 5)
    .background(
      target.state.wantsHuman ? Color.orange.opacity(0.1) : .clear,
      in: RoundedRectangle(cornerRadius: 5)
    )
    .contentShape(Rectangle())
    .onTapGesture { onTargetTapped(target.id) }
  }

  /// What has to be true for the handoff to happen, plus whether it already has — a row
  /// that only said "On success" would leave you wondering every time whether it went.
  private func condition(_ edge: LoopEdge) -> String {
    edge.fired ? "\(edge.condition.displayName.lowercased()) · fired" : edge.condition.displayName
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 2) {
      if let branch = node.worktreeBinding?.branch {
        Text(branch).lineLimit(1).truncationMode(.middle)
      }
      Text(started)
    }
    .font(.system(size: 9.5, design: .monospaced))
    .foregroundStyle(.white.opacity(0.4))
  }

  private var started: String {
    var parts = ["started \(node.createdAt.formatted(date: .omitted, time: .shortened))"]
    if let tokens = node.usage?.totalTokens { parts.append(LoopCardPresentation.tokens(tokens)) }
    return parts.joined(separator: " · ")
  }
}

/// The loop's own one-hop neighbourhood — what feeds it, itself, what it feeds. One hop
/// and no further: a rail that drew the whole graph would be a second canvas, badly, in
/// 212 points.
private struct RailMinimap: View {
  let node: LoopNode
  let upstream: [LoopNode]
  let downstream: [LoopNode]

  var body: some View {
    VStack(spacing: 10) {
      row(upstream)
      chip(node, width: 36, height: 16, isSelf: true)
      row(downstream)
    }
    .frame(maxWidth: .infinity)
    .frame(height: 118)
    .background(Self.surface, in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.06), lineWidth: 1)
    }
  }

  @ViewBuilder
  private func row(_ nodes: [LoopNode]) -> some View {
    if nodes.isEmpty {
      Text("—").font(.system(size: 10)).foregroundStyle(.white.opacity(0.25))
    } else {
      HStack(spacing: 5) {
        ForEach(nodes.prefix(4)) { chip($0, width: 26, height: 12, isSelf: false) }
      }
    }
  }

  private func chip(
    _ node: LoopNode, width: CGFloat, height: CGFloat, isSelf: Bool
  ) -> some View {
    RoundedRectangle(cornerRadius: 3)
      .fill(node.loopType.accent.opacity(isSelf ? 0.9 : 0.5))
      .frame(width: width, height: height)
      .overlay {
        if isSelf {
          RoundedRectangle(cornerRadius: 3)
            .stroke(Theme.paneFocusTint.opacity(0.7), lineWidth: 1.5)
        }
      }
      .overlay(alignment: .topTrailing) {
        if node.state.wantsHuman {
          Circle().fill(.orange).frame(width: 3, height: 3).offset(x: 1, y: -1)
        }
      }
      .help(node.title)
  }

  private static let surface = Color(red: 0.086, green: 0.086, blue: 0.102)  // #16161a
}

/// The metric's last few passes as bars, newest at full strength.
private struct RailSparkline: View {
  let node: LoopNode

  private var samples: [MetricSample] { Array(node.metricHistory.suffix(7)) }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .bottom, spacing: 3) {
        ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
          RoundedRectangle(cornerRadius: 1)
            .fill(node.loopType.accent.opacity(index == samples.count - 1 ? 1 : 0.45))
            .frame(height: max(3, 34 * height(of: sample.value)))
        }
      }
      .frame(height: 34)
      Text(caption)
        .font(.system(size: 9.5, design: .monospaced))
        .foregroundStyle(.white.opacity(0.45))
        .lineLimit(1)
    }
  }

  /// Scaled across the window shown, not from zero: seven readings of 0.71, 0.72, 0.70
  /// drawn from a zero baseline are seven identical bars, which is the one thing this is
  /// meant to tell apart.
  private func height(of value: Double) -> Double {
    let values = samples.map(\.value)
    guard let low = values.min(), let high = values.max(), high > low else { return 0.5 }
    let fraction = (value - low) / (high - low)
    // Direction-aware: with a metric being minimised, lower is a taller bar, so "the bars
    // are growing" means the same thing either way.
    return node.goal?.metricDirection == .minimize ? 1 - fraction : fraction
  }

  private var caption: String {
    guard let last = samples.last?.value else { return "" }
    guard samples.count >= 2 else { return LoopCardPresentation.number(last) }
    let previous = samples[samples.count - 2].value
    let delta = last - previous
    let sign = delta > 0 ? "+" : (delta < 0 ? "−" : "±")
    return
      "\(LoopCardPresentation.number(last)) · \(sign)\(LoopCardPresentation.number(abs(delta))) this pass"
  }
}
