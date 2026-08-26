import AppKit
import Foundation
import GraphcodeKit

/// A board as an `.excalidraw` file — the same boxes and arrows, somewhere they can be
/// moved.
///
/// **This direction and not the other, and the reason is in the format.** An Excalidraw
/// element carries `x`, `y`, `width` and `height`: the file has no layout engine, so
/// positions are baked into it. Asking a model to *write* Excalidraw is therefore asking a
/// model to do geometry, which is work `BoardLayout` already does correctly and models do
/// badly. Going the other way costs almost nothing — every coordinate the file needs has
/// already been computed to draw the board on screen — and it buys the one thing a native
/// renderer cannot: somewhere to drag a box that ended up in the wrong place.
///
/// Mermaid remains the source of truth (`SummaryBoard.source`). This is an export, not a
/// second representation to keep in step: nothing reads a `.excalidraw` file back in.
enum BoardExcalidrawExport {
  static let schemaVersion = 2
  static let source = "https://graphcode.app"

  /// Excalidraw's own ink on its own white canvas.
  ///
  /// Deliberately **not** the rail's palette. A board on screen is near-white strokes on
  /// #16161a; the same colours in a file that opens on white paper are invisible, and an
  /// export nobody can see is worse than no export.
  enum Ink {
    static let stroke = "#1e1e1e"
    static let transparent = "transparent"
    static let decisionStroke = "#1971c2"
    static let decisionFill = "#a5d8ff"
    static let terminalStroke = "#1971c2"
    static let terminalFill = "#d0ebff"
    static let arrow = "#1e1e1e"
  }

  /// `roundness: {type: 3}` is Excalidraw's adaptive corner radius, which is what its own
  /// "round" edge setting writes.
  static let adaptiveRoundness = 3

  /// The sizes the file is written at — Excalidraw's own defaults, not the rail's.
  static let boxFontSize: CGFloat = 16
  static let edgeFontSize: CGFloat = 14

  /// How much bigger the exported drawing is than the one on screen.
  ///
  /// **The whole geometry is scaled, rather than the font shrunk to fit.** `BoardLayout`
  /// sizes each box around its label measured at `BoardLayout.labelFont` — 11.5pt system —
  /// and the file is written in Excalidraw's own 16pt hand-drawn face, which is wider again
  /// per point. Exported one-to-one, the longer labels overflow their boxes: verified by
  /// importing a file and reading `Re-sign helper` off a box that should have said
  /// `Re-sign helpers`.
  ///
  /// Scaling every coordinate by the same factor keeps the drawing internally consistent —
  /// arrows still meet box edges, layers stay evenly spaced — where shrinking the font to
  /// fit would have produced a diagram nobody can read and boxes bigger than their contents.
  /// 1.55 is 16/11.5 with a tenth over for the hand-drawn face being wider than the metric
  /// one it was measured in.
  static let exportScale: CGFloat = 1.55

  static func document(
    for board: SummaryBoard, layout: BoardLayout, now: Date = Date()
  ) -> [String: Any] {
    var elements: [[String: Any]] = []
    let stamp = Int(now.timeIntervalSince1970 * 1000)

    for placed in layout.nodes {
      let containerID = identifier("box", placed.id)
      let textID = identifier("text", placed.id)
      elements.append(
        shape(placed, id: containerID, textID: textID, stamp: stamp))
      elements.append(
        label(placed, id: textID, containerID: containerID, stamp: stamp))
    }
    for edge in layout.edges {
      let arrowID = identifier("edge", edge.id)
      guard let text = edge.edge.label, !text.isEmpty else {
        elements.append(arrow(edge, id: arrowID, textID: nil, stamp: stamp))
        continue
      }
      let textID = identifier("edge-text", edge.id)
      elements.append(arrow(edge, id: arrowID, textID: textID, stamp: stamp))
      elements.append(
        edgeLabel(text, id: textID, containerID: arrowID, at: edge.labelPoint, stamp: stamp))
    }

    return [
      "type": "excalidraw",
      "version": schemaVersion,
      "source": source,
      "elements": elements,
      // Only the two keys that change how the file *opens*. Everything else in `appState`
      // is a preference belonging to whoever opens it, and writing our own would overrule
      // theirs for the sake of nothing.
      "appState": ["gridSize": NSNull(), "viewBackgroundColor": "#ffffff"],
      "files": [String: Any](),
    ]
  }

