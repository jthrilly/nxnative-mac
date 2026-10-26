// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NXNativeConverter",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "ConverterCore"),
        .executableTarget(name: "NXNativeConverter", dependencies: ["ConverterCore"]),
        .testTarget(name: "ConverterCoreTests", dependencies: ["ConverterCore"]),
    ]
)
