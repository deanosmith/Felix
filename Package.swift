// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Orth",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Orth", targets: ["MacAutocorrect"])
    ],
    targets: [
        .executableTarget(name: "MacAutocorrect")
    ]
)