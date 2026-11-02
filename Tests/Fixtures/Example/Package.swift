// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "Example", platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "Example", targets: ["Example"])],
    targets: [.target(name: "Example"), .testTarget(name: "ExampleTests", dependencies: ["Example"])])
