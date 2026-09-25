// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "SlurmBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SlurmBar", targets: ["SlurmBar"]),
        .executable(name: "slurmbar-check", targets: ["slurmbar-check"]),
    ],
    targets: [
        .target(name: "SlurmBarCore", swiftSettings: v5),
        .executableTarget(name: "SlurmBar", dependencies: ["SlurmBarCore"], swiftSettings: v5),
        .executableTarget(name: "slurmbar-check", dependencies: ["SlurmBarCore"], swiftSettings: v5),
    ]
)
