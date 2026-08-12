// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "GraphcodePortableDomainSpike",
  products: [
    .library(name: "GraphcodePortableDomain", targets: ["GraphcodePortableDomain"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/pointfreeco/swift-identified-collections",
      exact: "1.1.1")
  ],
  targets: [
    .target(
      name: "GraphcodePortableDomain",
      dependencies: [
        .product(name: "IdentifiedCollections", package: "swift-identified-collections")
      ],
      path: "Sources/GraphcodePortableDomain",
      exclude: [
        "BackendCommand.swift",
        "RemoteProjectLocation.swift",
        "SessionBriefing.swift",
      ]),
    .testTarget(
      name: "GraphcodePortableDomainTests",
      dependencies: ["GraphcodePortableDomain"]),
  ])
