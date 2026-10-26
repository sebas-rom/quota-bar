// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "QuotaBar", targets: ["QuotaBar"])
    ],
    targets: [
        .target(
            name: "QuotaBarKit",
            path: "Sources/QuotaBarKit"
        ),
        .executableTarget(
            name: "QuotaBar",
            dependencies: ["QuotaBarKit"],
            path: "Sources/QuotaBar"
        ),
        .testTarget(
            name: "QuotaBarKitTests",
            dependencies: ["QuotaBarKit"],
            path: "Tests/QuotaBarKitTests"
        ),
    ]
)
