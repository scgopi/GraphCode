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
      path: "Sources/GraphcodeKit")
  ])
