// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BetterDock",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BetterDock", targets: ["BetterDock"]),
    ],
    targets: [
        // No UI: the per-desktop dock model, storage, reading Apple's Dock.
        .target(name: "BetterDockCore"),
        // The menu bar app: the docks, following desktops, hiding Apple's Dock.
        .executableTarget(name: "BetterDock", dependencies: ["BetterDockCore"]),
        .testTarget(name: "BetterDockCoreTests", dependencies: ["BetterDockCore"]),
    ]
)
