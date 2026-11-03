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
        .package(url: "https://github.com/Aemi-Studio/aemi.git", revision: "7a8fe8ba6ec8d641cffa7e7a7a3152fee7e51619"),
        .package(url: "https://github.com/g-cqd/AemiJSON.git", revision: "3cd5a6aa8e0fd1e03573ee1df1e7fe7ffe488e08"),
        .package(
            url: "https://github.com/g-cqd/AemiProtobuf.git",
            revision: "4b8a245d3807ccc85f4b8e9128893eb53da2b3a1"
        ),
        .package(url: "https://github.com/g-cqd/analyzerkit.git", revision: "b3087f3212f14d0fed3a881a1af32e262e6bbf5a"),
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
