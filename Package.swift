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
    platforms: [.macOS(.v15)],
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
        .package(url: "https://github.com/g-cqd/analyzerkit.git", revision: "59ac36d3c267e997a24f47e62654e069bb1a7395"),
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
                .product(name: "AnalyzerCLI", package: "analyzerkit"),
                .product(name: "ReportSupport", package: "analyzerkit"),
            ],
            swiftSettings: strict
        ),
        .testTarget(
            name: "LitmusCoreTests",
            dependencies: [
                "LitmusCore", .product(name: "ProjectModel", package: "analyzerkit"),
                .product(name: "SourceCorpus", package: "analyzerkit"), .product(name: "AemiRuntime", package: "aemi"),
            ],
            swiftSettings: strict
        ),
    ],
    swiftLanguageModes: [.v6]
)
