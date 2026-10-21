// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Loupe",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "JsonCore", targets: ["JsonCore"]),
        .executable(name: "Loupe", targets: ["Loupe"]),
        .executable(name: "loupe-bench", targets: ["loupe-bench"]),
    ],
    targets: [
        // UI-free engine: buffer, lazy scanner, tree, search.
        .target(name: "JsonCore"),
        // AppKit viewer.
        .executableTarget(name: "Loupe", dependencies: ["JsonCore"]),
        // Synthetic data generator + timing harness.
        .executableTarget(name: "loupe-bench", dependencies: ["JsonCore"]),
        .testTarget(name: "JsonCoreTests", dependencies: ["JsonCore"]),
    ],
    // The UI uses GCD hand-offs to the main queue; keep Swift 5 checking.
    swiftLanguageModes: [.v5]
)
