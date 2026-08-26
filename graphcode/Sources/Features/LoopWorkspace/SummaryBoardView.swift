import GraphcodeKit
import SwiftUI

/// A board, drawn — the flowchart, the table, or the Mermaid itself when this build cannot
/// draw what the composer wrote.
///
/// Native SwiftUI shapes rather than a web view, and that is a product decision before it
/// is a technical one. The app ships no WebKit and no JavaScript; a board is a few dozen
/// structs that lay out in microseconds, so it can live in a rail that redraws on every
/// clock tick and inside a `scaleEffect` without either becoming a frame budget problem.
/// What it costs is fidelity: `MermaidBoardParser` reads a subset, and anything outside it
/// falls through to `BoardSourceView` rather than to an error.
struct SummaryBoardView: View {
  let board: SummaryBoard
  /// The loop's own accent, so a board reads as belonging to the card that opened it.
  let accent: Color
  /// How tall the board may get before it scrolls instead of growing. `nil` means take
  /// everything, which is what the expanded cover hands it; the rail hands it a ceiling so
  /// a twelve-layer flowchart cannot push the graph sections off the bottom.
  var ceiling: CGFloat? = SummaryBoardView.railCeiling

  /// Two thirds of a 900pt window's rail, after the summary above it has had its 120.
  static let railCeiling: CGFloat = 340

  var body: some View {
    switch board.form {
    case .flow: FlowBoardView(board: board, accent: accent, ceiling: ceiling)
    case .table: TableBoardView(board: board, ceiling: ceiling)
    }
  }
}

// MARK: - Flow

private struct FlowBoardView: View {
  let board: SummaryBoard
  let accent: Color
  let ceiling: CGFloat?

  /// The rail's content width, once the layout has been given one. Read rather than
  /// inferred from a `GeometryReader` wrapped round the whole thing: a `GeometryReader`
  /// takes the height it is offered instead of the height its content needs, which for a
  /// diagram means either a fixed panel with a gap under it or one that never scrolls.
  @State private var available: CGFloat = 0

  /// **Floored rather than left to shrink.** A board that always fitted would be legible
  /// only in the sense that it was all on screen; past about half size the labels stop
  /// being readable and the right answer is to let the panel scroll.
  static let minimumScale: CGFloat = 0.55

  var body: some View {
    let layout = BoardLayout(board: board)
    if layout.nodes.isEmpty {
      // Parsed to nothing — a diagram type outside the subset, or a flow with no arrows in
      // it. The Mermaid is still the answer; it is just text this build cannot draw.
      BoardSourceView(source: board.source)
    } else {
      let scale = scale(for: layout)
      ScrollView([.horizontal, .vertical]) {
        diagram(layout)
          .frame(width: layout.size.width, height: layout.size.height)
          .scaleEffect(scale, anchor: .topLeading)
          // `alignment` is load-bearing, not decoration. `scaleEffect` draws smaller
          // without changing the layout size, so this frame is being handed a box that is
          // still full size — and centred, the default, it pulls that box left and up by
          // half the difference, taking the drawing with it. At 0.78 on a 798pt board that
          // put the first box eighty points off the leading edge, clipped.
          .frame(
            width: layout.size.width * scale, height: layout.size.height * scale,
            alignment: .topLeading
          )
          // Centred when it does not fill the panel, rather than left-aligned. A four-box
          // flow in a 460pt rail is 270 points wide, and hard against one edge it reads as
          // a diagram that has been cut off.
          .padding(.leading, max(0, (available - layout.size.width * scale) / 2))
          .padding(.vertical, 2)
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(height: ceiling.map { min(layout.size.height * scale + 4, $0) })
      .frame(maxHeight: ceiling == nil ? .infinity : nil)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        available = $0
      }
    }
  }

  /// Fit to the width there is, down to the floor. Zero width is the first pass, before the
  /// panel has been measured — full size then, corrected on the next.
  private func scale(for layout: BoardLayout) -> CGFloat {
    guard available > 0, layout.size.width > 0 else { return 1 }
    return min(1, max(Self.minimumScale, available / layout.size.width))
  }

