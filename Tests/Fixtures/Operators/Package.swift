// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Operators",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "Operators", targets: ["Operators"])],
    targets: [.target(name: "Operators"), .testTarget(name: "OperatorsTests", dependencies: ["Operators"])]
)
