// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FlyingSketchKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "SketchCore", targets: ["SketchCore"]),
        .library(name: "NetKit", targets: ["NetKit"]),
        .library(name: "PartsKit", targets: ["PartsKit"]),
        .library(name: "InkEngine", targets: ["InkEngine"]),
        .library(name: "CanvasUI", targets: ["CanvasUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/SwiftDraw", exact: "0.30.0"),
    ],
    targets: [
        .target(name: "SketchCore"),
        .target(name: "NetKit", dependencies: ["SketchCore"]),
        .target(name: "PartsKit", dependencies: ["SketchCore"]),
        .target(name: "InkEngine", dependencies: ["SketchCore"]),
        .target(
            name: "CanvasUI",
            dependencies: ["InkEngine", "SketchCore", "PartsKit", .product(name: "SwiftDraw", package: "SwiftDraw")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "SketchCoreTests", dependencies: ["SketchCore"]),
        .testTarget(name: "NetKitTests", dependencies: ["NetKit", "SketchCore"]),
        .testTarget(
            name: "PartsKitTests",
            dependencies: ["PartsKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "InkEngineTests", dependencies: ["InkEngine"]),
        .testTarget(name: "CanvasUITests", dependencies: ["CanvasUI", "PartsKit"]),
    ],
    swiftLanguageModes: [.v6]
)
