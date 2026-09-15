// swift-tools-version: 6.0
import PackageDescription

// SwiftPM manifest for the non-UI products — GraphcodeKit, the `graphcode` CLI, and
// `graphcoded` — so they build anywhere swift-corelibs Foundation runs, where Tuist
// and Xcode don't. The macOS app keeps building through `Project.swift`; Tuist
// resolves its dependencies from `Tuist/Package.swift` and ignores this file.
#if os(Windows)
  let graphcodeKitTarget: Target = .target(
    name: "GraphcodeKit",
    dependencies: [
      "MailroomKit",
      .product(name: "IdentifiedCollections", package: "swift-identified-collections"),
    ],
    path: "GraphcodeKit/Sources",
    exclude: [
      "IPC/OutboundChannel.swift",
      "Platform/WindowsSessionServices.swift",
      "Sessions/PTYProcessSession.swift",
    ],
    sources: [
      "Domain",
      "CLI/GraphcodeCommand.swift",
      "IPC",
      "Platform",
      "Deadline.swift",
      "DaemonBootstrap.swift",
      "GraphExportBundle.swift",
      "GraphExportBundle+ZIP.swift",
      "GraphStore.swift",
      "GraphWriter.swift",
      "TerminalLayoutStore.swift",
      "Workspace.swift",
      "WorkspaceLock.swift",
      "QuickChatStore.swift",
      "Sessions/QuickChatSessionRegistry.swift",
      "ProjectPersistence.swift",
      "ProjectPersistence+Export.swift",
      "ProjectRegistry.swift",
      "SupportDirectory.swift",
      "Sessions/MessageBus.swift",
      "Sessions/NodeMemory.swift",
      "GraphcodeSettingsStore.swift",
      "Sessions/AgentEnvironment.swift",
      "Sessions/CLISessionBackend.swift",
      "Sessions/ClaudeSessionLog.swift",
      "Sessions/ClaudeCodeTrust.swift",
      "Sessions/CodexSessionLog.swift",
      "Sessions/CodexThreadResolver.swift",
      "Sessions/CondemnedSessions.swift",
      "Sessions/CopilotSessionLog.swift",
      "Sessions/CopilotTrust.swift",
      "Sessions/OpenCodePresencePlugin.swift",
      "Sessions/RemoteEnsureGate.swift",
      "Sessions/RemoteGraphAccess.swift",
      "Sessions/RemoteSocketForwarder.swift",
      "Sessions/RemoteTranscriptProbe.swift",
      "Sessions/GoalVerdictReader.swift",
      "Sessions/MermaidBoardParser.swift",
      "Sessions/OrphanedSessionReaper.swift",
      "Sessions/PiPresenceExtension.swift",
      "Sessions/ProviderPath.swift",
      "Sessions/SessionIDStore.swift",
      "Sessions/SessionTransplant.swift",
      "Sessions/SessionTransplant+Layouts.swift",
      "Sessions/ShellPredicateEvaluator.swift",
      "Sessions/SummaryBeatBuilder.swift",
      "Sessions/SummaryBoardComposer.swift",
      "Sessions/SummaryModelWriter.swift",
      "Sessions/TranscriptFreshness.swift",
      "Sessions/WindowsPTYProcessSession.swift",
      "Sessions/ZmxSessionLauncher.swift",
      "Sessions/PresenceHooks.swift",
      "Sessions/ZmxLocator.swift",
      "Templates",
    ],
    swiftSettings: [.swiftLanguageMode(.v5)]
  )
  let platformTestTargets: [Target] = [
    .testTarget(
      name: "GraphcodeWindowsProductionTests",
      dependencies: ["GraphcodeKit"],
      path: "windows-tests",
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
#else
  let graphcodeKitTarget: Target = .target(
    name: "GraphcodeKit",
    dependencies: [
      "MailroomKit",
      .product(name: "IdentifiedCollections", package: "swift-identified-collections"),
    ],
    path: "GraphcodeKit/Sources",
    swiftSettings: [.swiftLanguageMode(.v5)]
  )
  let platformTestTargets: [Target] = []
#endif

let package = Package(
  name: "graphcode",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "MailroomKit", targets: ["MailroomKit"]),
    .library(name: "GraphcodeKit", targets: ["GraphcodeKit"]),
    .executable(name: "graphcode", targets: ["graphcode-cli"]),
    .executable(name: "graphcoded", targets: ["graphcoded"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/pointfreeco/swift-identified-collections",
      exact: "1.1.1"
    )
  ],
  targets: [
    // Foundation-only, and listed here as well as in `Project.swift` for the reason
    // this file exists at all: Tuist builds the app, SwiftPM builds everything that
    // has to run on Linux, and a module added to one and not the other compiles on a
    // Mac and fails CI. `GraphcodeKit` exposes `MailroomPost` through `LoopGraph`,
    // so it is a product too — anything importing the kit needs this module in scope.
    .target(
      name: "MailroomKit",
      path: "MailroomKit/Sources",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    graphcodeKitTarget,
    .executableTarget(
      name: "graphcode-cli",
      dependencies: ["GraphcodeKit", "MailroomKit"],
      path: "graphcode-cli/Sources",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
      name: "graphcoded",
      dependencies: ["GraphcodeKit"],
      path: "graphcoded/Sources",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ] + platformTestTargets
)
