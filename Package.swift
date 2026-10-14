// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TokenBarCore"),
        .executableTarget(name: "TokenBar", dependencies: ["TokenBarCore"]),
        .testTarget(
            name: "TokenBarCoreTests",
            dependencies: ["TokenBarCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
