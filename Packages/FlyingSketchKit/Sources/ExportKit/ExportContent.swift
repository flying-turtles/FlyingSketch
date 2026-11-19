import Foundation
import SketchCore

public enum ExportScope: Hashable, Sendable {
    case all
    case selection(Set<ObjectID>)
}

public enum ExportError: Error, Equatable, Sendable, LocalizedError {
    case nothingToExport, tooLarge, encodingFailed

    public var errorDescription: String? {
        switch self {
        case .nothingToExport: "Nothing to export."
        case .tooLarge: "The drawing is too large to export."
        case .encodingFailed: "The file couldn't be created."
        }
    }
}

public struct ExportContent: Sendable {
    public let document: SketchDocument
    public let objects: [SceneObject]
    /// Content bounds including the margin (mm).
    public let bounds: Rect

    public static func make(_ doc: SketchDocument, scope: ExportScope, margin: Double = 5) throws(ExportError) -> ExportContent {
        let objects: [SceneObject]
        switch scope {
        case .all: objects = doc.objects
        case .selection(let ids): objects = doc.objects.filter { ids.contains($0.id) }
        }
        guard !objects.isEmpty, let raw = contentBounds(of: objects, in: doc) else { throw .nothingToExport }
        return ExportContent(document: doc, objects: objects, bounds: raw.insetBy(-margin))
    }
}
