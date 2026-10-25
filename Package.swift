// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DropNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DropNotch",
            path: "Sources/DropNotch"
        ),
        .testTarget(
            name: "DropNotchTests",
            dependencies: ["DropNotch"],
            path: "Tests/DropNotchTests"
        ),
    ]
)
