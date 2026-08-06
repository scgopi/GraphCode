import AppKit
import SwiftUI

/// Turns trackpad two-finger scroll and mouse-wheel scroll into canvas pan (or
/// ⌘-scroll into zoom). SwiftUI's `DragGesture` requires a click-drag; this bridges
/// the `scrollWheel(with:)` events that a trackpad and scroll wheel emit.
///
/// Applied as a `.background` — it never intercepts hit-testing.
struct CanvasScrollHandler: NSViewRepresentable {
  @Binding var transform: CanvasTransform
  let viewport: CGSize

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    let coordinator = context.coordinator
    coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
      guard let window = view.window,
        event.window === window,
        let contentView = window.contentView
      else { return event }

      let locationInContent = contentView.convert(event.locationInWindow, from: nil)
      let viewFrame = view.convert(view.bounds, to: contentView)
      guard viewFrame.contains(locationInContent) else { return event }

      let isZoom = event.modifierFlags.contains(.command)
      let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
      let dx = event.scrollingDeltaX * scale
      let dy = event.scrollingDeltaY * scale

      coordinator.apply?(dx, dy, isZoom)
      return nil
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.apply = { [self] dx, dy, isZoom in
      if isZoom {
        let centre = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let factor: CGFloat = dy > 0 ? 1 / CanvasTransform.step : CanvasTransform.step
        transform = transform.zoomed(to: transform.scale * factor, around: centre, in: viewport)
      } else {
        transform.offset.width += dx
        transform.offset.height += dy
      }
    }
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    if let monitor = coordinator.monitor {
      NSEvent.removeMonitor(monitor)
      coordinator.monitor = nil
    }
  }

  final class Coordinator {
    var monitor: Any?
    var apply: ((CGFloat, CGFloat, Bool) -> Void)?
  }
}
