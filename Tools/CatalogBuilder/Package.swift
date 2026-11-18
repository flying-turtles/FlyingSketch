// swift-tools-version: 6.2
import PackageDescription

// macOS-only tool that converts Fritzing parts into the bundled catalog (App/Catalog).
let package = Package(
    name: "CatalogBuilder",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../../Packages/FlyingSketchKit")],
    targets: [
        .executableTarget(
            name: "catalog-builder",
            dependencies: [.product(name: "PartsKit", package: "FlyingSketchKit")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
