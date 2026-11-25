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
        .package(url: "https://github.com/Aemi-Studio/aemi.git", revision: "32f1d61e0ee2fe19af99c1c1a040f1fbdae91d4a"),
        .package(url: "https://github.com/g-cqd/AemiJSON.git", revision: "fdcf306b1ffbbd29161df787ae2ea97e56718d2c"),
        .package(
            url: "https://github.com/g-cqd/AemiProtobuf.git",
            revision: "dc010bdba44b44de354805ca5ba24d07dca3047d"
        ),
        .package(url: "https://github.com/g-cqd/analyzerkit.git", revision: "682eadd1e42d1c0dda956a3325d691030c59b084"),
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
