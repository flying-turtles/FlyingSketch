/// Pure edit builders for creating and changing joints and groups. Each result is ONE undo step, `[]` when there
/// is nothing to do, and leaves a document for which `jointIntegrityEdits(in:)` is `[]`.

/// `edits` followed by the integrity edits of the document they produce.
private func withIntegrity(_ edits: [SceneEdit], in doc: SketchDocument) -> [SceneEdit] {
    var after = doc
    for edit in edits { _ = edit.apply(to: &after) }
    return edits + jointIntegrityEdits(in: after)
}

private func isBody(_ o: SceneObject) -> Bool {
    switch o {
    case .wire, .joint: false
    default: true
    }
}

/// `under`: non-wire, non-joint objects hit at `point`, bottom to top. Joins their bodies on one hinge at
/// `point`; exactly one body -> grounded hinge; none -> []. A hinge already at `point` gains the missing bodies
/// (nothing missing -> []).
public func pinEdits(at point: Vec2, under objects: [ObjectID], in doc: SketchDocument) -> [SceneEdit] {
    let usable = Set(doc.objects.filter(isBody).map(\.id))
    var seen = Set<ObjectID>()
    let anchors = objects.filter { usable.contains($0) && seen.insert(bodyID(of: $0, in: doc)).inserted }
        .map { JointAnchor(object: $0, point: point) }
    guard !anchors.isEmpty else { return [] }
    // A hinge already sits here: complete it instead of stacking a second one.
    for case .joint(var existing) in doc.objects where existing.kind == .hinge && existing.position.distance(to: point) < 1e-6 {
        let held = Set(existing.anchors.map { bodyID(of: $0.object, in: doc) })
        let missing = anchors.filter { !held.contains(bodyID(of: $0.object, in: doc)) }
        guard !missing.isEmpty else { return [] }
        existing.anchors += missing
        return withIntegrity([.replace([.joint(existing)])], in: doc)
    }
    let joint = Joint(kind: .hinge, position: point, anchors: anchors, grounded: anchors.count == 1)
    return withIntegrity([.insert([.joint(joint)], at: nil)], in: doc)
}

/// Flips `grounded` of a hinge; ungrounding a hinge left with a single anchor removes it. Fixed joints: `[]`.
public func toggleGroundEdits(joint id: ObjectID, in doc: SketchDocument) -> [SceneEdit] {
    guard case .joint(var j)? = doc.objects.first(where: { $0.id == id }), j.kind == .hinge else { return [] }
    j.grounded.toggle()
    return withIntegrity([.replace([.joint(j)])], in: doc)
}

/// Adds a `fixed` joint at the body's bounds centre, or removes the body's fixed joint when it has one.
public func toggleLockEdits(object: ObjectID, in doc: SketchDocument) -> [SceneEdit] {
    guard let target = doc.objects.first(where: { $0.id == object }), isBody(target) else { return [] }
    let members = bodyMembers(bodyID(of: object, in: doc), in: doc)
    let existing = doc.objects.compactMap { o -> ObjectID? in
        guard case .joint(let j) = o, j.kind == .fixed, j.anchors.contains(where: { members.contains($0.object) })
        else { return nil }
        return j.id
    }
    if !existing.isEmpty { return withIntegrity([.remove(Set(existing))], in: doc) }
    let rects = doc.objects.filter { members.contains($0.id) }.map { bounds(of: $0, in: doc) }
    guard let box = rects.dropFirst().reduce(rects.first, { $0?.union($1) }) else { return [] }
    let centre = Vec2(x: box.minX + box.size.x / 2, y: box.minY + box.size.y / 2)
    let joint = Joint(kind: .fixed, position: centre, anchors: [JointAnchor(object: object, point: centre)], grounded: true)
    return withIntegrity([.insert([.joint(joint)], at: nil)], in: doc)
}

/// Merges `ids` (and every group they belong to) into one flat group; wires and joints ignored; < 2 objects, or a
/// selection inside one existing group, -> [].
public func groupEdits(_ ids: Set<ObjectID>, in doc: SketchDocument) -> [SceneEdit] {
    let selected = Set(doc.objects.filter { isBody($0) && ids.contains($0.id) }.map(\.id))
    guard !selected.isEmpty else { return [] }
    let touched = doc.groups.filter { g in g.members.contains { selected.contains($0) } }
    let merged = selected.union(touched.flatMap(\.members))
    let members = doc.objects.map(\.id).filter(merged.contains)
    guard members.count >= 2 else { return [] }
    if touched.count == 1, Set(touched[0].members) == merged { return [] } // already one group
    let touchedIDs = Set(touched.map(\.id))
    let groups = doc.groups.filter { !touchedIDs.contains($0.id) } + [ObjectGroup(members: members)]
    return withIntegrity([.setGroups(groups)], in: doc)
}

/// Dissolves `group`; each joint anchor on a former member moves to the topmost former member at its point, or is
/// dropped when none is there. A `fixed` joint stays on its anchor object (that object alone stays locked).
/// `objectsAt`: objects hit at a point, bottom to top (the canvas supplies hit-testing).
public func ungroupEdits(group id: ObjectID, objectsAt: (Vec2) -> [ObjectID], in doc: SketchDocument) -> [SceneEdit] {
    guard let group = doc.groups.first(where: { $0.id == id }) else { return [] }
    let members = Set(group.members)
    var replaced: [SceneObject] = []
    for case .joint(var j) in doc.objects where j.kind == .hinge && j.anchors.contains(where: { members.contains($0.object) }) {
        j.anchors = j.anchors.compactMap { a in
            guard members.contains(a.object) else { return a }
            guard let top = objectsAt(a.point).last(where: members.contains) else { return nil }
            return JointAnchor(object: top, point: a.point)
        }
        replaced.append(.joint(j))
    }
    let edits: [SceneEdit] = (replaced.isEmpty ? [] : [.replace(replaced)]) + [.setGroups(doc.groups.filter { $0.id != id })]
    return withIntegrity(edits, in: doc)
}
