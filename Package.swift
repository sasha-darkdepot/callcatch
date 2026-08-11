// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CallCatch",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "CallCatch",
            path: "Sources/CallCatch",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CallCatchTests",
            dependencies: ["CallCatch"],
            path: "Tests/CallCatchTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
