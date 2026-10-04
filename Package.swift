// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KShot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "KShot",
            path: "Sources/KShot",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        )
    ]
)
