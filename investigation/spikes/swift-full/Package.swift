// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "GraphcodeKitWindowsFullSpike",
  products: [
    .library(name: "GraphcodeKit", targets: ["GraphcodeKit"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/pointfreeco/swift-identified-collections",
      exact: "1.1.1")
  ],
  targets: [
    .target(
      name: "GraphcodeKit",
      dependencies: [
        .product(name: "IdentifiedCollections", package: "swift-identified-collections")
      ],
      path: "Sources/GraphcodeKit",
      exclude: [
        "CLI",
        "IPC",
        "Sessions",
        "DaemonBootstrap.swift",
        "GraphStore.swift",
        "GraphcodeSettingsStore.swift",
        "ProjectRegistry.swift",
        "QuickChatStore.swift",
        "TerminalLayoutStore.swift",
        "Domain/BackendCommand.swift",
      ],
      sources: [
        "Domain",
        "Platform",
        "ProjectPersistence.swift",
        "SupportDirectory.swift",
      ]),
    .testTarget(
      name: "GraphcodeKitWindowsTests",
      dependencies: ["GraphcodeKit"],
      path: "Tests/GraphcodeKitWindowsTests"),
  ])
