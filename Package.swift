// swift-tools-version: 6.0
import PackageDescription

// No dependencies, on purpose: the whole tool is Foundation and Darwin.
let package = Package(
    name: "disk-auditor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dsa", targets: ["dsa"]),
        .executable(name: "DiskAuditor", targets: ["DiskAuditor"]),
    ],
    targets: [
        .target(name: "AuditorCore"),
        .executableTarget(name: "dsa", dependencies: ["AuditorCore"]),
        .executableTarget(name: "DiskAuditor", dependencies: ["AuditorCore"]),
        .testTarget(name: "AuditorCoreTests", dependencies: ["AuditorCore"]),
    ],
    swiftLanguageModes: [.v5]
)
