private func partsByID(_ doc: SketchDocument) -> [ObjectID: PartInstance] {
    var result: [ObjectID: PartInstance] = [:]
    for case .part(let p) in doc.objects { result[p.id] = p }
    return result
}

/// Syncs both ends of `wire` to `parts`: attached end -> connector position; missing part/definition/connector
/// -> attachment cleared, position kept.
private func reconciled(_ wire: Wire, parts: [ObjectID: PartInstance], doc: SketchDocument) -> Wire {
    reconciledWire(wire, parts: parts, definitions: doc.parts)
}

/// `wire` with both ends synced to `parts` (which must hold every part it attaches to): attached end -> connector
/// position; missing part/definition/connector -> attachment cleared, position kept.
public func reconciledWire(_ wire: Wire, parts: [ObjectID: PartInstance],
                           definitions: [String: PartDefinition]) -> Wire {
    func fix(_ end: WireEnd) -> WireEnd {
        guard case .connector(let partID, let connector)? = end.attachment else { return end }
        guard let p = parts[partID], let def = definitions[p.definitionKey],
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

/// Where the male connectors of moving parts are plugged, for deciding which leg ends hold during a move. Shared
/// by free part moves (`moveParts`) and mechanism drags so both treat legs the same way.
public struct LegPlugs: Sendable {
    private let pluggedTo: [ConnectorRef: Set<ObjectID>]

    /// Contacts of the male connectors of `parts`.
    public init(_ parts: Set<ObjectID>, in doc: SketchDocument) {
        var pluggedTo: [ConnectorRef: Set<ObjectID>] = [:]
        for c in contacts(in: doc) where parts.contains(c.male.part) { pluggedTo[c.male, default: []].insert(c.female.part) }
        self.pluggedTo = pluggedTo
    }

    /// Parts whose female `ref` is plugged into.
    public func females(of ref: ConnectorRef) -> Set<ObjectID> { pluggedTo[ref] ?? [] }

    /// True when the leg end of `ref` is plugged into a part outside `moving`: it keeps its end and the leg
    /// stretches.
    public func holds(_ ref: ConnectorRef, moving: Set<ObjectID>) -> Bool {
        pluggedTo[ref]?.contains { !moving.contains($0) } ?? false
    }
}

/// Moves parts by `delta`. Returns replaced part instances (a leg end stays put when plugged into a part
/// outside `ids`) plus every wire whose attached connector actually moved (end positions updated). Wires listed in `ids`
/// also shift their free ends and bends. Parts in `rigid` (directly dragged) never pin legs: they move whole and
/// unplug.
public func moveParts(_ ids: Set<ObjectID>, by delta: Vec2, in doc: SketchDocument,
                      rigid: Set<ObjectID> = []) -> [SceneObject] {
    let old = partsByID(doc)
    let plugs = LegPlugs(ids, in: doc)
    var moved: [ObjectID: PartInstance] = [:]
    for id in ids {
        guard var p = old[id], let def = doc.parts[p.definitionKey] else { continue }
        let current = connectorPositions(p, def)
        p.center = p.center + delta
        for c in def.connectors where c.leg != nil {
            let pinned = !rigid.contains(id) && plugs.holds(ConnectorRef(part: id, connector: c.id), moving: ids)
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

/// Rotates `ids` (whole groups) about `pivot`. What a move would carry rotates too (`PlugCarrier`: plugged parts
/// with their whole group, never a pinned body); wires attached to a rotated part follow it (an attached end ends on
/// its connector); a wire with both ends on rotating parts also rotates its bends. Returns only changed objects;
/// `angle == 0` -> `[]`.
public func rotateObjects(_ ids: Set<ObjectID>, by angle: Double, around pivot: Vec2,
                          in doc: SketchDocument) -> [SceneObject] {
    guard angle != 0 else { return [] }
    let old = partsByID(doc)
    let partIDs = Set(old.keys)
    let spinning = ids.intersection(partIDs).union(PlugCarrier(doc).carried(by: ids))
    var result: [SceneObject] = []
    var rotatedParts = old
    var wires: [Wire] = []
    for o in doc.objects {
        let id = o.id
        if case .wire(let w) = o { wires.append(w) }
        guard ids.contains(id) || spinning.contains(id) else { continue }
        if case .wire = o { continue } // handled with the re-sync below
        let r = o.rotated(by: angle, around: pivot)
        guard r != o else { continue }
        result.append(r)
        if case .part(let p) = r { rotatedParts[id] = p }
    }
    for original in wires {
        let own = ids.contains(original.id)
        let startRides = attached(original.start, toAnyOf: spinning), endRides = attached(original.end, toAnyOf: spinning)
        guard own || startRides || endRides else { continue }
        var w = original
        if own, case .wire(let r) = SceneObject.wire(original).rotated(by: angle, around: pivot) {
            w = r
        } else if startRides && endRides {
            w.bends = w.bends.map { pivot + ($0 - pivot).rotated(by: angle) } // jumper rides rigidly with its parts
        }
        let fixed = reconciled(w, parts: rotatedParts, doc: doc)
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
/// detached (attachment cleared, position kept); joint anchors on removed group members move to the group's first
/// surviving member (point kept: pins and locks belong to the body and go only with its last object); then
/// everything in `ids` is removed, then joints and groups are repaired for what is left (`jointIntegrityEdits`).
/// Empty when nothing to do.
public func deletionEdits(_ ids: Set<ObjectID>, in doc: SketchDocument) -> [SceneEdit] {
    let existing = ids.intersection(doc.objects.map(\.id))
    guard !existing.isEmpty else { return [] }
    let detached = removeParts(existing, in: doc).detachedWires.filter { !existing.contains($0.id) }
    let rehomed = rehomedJoints(deleting: existing, in: doc)
    let edits: [SceneEdit] = (detached.isEmpty ? [] : [.replace(detached)]) + (rehomed.isEmpty ? [] : [.replace(rehomed)])
        + [.remove(existing)]
    var after = doc
    for edit in edits { _ = edit.apply(to: &after) }
    return edits + jointIntegrityEdits(in: after)
}

/// Surviving joints with anchors on deleted objects that are moved to the first surviving member of the object's
/// group (in the group's member order). Anchors on ungrouped objects, or on wholly deleted groups, are left for
/// the integrity pass to drop.
private func rehomedJoints(deleting ids: Set<ObjectID>, in doc: SketchDocument) -> [SceneObject] {
    var heir: [ObjectID: ObjectID] = [:]
    for g in doc.groups {
        guard let survivor = g.members.first(where: { !ids.contains($0) }) else { continue }
        for m in g.members where ids.contains(m) && heir[m] == nil { heir[m] = survivor }
    }
    guard !heir.isEmpty else { return [] }
    var result: [SceneObject] = []
    for case .joint(var j) in doc.objects where !ids.contains(j.id) {
        var changed = false
        for k in j.anchors.indices {
            if let to = heir[j.anchors[k].object] {
                j.anchors[k].object = to
                changed = true
            }
        }
        if changed { result.append(.joint(j)) }
    }
    return result
}
