// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MountPoint",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure model + rule/status logic, no I/O: the test surface.
        .target(name: "MountPointCore"),
        .executableTarget(name: "MountPoint", dependencies: ["MountPointCore"]),
        .testTarget(name: "MountPointCoreTests", dependencies: ["MountPointCore"]),
    ],
    swiftLanguageModes: [.v5]
)
