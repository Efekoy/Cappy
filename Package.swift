// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoCaps",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AutoCaps", targets: ["AutoCaps"])],
    targets: [
        .executableTarget(name: "AutoCaps", path: "Sources/AutoCaps"),
        .testTarget(name: "AutoCapsTests", dependencies: ["AutoCaps"], path: "Tests/AutoCapsTests")
    ],
    swiftLanguageModes: [.v5]
)
