// swift-tools-version: 6.4
import PackageDescription

let strict: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .strictMemorySafety(),
]
let package = Package(
    name: "litmus",
    platforms: [.macOS("15.6")],
    products: [
        .library(name: "LitmusCore", targets: ["LitmusCore"]), .executable(name: "litmus", targets: ["litmus"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/Aemi-Studio/aemi.git", revision: "9f8d1a3eafed0ad23919b9c68d33606632ce0659"),
        .package(url: "https://github.com/g-cqd/AemiJSON.git", revision: "fb4478051725c95614e76b15ac11e9a5c6a502a3"),
        .package(
            url: "https://github.com/g-cqd/AemiProtobuf.git",
            revision: "d8985c489aa19e285214d032ef98855b6b95f30b"
        ),
        .package(
            url: "https://github.com/g-cqd/AemiMCP.git",
            revision: "f3e29cc0ba459bf3e12fd92375b331b1cb92f4ad",
            traits: []
        ),
        .package(url: "https://github.com/g-cqd/analyzerkit.git", revision: "a5464a5063aa98725faabf8d7f4058e7fb3b4f85"),
    ],
    targets: [
        .target(
            name: "LitmusCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
                .product(name: "AemiKernel", package: "aemi"),
                .product(name: "AemiFileSystem", package: "aemi"),
                .product(name: "AemiIO", package: "aemi"),
                .product(name: "AemiRuntime", package: "aemi"),
                .product(name: "AemiMetrics", package: "aemi"),
                .product(name: "AemiDigest", package: "aemi"),
                .product(name: "AemiJSON", package: "AemiJSON"),
                .product(name: "AemiMCP", package: "AemiMCP"),
                .product(name: "AemiProtobufCore", package: "AemiProtobuf"),
                .product(name: "AemiProtobuf", package: "AemiProtobuf"),
                .product(name: "SourceCorpus", package: "analyzerkit"),
                .product(name: "ProjectModel", package: "analyzerkit"),
                .product(name: "Suppression", package: "analyzerkit"),
                .product(name: "ReportSupport", package: "analyzerkit"),
                .product(name: "AnalyzerConfiguration", package: "analyzerkit"),
                .product(name: "IndexStoreSupport", package: "analyzerkit"),
                .product(name: "SwiftIfConfig", package: "swift-syntax"),
            ],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "litmus",
            dependencies: [
                "LitmusCore", .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "AemiMCP", package: "AemiMCP"), .product(name: "AemiJSON", package: "AemiJSON"),
                .product(name: "AnalyzerCLI", package: "analyzerkit"),
                .product(name: "ReportSupport", package: "analyzerkit"),
            ],
            swiftSettings: strict
        ),
        .testTarget(
            name: "LitmusCoreTests",
            dependencies: [
                "LitmusCore", .product(name: "ProjectModel", package: "analyzerkit"),
                .product(name: "AemiMCP", package: "AemiMCP"), .product(name: "AemiJSON", package: "AemiJSON"),
                .product(name: "SourceCorpus", package: "analyzerkit"),
                .product(name: "ReportSupport", package: "analyzerkit"), .product(name: "AemiRuntime", package: "aemi"),
            ],
            swiftSettings: strict
        ),
    ],
    swiftLanguageModes: [.v6]
)
