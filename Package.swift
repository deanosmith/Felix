// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Felix",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Felix", targets: ["Felix"])
    ],
    targets: [
        .executableTarget(name: "Felix")
    ]
)