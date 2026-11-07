// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "og",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "GoEditorCore",
            targets: ["GoEditorCore"]
        ),
        .executable(
            name: "og",
            targets: ["GoEditorApp"]
        )
    ],
    dependencies: [
        // Rope data structure for O(log N) text manipulation
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        // Incremental AST parsing for 0ms local syntax highlighting & FIM context extraction
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter.git", from: "0.8.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go.git", from: "0.21.0")
    ],
    targets: [
        .target(
            name: "GoEditorCore",
            dependencies: [
                .product(name: "_RopeModule", package: "swift-collections"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "GoEditorApp",
            dependencies: ["GoEditorCore"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "GoEditorCoreTests",
            dependencies: ["GoEditorCore"]
        )
    ]
)
