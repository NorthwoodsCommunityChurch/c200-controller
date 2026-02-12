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
    targets: [
        .executableTarget(
            name: "C200Controller",
            path: "Sources"
        )
    ]
)
