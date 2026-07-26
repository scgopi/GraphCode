import GraphcodeKit
import SwiftUI

/// The presence-dot color for a `LoopNode`'s state — shared by every place that shows
/// one (`AppSidebarView`'s rows, `ProjectCanvasView`'s node cards, `LoopTabBarView`'s
/// tabs), so there's one mapping instead of three copies. `GraphcodeKit` itself stays
/// free of SwiftUI (it's also linked into the plain `graphcoded` daemon target), so this
/// lives in the app target instead of alongside `LoopState`.
extension LoopState {
  var presenceColor: Color {
    switch self {
    case .idle: .gray
    case .running: .blue
    case .awaitingInput: .orange
    case .blocked: .orange
    case .succeeded: .green
    case .failed: .red
    case .stalled: .purple
    }
  }
}
