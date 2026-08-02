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

  /// A bar, not a node. The distinction is the whole point: a marker with lines running
  /// out of it looks like something work travels along, and nothing travels this. A rail
  /// is a boundary — it says "the graph starts on this side" and can't imply flow.
  @ViewBuilder
  private var entryRail: some View {
    if let top = entryPorts.map(\.y).min(), let bottom = entryPorts.map(\.y).max() {
      let railX = CanvasBand.railInset
      ZStack(alignment: .topLeading) {
        Capsule()
          .fill(CanvasBand.railTint)
          .frame(width: CanvasBand.railWidth, height: bottom - top + 24)
          .offset(x: railX, y: top - rect.minY - 12)
        ForEach(Array(entryPorts.enumerated()), id: \.offset) { _, port in
          Rectangle()
            .fill(CanvasBand.railTint)
            .frame(width: CanvasBand.stubLength, height: 2)
            .offset(x: port.x - rect.minX - CanvasBand.stubLength, y: port.y - rect.minY - 1)
        }
        Text("ENTRY")
          .font(.system(size: 10.5, weight: .bold))
          .tracking(0.4)
          .foregroundStyle(.white.opacity(0.42))
          .fixedSize()
          .rotationEffect(.degrees(-90))
          .offset(x: railX - 20, y: (top + bottom) / 2 - rect.minY)
      }
    }
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
