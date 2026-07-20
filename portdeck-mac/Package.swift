// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PortDeckMac",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "PortDeckMac", targets: ["PortDeckMac"])
  ],
  targets: [
    .target(name: "PortDeckCore"),
    .executableTarget(
      name: "PortDeckMac",
      dependencies: ["PortDeckCore"]
    ),
    .testTarget(
      name: "PortDeckCoreTests",
      dependencies: ["PortDeckCore", "PortDeckMac"]
    )
  ]
)
