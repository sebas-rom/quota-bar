// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "QuotaBar", targets: ["QuotaBar"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "QuotaBarKit",
            path: "Sources/QuotaBarKit"
        ),
        .executableTarget(
            name: "QuotaBar",
            dependencies: [
                "QuotaBarKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/QuotaBar",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "QuotaBarKitTests",
            dependencies: ["QuotaBarKit"],
            path: "Tests/QuotaBarKitTests"
        ),
    ]
)
