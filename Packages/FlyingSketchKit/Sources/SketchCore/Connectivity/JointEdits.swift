/// Edits that make joints and groups consistent with the objects present: anchors on missing objects or wires
/// dropped; duplicate bodies within one joint collapsed to the first anchor; invalid joints removed; groups
/// lose missing members and wires, groups with < 2 members removed. Empty when already consistent.
public func jointIntegrityEdits(in doc: SketchDocument) -> [SceneEdit] {
    var wires = Set<ObjectID>()
    var present = Set<ObjectID>()
    for o in doc.objects {
        present.insert(o.id)
        if case .wire = o { wires.insert(o.id) }
    }
    func usable(_ id: ObjectID) -> Bool { present.contains(id) && !wires.contains(id) }

    let groups = doc.groups
        .map { ObjectGroup(id: $0.id, members: $0.members.filter(usable)) }
        .filter { $0.members.count >= 2 }
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
