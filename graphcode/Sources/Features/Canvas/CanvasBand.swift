import CoreGraphics
import SwiftUI

/// The band a lane of cards sits in — what replaced the start marker and its tethers.
///
/// The marker's whole job was making a scatter of cards read as a graph, and it did that
/// by occupying the canvas's most legible column with a dot that carried no information:
/// the code comments conceded the tethers were not edges, nothing travelled along them,
/// and there was nothing to right-click. A band does the same grouping work with the
/// space the cards already occupy, and its caption is free to say something — how many
/// loops are in this project and how they are doing.
enum CanvasBand {
  static let radius: CGFloat = 12
  /// Between the band's edge and the cards inside it.
  static let padding: CGFloat = 20
  /// The strip along the top the caption sits in, when there is one.
  static let captionHeight: CGFloat = 18
  /// The caption's own inset from the band's top-left corner.
  static let captionInset = CGSize(width: 14, height: 10)

  static let fill = Color.white.opacity(0.022)
  static let border = Color.white.opacity(0.05)

  /// Where the entry rail sits inside the band's leading edge, and how far the stub
  /// reaches from it to a port. `padding - stub` is what puts the rail exactly one stub
  /// away from a first-column card's leading edge.
  static let railInset: CGFloat = padding - stubLength
  static let stubLength: CGFloat = 12
  static let railWidth: CGFloat = 3
  /// The origin dot, and how far it sits from the leading port it serves.
  static let originDiameter: CGFloat = 12
  static let originGap: CGFloat = 34
  static let railTint = Color.white.opacity(0.22)

  /// The band enclosing cards *centred* at `positions` — the project canvas's case,
  /// where a human drags cards anywhere they like and the band has to follow.
  ///
  /// `nil` for no cards: a band around nothing is a rectangle on an empty canvas, and
  /// `CanvasEmptyState` is already saying what to do about that.
  static func rect(
    around positions: [CGPoint], cardSize: CGSize, captioned: Bool
  ) -> CGRect? {
    guard let minX = positions.map(\.x).min(), let maxX = positions.map(\.x).max(),
      let minY = positions.map(\.y).min(), let maxY = positions.map(\.y).max()
    else { return nil }

    let top = minY - cardSize.height / 2 - padding - (captioned ? captionHeight : 0)
    return CGRect(
      x: minX - cardSize.width / 2 - padding,
      y: top,
      width: (maxX - minX) + cardSize.width + padding * 2,
      height: (maxY - minY) + cardSize.height + padding * 2 + (captioned ? captionHeight : 0))
  }
}

/// One band, drawn behind everything else on the canvas.
///
/// Hit-testing is off: the band covers the whole lane, so a band that took clicks would
/// swallow every pan gesture that started on empty canvas — which is most of them. The
/// caption alone is clickable, and only when it leads somewhere.
struct CanvasBandView: View {
  let rect: CGRect
  var name: String?
  var caption: String?
  var glyph = "folder.fill"
  /// Where each root's port sits, in canvas coordinates: the centre of the circle on
  /// that card's leading edge. The rail spans them and a stub reaches each one.
  var entryPorts: [CGPoint] = []
  var onCaptionTapped: (() -> Void)?

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: CanvasBand.radius)
        .fill(CanvasBand.fill)
        .overlay {
          RoundedRectangle(cornerRadius: CanvasBand.radius)
            .stroke(CanvasBand.border, lineWidth: 1)
        }
        // The band covers its whole lane, so one that took clicks would swallow every
        // pan that started on empty canvas — which is most of them.
        .allowsHitTesting(false)
      entryRail.allowsHitTesting(false)
      captionRow
        .padding(.leading, CanvasBand.captionInset.width)
        .padding(.top, CanvasBand.captionInset.height)
    }
    .frame(width: rect.width, height: rect.height)
    .position(x: rect.midX, y: rect.midY)
  }

  /// The lane's origin: one dot, with a line to every card nothing hands off to.
  ///
  /// This is a deliberate departure from the handoff, which retired the start marker in
  /// favour of a rail. The rail is the better idea in a wired graph — it is a boundary
  /// and cannot imply flow — and it failed the graph people actually have: with three
  /// loose loops and one root, a bar down the left edge labels nothing you can see it
  /// touching, and the canvas reads as scattered cards again.
  ///
  /// So the dot is back, with two things it did not have before. It hangs off the
  /// *ports on the cards*, which are still what carries "this is a beginning" into
  /// greyscale, zoom-out and the sidebar; and it reaches unwired loops too, so nothing
  /// on the canvas floats. What it must not become again is the old marker: these lines
  /// are quieter than any `EdgeLineView`, carry no arrowhead and no fired state, because
  /// nothing travels them.
  ///
  /// The cost is the one the handoff named: N rootless loops is N lines. That is a real
  /// starburst at twenty, and the answer then is to wire the graph up — which is what
  /// the lines are for saying.
  @ViewBuilder
  private var entryRail: some View {
    if let top = entryPorts.map(\.y).min(), let bottom = entryPorts.map(\.y).max(),
      let leading = entryPorts.map(\.x).min()
    {
      let originX = max(leading - rect.minX - CanvasBand.originGap, CanvasBand.railInset)
      let originY = (top + bottom) / 2 - rect.minY
      ZStack(alignment: .topLeading) {
        ForEach(Array(entryPorts.enumerated()), id: \.offset) { _, port in
          connector(
            from: CGPoint(x: originX, y: originY),
            to: CGPoint(x: port.x - rect.minX, y: port.y - rect.minY))
        }
        origin.offset(
          x: originX - CanvasBand.originDiameter / 2,
          y: originY - CanvasBand.originDiameter / 2)
      }
    }
  }

  private var origin: some View {
    Circle()
      .fill(CanvasBand.railTint)
      .frame(width: CanvasBand.originDiameter, height: CanvasBand.originDiameter)
      // Knocked out of the canvas so a connector passing behind it doesn't show through.
      .overlay(Circle().stroke(Theme.canvasTone, lineWidth: 2))
      .overlay(alignment: .bottom) {
        Text("ENTRY")
          .font(.system(size: 9.5, weight: .bold))
          .tracking(0.4)
          .foregroundStyle(.white.opacity(0.42))
          .fixedSize()
          .offset(y: 13)
      }
  }

  /// Curved, not straight, and quiet. A straight 1.5pt line between two cards is what an
  /// edge looks like; this one bends out of the origin and flattens into the port, which
  /// reads as structure rather than as a hand-off.
  private func connector(from origin: CGPoint, to port: CGPoint) -> some View {
    Path { path in
      path.move(to: origin)
      let reach = max((port.x - origin.x) * 0.55, 20)
      path.addCurve(
        to: port,
        control1: CGPoint(x: origin.x + reach, y: origin.y),
        control2: CGPoint(x: port.x - reach, y: port.y))
    }
    .stroke(CanvasBand.railTint, lineWidth: 1.5)
  }

  @ViewBuilder
  private var captionRow: some View {
    if let name {
      HStack(spacing: 6) {
        Image(systemName: glyph)
          .font(.system(size: 10))
          .foregroundStyle(Theme.folderGlyph.opacity(0.8))
        Text(name)
          .font(.system(size: 11.5, weight: .semibold))
          .foregroundStyle(.white.opacity(0.6))
        if let caption {
          Text(caption)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
        }
      }
      .lineLimit(1)
      .fixedSize()
      .contentShape(Rectangle())
      .onTapGesture { onCaptionTapped?() }
    }
  }
}
