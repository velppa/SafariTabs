// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SafariTabs",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SafariTabs",
            path: "Sources/SafariTabs"
        )
    ]
)
