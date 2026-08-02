import SwiftUI

/// One loop card plus its hover-revealed trailing handle, shared by the project canvas
/// and the Graph overview so a card behaves the same wherever you meet it.
///
/// Owns the hover state itself, per card, rather than letting the canvas keep it in
/// `@State`: up at canvas level a hover flip re-evaluated the whole body — and with it
/// the sub-graph walk and attention rollup that both canvases' `body` comments exist to
/// keep off the input path. Down here a pointer crossing cards re-renders exactly the
/// cards it crossed.
///
/// The handle stays while hovered itself — it hangs half outside the card, so moving
/// onto it must not count as leaving — and while a drag it started is in flight.
struct HoverRevealingCard<Card: View, Handle: View>: View {
  /// An edge drag this card's handle started. The overview has no drag to speak of and
  /// leaves it at its default; a folder's canvas passes its in-flight source.
  var isDragSource: Bool = false
  @ViewBuilder let card: () -> Card
  @ViewBuilder let handle: () -> Handle

  @State private var isHovered = false
  @State private var isHandleHovered = false

  var body: some View {
    card()
      .onHover { isHovered = $0 }
      .overlay(alignment: .trailing) {
        if isHovered || isHandleHovered || isDragSource {
          handle()
            .offset(x: 14)
            .onHover { isHandleHovered = $0 }
        }
      }
  }
}
