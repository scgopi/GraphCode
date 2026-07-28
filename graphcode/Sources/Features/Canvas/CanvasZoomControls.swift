import SwiftUI

/// Zoom out / readout / zoom in / fit, for any pan-and-zoom canvas — the Graph overview
/// and a project's own canvas both mount it bottom-right.
///
/// On-screen rather than shortcuts alone: a pinch is a trackpad gesture, and these are
/// views people will reach with a mouse. The readout is a button because "what scale am I
/// at" and "put me back at 1:1" are the same question asked twice.
///
/// Shared rather than copied into each canvas: two zoom widgets that drift apart in step
/// size or shortcuts would be worse than one in either place.
struct CanvasZoomControls: View {
  @Binding var transform: CanvasTransform
  /// The pane, so the buttons — which have no pointer position to zoom about — can zoom
  /// about its centre.
  let viewport: CGSize
  /// The graph's extent, for actual-size and fit.
  let content: CGSize

  var body: some View {
    HStack(spacing: 2) {
      Button {
        transform = transform.stepped(by: 1 / CanvasTransform.step, in: viewport)
      } label: {
        Image(systemName: "minus.magnifyingglass").frame(width: 22, height: 22)
      }
      .keyboardShortcut("-", modifiers: .command)
      .disabled(!transform.canZoomOut)
      .help("Zoom out (⌘−)")

      Button {
        transform = .centred(content, in: viewport)
      } label: {
        Text(transform.percentLabel)
          .font(.caption.monospacedDigit())
          .frame(width: 46)
      }
      .keyboardShortcut("0", modifiers: .command)
      .help("Actual size (⌘0)")

      Button {
        transform = transform.stepped(by: CanvasTransform.step, in: viewport)
      } label: {
        Image(systemName: "plus.magnifyingglass").frame(width: 22, height: 22)
      }
      // ⌘= rather than ⌘+, because ⌘+ is the shifted key nobody actually presses.
      .keyboardShortcut("=", modifiers: .command)
      .disabled(!transform.canZoomIn)
      .help("Zoom in (⌘=)")

      Divider().frame(height: 14)

      Button {
        transform = .fitting(content, in: viewport)
      } label: {
        Image(systemName: "arrow.down.forward.and.arrow.up.backward")
          .frame(width: 22, height: 22)
      }
      .keyboardShortcut("9", modifiers: .command)
      .disabled(content == .zero)
      .help("Fit the whole graph (⌘9)")
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    .padding(12)
  }
}

#Preview {
  CanvasZoomControls(
    transform: .constant(CanvasTransform()),
    viewport: CGSize(width: 600, height: 400),
    content: CGSize(width: 1200, height: 900)
  )
  .padding(40)
  .background(Theme.canvasBackground)
}
