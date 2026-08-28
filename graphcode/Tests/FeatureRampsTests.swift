import Foundation
import Testing

@testable import graphcode

/// The no-backend rollout ramp: `ramps.json` on the site, decoded and answered
/// per-install. What matters is determinism — the same install must get the same
/// answer every launch, and a raised percent must only ever add installs.
@Suite
struct FeatureRampsTests {
  @Test
  func theBucketIsStableAndCoversTheRange() {
    let id = "6E7F4C2A-9B1D-4E3F-8A5C-2D0B9F714E68"
    let bucket = FeatureRamps.bucket(installID: id)
    // Stable across calls (and, because it is SHA-256 rather than `Hasher`, across
    // launches — Hasher's per-process seed was the trap here).
    #expect(FeatureRamps.bucket(installID: id) == bucket)
    #expect((0..<100).contains(bucket))
    // Different installs spread: a hundred UUIDs should not all share one bucket.
    let buckets = Set((0..<100).map { _ in FeatureRamps.bucket(installID: UUID().uuidString) })
    #expect(buckets.count > 10)
  }

  @Test
  func percentEdgesAreAbsolute() {
    let off = FeatureRamps.Configuration(features: ["codespaces": ["beta": 0, "stable": 0]])
    let on = FeatureRamps.Configuration(features: ["codespaces": ["beta": 100, "stable": 100]])
    for _ in 0..<20 {
      let id = UUID().uuidString
      #expect(
        !FeatureRamps.isEnabled(.codespaces, configuration: off, channel: "beta", installID: id))
      #expect(
        FeatureRamps.isEnabled(.codespaces, configuration: on, channel: "stable", installID: id))
    }
  }

  @Test
  func rampsJSONDecodesAndDrivesTheDecision() throws {
    // The exact shape docs/ramps.json ships — beta on, stable off.
    let json = #"{ "features": { "codespaces": { "beta": 100, "stable": 0 } } }"#
    let configuration = try JSONDecoder().decode(
      FeatureRamps.Configuration.self, from: Data(json.utf8))
    let id = UUID().uuidString
    #expect(
      FeatureRamps.isEnabled(
        .codespaces, configuration: configuration, channel: "beta", installID: id))
    #expect(
      !FeatureRamps.isEnabled(
        .codespaces, configuration: configuration, channel: "stable", installID: id))
  }

  @Test
  func missingConfigurationFallsBackToTheBakedDefaults() {
    // Before any fetch (and after a failed one): beta has the feature, stable waits.
    let id = UUID().uuidString
    #expect(
      FeatureRamps.isEnabled(.codespaces, configuration: nil, channel: "beta", installID: id))
    #expect(
      !FeatureRamps.isEnabled(.codespaces, configuration: nil, channel: "stable", installID: id))
    // A fetched file that omits a channel falls back per-channel, not per-file.
    let partial = FeatureRamps.Configuration(features: ["codespaces": ["stable": 100]])
    #expect(
      FeatureRamps.isEnabled(.codespaces, configuration: partial, channel: "beta", installID: id))
    #expect(
      FeatureRamps.isEnabled(.codespaces, configuration: partial, channel: "stable", installID: id))
  }

  @Test
  func anUnknownChannelIsOff() {
    // A garbage override can't turn a ramp on: no percent for the channel and no
    // baked default means 0.
    let configuration = FeatureRamps.Configuration(features: ["codespaces": ["beta": 100]])
    #expect(
      !FeatureRamps.isEnabled(
        .codespaces, configuration: configuration, channel: "nightly",
        installID: UUID().uuidString))
  }
}