  static func data(
    for board: SummaryBoard, layout: BoardLayout, now: Date = Date()
  ) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: document(for: board, layout: layout, now: now),
      options: [.prettyPrinted, .sortedKeys])
  }

  // MARK: - Elements

  private static func shape(
    _ placed: BoardLayout.PlacedNode, id: String, textID: String, stamp: Int
  ) -> [String: Any] {
    var element = base(
      id: id, type: excalidrawType(placed.node.shape), frame: scaled(placed.frame),
      stamp: stamp)
    element["strokeColor"] = strokeColour(placed.node.shape)
    element["backgroundColor"] = fillColour(placed.node.shape)
    element["fillStyle"] = "solid"
    // A rectangle is the one shape where Excalidraw distinguishes sharp from round, so it
    // is the one shape that carries the board's own distinction between a step and a state.
    element["roundness"] =
      placed.node.shape == .rounded ? ["type": adaptiveRoundness] : NSNull()
    element["boundElements"] = [["id": textID, "type": "text"]]
    return element
  }

  /// A text element bound to its box, rather than a label drawn at the box's centre.
  ///
  /// Binding is what makes the export worth having: a bound label moves with its box, wraps
  /// inside it and stays centred when it is resized. An unbound one is a separate object
  /// that gets left behind the first time anybody drags anything.
  private static func label(
    _ placed: BoardLayout.PlacedNode, id: String, containerID: String, stamp: Int
  ) -> [String: Any] {
    var element = base(
      id: id, type: "text", frame: scaled(placed.frame).insetBy(dx: 6, dy: 6), stamp: stamp)
    element["strokeColor"] = Ink.stroke
    element["backgroundColor"] = Ink.transparent
    element["fillStyle"] = "solid"
    element["roundness"] = NSNull()
    element["text"] = placed.node.text
    element["originalText"] = placed.node.text
    element["fontSize"] = boxFontSize
    // 1 is Excalidraw's own hand-drawn face, which is what a file opened there is expected
    // to look like — the board on screen uses the system font because the rail does.
    element["fontFamily"] = 1
    element["textAlign"] = "center"
    element["verticalAlign"] = "middle"
    element["containerId"] = containerID
    element["lineHeight"] = 1.25
    element["autoResize"] = true
    return element
  }

  /// `points` are **local to the arrow**, not to the canvas: the first is always the origin
  /// and the rest are offsets from it. Absolute coordinates here draw every arrow at twice
  /// its intended distance from the origin, which is the one mistake this format invites.
  private static func arrow(
    _ edge: BoardLayout.PlacedEdge, id: String, textID: String?, stamp: Int
  ) -> [String: Any] {
    let path = ([edge.start] + edge.waypoints + [edge.end]).map(scaled)
    let origin = scaled(edge.start)
    let points = path.map { [$0.x - origin.x, $0.y - origin.y] }
    let width = (points.map { $0[0] }.max() ?? 0) - (points.map { $0[0] }.min() ?? 0)
    let height = (points.map { $0[1] }.max() ?? 0) - (points.map { $0[1] }.min() ?? 0)

    var element = base(
      id: id,
      type: "arrow",
      frame: CGRect(x: origin.x, y: origin.y, width: width, height: height),
      stamp: stamp)
    element["strokeColor"] = Ink.arrow
    element["backgroundColor"] = Ink.transparent
    element["fillStyle"] = "solid"
    element["strokeStyle"] = edge.edge.style == .dashed ? "dashed" : "solid"
    element["strokeWidth"] = edge.edge.style == .thick ? 2 : 1
    element["roundness"] = ["type": 2]
    element["points"] = points
    element["lastCommittedPoint"] = NSNull()
    element["startBinding"] = NSNull()
    element["endBinding"] = NSNull()
    element["startArrowhead"] = NSNull()
    element["endArrowhead"] = "arrow"
    element["elbowed"] = false
    element["boundElements"] = textID.map { [["id": $0, "type": "text"]] } ?? NSNull()
    return element
  }

  /// An arrow's own label, and it is a **bound text element** rather than a field on the
  /// arrow.
  ///
  /// `ExcalidrawLinearElement` has no `label` property — an arrow label in Excalidraw is a
  /// text element whose `containerId` names the arrow, exactly as a box label is. Writing a
  /// `label` key instead produces a file that opens without complaint and silently has no
  /// edge labels on it, which for a flowchart of decisions loses the half that says which
  /// branch is which.
  private static func edgeLabel(
    _ text: String, id: String, containerID: String, at point: CGPoint, stamp: Int
  ) -> [String: Any] {
    // **Measured, not left at zero.** A bound text element with no width or height is
    // discarded outright by Excalidraw's `restore` — verified by importing a file written
    // that way, which came back with every box label intact and every *arrow* label gone.
    // A flowchart of decisions that loses its yes and no is a flowchart of nothing.
    let size = textSize(text, fontSize: edgeFontSize)
    let centre = scaled(point)
    var element = base(
      id: id, type: "text",
      frame: CGRect(
        x: centre.x - size.width / 2, y: centre.y - size.height / 2,
        width: size.width, height: size.height), stamp: stamp)
    element["strokeColor"] = Ink.stroke
    element["backgroundColor"] = Ink.transparent
    element["fillStyle"] = "solid"
    element["roundness"] = NSNull()
    element["text"] = text
    element["originalText"] = text
    element["fontSize"] = edgeFontSize
    element["fontFamily"] = 1
    element["textAlign"] = "center"
    element["verticalAlign"] = "middle"
    element["containerId"] = containerID
    element["lineHeight"] = 1.25
    element["autoResize"] = true
    return element
  }

  /// The fields every element carries, whatever it is.
  private static func base(
    id: String, type: String, frame: CGRect, stamp: Int
  ) -> [String: Any] {
    [
      "id": id,
      "type": type,
      "x": frame.minX,
      "y": frame.minY,
      "width": frame.width,
      "height": frame.height,
      "angle": 0,
      "strokeWidth": 1,
      "strokeStyle": "solid",
      "roughness": 1,
      "opacity": 100,
      "groupIds": [String](),
      "frameId": NSNull(),
      // Derived from the element's own id rather than drawn at random, so exporting one
      // board twice produces the same file. Excalidraw uses the seed only to pick which
      // way its hand-drawn strokes wobble; a random one would make every export a diff.
      "seed": seed(id),
      "version": 1,
      "versionNonce": seed("nonce-" + id),
      "index": NSNull(),
      "isDeleted": false,
      "boundElements": NSNull(),
      "updated": stamp,
      "link": NSNull(),
      "locked": false,
    ]
  }

  // MARK: - Naming

  static func excalidrawType(_ shape: BoardNodeShape) -> String {
    switch shape {
    case .box, .rounded: return "rectangle"
    case .decision: return "diamond"
    // Excalidraw has no stadium, and an ellipse is the shape its own users draw a start or
    // an end as.
    case .terminal: return "ellipse"
    }
  }

  static func strokeColour(_ shape: BoardNodeShape) -> String {
    switch shape {
    case .decision: return Ink.decisionStroke
    case .terminal: return Ink.terminalStroke
    default: return Ink.stroke
    }
  }

  static func fillColour(_ shape: BoardNodeShape) -> String {
    switch shape {
    case .decision: return Ink.decisionFill
    case .terminal: return Ink.terminalFill
    default: return Ink.transparent
    }
  }

  static func scaled(_ frame: CGRect) -> CGRect {
    CGRect(
      x: frame.minX * exportScale, y: frame.minY * exportScale,
      width: frame.width * exportScale, height: frame.height * exportScale)
  }

  static func scaled(_ point: CGPoint) -> CGPoint {
    CGPoint(x: point.x * exportScale, y: point.y * exportScale)
  }

  /// What a label occupies at the size the file is written at.
  ///
  /// Excalidraw re-measures in its own font when the file is opened, so this does not have
  /// to be exact — it has to be *non-zero*, and close enough that the element's box is not
  /// visibly wrong before the first re-layout.
  static func textSize(_ text: String, fontSize: CGFloat) -> CGSize {
    let bounds = (text as NSString).size(
      withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)])
    return CGSize(width: ceil(bounds.width) + 8, height: ceil(bounds.height) + 4)
  }

  /// Excalidraw ids only have to be unique within the file, so the board's own names do the
  /// job — and make the file readable, which a nanoid does not.
  static func identifier(_ kind: String, _ name: String) -> String {
    let safe = name.unicodeScalars
      .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
    return "gc-\(kind)-\(String(safe))"
  }

  /// FNV-1a, for a stable 31-bit seed from a name. Any hash would do; this one is four
  /// lines and does not vary between processes the way `hashValue` does.
  static func seed(_ text: String) -> Int {
    var hash: UInt32 = 2_166_136_261
    for byte in text.utf8 {
      hash = (hash ^ UInt32(byte)) &* 16_777_619
    }
    return Int(hash & 0x7FFF_FFFF)
  }
}
