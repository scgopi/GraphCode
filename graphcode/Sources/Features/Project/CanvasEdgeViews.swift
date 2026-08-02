import GraphcodeKit
import SwiftUI

/// Edges are drawn distinctly per `EdgeKind`, per
/// docs/06-ux-terminals.md#graph-canvas: a solid line for `.handoff`, a dashed line for
/// `.message`, a fine dotted line for `.spawn`. On top of that, a `.handoff` that
/// `graphcoded` hasn't fired yet is drawn dashed and a fired one carries a pip at its
/// midpoint — so "which relationship is this" and "has it happened yet" stay two separate
/// readings of the same line.
///
/// **Directed.** The head is trimmed back to the target card's border
/// (`CanvasEdgeGeometry`), because a graph of handoffs whose lines have no direction is
/// withholding the one thing it is drawn to say. Ink rather than the system accent: an
/// accent-coloured line reads as selection, and these are structure.
///
/// There's no manual "Fire" affordance — from Phase 3 on, firing is automatic (see
/// `GraphcodeKit/Sources/GraphStore.swift`), so this view is read-only.
struct EdgeLineView: View {
  let from: CGPoint
  let to: CGPoint
  let kind: EdgeKind
  let fired: Bool
  /// A guarded back-edge's pass count — `"retry ×2"`. The full guard is in the edge's
  /// context menu (`canvasSummary`); a cycle bound spelled out in full would be a
  /// sentence lying across the canvas.
  var label: String?
  /// The card the head has to stop at. Passed rather than read so a canvas drawing
  /// something other than a loop card can say so.
  var targetSize: CGSize = LoopCardView.Metrics.size

  /// Where the curve starts, ends, and bends. Computed once — the path, the hit target,
  /// the head, the pip and the label all read the same three points, and a second
  /// derivation is how they drift apart by a pixel each.
  private var route: (start: CGPoint, end: CGPoint, controls: (CGPoint, CGPoint)) {
    let start = CanvasEdgeGeometry.exit(from: from, toward: to, cardSize: targetSize)
    let end = CanvasEdgeGeometry.entry(at: to, from: from, cardSize: targetSize)
    return (start, end, CanvasEdgeGeometry.controls(from: start, to: end))
  }

  var body: some View {
    ZStack {
      // A 1.5pt dashed line is almost impossible to right-click. This invisible
      // fat stroke is the hit target; the visible line is drawn on top of it.
      line.stroke(Color.clear.opacity(0.001), style: StrokeStyle(lineWidth: 12))
        .contentShape(line.stroke(style: StrokeStyle(lineWidth: 12)))
      line.stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: dashPattern))
      head.fill(color)
      if fired {
        Circle()
          .fill(Self.firedTint)
          .frame(
            width: CanvasEdgeGeometry.firedDotRadius * 2,
            height: CanvasEdgeGeometry.firedDotRadius * 2
          )
          .position(CanvasEdgeGeometry.midpoint(route.start, route.end))
      }
      if let label {
        Text(label)
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(Self.guardInk)
          .fixedSize()
          .position(CanvasEdgeGeometry.midpoint(route.start, route.end))
          .offset(y: 11)
          .allowsHitTesting(false)
      }
    }
  }

  private var line: Path {
    let route = route
    return Path { path in
      path.move(to: route.start)
      path.addCurve(to: route.end, control1: route.controls.0, control2: route.controls.1)
    }
  }

  private var head: Path {
    let route = route
    let approach = CanvasEdgeGeometry.arrivalTangent(
      control: route.controls.1, end: route.end)
    return Path { path in
      let corners = CanvasEdgeGeometry.arrowhead(at: route.end, from: approach)
      guard let first = corners.first else { return }
      path.move(to: first)
      for corner in corners.dropFirst() { path.addLine(to: corner) }
      path.closeSubpath()
    }
  }

  /// Amber for a guarded back-edge — the one edge kind that can run forever, and the one
  /// worth finding across a zoomed-out graph.
  private var color: Color {
    if label != nil { return Self.guardTint }
    switch kind {
    case .handoff: return .white.opacity(0.45)
    case .message: return .white.opacity(0.28)
    case .spawn: return Self.spawnTint
    }
  }

  private var dashPattern: [CGFloat] {
    if label != nil { return [5, 4] }
    switch kind {
    case .handoff: return fired ? [] : [5, 4]
    case .message: return [4, 4]
    case .spawn: return [2, 4]
    }
  }

  private static let spawnTint = Color(red: 0.565, green: 0.522, blue: 0.914).opacity(0.5)
  private static let guardTint = Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.55)
  private static let guardInk = Color(red: 1.0, green: 0.804, blue: 0.478).opacity(0.8)
  private static let firedTint = Color(red: 0.486, green: 0.737, blue: 1.0)  // #7cbcff
}

extension LoopEdge {
  /// What an edge says about itself in the canvas's context menu — the line's shape and
  /// color already carry the kind, so this is where everything the drawing can't show
  /// goes.
  var canvasSummary: String {
    var parts = [kind.displayName, condition.displayName]
    if let transform = payloadTransform.summary { parts.append(transform) }
    if let cycleGuard {
      // The pass count is the one thing you want at a glance on a running cycle.
      parts.append("loop \(fireCount)/\(cycleGuard.summary)")
    }
    return parts.joined(separator: " · ")
  }

  /// The label drawn beside a guarded back-edge, or `nil` when there is nothing to say
  /// yet. A guard that has never fired is a bound, not a fact — `"retry ×0"` would be
  /// the canvas reporting something that hasn't happened.
  var cycleLabel: String? {
    guard cycleGuard != nil, fireCount > 0 else { return nil }
    return "retry ×\(fireCount)"
  }
}
