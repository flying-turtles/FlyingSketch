import Foundation

public struct SketchDocument: Equatable, Sendable {
    public var formatVersion: Int
    /// Z-order: first = bottom.
    public var objects: [SceneObject]
    public var viewport: Viewport
    public var assets: [String: Data]
    /// Embedded part definitions, keyed by `PartDefinition.key`.
    public var parts: [String: PartDefinition]
    /// Rigid groups (bodies); members are ids in `objects`.
    public var groups: [ObjectGroup]

    public init(formatVersion: Int = 4, objects: [SceneObject] = [],
                viewport: Viewport = Viewport(center: .zero, zoom: 1), assets: [String: Data] = [:],
                parts: [String: PartDefinition] = [:], groups: [ObjectGroup] = []) {
        self.formatVersion = formatVersion
        self.objects = objects
        self.viewport = viewport
        self.assets = assets
        self.parts = parts
        self.groups = groups
    }

    public static let empty = SketchDocument()
}

public enum DocumentError: Error, Equatable {
    case missingDocumentJSON
    case unsupportedVersion(Int)
    case corrupt(String)
}
