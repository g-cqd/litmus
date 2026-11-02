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
        .package(url: "https://github.com/Aemi-Studio/aemi.git", revision: "921fd8d037855844e188b1b9e18a41773c7b9508"),
        .package(url: "https://github.com/g-cqd/AemiJSON.git", revision: "63af9e16552d3d53fed6a991a6953c6377448c38"),
        .package(
            url: "https://github.com/g-cqd/AemiProtobuf.git",
            revision: "24a46dc7a4b76fbc759e4f24a6395fa7cdd93b59"
        ),
        .package(url: "https://github.com/g-cqd/analyzerkit.git", revision: "fb3f5d67c89ba217a985c569f92e8ad3afe1eabd"),
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
                .product(name: "AemiJSON", package: "AemiJSON"),
                .product(name: "AemiProtobufCore", package: "AemiProtobuf"),
                .product(name: "SourceCorpus", package: "analyzerkit"),
                .product(name: "ProjectModel", package: "analyzerkit"),
                .product(name: "Suppression", package: "analyzerkit"),
                .product(name: "ReportSupport", package: "analyzerkit"),
                .product(name: "AnalyzerConfiguration", package: "analyzerkit"),
                .product(name: "IndexStoreSupport", package: "analyzerkit"),
            ],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "litmus",
            dependencies: [
                "LitmusCore", .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "AnalyzerCLI", package: "analyzerkit"),
            ],
            swiftSettings: strict
        ),
        .testTarget(name: "LitmusCoreTests", dependencies: ["LitmusCore"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
