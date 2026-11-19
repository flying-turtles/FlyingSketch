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
        guard !objects.isEmpty else { throw .nothingToExport }
        // Text uses CoreText-measured frames; SketchCore's estimate is too narrow for real Helvetica.
        var raw = contentBounds(of: objects.filter { if case .text = $0 { false } else { true } }, in: doc)
        for case .text(let t) in objects {
            let size = TextLayout.measuredSize(t)
            let corners = [Vec2.zero, Vec2(x: size.x, y: 0), size, Vec2(x: 0, y: size.y)]
                .map { t.position + $0.rotated(by: t.rotation) }
            let r = Rect.bounding(corners)!
            raw = raw.map { $0.union(r) } ?? r
        }
        guard let raw else { throw .nothingToExport }
        return ExportContent(document: doc, objects: objects, bounds: raw.insetBy(-margin))
    }
}
