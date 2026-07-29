import SwiftUI

/// The graph canvas's notebook ruling — graph paper for `ProjectCanvasView` to lay its
/// nodes on, drawn to fill whatever it's given.
///
/// Rather than drawing a huge grid inside the transformed node layer and hoping it's
/// wide enough, this draws only the lines that land on screen and derives their phase
/// from the canvas transform — so it is effectively infinite in every direction at no
/// cost, and never has an edge you can pan past.
///
/// The phase has two terms because the node layer is scaled about its center *and then*
/// translated: a rule at canvas x = k·cell lands at k·(cell·scale) + cx·(1 − scale) +
/// offset. Drop the second term and the ruling slides out from under the nodes as soon
/// as you zoom.
struct NotebookGrid: View {
  /// One notebook square, in canvas points — roughly a fifth of a node card's width, so a
  /// card sits on the ruling rather than being framed by it. 96pt landed about two squares
  /// to a card, which read as a box drawn around each node; 24pt was tried and is too
  /// fine, turning the surface into a texture that competes with the graph instead of
  /// sitting behind it.
  ///
  /// Shared by both canvases: two graph papers at different scales in one app would read
  /// as two different surfaces.
  static let defaultCellSize: CGFloat = 48

  let cellSize: CGFloat
  let offset: CGSize
  let scale: CGFloat

  var body: some View {
    Canvas { context, size in
      let step = cellSize * scale
      // Below a few points apart the rules stop being a grid and become a flat wash of
      // color, so there's nothing worth drawing (and a lot of lines to draw).
      guard step > 6 else { return }

      let phaseX = size.width / 2 * (1 - scale) + offset.width
      let phaseY = size.height / 2 * (1 - scale) + offset.height

      var path = Path()
      var lineX = phaseX.truncatingRemainder(dividingBy: step) - step
      while lineX <= size.width {
        path.move(to: CGPoint(x: lineX, y: 0))
        path.addLine(to: CGPoint(x: lineX, y: size.height))
        lineX += step
      }
      var lineY = phaseY.truncatingRemainder(dividingBy: step) - step
      while lineY <= size.height {
        path.move(to: CGPoint(x: 0, y: lineY))
        path.addLine(to: CGPoint(x: size.width, y: lineY))
        lineY += step
      }
      context.stroke(path, with: .color(Theme.canvasGridLine), lineWidth: 1)
    }
    // The ruling is scenery: it must never eat a canvas drag or a click on a node.
    .allowsHitTesting(false)
  }
}

#Preview {
  NotebookGrid(cellSize: 96, offset: .zero, scale: 1)
    .background(Theme.canvasBackground)
    .frame(width: 480, height: 320)
}
