// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PrettyAFM",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "PrettyAFM",
            path: "Sources/PrettyAFM",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PrettyAFMTests",
            dependencies: ["PrettyAFM"]
        ),
    ]
)
