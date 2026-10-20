// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClawdUsage",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClawdUsage", targets: ["ClawdUsage"]),
    ],
    targets: [
        // Pure logic: parsers, probes, state machines. No AppKit, fully unit-tested.
        .target(name: "ClawdCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // The app: menu bar item, floating panel, SwiftUI views.
        .executableTarget(name: "ClawdUsage", dependencies: ["ClawdCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ClawdCoreTests", dependencies: ["ClawdCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
