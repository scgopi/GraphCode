import SwiftUI

/// The `+` a lane's origin dot reveals when the pointer comes near it — "start another
/// chain in this folder". The card handle's twin (`CanvasConnectorHandle`), for the one
/// place on the canvas that isn't a card.
///
/// The dot itself is untouched: it stays the same marker it always was, and the handle
/// floats below it only while the pointer is close. A hover target much larger than the
/// 12pt dot, because "close to the entry" is what a hand aims at — hitting a dot that
/// size exactly is a demand, not an affordance.
struct CanvasEntryHandle: View {
  let help: String
  let action: () -> Void

  @State private var isNear = false
  @State private var isHandleHovered = false

  /// Below rather than beside: the connectors to this lane's entry loops all leave the
  /// dot to the right, and a handle sitting in that fan reads as a point on a line.
  private static let dropBelow: CGFloat = 20

  var body: some View {
    ZStack {
      Color.clear
        .frame(width: 60, height: 56)
        .contentShape(Rectangle())
        .onHover { isNear = $0 }
      if isNear || isHandleHovered {
        CanvasConnectorHandle()
          .offset(y: Self.dropBelow)
          .onHover { isHandleHovered = $0 }
          .onTapGesture(perform: action)
          .help(help)
      }
    }
  }
}
