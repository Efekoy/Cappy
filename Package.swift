// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cappy",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Cappy", targets: ["Cappy"])],
    targets: [
        .executableTarget(
            name: "Cappy",
            path: "Sources/Cappy",
            linkerSettings: [.linkedFramework("InputMethodKit")]
        ),
        .testTarget(name: "CappyTests", dependencies: ["Cappy"], path: "Tests/CappyTests")
    ],
    swiftLanguageModes: [.v5]
)
