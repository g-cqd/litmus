// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Library",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "Library", targets: ["Library"])],
    dependencies: [.package(path: "../Sibling")],
    targets: [
        .target(name: "Library", dependencies: ["Sibling"]),
        .testTarget(name: "LibraryTests", dependencies: ["Library"]),
    ]
)
