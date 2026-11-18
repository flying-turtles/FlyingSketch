import Foundation
import SketchCore

/// Drag-to-draw shapes. One `.insert` "Add Shape" at `end()`; nothing is committed while dragging.
final class ShapeController {
    /// Snap grid in mm; matches the 10 mm minor grid.
    static let gridSize = GridLayer.minorSpacing
    private static let angleStep = Double.pi / 12

    private let model: DocumentModel

    var strokeColor: RGBAColor = .black
    /// Millimetres.
    var lineWidth = 0.5
    var snapsToGrid = false
    /// Drags with start-to-end distance not above this (mm) are discarded.
    var minimumLength = 0.0

    /// Shape being dragged (live preview source); nil when idle.
    private(set) var current: ShapeObject?

    init(model: DocumentModel) { self.model = model }

    func begin(at p: Vec2, kind: ShapeKind) {
        let start = snapped(p)
        current = ShapeObject(kind: kind, start: start, end: start, strokeColor: strokeColor,
                              fillColor: nil, lineWidth: lineWidth)
    }

    func move(to p: Vec2, constrain: Bool) {
        guard var shape = current else { return }
        let raw = snapped(p)
        shape.end = constrain ? Self.constrained(raw, from: shape.start, kind: shape.kind) : raw
        current = shape
    }

    /// Commits the shape. Returns whether an edit was performed.
    @discardableResult
    func end() -> Bool {
        defer { current = nil }
        guard let shape = current, shape.end.distance(to: shape.start) > max(minimumLength, 0),
              shape.end != shape.start else { return false }
        model.perform(.insert([.shape(shape)], at: nil), actionName: "Add Shape")
        return true
    }

    func cancel() { current = nil }

    private func snapped(_ p: Vec2) -> Vec2 { snapsToGrid ? snap(p, grid: Self.gridSize) : p }

    /// Lines/arrows: angle to 15 degree steps, length kept. Rectangle/ellipse: square/circle on the larger extent.
    static func constrained(_ end: Vec2, from start: Vec2, kind: ShapeKind) -> Vec2 {
        let d = end - start
        switch kind {
        case .line, .arrow:
            let angle = (atan2(d.y, d.x) / angleStep).rounded() * angleStep
            return start + Vec2(x: cos(angle), y: sin(angle)) * d.length
        case .rectangle, .ellipse:
            let extent = max(abs(d.x), abs(d.y))
            return start + Vec2(x: d.x < 0 ? -extent : extent, y: d.y < 0 ? -extent : extent)
        }
    }
}
