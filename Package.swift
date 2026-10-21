// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hawkeye2",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Hawkeye2", targets: ["Hawkeye2"])],
    targets: [
        .target(name: "HawkeyeCore"),
        .executableTarget(name: "Hawkeye2", dependencies: ["HawkeyeCore"], resources: [.process("Resources")]),
        .testTarget(name: "HawkeyeCoreTests", dependencies: ["HawkeyeCore"]),
        .testTarget(name: "HawkeyeAppTests", dependencies: ["Hawkeye2", "HawkeyeCore"])
    ],
    swiftLanguageModes: [.v5]
)
