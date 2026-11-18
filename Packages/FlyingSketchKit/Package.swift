// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FlyingSketchKit",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "SketchCore", targets: ["SketchCore"]),
        .library(name: "InkEngine", targets: ["InkEngine"]),
        .library(name: "CanvasUI", targets: ["CanvasUI"]),
    ],
    targets: [
        .target(name: "SketchCore"),
        .target(name: "InkEngine", dependencies: ["SketchCore"]),
        .target(
            name: "CanvasUI",
            dependencies: ["InkEngine", "SketchCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "SketchCoreTests", dependencies: ["SketchCore"]),
        .testTarget(name: "InkEngineTests", dependencies: ["InkEngine"]),
        .testTarget(name: "CanvasUITests", dependencies: ["CanvasUI"]),
    ],
    swiftLanguageModes: [.v6]
)
