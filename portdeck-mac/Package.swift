// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PortDeckMac",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "PortDeckMac", targets: ["PortDeckMac"])
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
  ],
  targets: [
    .target(name: "PortDeckCore"),
    .executableTarget(
      name: "PortDeckMac",
      dependencies: [
        "PortDeckCore",
        .product(name: "Sparkle", package: "Sparkle")
      ],
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-rpath",
          "-Xlinker", "@executable_path/../Frameworks"
        ])
      ]
    ),
    .testTarget(
      name: "PortDeckCoreTests",
      dependencies: ["PortDeckCore", "PortDeckMac"]
    )
  ]
)
