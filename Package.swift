// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "QuotaBar",
            path: "Sources/QuotaBar"
        )
    ]
)
