// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DroidBridge",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "DroidBridgeCore"),
        .executableTarget(name: "DroidBridge", dependencies: ["DroidBridgeCore"]),
        .testTarget(name: "DroidBridgeCoreTests", dependencies: ["DroidBridgeCore"]),
    ]
)
