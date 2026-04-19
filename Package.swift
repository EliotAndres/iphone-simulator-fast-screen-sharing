// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimulatorStream",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "SimulatorStream",
            path: "Sources"
        )
    ]
)
