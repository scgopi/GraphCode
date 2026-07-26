import ProjectDescription

// Graphcode: a native macOS orchestrator for a graph of agentic loops.
// See docs/03-architecture.md for the full component breakdown this project scaffolds.
//
// Two products today:
//   - `graphcode`   — the SwiftUI app (the UI process).
//   - `graphcoded`  — the background orchestrator daemon (a command-line tool).
// Phase 0 (see docs/07-roadmap.md) keeps both to an empty, buildable skeleton: no
// Domain/Clients/Features layers yet, no third-party Swift packages yet. Those land
// starting Phase 1.

let bundleIdPrefix = "dev.graphcode"

let project = Project(
    name: "graphcode",
    organizationName: "Graphcode",
    targets: [
        .target(
            name: "graphcode",
            destinations: .macOS,
            product: .app,
            bundleId: "\(bundleIdPrefix).app",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            buildableFolders: [
                "graphcode/Sources"
            ],
            dependencies: []
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
            dependencies: []
        ),
    ]
)
