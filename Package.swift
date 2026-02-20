// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimulatorStream",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", .upToNextMajor(from: "125.0.0"))
    ],
    targets: [
        .executableTarget(
            name: "SimulatorStream",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC")
            ],
            path: "Sources"
        )
    ]
)
