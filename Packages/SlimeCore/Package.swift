// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SlimeCore", platforms: [.macOS(.v15)],
    products: [.library(name: "SlimeCore", targets: ["SlimeCore"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"), .package(url: "https://github.com/openid/AppAuth-iOS.git", exact: "3.0.0"), .package(url: "https://github.com/jpsim/Yams.git", exact: "6.1.0")],
    targets: [.target(name: "SlimeCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift"), .product(name: "AppAuth", package: "AppAuth-iOS"), .product(name: "Yams", package: "Yams")], resources: [.copy("Resources/mochlet-pi-guard.ts")]),
              .testTarget(name: "SlimeCoreTests", dependencies: ["SlimeCore"], resources: [.copy("Fixtures")])]
)
