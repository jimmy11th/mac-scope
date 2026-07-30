// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "MacScopeNative",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "MacScopeNative", targets: ["MacScopeNative"])
  ],
  targets: [
    .executableTarget(
      name: "MacScopeNative",
      linkerSettings: [
        .linkedFramework("IOKit")
      ]
    )
  ]
)
