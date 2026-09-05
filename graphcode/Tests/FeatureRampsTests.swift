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
    // docs/ramps.json's shape, holding stable off — the kill-switch posture, which a
    // fetched file must impose over any baked default.
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
    // Before any fetch (and after a failed one): the shipped state answers — fully
    // ramped on both channels since 0.1.54-beta3.
    let id = UUID().uuidString
    #expect(
      FeatureRamps.isEnabled(.codespaces, configuration: nil, channel: "beta", installID: id))
    #expect(
      FeatureRamps.isEnabled(.codespaces, configuration: nil, channel: "stable", installID: id))
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

  @Test
  func mailroomShipsOnEverywhere() {
    // The Mailroom is ramped fully on, so — the codespaces rule — its baked default
    // moved up with it: an offline first launch on either channel gets the board, and
    // the served file is the kill switch rather than the opener.
    let id = UUID().uuidString
    #expect(
      FeatureRamps.isEnabled(.mailroom, configuration: nil, channel: "beta", installID: id))
    #expect(
      FeatureRamps.isEnabled(.mailroom, configuration: nil, channel: "stable", installID: id))
    // The fetched file stays both the opener and the kill switch either way: raised
    // to 100 everywhere it turns stable installs on, dropped to 0 it turns even beta
    // installs off.
    let everywhere = FeatureRamps.Configuration(
      features: ["mailroom": ["beta": 100, "stable": 100]])
    #expect(
      FeatureRamps.isEnabled(
        .mailroom, configuration: everywhere, channel: "stable", installID: id))
    let nowhere = FeatureRamps.Configuration(features: ["mailroom": ["beta": 0, "stable": 0]])
    #expect(
      !FeatureRamps.isEnabled(
        .mailroom, configuration: nowhere, channel: "beta", installID: id))
  }
}
