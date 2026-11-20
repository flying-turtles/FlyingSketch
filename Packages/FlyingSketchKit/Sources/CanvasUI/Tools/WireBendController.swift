import SketchCore

/// A handle on a selected wire: an existing bend, or the insert point at a segment's midpoint.
enum WireHandle: Equatable {
    case bend(wire: ObjectID, index: Int)
    /// Segment `segment` runs `polyline[segment]` -> `polyline[segment + 1]`.
    case insert(wire: ObjectID, segment: Int)

    var wire: ObjectID {
        switch self {
        case .bend(let id, _), .insert(let id, _): id
        }
    }
}

/// Drags one wire bend handle and commits one edit: drag a bend "Move Wire Bend", tap a bend "Remove Wire Bend",
/// drag an insert handle "Add Wire Bend". A tap on an insert handle edits nothing. Wire ends never change.
final class WireBendController {
    private let model: DocumentModel
    private var original: Wire?
    private var handle: WireHandle?
    private var start = Vec2.zero
    private var grab = Vec2.zero

    /// Releases closer than this (mm) to the grab point are taps.
    var minDistance = 0.0
    var snapsToGrid = false
    var isActive: Bool { handle != nil }

    init(model: DocumentModel) { self.model = model }

    /// Starts a drag of `handle`, grabbed at world `world`. False (inactive) when the wire, bend or segment is missing.
    @discardableResult
    func begin(_ handle: WireHandle, grabAt world: Vec2) -> Bool {
        cancel()
        guard let w = Self.wire(handle.wire, in: model.document) else { return false }
        switch handle {
        case .bend(_, let i):
            guard w.bends.indices.contains(i) else { return false }
            start = w.bends[i]
        case .insert(_, let s):
            let mids = w.segmentMidpoints
            guard mids.indices.contains(s) else { return false }
            start = mids[s]
        }
        original = w
        self.handle = handle
        grab = world
        return true
    }

    /// Wire with the handle's point following `world`; nil when inactive.
    func move(to world: Vec2) -> Wire? {
        guard let original, let handle else { return nil }
        return Self.edited(original, handle, to: target(world))
    }

    /// Commits the edit for a release at `world`; true when one was made. Always ends the session.
    @discardableResult
    func end(at world: Vec2) -> Bool {
        guard let original, let handle else { return false }
        let isTap = world.distance(to: grab) < minDistance
        let point = target(world)
        cancel()
        guard Self.wire(original.id, in: model.document) == original else { return false } // changed underneath
        if isTap {
            guard case .bend(_, let i) = handle else { return false }
            model.perform(.replace([.wire(original.removingBend(i))]), actionName: "Remove Wire Bend")
            return true
        }
        guard point.distance(to: start) > 1e-9 else { return false }
        let name: String
        switch handle {
        case .bend: name = "Move Wire Bend"
        case .insert: name = "Add Wire Bend"
        }
        model.perform(.replace([.wire(Self.edited(original, handle, to: point))]), actionName: name)
        return true
    }

    func cancel() {
        original = nil
        handle = nil
    }

    private func target(_ world: Vec2) -> Vec2 {
        let p = start + (world - grab)
        return snapsToGrid ? snap(p, grid: ShapeController.gridSize) : p
    }

    private static func edited(_ w: Wire, _ handle: WireHandle, to p: Vec2) -> Wire {
        switch handle {
        case .bend(_, let i): w.movingBend(i, to: p)
        case .insert(_, let s): w.insertingBend(inSegment: s, at: p)
        }
    }

    private static func wire(_ id: ObjectID, in doc: SketchDocument) -> Wire? {
        for case .wire(let w) in doc.objects where w.id == id { return w }
        return nil
    }
}
