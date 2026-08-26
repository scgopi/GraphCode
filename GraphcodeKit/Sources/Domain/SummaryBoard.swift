import Foundation

/// What shape a run turned out to have — the one judgement the composer is asked to make.
///
/// Deliberately two, not ten. A model given a menu of diagram types will find a reason to
/// use every one of them, and a run rendered as a sequence diagram because the menu had a
/// sequence diagram on it is a picture that tells you about the menu. Work either has an
/// order to it or it has facts in columns; anything else is a sentence, which the summary
/// rail above already draws.
public enum BoardForm: String, Codable, Sendable, CaseIterable {
  /// Steps, branches and hand-offs — a plan, a pipeline, a decision the session made.
  case flow
  /// Rows and columns — findings, files touched, options weighed, a comparison.
  case table
}

/// Which way a flow runs. Mermaid's own two useful answers; `RL`/`BT` are parsed and
/// normalised to these, because a board that reads bottom-up next to a terminal that reads
/// top-down is a board nobody reads twice.
public enum BoardDirection: String, Codable, Sendable {
  case topDown
  case leftRight
}

/// A box on a flow board. The shapes are Mermaid's, narrowed to the four that survive
/// being drawn at 90 points wide.
public enum BoardNodeShape: String, Codable, Sendable {
  /// `[text]` — a step.
  case box
  /// `(text)` — a state, something the run is in rather than does.
  case rounded
  /// `{text}` — a branch. The only shape that earns its geometry: a diamond is how you
  /// see there was a choice without reading the label.
  case decision
  /// `([text])` — where the flow starts or stops.
  case terminal
}

public struct BoardNode: Codable, Equatable, Sendable, Identifiable {
  /// Mermaid's own identifier, kept rather than reissued: the edges name it, and a board
  /// re-parsed from its own `source` has to come out the same both times.
  public let id: String
  public let text: String
  public let shape: BoardNodeShape

  public init(id: String, text: String, shape: BoardNodeShape = .box) {
    self.id = id
    self.text = text
    self.shape = shape
  }
}

public enum BoardEdgeStyle: String, Codable, Sendable {
  case solid
  /// `-.->` — a path taken conditionally, or a hand-off that hasn't happened.
  case dashed
  /// `==>` — the spine of the run, when the composer marks one.
  case thick
}

public struct BoardEdge: Codable, Equatable, Sendable, Identifiable {
  public let from: String
  public let to: String
  /// `-->|yes|` — the condition, when there is one. Never invented: an unlabelled arrow
  /// stays unlabelled rather than being given "then".
  public let label: String?
  public let style: BoardEdgeStyle

  public var id: String { "\(from)→\(to)#\(label ?? "")" }

  public init(from: String, to: String, label: String? = nil, style: BoardEdgeStyle = .solid) {
    self.from = from
    self.to = to
    self.label = label
    self.style = style
  }
}

public struct BoardTable: Codable, Equatable, Sendable {
  public let headers: [String]
  public let rows: [[String]]

  public init(headers: [String], rows: [[String]]) {
    self.headers = headers
    self.rows = rows
  }

  /// Rows padded and clipped to the header count, so the renderer can index a row by
  /// column without checking. A model writing Markdown by hand drops a cell often enough
  /// that the alternative is a crash on a table that looked fine.
  public var normalisedRows: [[String]] {
    rows.map { row in
      row.count == headers.count
        ? row
        : Array((row + Array(repeating: "", count: headers.count)).prefix(headers.count))
    }
  }
}

