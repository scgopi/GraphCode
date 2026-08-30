// swift-tools-version: 6.0
import PackageDescription

// SwiftPM manifest for the non-UI products — GraphcodeKit, the `graphcode` CLI, and
// `graphcoded` — so they build on Linux (and anywhere else swift-corelibs Foundation
// runs), where Tuist and Xcode don't. The macOS app keeps building through
// `Project.swift`; Tuist resolves its dependencies from `Tuist/Package.swift` and
// ignores this file. See issue #83.
let package = Package(
  name: "graphcode",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "GraphcodeKit", targets: ["GraphcodeKit"]),
    .executable(name: "graphcode", targets: ["graphcode-cli"]),
    .executable(name: "graphcoded", targets: ["graphcoded"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/pointfreeco/swift-identified-collections",
      from: "1.1.0"
    )
  ],
  targets: [
    .target(
      name: "GraphcodeKit",
      dependencies: [
        .product(name: "IdentifiedCollections", package: "swift-identified-collections")
      ],
      path: "GraphcodeKit/Sources",
      // Language mode 5 to match how Tuist/Xcode builds these same sources today;
      // moving the tree to strict mode 6 is its own change, not the Linux port's.
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
      name: "graphcode-cli",
      dependencies: ["GraphcodeKit"],
      path: "graphcode-cli/Sources",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
      name: "graphcoded",
      dependencies: ["GraphcodeKit"],
      path: "graphcoded/Sources",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
