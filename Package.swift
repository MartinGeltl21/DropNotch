// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NotchStash",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchStash",
            path: "Sources/NotchStash"
        )
    ]
)
