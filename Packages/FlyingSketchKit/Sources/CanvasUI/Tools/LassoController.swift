import UIKit
import SketchCore

/// Collects a freehand polygon (world mm) and resolves it to the objects it encloses.
final class LassoController {
    private let model: DocumentModel
    /// Objects whose bounds intersect the rect. Defaults to a document scan; the canvas supplies the spatial index.
    private let candidates: (Rect) -> [SceneObject]
    private(set) var points: [Vec2] = []

    init(model: DocumentModel, candidates: ((Rect) -> [SceneObject])? = nil) {
        self.model = model
        self.candidates = candidates ?? { [unowned model] rect in
            model.document.objects.filter { bounds(of: $0, in: model.document).intersects(rect) }
        }
    }

    func begin(at p: Vec2) { points = [p] }

    func move(to p: Vec2) {
        guard !points.isEmpty else { return }
        points.append(p)
    }

    func end() -> Set<ObjectID> {
        defer { points = [] }
        guard let box = Rect.bounding(points) else { return [] }
        let doc = model.document
        return Set(candidates(box).filter { lassoContains(points, object: $0, in: doc) }.map(\.id))
    }

    func cancel() { points = [] }
}

/// Dashed lasso path in view space.
final class LassoPathLayer {
    let layer = CAShapeLayer()

    init() {
        layer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        layer.strokeColor = UIColor.systemBlue.cgColor
        layer.lineWidth = 1.5
        layer.lineDashPattern = [6, 4]
        layer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer.isHidden = true
    }

    func update(_ points: [Vec2], viewport: Viewport, viewSize: Vec2) {
        let path = CGMutablePath()
        for (i, p) in points.enumerated() {
            let v = viewport.worldToView(p, viewSize: viewSize)
            i == 0 ? path.move(to: CGPoint(x: v.x, y: v.y)) : path.addLine(to: CGPoint(x: v.x, y: v.y))
        }
        layer.path = path
        layer.isHidden = false
    }

    func clear() {
        layer.path = nil
        layer.isHidden = true
    }
}
