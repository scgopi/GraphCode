// swift-tools-version: 5.9

import PackageDescription

#if os(Windows)
let graphcodeKitTarget: Target = .target(
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
  ])
let graphcodedExclude = ["DarwinMain.swift"]
let platformTestTargets: [Target] = [
  .testTarget(
    name: "GraphcodeWindowsProductionTests",
    dependencies: ["GraphcodeKit"],
    path: "windows-tests")
]
#else
// The production package is also buildable on Darwin. The complete source tree
// supplies the Unix transport/session providers, while Windows-only files are
// guarded with #if os(Windows).
let graphcodeKitTarget: Target = .target(
  name: "GraphcodeKit",
  dependencies: [
    .product(name: "IdentifiedCollections", package: "swift-identified-collections")
  ],
  path: "GraphcodeKit/Sources")
let graphcodedExclude: [String] = []
let platformTestTargets: [Target] = []
#endif

let package = Package(
  name: "GraphcodeProduction",
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
    graphcodeKitTarget,
    .executableTarget(
      name: "graphcoded",
      dependencies: ["GraphcodeKit"],
      path: "graphcoded/Sources",
      exclude: graphcodedExclude),
    .executableTarget(
      name: "graphcode",
      dependencies: ["GraphcodeKit"],
      path: "graphcode-cli/Sources"),
  ] + platformTestTargets)
