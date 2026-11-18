import Foundation
import SketchCore

/// Wire tool session model. A wire is built across several touches: `begin` -> (`moveRubberBand`)* -> on lift either
/// `finish` (over a connector) or `addBend` (session stays open; the next touch continues from the last point).
/// Separately, an existing wire end can be dragged (`beginEndDrag` ...). Edits: "Add Wire", "Move Wire End".
final class WireController {
    /// Connector hit radius (mm): at least 0.8 mm, at least 12 pt on screen.
    static func hitRadius(zoom: Double) -> Double {
        max(0.8, 12 / (Viewport.pointsPerMillimetre * zoom))
    }

    private let model: DocumentModel
    private let candidates: ((Rect) -> [SceneObject])?

    /// Colour of the wire being drawn; set before `begin`.
    var color: RGBAColor = .black

    // MARK: Draw session

    private var points: [Vec2] = []
    private var startAttachment: ConnectorRef?
    private var base: (objects: [SceneObject], parts: [String: PartDefinition])?
    private(set) var isOpen = false
    /// Placed points (start, bends) of the open wire.
    var openPoints: [Vec2] { points }
    var lastPoint: Vec2? { points.last }

    // MARK: End drag

    private struct EndDrag {
        var original: Wire
        var isStart: Bool
        var engaged = false
    }
    private var endDrag: EndDrag?
    /// Travel (mm) before an end drag engages; below it a release is a tap and edits nothing.
    var dragSlop = 0.0
    var isDraggingEnd: Bool { endDrag != nil }

    /// `candidates` returns objects intersecting a world rect (the renderer's spatial index); defaults to a
    /// scan of the document.
    init(model: DocumentModel, candidates: ((Rect) -> [SceneObject])? = nil) {
        self.model = model
        self.candidates = candidates
    }

    // MARK: Lookup

    private func objects(near p: Vec2, radius: Double) -> [SceneObject] {
        let rect = Rect(origin: p - Vec2(x: radius, y: radius), size: Vec2(x: 2 * radius, y: 2 * radius))
        if let candidates { return candidates(rect) }
        let doc = model.document
        return doc.objects.filter { bounds(of: $0, in: doc).intersects(rect) }
    }

    /// Nearest connector within `radius`; ties go to the earlier part (z-order), then declaration order.
    func connector(near world: Vec2, radius: Double) -> (ConnectorRef, Vec2)? {
        var best: (ConnectorRef, Vec2)?
        var bestDistance = Double.infinity
        for case .part(let p) in objects(near: world, radius: radius) {
            guard let def = model.document.parts[p.definitionKey] else { continue }
            let positions = connectorPositions(p, def)
            for c in def.connectors {
                guard let pos = positions[c.id] else { continue }
                let d = pos.distance(to: world)
                if d <= radius, d < bestDistance {
                    bestDistance = d
                    best = (ConnectorRef(part: p.id, connector: c.id), pos)
                }
            }
        }
        return best
    }

    // MARK: Draw

    func begin(at world: Vec2, radius: Double) {
        cancel()
        if let (ref, pos) = connector(near: world, radius: radius) {
            points = [pos]
            startAttachment = ref
        } else {
            points = [world]
            startAttachment = nil
        }
        base = (model.document.objects, model.document.parts)
        isOpen = true
    }

    func addBend(at world: Vec2) {
        guard isOpen, let last = points.last, last.distance(to: world) > 1e-9 else { return }
        points.append(world)
    }

    /// Preview polyline: placed points plus the moving end.
    func moveRubberBand(to world: Vec2) -> [Vec2] { points + [world] }

    /// Ends the wire at `world` (snapped to a connector within `radius`). Closes the session whether or not a wire
    /// is inserted. No edit for fewer than 2 distinct points, or when both ends sit on the same connector.
    @discardableResult
    func finish(at world: Vec2, radius: Double) -> Bool {
        guard isOpen else { return false }
        if let (ref, pos) = connector(near: world, radius: radius) {
            return commit(WireEnd(position: pos, attachment: .connector(part: ref.part, connector: ref.connector)))
        }
        return commit(WireEnd(position: world))
    }

    /// Ends the open wire free at its last point.
    @discardableResult
    func finishFree() -> Bool {
        guard isOpen, let last = points.last else { return false }
        return commit(WireEnd(position: last))
    }

    func cancel() {
        points = []
        startAttachment = nil
        base = nil
        isOpen = false
        endDrag = nil
    }

