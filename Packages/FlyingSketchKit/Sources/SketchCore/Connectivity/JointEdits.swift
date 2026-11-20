/// Edits that make joints and groups consistent with the objects present: anchors on missing objects, wires or
/// joints dropped; duplicate bodies within one joint collapsed to the first anchor; invalid joints removed; groups
/// lose missing, duplicate, wire and joint members, an object stays in the first group listing it, groups with
/// < 2 members removed. Joints are never bodies, so one call reaches a fixed point (a second returns `[]`).
public func jointIntegrityEdits(in doc: SketchDocument) -> [SceneEdit] {
    var bodies = Set<ObjectID>()
    for o in doc.objects {
        switch o {
        case .wire, .joint: break
        default: bodies.insert(o.id)
        }
    }
    func usable(_ id: ObjectID) -> Bool { bodies.contains(id) }

    var claimed = Set<ObjectID>()
    var groups: [ObjectGroup] = []
    for g in doc.groups {
        var seen = Set<ObjectID>()
        let members = g.members.filter { usable($0) && !claimed.contains($0) && seen.insert($0).inserted }
        guard members.count >= 2 else { continue }
        claimed.formUnion(members)
        groups.append(ObjectGroup(id: g.id, members: members))
    }
    var cleaned = doc
    cleaned.groups = groups

    var replaced: [SceneObject] = []
    var removed = Set<ObjectID>()
    for case .joint(let j) in doc.objects {
        var fixed = j
        var seen = Set<ObjectID>()
        fixed.anchors = j.anchors.filter { usable($0.object) && seen.insert(bodyID(of: $0.object, in: cleaned)).inserted }
        let valid: Bool
        switch j.kind {
        case .hinge: valid = fixed.anchors.count >= 2 || (fixed.anchors.count == 1 && j.grounded)
        case .fixed: valid = fixed.anchors.count == 1 && j.grounded
        }
        if !valid { removed.insert(j.id) } else if fixed != j { replaced.append(.joint(fixed)) }
    }

    var edits: [SceneEdit] = []
    if !replaced.isEmpty { edits.append(.replace(replaced)) }
    if !removed.isEmpty { edits.append(.remove(removed)) }
    if groups != doc.groups { edits.append(.setGroups(groups)) }
    return edits
}
