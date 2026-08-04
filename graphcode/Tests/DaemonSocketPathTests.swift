import Foundation
import Testing

@testable import GraphcodeKit

@Suite
struct DaemonSocketPathTests {
  @Test
  func theSocketPathHonoursItsEnvironmentOverride() {
    // `GRAPHCODE_SOCKET` moves just the socket — what a forwarded one is — where
    // `GRAPHCODE_SUPPORT_DIR` moves the whole directory.
    #expect(
      DaemonSocketPath.url(environment: ["GRAPHCODE_SOCKET": "/tmp/elsewhere.sock"]).path
        == "/tmp/elsewhere.sock")
    #expect(
      DaemonSocketPath.url(environment: ["GRAPHCODE_SOCKET": "~/fwd.sock"]).path
        == (("~/fwd.sock" as NSString).expandingTildeInPath))
    // Blank means unset, not "the empty path".
    #expect(
      DaemonSocketPath.url(environment: ["GRAPHCODE_SOCKET": "  "]).path
        == SupportDirectory.url.appendingPathComponent("graphcoded.sock").path)
    #expect(
      DaemonSocketPath.url(environment: [:]).path
        == SupportDirectory.url.appendingPathComponent("graphcoded.sock").path)
  }
}
