// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Nightstand",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Nightstand", path: "Sources/Nightstand"),
        .testTarget(name: "NightstandTests", dependencies: ["Nightstand"], path: "Tests/NightstandTests"),
    ]
)
