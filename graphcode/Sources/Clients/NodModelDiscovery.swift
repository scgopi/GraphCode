import Foundation
import GraphcodeKit

/// Asks the Copilot SDK which models the signed-in account may use and merges them into
/// `NodModelCatalog`, so Nod offers models the built-in list predates. The last answer is
/// cached, so pickers have it from launch rather than after a network round trip.
enum NodModelDiscovery {
  struct Listing: Decodable, Equatable {
    struct Model: Decodable, Equatable {
      var id: String
      var name: String
    }

    var models: [Model]?
  }

  static var cacheFile: URL {
    SupportDirectory.url.appendingPathComponent("nod/copilot-models.json")
  }

  static func models(from data: Data) -> [NodModel] {
    guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else { return [] }
    var seen = Set<String>()
    return (listing.models ?? []).compactMap { model in
      guard seen.insert(model.id).inserted else { return nil }
      return NodModelCatalog.copilotModel(id: model.id, name: model.name)
    }
  }

  static func loadCache() {
    guard let data = try? Data(contentsOf: cacheFile) else { return }
    NodModelCatalog.discoveredCopilotModels = models(from: data)
  }

  /// Runs `graphcode-nod --list-models` in the background; a failure leaves the cache as is.
  static func refresh() {
    guard let binary = NodRuntimeLocator.binaryURL() else { return }
    Task.detached(priority: .utility) {
      let process = Process()
      process.executableURL = binary
      process.arguments = ["--list-models", "--engine", "copilot"]
      let output = Pipe()
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      let data: Data? = await withCheckedContinuation { continuation in
        process.terminationHandler = { process in
          let data = output.fileHandleForReading.readDataToEndOfFile()
          continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
        }
        do {
          try process.run()
        } catch {
          process.terminationHandler = nil
          continuation.resume(returning: nil)
        }
      }
      guard let data, !models(from: data).isEmpty else { return }
      try? FileManager.default.createDirectory(
        at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? data.write(to: cacheFile, options: .atomic)
      let found = models(from: data)
      await MainActor.run { NodModelCatalog.discoveredCopilotModels = found }
    }
  }
}
