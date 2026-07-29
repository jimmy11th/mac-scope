// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "MacScopeShell",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "MacScopeShell", targets: ["MacScopeShell"]),
    .executable(
      name: "MacScopeShellConfigCheck",
      targets: ["MacScopeShellConfigCheck"]
    ),
  ],
  dependencies: [
    .package(
      url: "https://github.com/migueldeicaza/SwiftTerm.git",
      exact: "1.15.0"
    )
  ],
  targets: [
    .executableTarget(
      name: "MacScopeShell",
      dependencies: [
        "MacScopeShellCore",
        .product(name: "SwiftTerm", package: "SwiftTerm"),
      ]
    ),
    .target(name: "MacScopeShellCore"),
    .executableTarget(
      name: "MacScopeShellConfigCheck",
      dependencies: ["MacScopeShellCore"]
    ),
  ]
)
