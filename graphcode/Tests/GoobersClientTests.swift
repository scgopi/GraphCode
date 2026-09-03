import Foundation
import Testing

@testable import GraphcodeKit

@Suite
struct GoobersClientTests {
  private func instance(address: String? = "127.0.0.1:8080") throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-goobers-\(UUID().uuidString)", isDirectory: true)
    if let address {
      let scheduler = root.appendingPathComponent("scheduler", isDirectory: true)
      try FileManager.default.createDirectory(
        at: scheduler, withIntermediateDirectories: true)
      try address.write(
        to: scheduler.appendingPathComponent("api.address"),
        atomically: true,
        encoding: .utf8)
    }
    return root
  }

  @Test
  func discoversTheDaemonAddressFromTheInstance() throws {
    let root = try instance(address: "  127.0.0.1:4321\n")
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(
      try GoobersClient(instanceRoot: root).baseURL().absoluteString == "http://127.0.0.1:4321")
  }

  @Test
  func missingAddressMeansTheDaemonIsNotRunning() throws {
    let root = try instance(address: nil)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: GoobersClient.ClientError.daemonNotRunning) {
      try GoobersClient(instanceRoot: root).baseURL()
    }
  }

  @Test
  func refusesRemoteAddressesUntilTheyHaveATrustModel() throws {
    let root = try instance(address: "mdb.example.test:8080")
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: GoobersClient.ClientError.nonLoopbackAddress("mdb.example.test:8080")) {
      try GoobersClient(instanceRoot: root).baseURL()
    }
  }

  @Test
  func readsHealthAndRunSummaries() async throws {
    let root = try instance()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = GoobersClient(instanceRoot: root) { url in
      switch url.path {
      case "/api/v1/health":
        return (
          Data(
            #"{"apiVersion":"v1","schemaVersion":"v1","ready":true,"healthy":true,"instance":{"name":"demo","environment":"dev"}}"#
              .utf8), 200
        )
      case "/api/v1/runs":
        #expect(url.query == "limit=12")
        return (
          Data(
            #"{"runs":[{"id":"run-1","workflow":"implementation","workflowVersion":1,"gaggle":"demo","trigger":{"kind":"schedule","ref":"@hourly"},"phase":"running","terminal":false,"currentStage":"review","startedAt":"2026-09-03T18:00:00Z","durationMillis":1000,"lastActivityAt":"2026-09-03T18:00:01Z","stale":false,"repassCount":1,"retryCount":0,"noWork":false}]}"#
              .utf8), 200
        )
      default:
        return (Data(), 404)
      }
    }

    let health = try await client.health()
    #expect(health.ready && health.healthy)
    #expect(health.instance.name == "demo")

    let runs = try await client.runs(limit: 12)
    #expect(runs.runs.count == 1)
    #expect(runs.runs[0].trigger.kind == "schedule")
    #expect(runs.runs[0].currentStage == "review")
  }

  @Test
  func boundsTheRunLimitToTheGoobersContract() async throws {
    let root = try instance()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = GoobersClient(instanceRoot: root) { url in
      #expect(url.query == "limit=200")
      return (Data(#"{"runs":[]}"#.utf8), 200)
    }

    _ = try await client.runs(limit: 500)
  }
}
