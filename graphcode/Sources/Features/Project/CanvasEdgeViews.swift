import GraphcodeKit
import SwiftUI

/// Edges are drawn distinctly per `EdgeKind`, per
/// docs/06-ux-terminals.md#graph-canvas: a solid line for `.handoff`, a long-dashed
/// line for `.message`, a dotted line for `.spawn`. On top of that, a `.handoff` that
/// `graphcoded` hasn't fired yet is drawn dimmed and dashed — so "which relationship is
/// this" and "has it happened yet" stay two separate readings of the same line.
///
/// There's no manual "Fire" affordance — from Phase 3 on, firing is automatic (see
/// `GraphcodeKit/Sources/GraphStore.swift`), so this view is read-only.
struct EdgeLineView: View {
  let from: CGPoint
  let to: CGPoint
  let kind: EdgeKind
  let fired: Bool

  var body: some View {
    ZStack {
      // A 1.5pt dashed line is almost impossible to right-click. This invisible
      // fat stroke is the hit target; the visible line is drawn on top of it.
      line.stroke(Color.clear.opacity(0.001), style: StrokeStyle(lineWidth: 12))
        .contentShape(line.stroke(style: StrokeStyle(lineWidth: 12)))
      line.stroke(color, style: StrokeStyle(lineWidth: fired ? 2 : 1.5, dash: dashPattern))
    }
  }

  private var line: Path {
    Path { path in
      path.move(to: from)
      path.addLine(to: to)
    }
  }

  private var color: Color {
    switch kind {
    case .handoff: return fired ? Color.accentColor : Color.secondary
    case .message: return Color.teal
    case .spawn: return Color.purple
    }
  }

  private var dashPattern: [CGFloat] {
    switch kind {
    case .handoff: return fired ? [] : [5, 4]
    case .message: return [10, 5]
    case .spawn: return [2, 4]
    }
  }
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
}
