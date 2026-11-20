import Foundation
import SketchCore

/// Drags the selection's rotate handle and commits one "Rotate" edit. The angle is the signed angle (clockwise
/// positive) from the grab point to the touch, both seen from the pivot.
final class RotationController {
    private let model: DocumentModel
    private var ids: Set<ObjectID> = []
    private var originals: [ObjectID: SceneObject] = [:]
    private var pivot = Vec2.zero
    private var grab = Vec2.zero
    private var active = false
    /// Farthest the touch got from the grab point; a drag that comes back is still a drag, not a tap.
    private var travel = 0.0
    private(set) var angle = 0.0

    /// Releases closer than this (mm) to the grab point are taps.
    var minDistance = 0.0
    /// Snap the angle to 15° steps.
    var snapsAngle = false
    var isActive: Bool { active }

    init(model: DocumentModel) { self.model = model }

    /// Starts rotating `ids` about `pivot`, grabbed at world `world`.
    func begin(ids: Set<ObjectID>, pivot: Vec2, grabAt world: Vec2) {
        cancel()
        self.ids = ids
        originals = Dictionary(model.document.objects.filter { ids.contains($0.id) }.map { ($0.id, $0) },
                               uniquingKeysWith: { first, _ in first })
        self.pivot = pivot
        grab = world
        travel = 0
        angle = 0
        active = true
    }

    /// Replacement objects for the angle at `world`; `[]` when inactive (an angle of 0 yields no changed objects).
    func move(to world: Vec2) -> [SceneObject] {
        guard active else { return [] }
        travel = max(travel, world.distance(to: grab))
        angle = angle(at: world)
        return rotateObjects(ids, by: angle, around: pivot, in: model.document)
    }

    /// Commits the edit for a release at `world`; true when one was made. Always ends the session.
    @discardableResult
    func end(at world: Vec2) -> Bool {
        guard active else { return false }
        let isTap = max(travel, world.distance(to: grab)) < minDistance
        let a = angle(at: world)
        let ids = ids
        let pivot = pivot
        cancel()
        guard !isTap, a != 0 else { return false }
        let edits = rotateObjects(ids, by: a, around: pivot, in: model.document)
        guard !edits.isEmpty else { return false }
        model.perform(.replace(edits), actionName: "Rotate")
        return true
    }

    /// A document change from outside (e.g. toolbar undo) that alters or removes a dragged object cancels the
    /// drag. Returns whether it was cancelled.
    @discardableResult
    func documentDidChange(_ doc: SketchDocument) -> Bool {
        guard active else { return false }
        let current = Dictionary(doc.objects.filter { ids.contains($0.id) }.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
        guard current != originals else { return false }
        cancel()
        return true
    }

    func cancel() {
        active = false
        ids = []
        originals = [:]
        angle = 0
        travel = 0
    }

    private func angle(at world: Vec2) -> Double {
        let a = grab - pivot, b = world - pivot
        guard a.length > 0, b.length > 0 else { return 0 }
        let raw = atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y)
        guard snapsAngle else { return raw }
        let step = Double.pi / 12
        if ids.count == 1, let o = originals[ids.first!], let stored = Self.storedRotation(of: o) {
            // A lone object that stores a rotation snaps its resulting rotation, so a freely rotated one can be made straight.
            return ((stored + raw) / step).rounded() * step - stored
        }
        return (raw / step).rounded() * step
    }

    private static func storedRotation(of o: SceneObject) -> Double? {
        switch o {
        case .part(let p): return p.rotation
        case .shape(let s): return (s.kind == .rectangle || s.kind == .ellipse) ? s.rotation : nil
        case .text(let t): return t.rotation
        case .image(let i): return i.rotation
        case .ink, .wire, .joint: return nil
        }
    }
}
