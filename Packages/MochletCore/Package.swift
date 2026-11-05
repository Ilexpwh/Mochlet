// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MochletCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MochletCore", targets: ["MochletCore"]),
        .library(name: "MochletServices", targets: ["MochletServices"]),
    ],
    targets: [
        // Pure app logic: notch FSM and geometry, hooks, sessions, projects, knowledge, signals, meetings.
        .target(name: "MochletCore"),
        // Headless Apple-framework services (no UI).
        .target(name: "MochletServices", dependencies: ["MochletCore"]),
        .testTarget(name: "MochletCoreTests", dependencies: ["MochletCore"]),
    ],
    swiftLanguageModes: [.v6]
)
