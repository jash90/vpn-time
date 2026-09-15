// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VPNTime",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "VPNTimeCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "VPNTime",
            dependencies: ["VPNTimeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VPNTimeCoreTests",
            dependencies: ["VPNTimeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
