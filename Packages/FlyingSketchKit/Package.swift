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
        .library(name: "PhotoPartKit", targets: ["PhotoPartKit"]),
        .library(name: "CanvasUI", targets: ["CanvasUI"]),
        .library(name: "ExportKit", targets: ["ExportKit"]),
        .library(name: "MechKit", targets: ["MechKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/SwiftDraw", exact: "0.30.0"),
    ],
    targets: [
        .target(name: "SketchCore"),
        .target(name: "NetKit", dependencies: ["SketchCore"]),
        .target(name: "PartsKit", dependencies: ["SketchCore"]),
        .target(name: "InkEngine", dependencies: ["SketchCore"]),
        .target(name: "PhotoPartKit", dependencies: ["SketchCore", "PartsKit"]),
        .target(
            name: "CanvasUI",
            dependencies: ["InkEngine", "SketchCore", "NetKit", "PartsKit", "PhotoPartKit", "MechKit", .product(name: "SwiftDraw", package: "SwiftDraw")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .target(
            name: "ExportKit",
            dependencies: ["SketchCore", "InkEngine", "NetKit", "PartsKit", .product(name: "SwiftDraw", package: "SwiftDraw")]
        ),
        .target(name: "MechKit", dependencies: ["SketchCore"]),
        .testTarget(name: "SketchCoreTests", dependencies: ["SketchCore"]),
        .testTarget(name: "NetKitTests", dependencies: ["NetKit", "SketchCore"]),
        .testTarget(
            name: "PartsKitTests",
            dependencies: ["PartsKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "InkEngineTests", dependencies: ["InkEngine"]),
        .testTarget(name: "PhotoPartKitTests", dependencies: ["PhotoPartKit", "SketchCore", "PartsKit"]),
        .testTarget(name: "ExportKitTests", dependencies: ["ExportKit", "SketchCore", "NetKit"]),
        .testTarget(name: "MechKitTests", dependencies: ["MechKit", "SketchCore"]),
        .testTarget(name: "CanvasUITests", dependencies: ["CanvasUI", "PartsKit", "PhotoPartKit"]),
    ],
    swiftLanguageModes: [.v6]
)
