// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KitStudio",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MPCCore", targets: ["MPCCore"]),
        .executable(name: "KitStudio", targets: ["KitStudio"])
    ],
    targets: [
        .target(name: "MPCCore", resources: [.process("Resources")]),
        .executableTarget(name: "KitStudio", dependencies: ["MPCCore"]),
        .testTarget(name: "MPCCoreTests", dependencies: ["MPCCore"])
    ],
    swiftLanguageVersions: [.v5]
)
