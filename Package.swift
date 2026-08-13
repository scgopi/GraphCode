// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "GraphcodeWindowsProduction",
  products: [
    .library(name: "GraphcodeKit", targets: ["GraphcodeKit"]),
    .executable(name: "graphcoded", targets: ["graphcoded"]),
    .executable(name: "graphcode", targets: ["graphcode"]),
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
      path: "GraphcodeKit/Sources",
      exclude: [
        "GraphcodeSettingsStore.swift",
        "QuickChatStore.swift",
        "TerminalLayoutStore.swift",
        "Sessions/AgentEnvironment.swift",
        "Sessions/CLISessionBackend.swift",
        "Sessions/CodexSessionLog.swift",
        "Sessions/CopilotSessionLog.swift",
        "Sessions/PTYProcessSession.swift",
        "Sessions/PresenceHooks.swift",
        "Sessions/RemoteEnsureGate.swift",
        "Sessions/RemoteGraphAccess.swift",
        "Sessions/RemoteSocketForwarder.swift",
        "Sessions/SessionIDStore.swift",
        "Sessions/ShellPredicateEvaluator.swift",
        "Sessions/ZmxLocator.swift",
        "Sessions/ZmxSessionLauncher.swift",
      ],
      sources: [
        "Domain",
        "CLI/GraphcodeCommand.swift",
        "IPC",
        "Platform",
        "DaemonBootstrap.swift",
        "GraphStore.swift",
        "ProjectPersistence.swift",
        "ProjectRegistry.swift",
        "SupportDirectory.swift",
        "Sessions/MessageBus.swift",
        "Sessions/NodeMemory.swift",
      ]),
    .executableTarget(
      name: "graphcoded",
      dependencies: ["GraphcodeKit"],
      path: "graphcoded/Sources",
      exclude: ["DarwinMain.swift"]),
    .executableTarget(
      name: "graphcode",
      dependencies: ["GraphcodeKit"],
      path: "graphcode-cli/Sources"),
    .testTarget(
      name: "GraphcodeWindowsProductionTests",
      dependencies: ["GraphcodeKit"],
      path: "windows-tests"),
  ])
