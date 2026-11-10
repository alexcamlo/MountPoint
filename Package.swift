// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MountPoint",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure model + rule/status logic, no I/O: the test surface.
        .target(name: "MountPointCore"),
        .executableTarget(name: "MountPoint", dependencies: ["MountPointCore"],
                          swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "MountPointCoreTests", dependencies: ["MountPointCore"]),
    ]
)
