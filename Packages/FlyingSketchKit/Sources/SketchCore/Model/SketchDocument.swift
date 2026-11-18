import Foundation

public struct SketchDocument: Equatable, Sendable {
    public var formatVersion: Int
    /// Z-order: first = bottom.
    public var objects: [SceneObject]
    public var viewport: Viewport
    public var assets: [String: Data]

    public init(formatVersion: Int = 1, objects: [SceneObject] = [],
                viewport: Viewport = Viewport(center: .zero, zoom: 1), assets: [String: Data] = [:]) {
        self.formatVersion = formatVersion
        self.objects = objects
        self.viewport = viewport
        self.assets = assets
    }

    public static let empty = SketchDocument()
}

public enum DocumentError: Error, Equatable {
    case missingDocumentJSON
    case unsupportedVersion(Int)
    case corrupt(String)
}
