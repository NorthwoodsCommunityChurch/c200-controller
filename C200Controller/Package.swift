// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "C200Controller",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "C200Controller", targets: ["C200Controller"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "C200Controller",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources"
        )
    ]
)
