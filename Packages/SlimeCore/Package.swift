// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SlimeCore", platforms: [.macOS(.v15)],
    products: [.library(name: "SlimeCore", targets: ["SlimeCore"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")],
    targets: [.target(name: "SlimeCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
              .testTarget(name: "SlimeCoreTests", dependencies: ["SlimeCore"])]
)
