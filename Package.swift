// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notchload",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NotchloadCore", targets: ["NotchloadCore"]),
        .executable(name: "Notchload", targets: ["Notchload"]),
    ],
    targets: [
        // UI-free sampler: CPU, memory, GPU, network, processes.
        .target(name: "NotchloadCore", path: "Sources/NotchloadCore"),
        // The notch panel.
        .executableTarget(name: "Notchload", dependencies: ["NotchloadCore"], path: "Sources/Notchload"),
        .testTarget(name: "NotchloadCoreTests", dependencies: ["NotchloadCore"], path: "Tests/NotchloadCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
