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
    /// Group member -> group id, for `body(of:)`.
    private let groupOf: [ObjectID: ObjectID]

    /// Connected set of bodies reachable from `object` through joints; nil when its body has no joint.
    public init?(containing object: ObjectID, in doc: SketchDocument) {
        self.init(containing: object, in: MechanismGraph(doc))
    }

    /// As `init(containing:in:)`, reusing a graph built once for several queries on one document.
    init?(containing object: ObjectID, in graph: MechanismGraph) {
        let start = graph.body(of: object)
        guard graph.jointsByBody[start] != nil else { return nil }

        var found: Set<ObjectID> = [start]
        var jointIDs = Set<ObjectID>()
        var frontier = [start]
        while let body = frontier.popLast() {
            for j in graph.jointsByBody[body] ?? [] where jointIDs.insert(j.id).inserted {
                for a in j.anchors {
                    let other = graph.body(of: a.object)
                    if found.insert(other).inserted { frontier.append(other) }
                }
            }
        }

        func firstIndex(_ body: ObjectID) -> Int {
            graph.members(of: body).compactMap { graph.order[$0] }.min() ?? Int.max
        }
        bodies = found.map { ($0, firstIndex($0)) }.sorted { $0.1 < $1.1 }.map(\.0)
        var hasGround = false
        joints = graph.doc.objects.compactMap { o in
            guard case .joint(let j) = o, jointIDs.contains(j.id) else { return nil }
            if j.grounded || j.kind == .fixed { hasGround = true }
            return j.id
        }
        hasGroundOrLock = hasGround
        groupOf = graph.groupOf
        membersByBody = carriedMembers(of: bodies, in: graph)
        objectIDs = membersByBody.values.reduce(into: []) { $0.formUnion($1) }
    }

    /// Members of `body` plus the parts it carries; empty for a body not in the mechanism.
    public func members(of body: ObjectID) -> Set<ObjectID> { membersByBody[body] ?? [] }

    /// The body `object` belongs to (as `bodyID(of:in:)` for the mechanism's document).
    func body(of object: ObjectID) -> ObjectID { groupOf[object] ?? object }
}

/// Joint connectivity of one document, built once (O(document)) so several mechanism queries share it.
struct MechanismGraph {
    let doc: SketchDocument
    /// Group member -> group id (first group listing it, as `bodyID(of:in:)`).
    let groupOf: [ObjectID: ObjectID]
    /// Group id -> members (first group with that id, as `bodyMembers(_:in:)`).
    private let groupMembers: [ObjectID: [ObjectID]]
    /// Joints anchoring each body (once per joint).
    let jointsByBody: [ObjectID: [Joint]]
    /// Object id -> document index.
    let order: [ObjectID: Int]
    let carrier: PlugCarrier

    init(_ doc: SketchDocument) {
        self.doc = doc
        var groupOf: [ObjectID: ObjectID] = [:]
        var groupMembers: [ObjectID: [ObjectID]] = [:]
        for g in doc.groups {
            if groupMembers[g.id] == nil { groupMembers[g.id] = g.members }
            for m in g.members where groupOf[m] == nil { groupOf[m] = g.id }
        }
        self.groupOf = groupOf
        self.groupMembers = groupMembers
        var jointsByBody: [ObjectID: [Joint]] = [:]
        var order: [ObjectID: Int] = [:]
        for (i, o) in doc.objects.enumerated() {
            order[o.id] = i
            guard case .joint(let j) = o else { continue }
            var seen = Set<ObjectID>()
            for a in j.anchors {
                let body = groupOf[a.object] ?? a.object
                if seen.insert(body).inserted { jointsByBody[body, default: []].append(j) }
            }
        }
        self.jointsByBody = jointsByBody
        self.order = order
        carrier = PlugCarrier(doc)
    }

    func body(of object: ObjectID) -> ObjectID { groupOf[object] ?? object }
    func members(of body: ObjectID) -> [ObjectID] { groupMembers[body] ?? [body] }
}

/// Each body's members plus what it carries (`PlugCarrier`, as a free move): parts plugged into them
/// (transitively), each with its whole group. A pinned part or group is never carried (a mechanism body, or held by
/// its pin), nor is what is plugged only into it. A carried object rides with the first body reaching it.
private func carriedMembers(of bodies: [ObjectID], in graph: MechanismGraph) -> [ObjectID: Set<ObjectID>] {
    var taken = Set<ObjectID>()
    var result: [ObjectID: Set<ObjectID>] = [:]
    for body in bodies {
        let own = Set(graph.members(of: body))
        let members = own.union(graph.carrier.carried(by: own).subtracting(taken))
        taken.formUnion(members)
        result[body] = members
    }
    return result
}

/// Mechanisms touched by `ids` (through body members, and through joints in `ids`), with the graph they were
/// found in; connectivity is built once for all seeds.
private func touchedMechanisms(_ ids: Set<ObjectID>, in doc: SketchDocument) -> (MechanismGraph, [Mechanism]) {
    let graph = MechanismGraph(doc)
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
        guard let m = Mechanism(containing: id, in: graph) else { continue }
        result.append(m)
        covered.formUnion(m.objectIDs)
    }
    return (graph, result)
}

/// True when `ids` holds every body member and every joint of each mechanism it touches (then it moves freely as
/// one piece). Carried plugged parts need not be in `ids`: a free move carries them anyway.
public func selectionCoversWholeMechanisms(_ ids: Set<ObjectID>, in doc: SketchDocument) -> Bool {
    let (graph, mechanisms) = touchedMechanisms(ids, in: doc)
    return mechanisms.allSatisfy { m in
        m.joints.allSatisfy(ids.contains) && m.bodies.allSatisfy { graph.members(of: $0).allSatisfy(ids.contains) }
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
