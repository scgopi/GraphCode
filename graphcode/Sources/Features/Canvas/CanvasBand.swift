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
      captionRow
        .padding(.leading, CanvasBand.captionInset.width)
        .padding(.top, CanvasBand.captionInset.height)
    }
    .frame(width: rect.width, height: rect.height)
    .position(x: rect.midX, y: rect.midY)
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
