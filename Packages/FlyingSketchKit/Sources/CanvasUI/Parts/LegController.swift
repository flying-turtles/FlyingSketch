import SketchCore

/// Drags one leg end of a part. `move` returns preview geometry (the part plus attached wires); `end` snaps the
/// leg to a female within 1.0 mm on a different part and commits one "Bend Leg" edit.
final class LegController {
    private let model: DocumentModel
    private var part: ObjectID?
    private var connector = ""
    private var startEnd = Vec2.zero
    private var current = Vec2.zero
    /// Releases closer than this (mm) to the original leg end make no edit.
    var minDistance = 0.0

    init(model: DocumentModel) { self.model = model }

    var isActive: Bool { part != nil }

    /// World position of a leg end, nil if `part`/`connector` has no leg.
    static func legEnd(part id: ObjectID, connector: String, in doc: SketchDocument) -> Vec2? {
        guard case .part(let p)? = doc.objects.first(where: { $0.id == id }), let def = doc.parts[p.definitionKey],
              let c = def.connectors.first(where: { $0.id == connector }), c.leg != nil else { return nil }
        return connectorPositions(p, def)[connector]
    }

    func begin(part id: ObjectID, connector: String) {
        guard let end = Self.legEnd(part: id, connector: connector, in: model.document) else { return }
        part = id
        self.connector = connector
        startEnd = end
        current = end
    }

    /// Previews the leg at `world` (unsnapped): replacement objects for the part and its attached wires.
    @discardableResult
    func move(to world: Vec2) -> [SceneObject] {
        guard let id = part else { return [] }
        current = world
        return Self.bent(id, connector, to: world, in: model.document)
    }

    func end() {
        guard let id = part else { return }
        let doc = model.document
        let (leg, start, release) = (connector, startEnd, current)
        let target = nearestFemale(to: release, in: doc, excluding: id)?.position ?? release
        cancel()
        guard release.distance(to: start) >= minDistance, target.distance(to: start) > 1e-9 else { return }
        model.perform(.replace(Self.bent(id, leg, to: target, in: doc)), actionName: "Bend Leg")
    }

    func cancel() {
        part = nil
        connector = ""
    }

    /// The part with leg `connector` ending at `world`, plus every wire attached to the part re-pathed.
    private static func bent(_ id: ObjectID, _ connector: String, to world: Vec2, in doc: SketchDocument) -> [SceneObject] {
        guard case .part(var p)? = doc.objects.first(where: { $0.id == id }) else { return [] }
        p.legEnds[connector] = world
        var working = doc
        _ = SceneEdit.replace([.part(p)]).apply(to: &working)
        var result: [SceneObject] = [.part(p)]
        for case .wire(let w) in reconcileWires(in: working) {
            if case .connector(let a, _)? = w.start.attachment, a == id { result.append(.wire(w)); continue }
            if case .connector(let a, _)? = w.end.attachment, a == id { result.append(.wire(w)) }
        }
        return result
    }
}
