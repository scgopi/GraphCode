import AppKit

/// The slot a borrowed terminal surface is dropped into.
///
/// `GhosttyTerminalView` can't hand its surface straight to SwiftUI: SwiftUI treats the
/// view it is given as its own and releases it on unmount, which is precisely the
/// ownership `TerminalSurfaceStore` exists to take back. So the representable makes one of
/// these — cheap, disposable, and genuinely SwiftUI's — and the real surface is adopted
/// into it as a subview. Unmounting throws away the host; the surface goes back to being
/// held only by the store, loses its window, and is told it is occluded.
///
/// Re-parenting a live surface is safe: the Metal layer belongs to the surface view,
/// not to whatever is above it, so
/// moving the view moves the layer with it and the terminal never notices.
final class TerminalSurfaceHostView: NSView {
  private(set) weak var surfaceView: GhosttyTerminalNSView?

  /// Takes the surface in, moving it out of any host that had it before.
  ///
  /// Autoresizing rather than constraints, because the surface's own `setFrameSize`
  /// override is what tells libghostty its new pixel size — the springs drive that
  /// directly, where a constraint pass would need a layout round trip first.
  func adopt(_ view: GhosttyTerminalNSView) {
    guard view.superview !== self else { return }
    view.removeFromSuperview()
    view.frame = bounds
    view.autoresizingMask = [.width, .height]
    addSubview(view)
    surfaceView = view
  }
}