/// A run, drawn — the visual counterpart to `LoopSummary`, produced once per finished pass
/// and bounded the same way.
///
/// **The Mermaid is the source and the drawing is derived, not the other way round.** The
/// composer's whole output is `source`; everything else on this type is what
/// `MermaidBoardParser` made of it. That ordering is what makes the board portable — the
/// text pastes into a pull request, a GitHub comment or anywhere else that speaks Mermaid,
/// and graphcode renders it natively rather than being the only place it exists. It also
/// means a board that fails to re-parse is still a board: the source is shown as code and
/// nothing is lost, which is the honest outcome for a diagram type this build cannot draw.
///
/// Bounded by construction, like the summary it sits under: a board is capped at
/// `maxNodes`/`maxEdges` or `maxRows` and re-composed rather than accumulated, so a
/// six-hour loop and a six-minute one cost the same bytes in the graph file.
public struct SummaryBoard: Codable, Equatable, Sendable {
  /// Past this a flow stops being a picture and becomes a diagram of a diagram. Chosen
  /// against the rail's expanded width rather than a round number: 24 boxes is roughly six
  /// layers of four, which is what fits at a readable font before anything has to scroll.
  public static let maxNodes = 24
  public static let maxEdges = 40
  public static let maxRows = 12
  /// Five columns at the expanded rail's ~520 points of content is about 100 points each —
  /// the point at which a heading stops fitting on one line.
  public static let maxColumns = 5

  public let form: BoardForm
  /// The board's own heading, when the composer gave one. Not the loop's title: the loop
  /// is named twice on screen already.
  public let title: String?
  public let direction: BoardDirection
  public let nodes: [BoardNode]
  public let edges: [BoardEdge]
  public let table: BoardTable?
  /// The composer's reply, verbatim and unrepaired. Copyable, and the fallback the view
  /// shows when this build cannot draw what it describes.
  public let source: String
  /// Which pass this describes — `LoopSummary.currentPass` at the moment it was composed.
  ///
  /// The whole of the dedupe. A board whose pass equals the summary's is a board already
  /// paid for, and `GraphStore` will not spend a second call on it however many times the
  /// poll comes round.
  public let pass: Int
  public let composedAt: Date

  public init(
    form: BoardForm, title: String? = nil, direction: BoardDirection = .topDown,
    nodes: [BoardNode] = [], edges: [BoardEdge] = [], table: BoardTable? = nil,
    source: String, pass: Int, composedAt: Date = Date()
  ) {
    self.form = form
    self.title = title
    self.direction = direction
    self.nodes = Array(nodes.prefix(Self.maxNodes))
    let known = Set(self.nodes.map(\.id))
    // Edges are filtered against the nodes that survived the cap, not merely counted: an
    // arrow into a box that was trimmed away draws as a line to nowhere, and the layout
    // would place a phantom layer to hold the box it points at.
    self.edges = Array(
      edges.filter { known.contains($0.from) && known.contains($0.to) }
        .prefix(Self.maxEdges))
    self.table = table.map {
      BoardTable(
        headers: Array($0.headers.prefix(Self.maxColumns)),
        rows: Array($0.rows.prefix(Self.maxRows)).map { row in
          Array(row.prefix(Self.maxColumns))
        })
    }
    self.source = source
    self.pass = pass
    self.composedAt = composedAt
  }

  /// Whether there is anything worth giving the rail's space to. A single box with no
  /// arrows is a sentence drawn as a rectangle — the summary above already said it better.
  public var isDrawable: Bool {
    switch form {
    case .flow: return nodes.count >= 2 && !edges.isEmpty
    case .table: return (table?.rows.isEmpty == false) && (table?.headers.isEmpty == false)
    }
  }

  /// Hand-written for the reason `LoopSummary`'s is: a graph file that fails to decode is
  /// a graph the app reports as having no loops in it. Every field is optional on the way
  /// in, so a board written by a build before this one — or after the next one — still
  /// loads, and an unreadable one degrades to its source text rather than to nothing.
  private enum CodingKeys: String, CodingKey {
    case form, title, direction, nodes, edges, table, source, pass, composedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    form = try container.decodeIfPresent(BoardForm.self, forKey: .form) ?? .flow
    title = try container.decodeIfPresent(String.self, forKey: .title)
    direction = try container.decodeIfPresent(BoardDirection.self, forKey: .direction) ?? .topDown
    nodes = try container.decodeIfPresent([BoardNode].self, forKey: .nodes) ?? []
    edges = try container.decodeIfPresent([BoardEdge].self, forKey: .edges) ?? []
    table = try container.decodeIfPresent(BoardTable.self, forKey: .table)
    source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
    pass = try container.decodeIfPresent(Int.self, forKey: .pass) ?? 0
    composedAt = try container.decodeIfPresent(Date.self, forKey: .composedAt) ?? Date()
  }
}
