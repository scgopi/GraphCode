import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// The `.excalidraw` file a board exports to.
///
/// Every assertion here is about the *format* rather than about the picture, because the
/// picture has already been laid out and tested: this is a serialiser over geometry
/// `BoardLayout` computed. What can go wrong is exactly what a schema-shaped format lets go
/// wrong — a field the app that reads it needs and this one did not write, or a coordinate
/// in the wrong space.
@Suite
struct BoardExportTests {

  private func board() throws -> SummaryBoard {
    try #require(
      MermaidBoardParser.board(
        fromReply: """
          %% title: Release gate
          flowchart TD
            A([Start]) --> B[Build it]
            B --> C{Green?}
            C -->|yes| D([Ship])
            C -.->|no| B
          """, pass: 4, now: Date(timeIntervalSince1970: 0)))
  }

  private func document() throws -> [String: Any] {
    let subject = try board()
    return BoardExcalidrawExport.document(
      for: subject, layout: BoardLayout(board: subject),
      now: Date(timeIntervalSince1970: 1_700_000_000))
  }

  private func elements(_ document: [String: Any]) -> [[String: Any]] {
    document["elements"] as? [[String: Any]] ?? []
  }

  @Test
  func theFileHasTheTopLevelShapeExcalidrawExpects() throws {
    let file = try document()
    #expect(file["type"] as? String == "excalidraw")
    #expect(file["version"] as? Int == BoardExcalidrawExport.schemaVersion)
    #expect(file["source"] is String)
    #expect(file["files"] is [String: Any])
    #expect(file["appState"] is [String: Any])
    #expect(!elements(file).isEmpty)
  }

  @Test
  func everyElementCarriesTheFieldsTheSchemaRequires() throws {
    // From `_ExcalidrawElementBase`. A reader that finds one of these missing does not
    // fail loudly — it draws the element wrong, or not at all.
    let required = [
      "id", "type", "x", "y", "width", "height", "angle", "strokeColor", "backgroundColor",
      "fillStyle", "strokeWidth", "strokeStyle", "roughness", "opacity", "groupIds",
      "frameId", "roundness", "seed", "version", "versionNonce", "isDeleted",
      "boundElements", "updated", "link", "locked",
    ]
    for element in elements(try document()) {
      let type = element["type"] as? String ?? "?"
      for key in required {
        #expect(element[key] != nil, "\(type) element is missing \(key)")
      }
    }
  }

  @Test
  func eachBoxBecomesAShapeOfTheRightKind() throws {
    let byID = Dictionary(
      elements(try document()).compactMap { element -> (String, [String: Any])? in
        guard let id = element["id"] as? String else { return nil }
        return (id, element)
      }, uniquingKeysWith: { first, _ in first })

    #expect(byID["gc-box-A"]?["type"] as? String == "ellipse")  // ([Start])
    #expect(byID["gc-box-B"]?["type"] as? String == "rectangle")  // [Build it]
    #expect(byID["gc-box-C"]?["type"] as? String == "diamond")  // {Green?}
    #expect(byID["gc-box-D"]?["type"] as? String == "ellipse")  // ([Ship])
  }

  /// A bound label moves, wraps and re-centres with its box. An unbound one is a separate
  /// object that is left behind the first time anybody drags anything — which is the whole
  /// reason to export to an editor rather than to an image.
  @Test
  func everyLabelIsBoundToItsBoxInBothDirections() throws {
    let all = elements(try document())
    let shapes = all.filter {
      ($0["type"] as? String).map { $0 != "text" && $0 != "arrow" } == true
    }
    // Box labels only — an arrow's label is bound the same way but to an arrow, and has its
    // own test below.
    let texts = all.filter { element in
      guard element["type"] as? String == "text" else { return false }
      let container = element["containerId"] as? String
      return shapes.contains { $0["id"] as? String == container }
    }
    #expect(texts.count == shapes.count)

    for text in texts {
      let container = try #require(text["containerId"] as? String)
      let box = try #require(shapes.first { $0["id"] as? String == container })
      let bound = try #require(box["boundElements"] as? [[String: String]])
      #expect(bound.contains { $0["id"] == text["id"] as? String && $0["type"] == "text" })
      // The fields Excalidraw needs to lay text out inside a container.
      for key in [
        "text", "originalText", "fontSize", "fontFamily", "textAlign",
        "verticalAlign", "lineHeight",
      ] {
        #expect(text[key] != nil, "text element is missing \(key)")
      }
    }
  }

  /// **The one mistake this format invites.** `points` are local to the arrow, not to the
  /// canvas: the first is always the origin and the rest are offsets from it. Absolute
  /// coordinates draw every arrow at twice its intended distance from the origin.
  @Test
  func arrowPointsAreLocalToTheArrowAndStartAtItsOrigin() throws {
    let arrows = elements(try document()).filter { $0["type"] as? String == "arrow" }
    #expect(!arrows.isEmpty)

    for arrow in arrows {
      let points = try #require(arrow["points"] as? [[CGFloat]])
      #expect(points.count >= 2)
      #expect(points[0] == [0, 0])
      let width = try #require(arrow["width"] as? CGFloat)
      let height = try #require(arrow["height"] as? CGFloat)
      // The frame has to cover every point, or the element's own bounding box is wrong and
      // selecting it in Excalidraw grabs the wrong area.
      #expect(points.allSatisfy { abs($0[0]) <= width + 0.001 })
      #expect(points.allSatisfy { abs($0[1]) <= height + 0.001 })
    }
  }

  @Test
  func aDashedLinkStaysDashed() throws {
    let arrows = elements(try document()).filter { $0["type"] as? String == "arrow" }
    #expect(arrows.filter { $0["strokeStyle"] as? String == "dashed" }.count == 1)
    #expect(arrows.allSatisfy { $0["endArrowhead"] as? String == "arrow" })
  }

  /// **An arrow label is a bound text element, not a field on the arrow.**
  /// `ExcalidrawLinearElement` has no `label` property, so writing one produces a file that
  /// opens without complaint and has no edge labels on it — which for a flowchart of
  /// decisions loses the half that says which branch is which.
  @Test
  func edgeLabelsAreBoundTextRatherThanAFieldOnTheArrow() throws {
    let all = elements(try document())
    let arrows = all.filter { $0["type"] as? String == "arrow" }
    #expect(arrows.allSatisfy { $0["label"] == nil })

    // Two labelled links in the fixture: `-->|yes|` and `-.->|no|`.
    let labelled = arrows.filter { $0["boundElements"] is [[String: String]] }
    #expect(labelled.count == 2)

    let texts = all.filter { $0["type"] as? String == "text" }
    for arrow in labelled {
      let bound = try #require(arrow["boundElements"] as? [[String: String]])
      let textID = try #require(bound.first?["id"])
      let text = try #require(texts.first { $0["id"] as? String == textID })
      #expect(text["containerId"] as? String == arrow["id"] as? String)
    }
    #expect(
      Set(texts.compactMap { $0["text"] as? String })
        .isSuperset(of: ["yes", "no"]))
  }

  /// **A zero-sized text element is discarded by Excalidraw's `restore`.** Verified by
  /// importing a file written that way: every box label came back and every arrow label was
  /// gone, silently. A flowchart of decisions that loses its yes and its no is a flowchart
  /// of nothing.
  /// The exported drawing is bigger than the one on screen, and uniformly so — see
  /// `exportScale`. A box that kept its screen size would have its 16pt hand-drawn label
  /// overflow it, which is what the first version did.
  @Test
  func theWholeDrawingIsScaledByTheSameFactor() throws {
    let subject = try board()
    let layout = BoardLayout(board: subject)
    let file = BoardExcalidrawExport.document(for: subject, layout: layout)
    let boxes = elements(file).filter { $0["id"] as? String == "gc-box-B" }
    let onScreen = try #require(layout.nodes.first { $0.id == "B" }?.frame)
    let exported = try #require(boxes.first)

    let width = try #require(exported["width"] as? CGFloat)
    let originX = try #require(exported["x"] as? CGFloat)
    #expect(abs(width - onScreen.width * BoardExcalidrawExport.exportScale) < 0.001)
    #expect(abs(originX - onScreen.minX * BoardExcalidrawExport.exportScale) < 0.001)

    // Arrows are scaled by the same factor or they stop meeting the boxes.
    let arrow = try #require(
      elements(file).first { $0["id"] as? String == "gc-edge-A-B-" })
    let arrowX = try #require(arrow["x"] as? CGFloat)
    let start = try #require(layout.edges.first { $0.edge.from == "A" }?.start)
    #expect(abs(arrowX - start.x * BoardExcalidrawExport.exportScale) < 0.001)
  }

  @Test
  func everyTextElementHasARealSize() throws {
    let texts = elements(try document()).filter { $0["type"] as? String == "text" }
    #expect(!texts.isEmpty)
    for text in texts {
      let width = try #require(text["width"] as? CGFloat)
      let height = try #require(text["height"] as? CGFloat)
      #expect(width > 0, "\(text["text"] as? String ?? "?") has no width")
      #expect(height > 0, "\(text["text"] as? String ?? "?") has no height")
    }
  }

  /// Dark ink, because the file opens on white paper. The rail's own near-white strokes
  /// would be an export nobody can see, which is worse than no export.
  @Test
  func theExportUsesInkThatShowsOnAWhiteCanvas() throws {
    for element in elements(try document()) {
      let stroke = try #require(element["strokeColor"] as? String)
      #expect(stroke != "transparent")
      #expect(!stroke.lowercased().hasPrefix("#ff"), "\(stroke) will not read on white")
    }
  }

  /// Exporting the same board twice must produce the same bytes, or every export is a diff
  /// against the last one. Only `updated` is a clock, and it is passed in.
  @Test
  func theSameBoardExportsToTheSameBytes() throws {
    let subject = try board()
    let layout = BoardLayout(board: subject)
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    let first = try BoardExcalidrawExport.data(for: subject, layout: layout, now: stamp)
    let second = try BoardExcalidrawExport.data(for: subject, layout: layout, now: stamp)
    #expect(first == second)
  }

  @Test
  func theWholeFileIsValidJSON() throws {
    let subject = try board()
    let data = try BoardExcalidrawExport.data(
      for: subject, layout: BoardLayout(board: subject))
    let reparsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(reparsed?["type"] as? String == "excalidraw")
  }
}