    private func commit(_ end: WireEnd) -> Bool {
        var polyline: [Vec2] = []
        for p in points + [end.position] where polyline.last.map({ $0.distance(to: p) > 1e-9 }) ?? true {
            polyline.append(p)
        }
        let start = WireEnd(position: polyline.first ?? end.position,
                            attachment: startAttachment.map { .connector(part: $0.part, connector: $0.connector) })
        let rejected = start.attachment != nil && start.attachment == end.attachment
        cancel()
        guard polyline.count >= 2, !rejected else { return false }
        let wire = Wire(start: start, end: WireEnd(position: polyline.last!, attachment: end.attachment),
                        bends: Array(polyline.dropFirst().dropLast()), color: color)
        model.perform(.insert([.wire(wire)], at: nil), actionName: "Add Wire")
        return true
    }

    /// Wire for displaying `polyline` (>= 2 points) in the draw colour; nil when too short.
    func previewWire(_ polyline: [Vec2]) -> Wire? {
        guard polyline.count >= 2 else { return nil }
        return Wire(start: WireEnd(position: polyline[0], attachment: startAttachment.map {
                        .connector(part: $0.part, connector: $0.connector) }),
                    end: WireEnd(position: polyline[polyline.count - 1]),
                    bends: Array(polyline.dropFirst().dropLast()), color: color)
    }

    /// A document change from outside the session (undo, another tool) cancels the open wire / end drag.
    /// Returns whether something was cancelled.
    @discardableResult
    func documentDidChange(_ doc: SketchDocument) -> Bool {
        guard isOpen || endDrag != nil else { return false }
        if let base, doc.objects == base.objects, doc.parts == base.parts { return false }
        cancel()
        return true
    }

    // MARK: End drag

    /// Nearest wire end (not bend) within `radius`; ties go to the topmost wire, then start before end.
    func end(near world: Vec2, radius: Double) -> (wire: Wire, isStart: Bool)? {
        var best: (wire: Wire, isStart: Bool)?
        var bestDistance = Double.infinity
        for case .wire(let w) in objects(near: world, radius: radius).reversed() {
            for (end, isStart) in [(w.start, true), (w.end, false)] {
                let d = end.position.distance(to: world)
                if d <= radius, d < bestDistance {
                    bestDistance = d
                    best = (w, isStart)
                }
            }
        }
        return best
    }

    /// Starts dragging the wire end under `world`. False when none.
    @discardableResult
    func beginEndDrag(at world: Vec2, radius: Double) -> Bool {
        guard let hit = end(near: world, radius: radius) else { return false }
        cancel()
        base = (model.document.objects, model.document.parts)
        endDrag = EndDrag(original: hit.wire, isStart: hit.isStart)
        return true
    }

    private enum Target { case free, snap(ConnectorRef, Vec2), rejected }

    private func target(_ world: Vec2, radius: Double, other: WireEnd) -> Target {
        guard let (ref, pos) = connector(near: world, radius: radius) else { return .free }
        if other.attachment == .connector(part: ref.part, connector: ref.connector) { return .rejected }
        return .snap(ref, pos)
    }

    private func moved(_ drag: EndDrag, to world: Vec2, radius: Double) -> Wire? {
        var w = drag.original
        let other = drag.isStart ? w.end : w.start
        let new: WireEnd
        switch target(world, radius: radius, other: other) {
        case .free: new = WireEnd(position: world)
        case .snap(let ref, let pos): new = WireEnd(position: pos, attachment: .connector(part: ref.part, connector: ref.connector))
        case .rejected: return nil
        }
        if drag.isStart { w.start = new } else { w.end = new }
        return w
    }

    /// Wire as it would look if released at `world` (snapped to a connector in range); nil when no drag.
    func moveEndDrag(to world: Vec2, radius: Double) -> Wire? {
        guard var drag = endDrag else { return nil }
        let origin = drag.isStart ? drag.original.start.position : drag.original.end.position
        if world.distance(to: origin) > dragSlop { drag.engaged = true }
        endDrag = drag
        guard drag.engaged else { return drag.original }
        return moved(drag, to: world, radius: radius) ?? {
            var w = drag.original // dropping on the other end's connector: shown free, committed as no edit
            if drag.isStart { w.start = WireEnd(position: world) } else { w.end = WireEnd(position: world) }
            return w
        }()
    }

    /// Releases at `world`: over a connector attaches (position = connector), elsewhere detaches (position =
    /// release point). One edit "Move Wire End"; none for a tap or when it would join a wire's two ends.
    @discardableResult
    func finishEndDrag(at world: Vec2, radius: Double) -> Bool {
        guard let drag = endDrag else { return false }
        cancel()
        guard drag.engaged || world.distance(to: (drag.isStart ? drag.original.start : drag.original.end).position) > dragSlop,
              let wire = moved(drag, to: world, radius: radius) else { return false }
        model.perform(.replace([.wire(wire)]), actionName: "Move Wire End")
        return true
    }

    func cancelEndDrag() { endDrag = nil; if !isOpen { base = nil } }
}
