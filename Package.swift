// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Boardwalk",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Boardwalk", targets: ["Boardwalk"]),
    ],
    targets: [
        // No UI: the per-desktop dock model, storage, reading Apple's Dock, window layouts.
        .target(name: "BoardwalkCore"),
        // The menu bar app: the docks, following desktops, arranging windows, hiding Apple's Dock.
        .executableTarget(name: "Boardwalk", dependencies: ["BoardwalkCore"]),
        .testTarget(name: "BoardwalkCoreTests", dependencies: ["BoardwalkCore"]),
    ]
)
