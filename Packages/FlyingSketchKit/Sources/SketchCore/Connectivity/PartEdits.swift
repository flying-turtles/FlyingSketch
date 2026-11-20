private func partsByID(_ doc: SketchDocument) -> [ObjectID: PartInstance] {
    var result: [ObjectID: PartInstance] = [:]
    for case .part(let p) in doc.objects { result[p.id] = p }
    return result
}

/// Syncs both ends of `wire` to `parts`: attached end -> connector position; missing part/definition/connector
/// -> attachment cleared, position kept.
private func reconciled(_ wire: Wire, parts: [ObjectID: PartInstance], doc: SketchDocument) -> Wire {
    func fix(_ end: WireEnd) -> WireEnd {
        guard case .connector(let partID, let connector)? = end.attachment else { return end }
        guard let p = parts[partID], let def = doc.parts[p.definitionKey],
              let pos = connectorPositions(p, def)[connector] else {
            return WireEnd(position: end.position, attachment: nil)
        }
        return WireEnd(position: pos, attachment: end.attachment)
    }
    var w = wire
    w.start = fix(wire.start)
    w.end = fix(wire.end)
    return w
}

private func attached(_ end: WireEnd, toAnyOf ids: Set<ObjectID>) -> Bool {
    if case .connector(let part, _)? = end.attachment { return ids.contains(part) }
    return false
}

/// Moves parts by `delta`. Returns replaced part instances (a leg end stays put when plugged into a part
/// outside `ids`) plus every wire whose attached connector actually moved (end positions updated). Wires listed in `ids`
/// also shift their free ends and bends. Parts in `rigid` (directly dragged) never pin legs: they move whole and
/// unplug.
public func moveParts(_ ids: Set<ObjectID>, by delta: Vec2, in doc: SketchDocument,
                      rigid: Set<ObjectID> = []) -> [SceneObject] {
    let old = partsByID(doc)
    var pluggedTo: [ConnectorRef: Set<ObjectID>] = [:]
    for c in contacts(in: doc) where ids.contains(c.male.part) { pluggedTo[c.male, default: []].insert(c.female.part) }
    var moved: [ObjectID: PartInstance] = [:]
    for id in ids {
        guard var p = old[id], let def = doc.parts[p.definitionKey] else { continue }
        let current = connectorPositions(p, def)
        p.center = p.center + delta
        for c in def.connectors where c.leg != nil {
            let pinned = !rigid.contains(id)
                && (pluggedTo[ConnectorRef(part: id, connector: c.id)]?.contains { !ids.contains($0) } ?? false)
            if pinned {
                p.legEnds[c.id] = current[c.id]
            } else if let end = p.legEnds[c.id] {
                p.legEnds[c.id] = end + delta
            }
        }
        moved[id] = p
    }
    var result: [SceneObject] = doc.objects.compactMap { o in
        guard case .part(let p) = o, let m = moved[p.id] else { return nil }
        return .part(m)
    }
    let merged = old.merging(moved) { _, new in new }
    let movedIDs = Set(moved.keys)
    for case .wire(var w) in doc.objects {
        let own = ids.contains(w.id)
        guard own || attached(w.start, toAnyOf: movedIDs) || attached(w.end, toAnyOf: movedIDs) else { continue }
        let original = w
        if own {
            w.bends = w.bends.map { $0 + delta }
            if w.start.attachment == nil { w.start.position = w.start.position + delta }
            if w.end.attachment == nil { w.end.position = w.end.position + delta }
        }
        let fixed = reconciled(w, parts: merged, doc: doc)
        if fixed != original { result.append(.wire(fixed)) }
    }
    return result
}

/// Rotates one part a quarter turn: legs reset to default ends, attached wire ends follow.
public func rotatePart(_ id: ObjectID, clockwise: Bool, in doc: SketchDocument) -> [SceneObject] {
    guard var p = partsByID(doc)[id] else { return [] }
    p.rotation = normalizedAngle(p.rotation + (clockwise ? .pi / 2 : -.pi / 2))
    p.legEnds = [:]
    var result: [SceneObject] = [.part(p)]
    let parts = partsByID(doc).merging([id: p]) { _, new in new }
    for case .wire(let w) in doc.objects where attached(w.start, toAnyOf: [id]) || attached(w.end, toAnyOf: [id]) {
        result.append(.wire(reconciled(w, parts: parts, doc: doc)))
    }
    return result
}

/// Parts to remove plus wires detached from them (attachment cleared, position unchanged).
public func removeParts(_ ids: Set<ObjectID>, in doc: SketchDocument) -> (removed: Set<ObjectID>, detachedWires: [SceneObject]) {
    let removed = Set(partsByID(doc).keys).intersection(ids)
    var wires: [SceneObject] = []
    for case .wire(var w) in doc.objects {
        var changed = false
        if attached(w.start, toAnyOf: removed) { w.start.attachment = nil; changed = true }
        if attached(w.end, toAnyOf: removed) { w.end.attachment = nil; changed = true }
        if changed { wires.append(.wire(w)) }
    }
    return (removed, wires)
}

/// Wires whose attached connector moved or vanished: position updated or attachment cleared.
public func reconcileWires(in doc: SketchDocument) -> [SceneObject] {
    let parts = partsByID(doc)
    var result: [SceneObject] = []
    for case .wire(let w) in doc.objects {
        let fixed = reconciled(w, parts: parts, doc: doc)
        if fixed != w { result.append(.wire(fixed)) }
    }
    return result
}

/// Edits that delete `ids` as one action: wires attached to removed parts (and not removed themselves) are
/// detached (attachment cleared, position kept), then everything in `ids` is removed. Empty when nothing to do.
public func deletionEdits(_ ids: Set<ObjectID>, in doc: SketchDocument) -> [SceneEdit] {
    let existing = ids.intersection(doc.objects.map(\.id))
    guard !existing.isEmpty else { return [] }
    let detached = removeParts(existing, in: doc).detachedWires.filter { !existing.contains($0.id) }
    return (detached.isEmpty ? [] : [.replace(detached)]) + [.remove(existing)]
}
