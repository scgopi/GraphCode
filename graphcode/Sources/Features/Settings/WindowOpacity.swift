import AppKit
import SwiftUI

/// Applies the window-opacity setting to the real `NSWindow` behind a SwiftUI view.
///
/// `NSWindow.alphaValue` rather than making the *fills* translucent. The honest tradeoff:
/// this fades everything, terminal text included, where a background-only effect would
/// leave text crisp. Doing it the other way means every opaque surface in the app —
/// sidebar gloss, canvas, tab strip, and the Ghostty-rendered terminal, which paints its
/// own background in Metal and knows nothing about `Theme` — would have to agree on an
/// alpha, and the terminal simply wouldn't. One window-level value that visibly does what
/// it says beats a half-transparent app where the one pane you look at most stays solid.
///
/// A no-op at 1.0, so the default costs nothing and an untouched window is exactly as
/// opaque as it was before this existed.
private struct WindowOpacityApplier: NSViewRepresentable {
  let opacity: Double

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    // The window isn't attached during `makeNSView`; it is by the next runloop turn.
    DispatchQueue.main.async { view.window?.alphaValue = opacity }
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    DispatchQueue.main.async { view.window?.alphaValue = opacity }
  }
}

extension View {
  /// Sets the enclosing window's opacity. See `WindowOpacityApplier` for what that covers.
  func windowOpacity(_ opacity: Double) -> some View {
    background(WindowOpacityApplier(opacity: opacity).frame(width: 0, height: 0))
  }
}
