// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WalletKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "WalletKit", targets: ["WalletKit"])],
    targets: [
        .target(name: "WalletKit"),
        .testTarget(name: "WalletKitTests", dependencies: ["WalletKit"]),
    ]
)
