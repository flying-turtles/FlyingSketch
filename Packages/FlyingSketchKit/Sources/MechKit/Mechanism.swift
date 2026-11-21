import SketchCore

/// Bodies connected through joints, as found in a document. A body is a group, or an object in no group;
/// wires and joints are never bodies.
public struct Mechanism: Sendable {
    /// Body ids, in document order of each body's first member.
    public var bodies: [ObjectID]
    /// Joints anchoring any of `bodies`, in document order.
    public var joints: [ObjectID]
    /// Every object that moves with the mechanism: body members plus carried plugged parts.
    public var objectIDs: Set<ObjectID>
    /// Any joint grounded or a lock.
    public var hasGroundOrLock: Bool
    private var membersByBody: [ObjectID: Set<ObjectID>]

    /// Connected set of bodies reachable from `object` through joints; nil when its body has no joint.
    public init?(containing object: ObjectID, in doc: SketchDocument) {
        let start = bodyID(of: object, in: doc)
        var jointsByBody: [ObjectID: [Joint]] = [:]
        for case .joint(let j) in doc.objects {
            var seen = Set<ObjectID>()
            for a in j.anchors {
                let body = bodyID(of: a.object, in: doc)
                if seen.insert(body).inserted { jointsByBody[body, default: []].append(j) }
            }
        }
        guard jointsByBody[start] != nil else { return nil }

        var found: Set<ObjectID> = [start]
        var jointIDs = Set<ObjectID>()
        var frontier = [start]
        while let body = frontier.popLast() {
            for j in jointsByBody[body] ?? [] where jointIDs.insert(j.id).inserted {
                for a in j.anchors {
                    let other = bodyID(of: a.object, in: doc)
                    if found.insert(other).inserted { frontier.append(other) }
                }
            }
        }

        var order: [ObjectID: Int] = [:]
        for (i, o) in doc.objects.enumerated() { order[o.id] = i }
        func firstIndex(_ body: ObjectID) -> Int {
            bodyMembers(body, in: doc).compactMap { order[$0] }.min() ?? Int.max
        }
        bodies = found.map { ($0, firstIndex($0)) }.sorted { $0.1 < $1.1 }.map(\.0)
        var hasGround = false
        joints = doc.objects.compactMap { o in
            guard case .joint(let j) = o, jointIDs.contains(j.id) else { return nil }
            if j.grounded || j.kind == .fixed { hasGround = true }
            return j.id
        }
        hasGroundOrLock = hasGround
        membersByBody = carriedMembers(of: bodies, in: doc)
        objectIDs = membersByBody.values.reduce(into: []) { $0.formUnion($1) }
    }

    /// Members of `body` plus the parts it carries; empty for a body not in the mechanism.
    public func members(of body: ObjectID) -> Set<ObjectID> { membersByBody[body] ?? [] }
}

/// Each body's members plus what it carries (`PlugCarrier`, as a free move): parts plugged into them
/// (transitively), each with its whole group. A pinned part or group is never carried (a mechanism body, or held by
/// its pin), nor is what is plugged only into it. A carried object rides with the first body reaching it.
private func carriedMembers(of bodies: [ObjectID], in doc: SketchDocument) -> [ObjectID: Set<ObjectID>] {
    let carrier = PlugCarrier(doc)
    var taken = Set<ObjectID>()
    var result: [ObjectID: Set<ObjectID>] = [:]
    for body in bodies {
        let own = Set(bodyMembers(body, in: doc))
        let members = own.union(carrier.carried(by: own).subtracting(taken))
        taken.formUnion(members)
        result[body] = members
    }
    return result
}

/// Mechanisms touched by `ids`: through body members, and through joints in `ids`.
private func touchedMechanisms(_ ids: Set<ObjectID>, in doc: SketchDocument) -> [Mechanism] {
    var seeds: [ObjectID] = []
    for o in doc.objects where ids.contains(o.id) {
        switch o {
        case .wire: break
        case .joint(let j): seeds += j.anchors.map(\.object)
        default: seeds.append(o.id)
        }
    }
    var covered = Set<ObjectID>()
    var result: [Mechanism] = []
    for id in seeds where !covered.contains(id) {
        guard let m = Mechanism(containing: id, in: doc) else { continue }
        result.append(m)
        covered.formUnion(m.objectIDs)
    }
    return result
}

/// True when `ids` holds every body member and every joint of each mechanism it touches (then it moves freely as
/// one piece). Carried plugged parts need not be in `ids`: a free move carries them anyway.
public func selectionCoversWholeMechanisms(_ ids: Set<ObjectID>, in doc: SketchDocument) -> Bool {
    touchedMechanisms(ids, in: doc).allSatisfy { m in
        m.joints.allSatisfy(ids.contains) && m.bodies.allSatisfy { bodyMembers($0, in: doc).allSatisfy(ids.contains) }
    }
}

/// True when rotating / free-moving `ids` would break a pin: a joint in `ids` has an anchor outside `ids` (the pin
/// would leave its body), a joint has an anchor inside and an anchor outside `ids`, or a grounded / fixed joint has
/// an anchor inside `ids` while the joint itself is not in `ids`.
public func selectionIsPinnedToOutside(_ ids: Set<ObjectID>, in doc: SketchDocument) -> Bool {
    for case .joint(let j) in doc.objects {
        let outside = j.anchors.contains { !ids.contains($0.object) }
        if outside, ids.contains(j.id) { return true }
        let inside = j.anchors.contains { ids.contains($0.object) }
        guard inside else { continue }
        if outside { return true }
        if (j.grounded || j.kind == .fixed) && !ids.contains(j.id) { return true }
    }
    return false
}
