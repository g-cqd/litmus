// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Sibling",
    products: [.library(name: "Sibling", targets: ["Sibling"])],
    targets: [.target(name: "Sibling")]
)
