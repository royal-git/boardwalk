// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BetterDock",
    platforms: [.macOS(.v13)],
    targets: [
        // No UI: the per-desktop dock model, storage, reading Apple's Dock.
        .target(name: "BetterDockCore"),
        .testTarget(name: "BetterDockCoreTests", dependencies: ["BetterDockCore"]),
    ]
)
