// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FareKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FareKit", targets: ["FareKit"])],
    targets: [
        .target(name: "FareKit"),
        .testTarget(name: "FareKitTests", dependencies: ["FareKit"]),
    ]
)
