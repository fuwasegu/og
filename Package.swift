// swift-tools-version: 6.0
import PackageDescription

let strict: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency")
]

let package = Package(
    name: "og",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OgCore", targets: ["OgCore"]),
        .executable(name: "og", targets: ["OgApp"])
    ],
    dependencies: [
        // Native AppKit xterm emulator (no WebView). Pinned: tools-version 6.0 keeps CI on Swift 6.1 working.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")
    ],
    targets: [
        .target(
            name: "OgCore",
            swiftSettings: strict
        ),
        .executableTarget(
            name: "OgApp",
            dependencies: [
                "OgCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            swiftSettings: strict
        ),
        .testTarget(
            name: "OgCoreTests",
            dependencies: ["OgCore"]
        )
    ]
)
