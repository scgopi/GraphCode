// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "GraphcodeWindowsContractsSpike",
  products: [
    .library(name: "GraphcodeWindowsContracts", targets: ["GraphcodeWindowsContracts"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/pointfreeco/swift-identified-collections",
      exact: "1.1.1")
  ],
  targets: [
    .target(
      name: "MailroomKit",
      path: "Sources/GraphcodeWindowsContracts/MailroomKit"),
    .target(
      name: "GraphcodeWindowsContracts",
      dependencies: [
        "MailroomKit",
        .product(name: "IdentifiedCollections", package: "swift-identified-collections"),
      ],
      path: "Sources/GraphcodeWindowsContracts",
      exclude: [
        "Domain/BackendCommand.swift",
        "Domain/SessionBriefing.swift",
        "IPC/DaemonSocketClient.swift",
        "IPC/OutboundChannel.swift",
        "MailroomKit",
      ],
      sources: [
        "Domain",
        "IPC",
        "Platform",
        "QuickChatStore.swift",
        "SupportDirectory.swift",
      ]),
    .testTarget(
      name: "GraphcodeWindowsContractsTests",
      dependencies: ["GraphcodeWindowsContracts"]),
  ])
