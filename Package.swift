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
    "TerminalLayoutStore.swift",
    "Platform/WindowsSessionServices.swift",
    "Sessions/PTYProcessSession.swift",
  ],
  sources: [
    "Domain",
    "CLI/GraphcodeCommand.swift",
    "IPC",
    "Platform",
    "DaemonBootstrap.swift",
    "GraphStore.swift",
    "QuickChatStore.swift",
    "Sessions/QuickChatSessionRegistry.swift",
    "ProjectPersistence.swift",
    "ProjectRegistry.swift",
    "SupportDirectory.swift",
    "Sessions/MessageBus.swift",
    "Sessions/NodeMemory.swift",
    "GraphcodeSettingsStore.swift",
    "Sessions/AgentEnvironment.swift",
    "Sessions/CLISessionBackend.swift",
    "Sessions/CodexSessionLog.swift",
    "Sessions/CopilotSessionLog.swift",
    "Sessions/RemoteEnsureGate.swift",
    "Sessions/RemoteGraphAccess.swift",
    "Sessions/RemoteSocketForwarder.swift",
    "Sessions/SessionIDStore.swift",
    "Sessions/ShellPredicateEvaluator.swift",
    "Sessions/WindowsPTYProcessSession.swift",
    "Sessions/ZmxSessionLauncher.swift",
    "Sessions/PresenceHooks.swift",
    "Sessions/ZmxLocator.swift",
  ])
let graphcodedExclude: [String] = []
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
  // Only consulted by the Apple toolchain; the Windows build ignores it. Without it
  // SwiftPM assumes macOS 10.13 and the shared sources fail to build there on APIs the
  // Xcode app has always had, since that project sets its own far higher target.
  platforms: [.macOS(.v13)],
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
