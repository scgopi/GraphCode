// swift-tools-version: 6.0
import PackageDescription

#if TUIST
  import struct ProjectDescription.PackageSettings

  let packageSettings = PackageSettings(
    productTypes: [:]
  )
#endif

let package = Package(
  name: "graphcode",
  dependencies: [
    // State management for Features (Domain/Clients stay dependency-free — see
    // docs/03-architecture.md). Pulls in swift-dependencies transitively for the
    // Clients dependency-injection pattern (GitClient, CLISessionClient, ...).
    //
    // Pinned past the 1.23.1 tag (latest release as of this writing) because 1.23.1
    // fails to compile under this project's Swift 6.3.3 toolchain — Binding+Observation.swift
    // hits a `WritableKeyPath` Sendable-conformance error that main has since fixed.
    // Revisit this pin once a release after 1.23.1 ships.
    .package(
      url: "https://github.com/pointfreeco/swift-composable-architecture",
      revision: "269d6457986d163557ea2601275b1117e4dee3c0"
    )
  ]
)
