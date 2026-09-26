import Foundation
import Testing

/// macOS 27 charges a pane's LAN traffic (`ssh`, `git`, an agent's own requests) to the app
/// as the responsible process. With no purpose string there is nothing to prompt with, and
/// the connection can fail with EHOSTUNREACH instead.
@Suite
struct PrivacyUsageDescriptionTests {
  @Test func appDeclaresLocalNetworkUsage() {
    let description =
      Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
    #expect(description?.isEmpty == false)
  }
}
