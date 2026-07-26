import ProjectDescription

// Graphcode: a native macOS orchestrator for a graph of agentic loops.
// See docs/03-architecture.md for the full component breakdown this project scaffolds.
//
// Three products today:
//   - `GraphcodeKit` — shared static framework: Domain types, the daemon<->app IPC
//     protocol, and the PTY session primitive both `graphcode` and `graphcoded` launch
//     CLI backends through. Static, not dynamic, so `graphcoded` (a plain command-line
//     tool with nowhere sensible to embed a dynamic framework) can link it directly.
//   - `graphcode`   — the SwiftUI app (the UI process).
//   - `graphcoded`  — the background orchestrator daemon. From Phase 3 on it's no
//     longer an empty skeleton: it owns the real `LoopGraph` state, fires `.handoff`
//     edges automatically, and arms time-based triggers that survive the app quitting
//     — see docs/07-roadmap.md#phase-3--orchestrator-automation.

let bundleIdPrefix = "dev.graphcode"

let project = Project(
    name: "graphcode",
    organizationName: "Graphcode",
    targets: [
        .target(
            name: "GraphcodeKit",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "\(bundleIdPrefix).kit",
            deploymentTargets: .macOS("15.0"),
            buildableFolders: [
                "GraphcodeKit/Sources"
            ],
            dependencies: [
                .external(name: "IdentifiedCollections")
            ]
        ),
        .target(
            name: "graphcode",
            destinations: .macOS,
            product: .app,
            bundleId: "\(bundleIdPrefix).app",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(with: ["CFBundleIconName": "AppIcon"]),
            resources: [
                "graphcode/Resources/**"
            ],
            buildableFolders: [
                "graphcode/Sources"
            ],
            dependencies: [
                .target(name: "GraphcodeKit"),
                .external(name: "ComposableArchitecture"),
                .external(name: "Dependencies"),
                .external(name: "IdentifiedCollections"),
            ]
        ),
        .target(
            name: "graphcodeTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "\(bundleIdPrefix).app.tests",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            buildableFolders: [
                "graphcode/Tests"
            ],
            dependencies: [.target(name: "graphcode")]
        ),
        .target(
            name: "graphcoded",
            destinations: .macOS,
            product: .commandLineTool,
            bundleId: "\(bundleIdPrefix).graphcoded",
            deploymentTargets: .macOS("15.0"),
            buildableFolders: [
                "graphcoded/Sources"
            ],
            dependencies: [
                .target(name: "GraphcodeKit")
            ]
        ),
    ]
)
