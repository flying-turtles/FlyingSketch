import SketchCore

/// Whole-stroke eraser. Objects touched during a gesture are reported via `onHiddenChange` (renderer feedback)
/// and removed from the document in ONE `.remove` edit "Erase" at `end()`.
final class EraserController {
    private let model: DocumentModel
    /// Objects whose bounds intersect the rect. Defaults to a document scan; the canvas supplies the spatial index.
    private let candidates: (Rect) -> [SceneObject]

    var onHiddenChange: ((Set<ObjectID>) -> Void)?

    private var radius = 0.0
    private var last: Vec2?
    private(set) var hit: Set<ObjectID> = []
    private(set) var isActive = false

    init(model: DocumentModel, candidates: ((Rect) -> [SceneObject])? = nil) {
        self.model = model
        self.candidates = candidates ?? { [unowned model] rect in
            model.document.objects.filter { bounds(of: $0, in: model.document).intersects(rect) }
        }
    }

    /// World radius (mm) that is a constant `points` on screen at `zoom`.
    static func worldRadius(screenPoints points: Double = 8, zoom: Double) -> Double {
        points / (Viewport.pointsPerMillimetre * zoom)
    }

    func begin(at p: Vec2, radius: Double) {
        self.radius = radius
        hit = []
        isActive = true
        last = p
        sweep(from: p, to: p)
    }

    func move(to p: Vec2) {
        guard isActive, let from = last else { return }
        sweep(from: from, to: p)
        last = p
    }

    func end() {
        guard isActive else { return }
        let existing = Set(model.document.objects.map(\.id))
        let ids = hit.intersection(existing) // an undo mid-gesture may have removed some
        reset()
        guard !ids.isEmpty else { return }
        model.perform(.remove(ids), actionName: "Erase")
    }

    /// Nothing removed; hidden objects reappear.
    func cancel() {
        guard isActive else { return }
        reset()
    }

    private func reset() {
        isActive = false
        last = nil
        let hadHits = !hit.isEmpty
        hit = []
        if hadHits { onHiddenChange?([]) }
    }

    /// Tests the swept capsule. Samples are <= radius/2 apart; the tolerance is widened to the worst-case gap
    /// distance, so every object within `radius` of the segment is hit (over-reach <= ~3 %).
    private func sweep(from a: Vec2, to b: Vec2) {
        let box = Rect.bounding([a, b])!.insetBy(-radius)
        let pending = candidates(box).filter { !hit.contains($0.id) }
        guard !pending.isEmpty else { return }
        let doc = model.document
        let step = max(radius / 2, 1e-6)
        let tolerance = (radius * radius + step * step / 4).squareRoot()
        let n = max(Int((a.distance(to: b) / step).rounded(.up)), 1)
        var newHits: Set<ObjectID> = []
        for object in pending {
            for i in 0...n {
                let p = a + (b - a) * (Double(i) / Double(n))
                if hitTest(object, point: p, tolerance: tolerance, in: doc) {
                    newHits.insert(object.id)
                    break
                }
            }
        }
        guard !newHits.isEmpty else { return }
        hit.formUnion(newHits)
        onHiddenChange?(hit)
    }
}
