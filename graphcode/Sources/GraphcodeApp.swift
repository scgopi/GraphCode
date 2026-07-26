import ComposableArchitecture
import SwiftUI

@main
struct GraphcodeApp: App {
  static let store = Store(initialState: GraphCanvasFeature.State()) {
    GraphCanvasFeature()
  }

  var body: some Scene {
    WindowGroup {
      GraphCanvasView(store: Self.store)
    }
  }
}
