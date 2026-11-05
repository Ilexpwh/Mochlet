// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SlimeKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SlimeKit", targets: ["SlimeKit"]),
        .library(name: "SlimeKitUI", targets: ["SlimeKitUI"]),
        .library(name: "SlimeKitAudio", targets: ["SlimeKitAudio"]),
        .executable(name: "slimekit-tools", targets: ["slimekit-tools"]),
    ],
    targets: [
        // Pure character model: physics, face, states, click grammar, sound table. No UI frameworks.
        .target(name: "SlimeKit"),
        // SwiftUI Canvas renderer and the Emote Lab.
        .target(name: "SlimeKitUI", dependencies: ["SlimeKit"]),
        // AVAudioPlayer pool over the generated WAVs (user override folder, on-the-fly synthesis fallback).
        .target(name: "SlimeKitAudio", dependencies: ["SlimeKit"], resources: [.copy("Resources/sounds")]),
        // gen-sounds and render-filmstrip for motion review.
        .executableTarget(name: "slimekit-tools", dependencies: ["SlimeKit", "SlimeKitUI", "SlimeKitAudio"]),
        .testTarget(name: "SlimeKitTests", dependencies: ["SlimeKit", "SlimeKitUI", "SlimeKitAudio"]),
    ],
    swiftLanguageModes: [.v6]
)
