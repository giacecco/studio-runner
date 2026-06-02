// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StudioRunner",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "StudioRunner",
            path: "Sources/StudioRunner"
        )
    ]
)