  private func diagram(_ layout: BoardLayout) -> some View {
    ZStack(alignment: .topLeading) {
      // One `Canvas` for every arrow rather than a shape view each: the edges are the part
      // with no text in them, and drawing forty of them as separate views is forty layers
      // for something that is one path.
      Canvas { context, _ in
        for edge in layout.edges {
          context.stroke(
            BoardArrow.path(for: edge), with: .color(.white.opacity(edge.isFeedback ? 0.22 : 0.34)),
            style: BoardArrow.stroke(edge.edge.style))
          context.fill(BoardArrow.head(for: edge), with: .color(.white.opacity(0.42)))
        }
      }
      ForEach(layout.edges) { edge in
        if let label = edge.edge.label, !label.isEmpty {
          Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.62))
            .lineLimit(1)
            .padding(.horizontal, 3.5)
            .padding(.vertical, 1)
            .background(BoardPalette.surface, in: RoundedRectangle(cornerRadius: 3))
            .position(edge.labelPoint)
        }
      }
      ForEach(layout.nodes) { placed in
        BoardNodeView(node: placed.node, accent: accent)
          .frame(width: placed.frame.width, height: placed.frame.height)
          .position(x: placed.frame.midX, y: placed.frame.midY)
      }
    }
  }
}

private struct BoardNodeView: View {
  let node: BoardNode
  let accent: Color

  var body: some View {
    Text(node.text)
      .font(.system(size: 11.5))
      .foregroundStyle(.white.opacity(0.88))
      .multilineTextAlignment(.center)
      .padding(.horizontal, 4)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(shape.fill(fill))
      .overlay(shape.stroke(stroke, lineWidth: 1))
      .help(node.text)
  }

  /// `AnyShape` rather than four branches drawing four backgrounds: the fill and the stroke
  /// have to be the *same* outline or a diamond ends up with a rectangle's border.
  private var shape: AnyShape {
    switch node.shape {
    case .box: return AnyShape(RoundedRectangle(cornerRadius: 4))
    case .rounded: return AnyShape(RoundedRectangle(cornerRadius: 10))
    case .terminal: return AnyShape(Capsule())
    case .decision: return AnyShape(BoardDiamond())
    }
  }

  /// Only two shapes are tinted — the branch and the end. Colouring every box would make
  /// the accent mean "this is a box", and the whole point of the shapes is that the run's
  /// structure is legible before a word is read.
  private var fill: Color {
    switch node.shape {
    case .decision: return accent.opacity(0.16)
    case .terminal: return accent.opacity(0.1)
    default: return .white.opacity(0.05)
    }
  }

  private var stroke: Color {
    switch node.shape {
    case .decision: return accent.opacity(0.5)
    case .terminal: return accent.opacity(0.35)
    default: return .white.opacity(0.14)
    }
  }
}

struct BoardDiamond: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.midX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
    path.closeSubpath()
    return path
  }
}

/// The arrows: the line, its dash pattern, and the head.
enum BoardArrow {
  static let headLength: CGFloat = 6
  static let headWidth: CGFloat = 4.5
  /// How far a straight arrow bows towards its own midpoint. A perfectly straight line
  /// between two boxes that are not vertically aligned reads as a mistake; a slight curve
  /// reads as a route.
  static let bow: CGFloat = 0.42

