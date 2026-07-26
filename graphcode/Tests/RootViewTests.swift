import Testing

@testable import graphcode

@Suite
struct RootViewTests {
  @Test
  func rootViewBuilds() {
    // Phase 0: nothing to assert yet beyond "the app target compiles and links
    // its test target." Real behavior lands with the first feature in Phase 1.
    _ = RootView()
  }
}
