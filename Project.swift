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
            infoPlist: .extendingDefault(with: [
                // The name a human sees — menu bar, Finder, Dock, About. Distinct from
                // the bundle's filename and from `graphcode` the CLI, which stay lower
                // case because they are a path and a command someone types.
                "CFBundleName": "GraphCode",
                "CFBundleDisplayName": "GraphCode",
                "CFBundleIconName": "AppIcon",
                // The app reported Tuist's default 1.0 while every release was tagged
                // v0.0.x, so About said one thing and the download page another. Keep
                // this in step with the git tag when cutting a release — suffix and
                // all: since 0.1.15-beta3 a beta carries its full version here, which
                // is how Check for Updates knows the install is on the beta channel
                // (#33). Before that the suffix lived on the tag only, so betas 48/49
                // of the 0.1.15 line read "0.1.15" and are told by the build number
                // apart.
                "CFBundleShortVersionString": "0.1.42-beta8",
                "CFBundleVersion": "148",
            ]),
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
                // Built by `make build-ghostty` (see Makefile) — not committed, not
                // vendored in-tree. `generate`/`build-app` depend on that target so
                // this path exists before Tuist needs to inspect it.
                .xcframework(path: ".build/ghostty/GhosttyKit.xcframework"),
                // libghostty's keyboard-layout handling (`input.KeymapDarwin`) calls
                // the Carbon TIS* APIs directly.
                .sdk(name: "Carbon", type: .framework),
            ],
            settings: .settings(base: [
                "SWIFT_EMIT_LOC_STRINGS": "YES"
            ])
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
        // `graphcode` the CLI (docs/03-architecture.md#cli-graphcode) — a separate
        // product from `graphcode` the app, talking to `graphcoded` over the same socket
        // the app uses. Named `graphcode-cli` as a Tuist target because two targets
        // can't share a name; the built binary is what a human types.
        .target(
            name: "graphcode-cli",
            destinations: .macOS,
            product: .commandLineTool,
            // Without this the binary is `graphcode_cli` — Tuist sanitizes the hyphen
            // out of the target name. The thing a human types is `graphcode`.
            productName: "graphcode",
            bundleId: "\(bundleIdPrefix).cli",
            deploymentTargets: .macOS("15.0"),
            buildableFolders: [
                "graphcode-cli/Sources"
            ],
            dependencies: [
                .target(name: "GraphcodeKit")
            ]
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
