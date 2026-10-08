// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KShot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "KShot",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/KShot",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("UniformTypeIdentifiers"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "KShotTests", dependencies: ["KShot"], path: "Tests/KShotTests")
    ]
)
