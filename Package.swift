// swift-tools-version: 6.2
// SwiftPM manifest for the app itself, so `swift build` can produce Mochlet.app without xcodebuild
// (scripts/build-app.sh assembles the bundle). project.yml / XcodeGen remain the release path.
import PackageDescription

let package = Package(
    name: "Mochlet",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Mochlet", targets: ["Mochlet"]),
        .executable(name: "mochlet-hook", targets: ["mochlet-hook"]),
        .executable(name: "mochlet-mcp", targets: ["mochlet-mcp"]),
        .executable(name: "mochlet-cli", targets: ["mochlet-cli"]),
    ],
    dependencies: [
        .package(path: "Packages/SlimeKit"),
        .package(path: "Packages/MochletCore"),
    ],
    targets: [
        .executableTarget(
            name: "Mochlet",
            dependencies: [
                .product(name: "SlimeKit", package: "SlimeKit"),
                .product(name: "SlimeKitUI", package: "SlimeKit"),
                .product(name: "SlimeKitAudio", package: "SlimeKit"),
                .product(name: "MochletCore", package: "MochletCore"),
                .product(name: "MochletServices", package: "MochletCore"),
            ],
            path: "App",
            swiftSettings: [.unsafeFlags(["-Xfrontend", "-warn-long-expression-type-checking=400"])]
        ),
        // The hook relay: Foundation only, so it starts in a few milliseconds.
        .executableTarget(name: "mochlet-hook", path: "Helpers/mochlet-hook"),
        // stdio ⇄ local HTTP shim so `claude mcp add mochlet -- mochlet-mcp` reaches the running app.
        .executableTarget(name: "mochlet-mcp", path: "Helpers/mochlet-mcp"),
        // Reindex / find / lint / ingest the knowledge bundle without the app.
        .executableTarget(
            name: "mochlet-cli",
            dependencies: [
                .product(name: "MochletCore", package: "MochletCore"),
                .product(name: "MochletServices", package: "MochletCore"),
            ],
            path: "Helpers/mochlet-cli"
        ),
        .testTarget(name: "MochletAppTests", dependencies: ["Mochlet"], path: "Tests/App"),
    ],
    swiftLanguageModes: [.v6]
)
