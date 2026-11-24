// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GeminiQuotaBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "GeminiQuotaBar", targets: ["GeminiQuotaBar"])
    ],
    targets: [
        .executableTarget(
            name: "GeminiQuotaBar",
            path: "Sources/GeminiQuotaBar",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        )
    ]
)