  static func stroke(_ style: BoardEdgeStyle) -> StrokeStyle {
    switch style {
    case .solid: return StrokeStyle(lineWidth: 1.2, lineCap: .round)
    case .dashed: return StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 3])
    case .thick: return StrokeStyle(lineWidth: 2.1, lineCap: .round)
    }
  }

  static func path(for edge: BoardLayout.PlacedEdge) -> Path {
    var path = Path()
    path.move(to: edge.start)
    if edge.waypoints.isEmpty {
      // A cubic whose controls sit on the *axis of travel* — straight out of the box it
      // leaves and straight into the one it enters, however far sideways the two are. The
      // spread pushes both controls the same way, which separates two arrows sharing a pair
      // of boxes without either leaving its own ends.
      // Offset along the axis of travel only. Adding the sideways component too made the
      // curve arrive along the chord, and a box two columns over then took its arrow in
      // the side of its top edge.
      let travel = edge.axis == .topDown ? edge.end.y - edge.start.y : edge.end.x - edge.start.x
      let reach = travel * bow
      let control1 =
        edge.axis == .topDown
        ? CGPoint(x: edge.start.x + edge.spread, y: edge.start.y + reach)
        : CGPoint(x: edge.start.x + reach, y: edge.start.y + edge.spread)
      let control2 =
        edge.axis == .topDown
        ? CGPoint(x: edge.end.x + edge.spread, y: edge.end.y - reach)
        : CGPoint(x: edge.end.x - reach, y: edge.end.y + edge.spread)
      path.addCurve(to: edge.end, control1: control1, control2: control2)
    } else {
      // Orthogonal, with the corners rounded. A feedback arrow runs through the empty bands
      // between layers, so its bends are right angles rather than a curve — and a right
      // angle drawn sharp at 1.2pt reads as two lines that happen to meet.
      var previous = edge.start
      for (index, point) in edge.waypoints.enumerated() {
        let next = index + 1 < edge.waypoints.count ? edge.waypoints[index + 1] : edge.end
        path.addLine(to: shortened(point, towards: previous))
        path.addQuadCurve(to: shortened(point, towards: next), control: point)
        previous = point
      }
      path.addLine(to: edge.end)
    }
    return path
  }

  /// A point pulled back off a corner towards its neighbour, so the quadratic that rounds
  /// the corner has somewhere to start. Never more than half the segment, or a short leg
  /// would round past its own far end.
  private static func shortened(_ corner: CGPoint, towards neighbour: CGPoint) -> CGPoint {
    let dx = neighbour.x - corner.x
    let dy = neighbour.y - corner.y
    let length = max(sqrt(dx * dx + dy * dy), 0.001)
    let radius = min(cornerRadius, length / 2)
    return CGPoint(x: corner.x + dx / length * radius, y: corner.y + dy / length * radius)
  }

  static let cornerRadius: CGFloat = 6

  /// A filled triangle at the arrow's end, pointing the way the last segment travels.
  static func head(for edge: BoardLayout.PlacedEdge) -> Path {
    let approach = edge.waypoints.last ?? edge.start
    let dx = edge.end.x - approach.x
    let dy = edge.end.y - approach.y
    let length = max(sqrt(dx * dx + dy * dy), 0.001)
    // A bowed arrow arrives along its own axis rather than along the chord — see
    // `PlacedEdge.axis`. Only an elbowed route, whose last leg is a straight line, can take
    // its direction from the two points that make that leg.
    let unit: CGPoint
    if edge.waypoints.isEmpty {
      unit =
        edge.axis == .topDown
        ? CGPoint(x: 0, y: edge.end.y >= edge.start.y ? 1 : -1)
        : CGPoint(x: edge.end.x >= edge.start.x ? 1 : -1, y: 0)
    } else {
      unit = CGPoint(x: dx / length, y: dy / length)
    }
    let base = CGPoint(
      x: edge.end.x - unit.x * headLength, y: edge.end.y - unit.y * headLength)
    let normal = CGPoint(x: -unit.y, y: unit.x)
    var path = Path()
    path.move(to: edge.end)
    path.addLine(
      to: CGPoint(x: base.x + normal.x * headWidth, y: base.y + normal.y * headWidth))
    path.addLine(
      to: CGPoint(x: base.x - normal.x * headWidth, y: base.y - normal.y * headWidth))
    path.closeSubpath()
    return path
  }
}

// MARK: - Table

private struct TableBoardView: View {
  let board: SummaryBoard
  let ceiling: CGFloat?

  var body: some View {
    if let table = board.table {
      // Horizontally scrollable rather than squeezed: five columns at the rail's folded
      // width is 40 points each, which is a column of ellipses.
      ScrollView([.horizontal, .vertical]) {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 0) {
          GridRow {
            ForEach(Array(table.headers.enumerated()), id: \.offset) { _, header in
              Text(header)
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.45))
            }
          }
          .padding(.vertical, 5)
          // Ruled, not striped. A `GridRow` background is applied to each *cell*, not across
          // the row, so alternating fills came out as a ragged block behind each piece of
          // text rather than as a band — worse than the plain rules it was meant to improve
          // on.
          ForEach(Array(table.normalisedRows.enumerated()), id: \.offset) { _, row in
            Divider().overlay(.white.opacity(0.07)).gridCellUnsizedAxes(.horizontal)
            GridRow {
              ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                Text(cell)
                  .font(.system(size: 11, design: column == 0 ? .default : .monospaced))
                  .foregroundStyle(.white.opacity(column == 0 ? 0.85 : 0.65))
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
            .padding(.vertical, 5)
          }
        }
        .padding(.horizontal, 2)
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxHeight: ceiling ?? .infinity)
    } else {
      BoardSourceView(source: board.source)
    }
  }
}

// MARK: - Fallback

/// What a board looks like when this build cannot draw it: its own source, as code.
///
/// The honest outcome rather than a failure state, and the reason `SummaryBoard.source` is
/// the field the composer actually produces. A diagram type the parser does not read is
/// still a diagram — it renders anywhere else that speaks Mermaid, and the copy button in
/// the section header is how it gets there.
struct BoardSourceView: View {
  let source: String

  var body: some View {
    ScrollView([.horizontal, .vertical]) {
      Text(source)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white.opacity(0.6))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }
    .scrollBounceBehavior(.basedOnSize)
    .background(BoardPalette.surface, in: RoundedRectangle(cornerRadius: 6))
  }
}

enum BoardPalette {
  /// The same #16161a `RailMinimap` sits on, so the two panels in one rail read as one
  /// surface rather than two.
  static let surface = Color(red: 0.086, green: 0.086, blue: 0.102)
}
